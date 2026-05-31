--
-- Failover coordinator (open-source `supervised`-equivalent).
--
-- One fiber per instance attempts to acquire an etcd lease on
-- `<prefix>/failover/coordinator`. Only the lease holder runs the
-- appointment loop — every other peer's fiber idles until the
-- current coordinator's lease expires.
--
-- The appointment loop walks every replicaset, probes its
-- instances over the existing `webui_peer` net.box pool, picks the
-- best candidate, and writes
-- `<prefix>/failover/replicasets/<rs>/leader` to etcd as plain
-- JSON. Each instance's watcher fiber (see `failover/watcher.lua`)
-- polls that key and calls `box.ctl.promote/demote` accordingly.
--
-- Safety guarantees (production hardening):
--   * **Election safety** — only one coordinator at a time. Lease
--     is bound to the coordinator key via etcd txn_create; lease
--     loss frees the key automatically (etcd evicts on TTL).
--   * **Appointment safety** — every appointment write is CAS-
--     bound to the coordinator key's mod_revision. A stale
--     coordinator that wakes up after its lease expired cannot
--     overwrite the new coordinator's appointments.
--   * **Hysteresis** — no leader change is published more often
--     than `min_promotion_interval` seconds, preventing flapping
--     on borderline-healthy candidates.
--   * **Fencing** — candidates are scored from a local view of
--     each peer's box.info; only `running` instances with bounded
--     replication lag qualify. Stale or orphan peers are rejected.
--   * **Idempotency** — appointment writes are skipped when the
--     payload hasn't changed; lease keepalive runs even when we
--     haven't observed a config change so the coordinator does
--     not silently lose ownership during quiet periods.
--   * **Error visibility** — last_error is cleared on every
--     successful iteration so a transient etcd blip does not
--     stick to the status panel forever.
--

local fiber = require('fiber')
local json  = require('json')
local math  = require('math')

local etcd_client = require('webui.config_store.client')
local log_util    = require('webui.log_util')
local logger      = log_util.with_tag('failover.agent')

local M = {}

-- Tunable defaults. Operators override via roles_cfg.webui.failover.
M.DEFAULTS = {
    lease_ttl_sec            = 10,
    keepalive_interval       = 3,
    election_interval        = 5,
    appointment_interval     = 2,
    probe_timeout_sec        = 1,
    -- Operational fencing:
    max_replication_lag_sec  = 5,   -- candidate's lag ceiling
    min_promotion_interval   = 10,  -- no two promotions within N seconds
    election_jitter_sec      = 1,   -- backoff jitter to avoid herd
}

M.KEY_COORDINATOR = '/failover/coordinator'
M.KEY_APPOINTMENT = '/failover/replicasets/%s/leader'

local STATE = {
    enabled              = false,
    config               = nil,
    self_alias           = nil,
    coordinator          = nil,
    is_coordinator       = false,
    lease_id             = nil,
    coordinator_revision = nil,    -- mod_revision of OUR coordinator key
    election_fiber       = nil,
    last_appointments    = {},
    last_error           = nil,
    last_promotion_at    = 0,
    stop_flag            = false,
}

local function clear_error()
    STATE.last_error = nil
end

local function set_error(msg)
    STATE.last_error = msg
end

local function self_payload(extra)
    local p = { alias = STATE.self_alias, ts = fiber.time() }
    if extra ~= nil then
        for k, v in pairs(extra) do p[k] = v end
    end
    return p
end

-- ─────────────────────────────────────────────────────────────────────
-- Etcd helpers
-- ─────────────────────────────────────────────────────────────────────

local function read_coordinator(client)
    local kv, err = client:get(M.KEY_COORDINATOR)
    if err ~= nil then return nil, err end
    if kv == nil then return nil end
    local ok, parsed = pcall(json.decode, kv.value)
    if not ok then return nil end
    return parsed, kv.revision
end

local function release_lease(client)
    if STATE.lease_id == nil then return end
    local lease_id = STATE.lease_id
    STATE.lease_id = nil
    STATE.coordinator_revision = nil
    STATE.is_coordinator = false
    if client ~= nil then
        pcall(function() return client:lease_revoke(lease_id) end)
    end
    logger.info('coordinator lease released', { lease_id = lease_id })
end

-- Try to become the coordinator. On success: STATE.is_coordinator
-- = true, STATE.lease_id holds the active lease,
-- STATE.coordinator_revision holds the mod_revision of OUR
-- coordinator key. Returns (true, nil) on success, (false, reason)
-- otherwise.
local function try_become_coordinator(client, ttl_sec)
    local lease, lease_err = client:lease_grant(ttl_sec)
    if lease == nil then return false, 'lease_grant: ' .. tostring(lease_err) end
    local payload = json.encode(self_payload({ ttl_sec = ttl_sec }))
    local result, txn_err = client:txn_create(M.KEY_COORDINATOR, payload, lease.id)
    if txn_err ~= nil then
        pcall(function() return client:lease_revoke(lease.id) end)
        return false, 'coordinator key held by another peer'
    end
    STATE.lease_id = lease.id
    STATE.is_coordinator = true
    STATE.coordinator = STATE.self_alias
    STATE.coordinator_revision = result.revision
    logger.info('became coordinator', {
        lease_id = lease.id, ttl = ttl_sec,
        revision = STATE.coordinator_revision,
    })
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- Candidate selection
-- ─────────────────────────────────────────────────────────────────────

-- Rank an instance for leadership. Higher = preferred. Pure over
-- the probe table for unit-testability. Fencing rules:
--   * unreachable          → disqualified
--   * not running           → disqualified
--   * orphan                → disqualified
--   * lag > ceiling         → disqualified (would risk lost commits)
-- Among qualified candidates, prefer:
--   * smallest replication lag (most caught up)
--   * already-RW instance (stability over flapping)
function M.score_candidate(probe, max_lag_sec)
    if probe == nil or not probe.reachable then return -math.huge end
    if probe.status ~= 'running' then return -math.huge end
    if probe.ro_reason == 'orphan' then return -math.huge end
    local lag = tonumber(probe.lag) or 0
    if lag < 0 then lag = 0 end
    if lag > (max_lag_sec or M.DEFAULTS.max_replication_lag_sec) then
        return -math.huge
    end
    local base = 1000 - lag
    if probe.ro == false then base = base + 50 end
    return base
end

local function probe_peer(conn)
    if conn == nil then return { reachable = false } end
    local ok, info = pcall(function()
        return conn:eval([[
            local i = box.info
            return {
                name = i.name,
                replicaset = i.replicaset and i.replicaset.name,
                ro = i.ro, ro_reason = i.ro_reason,
                status = i.status, lag = i.replication_lag,
                lsn = i.lsn,
            }
        ]], {}, { timeout = M.DEFAULTS.probe_timeout_sec })
    end)
    if not ok or type(info) ~= 'table' then
        return { reachable = false, err = tostring(info) }
    end
    info.reachable = true
    return info
end

local function probe_replicasets()
    local ok_peers, peers = pcall(require, 'webui.cluster.peers')
    if not ok_peers then return {} end
    local conns = peers.connections() or {}
    local out = {}
    local self_probe = {
        reachable  = true,
        name       = box.info.name,
        replicaset = box.info.replicaset and box.info.replicaset.name,
        ro         = box.info.ro,
        ro_reason  = box.info.ro_reason,
        status     = box.info.status,
        lag        = 0,
        lsn        = box.info.lsn,
    }
    if self_probe.replicaset ~= nil then
        out[self_probe.replicaset] = out[self_probe.replicaset] or {}
        out[self_probe.replicaset][STATE.self_alias] = self_probe
    end
    for alias, conn in pairs(conns) do
        if alias ~= STATE.self_alias then
            local probe = probe_peer(conn)
            if probe.replicaset ~= nil then
                out[probe.replicaset] = out[probe.replicaset] or {}
                out[probe.replicaset][alias] = probe
            end
        end
    end
    return out
end

-- Pick the best candidate for a replicaset given a probe map.
-- Deterministic on ties: alphabetical alias ordering.
function M.pick_leader(replicaset_probes, max_lag_sec)
    local best_alias, best_score = nil, -math.huge
    local aliases = {}
    for alias in pairs(replicaset_probes) do table.insert(aliases, alias) end
    table.sort(aliases)
    for _, alias in ipairs(aliases) do
        local score = M.score_candidate(
            replicaset_probes[alias], max_lag_sec)
        if score > best_score then
            best_alias, best_score = alias, score
        end
    end
    if best_score == -math.huge then return nil end
    return best_alias
end

-- ─────────────────────────────────────────────────────────────────────
-- Coordinator-only: appointment cycle
-- ─────────────────────────────────────────────────────────────────────

local function write_appointment(client, rs_name, leader_alias, previous)
    local key = string.format(M.KEY_APPOINTMENT, rs_name)
    local payload = json.encode({
        leader = leader_alias, ts = fiber.time(),
        coordinator = STATE.self_alias, previous = previous,
    })
    -- CAS-bind the write to OUR coordinator key revision. If our
    -- lease has expired and another peer claimed coordinator (new
    -- mod_revision), this txn fails atomically and we step down.
    local _, put_err = client:put_if_witness_unchanged(
        key, payload, M.KEY_COORDINATOR, STATE.coordinator_revision)
    if put_err ~= nil then
        return nil, put_err
    end
    return true
end

local function appointment_cycle(client)
    local rs_map = probe_replicasets()
    local now = fiber.time()
    -- Global hysteresis: any promotion (across any replicaset)
    -- in the last min_promotion_interval seconds blocks the next
    -- one. Cheap and prevents flapping when two candidates have
    -- nearly-equal scores.
    local can_change = (now - STATE.last_promotion_at)
        >= STATE.config.min_promotion_interval
    for rs_name, probes in pairs(rs_map) do
        local leader = M.pick_leader(probes,
            STATE.config.max_replication_lag_sec)
        if leader == nil then
            logger.debug('no qualified candidate', { replicaset = rs_name })
        else
            local current = STATE.last_appointments[rs_name]
            local needs_change = current == nil or current.leader ~= leader
            local needs_refresh = current ~= nil
                and (now - (current.ts or 0)) > 30
            if needs_change and not can_change then
                logger.debug('hysteresis blocks promotion',
                    { replicaset = rs_name, to = leader,
                      since_last = now - STATE.last_promotion_at })
            elseif needs_change or needs_refresh then
                local previous = current and current.leader
                local ok, write_err = write_appointment(
                    client, rs_name, leader, previous)
                if ok then
                    STATE.last_appointments[rs_name] = {
                        leader = leader, ts = now, previous = previous,
                    }
                    if needs_change then
                        STATE.last_promotion_at = now
                        logger.info('appointment changed', {
                            replicaset = rs_name,
                            from = previous, to = leader,
                        })
                    end
                else
                    -- CAS_CONFLICT means we lost coordinator status.
                    -- Step down immediately to avoid further writes.
                    if type(write_err) == 'table'
                            and write_err.category == 'CAS_CONFLICT' then
                        logger.warn('lost coordinator; stepping down',
                            { reason = 'CAS conflict on appointment' })
                        STATE.is_coordinator = false
                        STATE.coordinator_revision = nil
                        STATE.lease_id = nil
                        return  -- exit loop; election_loop will re-evaluate
                    end
                    set_error('appointment write: ' .. tostring(write_err))
                end
            end
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────
-- Main loop
-- ─────────────────────────────────────────────────────────────────────

local function jittered_sleep(base, jitter)
    fiber.sleep(base + math.random() * (jitter or 0))
end

local function coordinator_loop()
    fiber.self():name('webui_failover_coord', { truncate = true })
    while not STATE.stop_flag do
        local client, err = etcd_client.get_client()
        if client == nil then
            set_error('etcd unavailable: ' .. tostring(err))
            jittered_sleep(STATE.config.election_interval,
                STATE.config.election_jitter_sec)
        else
            -- Refresh our observation of who currently holds the
            -- coordinator key. If it's us, drive appointments; if
            -- it's another peer, idle; if no one holds it, claim.
            local coord, coord_rev = read_coordinator(client)
            if coord == nil then
                -- Vacancy. Try to claim. On loss we'll observe the
                -- winner on the next iteration.
                local ok, why = try_become_coordinator(
                    client, STATE.config.lease_ttl_sec)
                if not ok then
                    logger.debug('coordinator claim failed', { reason = why })
                end
            elseif coord.alias == STATE.self_alias
                    and STATE.lease_id ~= nil then
                -- We still own the key (cross-check by lease).
                STATE.coordinator = STATE.self_alias
                STATE.is_coordinator = true
                -- Refresh witness revision in case etcd compacted /
                -- our cache drifted.
                STATE.coordinator_revision = coord_rev
            else
                -- Either a real other coordinator or we somehow
                -- lost ownership. Drop our stale state.
                STATE.coordinator = coord.alias
                STATE.is_coordinator = false
                if STATE.lease_id ~= nil then release_lease(client) end
            end
            if STATE.is_coordinator then
                local ka_ok, ka = pcall(function()
                    return client:lease_keepalive(STATE.lease_id)
                end)
                if not ka_ok or ka == nil or ka.ttl == nil or ka.ttl == 0 then
                    logger.warn('lease keepalive failed; stepping down',
                        { lease_id = STATE.lease_id })
                    STATE.is_coordinator = false
                    STATE.lease_id = nil
                    STATE.coordinator_revision = nil
                else
                    local ok_appt, appt_err = pcall(appointment_cycle, client)
                    if not ok_appt then
                        set_error('appointment: ' .. tostring(appt_err))
                    else
                        clear_error()
                    end
                end
            else
                -- Lurking. No work; just refresh our view.
                clear_error()
            end
            fiber.sleep(STATE.config.keepalive_interval)
        end
    end
    -- Best-effort cleanup on stop: try to release the lease so the
    -- next coordinator does not have to wait for TTL.
    local client = etcd_client.get_client()
    release_lease(client)
end

-- ─────────────────────────────────────────────────────────────────────
-- Public surface
-- ─────────────────────────────────────────────────────────────────────

function M.start(opts)
    if STATE.enabled then return end
    opts = opts or {}
    STATE.config = {}
    for k, default in pairs(M.DEFAULTS) do
        local v = tonumber(opts[k])
        STATE.config[k] = (v and v > 0) and v or default
    end
    STATE.self_alias = (rawget(_G, 'box') and box.info and box.info.name) or nil
    if STATE.self_alias == nil then
        return nil, 'box.info.name unavailable; refusing to start agent'
    end
    -- Reset everything except STATE.last_appointments so a restart
    -- preserves the previous view until the loop refreshes it.
    STATE.stop_flag = false
    STATE.enabled = true
    STATE.is_coordinator = false
    STATE.lease_id = nil
    STATE.coordinator_revision = nil
    STATE.last_promotion_at = 0
    STATE.last_error = nil
    -- Seed math.random with a per-instance fiber/PID mix so the
    -- jitter is not identical across the cluster.
    math.randomseed(math.floor(fiber.time() * 1e6) % 2147483647)
    STATE.election_fiber = fiber.create(coordinator_loop)
    logger.info('failover agent started', {
        self = STATE.self_alias,
        lease_ttl_sec = STATE.config.lease_ttl_sec,
        min_promotion_interval = STATE.config.min_promotion_interval,
        max_replication_lag_sec = STATE.config.max_replication_lag_sec,
    })
    return true
end

function M.stop()
    if not STATE.enabled then return end
    STATE.stop_flag = true
    STATE.enabled = false
    logger.info('failover agent stop requested')
end

function M.status()
    local appointments = {}
    for rs, info in pairs(STATE.last_appointments) do
        table.insert(appointments, {
            replicaset = rs,
            leader     = info.leader,
            previous   = info.previous,
            ts         = info.ts,
        })
    end
    table.sort(appointments, function(a, b)
        return (a.replicaset or '') < (b.replicaset or '')
    end)
    return {
        enabled         = STATE.enabled,
        self_alias      = STATE.self_alias,
        coordinator     = STATE.coordinator,
        is_coordinator  = STATE.is_coordinator,
        lease_id        = STATE.lease_id and tostring(STATE.lease_id),
        coordinator_revision = STATE.coordinator_revision,
        appointments    = appointments,
        last_error      = STATE.last_error,
        last_promotion_at = STATE.last_promotion_at,
    }
end

function M._reset()
    STATE.enabled = false
    STATE.stop_flag = true
    STATE.lease_id = nil
    STATE.coordinator_revision = nil
    STATE.is_coordinator = false
    STATE.coordinator = nil
    STATE.last_appointments = {}
    STATE.last_error = nil
end

return M
