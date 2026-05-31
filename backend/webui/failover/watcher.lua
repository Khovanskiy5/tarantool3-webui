--
-- Failover appointment watcher.
--
-- Runs on every instance. Polls
-- `<prefix>/failover/replicasets/<my-replicaset>/leader` in etcd,
-- compares the leader alias to its own name, and toggles
-- `box.cfg.read_only` accordingly.
--
-- Polling-based (not streaming) because the embedded etcd HTTP
-- client does not support gRPC watch streams. Default cadence is
-- 1s — fast enough that promotion happens within a couple of
-- seconds of the coordinator writing an appointment, and slow
-- enough that the etcd load is negligible (one GET per second
-- per instance).
--
-- The watcher writes through `box.cfg` directly. That means it
-- ONLY works when `replication.failover` is `off` — otherwise
-- Tarantool's own failover loops re-apply read_only on every
-- election and stomp our value. The role validator enforces this
-- and refuses to start the watcher if the mode conflicts.
--

local fiber = require('fiber')
local json  = require('json')

local etcd_client = require('webui.config_store.client')
local log_util    = require('webui.log_util')
local logger      = log_util.with_tag('failover.watcher')

local M = {}

M.DEFAULTS = { poll_interval_sec = 1 }
M.KEY_APPOINTMENT = '/failover/replicasets/%s/leader'

local STATE = {
    enabled     = false,
    config      = nil,
    self_alias  = nil,
    replicaset  = nil,
    fiber       = nil,
    last_seen   = nil,    -- { leader, ts }
    last_applied = nil,   -- { read_only, ts }
    last_error  = nil,
    stop_flag   = false,
}

local function read_appointment(client)
    local key = string.format(M.KEY_APPOINTMENT, STATE.replicaset)
    local kv, err = client:get(key)
    if err ~= nil then return nil, err end
    if kv == nil then return nil end
    local ok, parsed = pcall(json.decode, kv.value)
    if not ok or type(parsed) ~= 'table' then return nil end
    return {
        leader = parsed.leader,
        ts     = tonumber(parsed.ts),
        coordinator = parsed.coordinator,
        revision = kv.revision,
    }
end

-- Determine whether we're "really" the leader from Tarantool's
-- perspective. `box.info.ro == false` alone is not enough — with
-- every instance declared `database.mode: rw` (required so the
-- config-applier does not stomp our box.ctl calls), all three
-- peers technically have ro=false. The single source of truth for
-- "who is the leader" is the synchronous-queue ownership: only
-- the owner can append to synchro spaces; everyone else either
-- waits (synchro_quorum) or hits `ro_reason='synchro'`.
--
-- An owner of 0 means NO ONE currently owns the queue — that is
-- the post-bootstrap state before the first box.ctl.promote()
-- claim. Treating "no owner" as "I am leader" was a bug: it
-- caused the watcher to skip the initial promote(), leaving
-- every peer in a quasi-RW state where the appointed leader had
-- never actually claimed the queue.
local function effectively_leader()
    if box.info.ro then return false end
    local synchro = box.info.synchro
    if synchro == nil or synchro.queue == nil then
        -- Old build without synchro info — fall back to the ro flag.
        return true
    end
    return synchro.queue.owner == box.info.id
end

local function apply_appointment(appt)
    if appt == nil then return end
    STATE.last_seen = appt
    local should_be_leader = (appt.leader == STATE.self_alias)
    local am_leader = effectively_leader()
    -- Skip if already in the right state. The guard considers both
    -- `box.cfg.read_only` AND synchro queue ownership so we do not
    -- spam `box.ctl.promote()` once per second on the steady
    -- leader.
    if should_be_leader and not am_leader then
        -- Two-step handoff. In Tarantool 3.x with
        -- `replication.failover: off`, `box.ctl.promote()` claims
        -- the synchronous queue but does NOT flip
        -- `box.cfg.read_only` on its own (verified empirically
        -- 2026-05-31: queue.owner moved to our id, ro stayed
        -- true). Cartridge's failover module does the same pair
        -- explicitly:
        --     box.cfg{ read_only = false }
        --     box.ctl.promote()
        -- The order matters: a RO peer cannot claim the queue.
        local rw_ok, rw_err = pcall(function()
            box.cfg({ read_only = false })
        end)
        if not rw_ok then
            STATE.last_error = 'read_only=false: ' .. tostring(rw_err)
            logger.error('failed to flip read_only before promote',
                { err = tostring(rw_err) })
        end
        local ok, err = pcall(box.ctl.promote)
        if ok then
            STATE.last_applied = { read_only = false, ts = fiber.time() }
            logger.info('promoted to leader by appointment',
                { coordinator = appt.coordinator, ts = appt.ts })
        else
            STATE.last_error = 'promote: ' .. tostring(err)
            logger.error('failed to apply promotion', { err = tostring(err) })
        end
    elseif not should_be_leader and am_leader then
        -- box.ctl.demote() releases the synchronous queue and
        -- flips `read_only` back to true. Mirror of promote().
        local ok, err = pcall(box.ctl.demote)
        if ok then
            STATE.last_applied = { read_only = true, ts = fiber.time() }
            logger.info('demoted to follower by appointment',
                { coordinator = appt.coordinator,
                  new_leader = appt.leader, ts = appt.ts })
        else
            STATE.last_error = 'demote: ' .. tostring(err)
            logger.error('failed to apply demotion', { err = tostring(err) })
        end
    end
end

local function loop()
    fiber.self():name('webui_failover_watch', { truncate = true })
    while not STATE.stop_flag do
        local client, err = etcd_client.get_client()
        if client == nil then
            STATE.last_error = 'etcd unavailable: ' .. tostring(err)
        else
            local appt, get_err = read_appointment(client)
            if get_err ~= nil then
                STATE.last_error = 'get: ' .. tostring(get_err)
            elseif appt == nil then
                -- No appointment yet — the coordinator hasn't
                -- written one. Wait quietly; do NOT clear
                -- last_error from a previous transient failure
                -- until we actually succeed at applying state.
                STATE.last_error = nil
            else
                STATE.last_error = nil
                local ok, ap_err = pcall(apply_appointment, appt)
                if not ok then
                    STATE.last_error = 'apply: ' .. tostring(ap_err)
                end
            end
        end
        fiber.sleep(STATE.config.poll_interval_sec)
    end
end

function M.start(opts)
    if STATE.enabled then return end
    opts = opts or {}
    STATE.config = {
        poll_interval_sec = tonumber(opts.poll_interval_sec)
            or M.DEFAULTS.poll_interval_sec,
    }
    STATE.self_alias = box.info.name
    STATE.replicaset = box.info.replicaset and box.info.replicaset.name
    if STATE.self_alias == nil or STATE.replicaset == nil then
        return nil, 'box.info.name / replicaset.name unavailable'
    end
    STATE.stop_flag = false
    STATE.enabled = true
    STATE.fiber = fiber.create(loop)
    logger.info('failover watcher started', {
        self = STATE.self_alias,
        replicaset = STATE.replicaset,
        interval_sec = STATE.config.poll_interval_sec,
    })
    return true
end

function M.stop()
    if not STATE.enabled then return end
    STATE.stop_flag = true
    STATE.enabled = false
    logger.info('failover watcher stop requested')
end

function M.status()
    return {
        enabled    = STATE.enabled,
        self_alias = STATE.self_alias,
        replicaset = STATE.replicaset,
        last_seen  = STATE.last_seen,
        last_applied = STATE.last_applied,
        last_error = STATE.last_error,
    }
end

function M._reset()
    STATE.enabled = false
    STATE.stop_flag = true
    STATE.last_seen = nil
    STATE.last_applied = nil
    STATE.last_error = nil
end

return M
