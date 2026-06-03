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
-- FO-5: defaults satisfy the canonical timing invariants on their own
-- (keepalive + 2*probe = 5 + 6 = 11 <= lease_ttl 20, and 20 >= 2*5).
-- failover/init.lua re-validates and auto-corrects operator overrides
-- via failover/timings.lua before these reach build_config.
M.DEFAULTS = {
    lease_ttl_sec            = 20,
    keepalive_interval       = 5,
    election_interval        = 5,
    appointment_interval     = 2,
    probe_timeout_sec        = 3,
    -- Operational fencing:
    max_replication_lag_sec  = 5,   -- candidate's lag ceiling
    min_promotion_interval   = 10,  -- no two promotions within N seconds
    election_jitter_sec      = 1,   -- backoff jitter to avoid herd
    -- failover_priority auto-return throttle (Task 5.12): wait at
    -- least this many seconds after the current leader's
    -- appointment before swapping back to priority[0]. Keeps
    -- flapping primaries from ping-ponging the queue.
    autoreturn_delay         = 60,
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
    paused_until         = nil,  -- epoch seconds while a pause is active
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
    -- Anonymous replicas (FO-20) are read-only observers: they don't
    -- vote, aren't in the synchro quorum, and box.ctl.promote() is
    -- rejected on them. Never appoint one — a promote would just fail
    -- and leave the replicaset leaderless.
    if probe.anon == true then return -math.huge end
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
                vclock = i.vclock,
                anon = box.cfg.replication_anon == true,
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
        vclock     = box.info.vclock,
        anon       = box.cfg.replication_anon == true,
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
-- Deterministic on ties: alphabetical alias ordering. `disabled`
-- is an optional set of aliases the operator has marked as
-- ineligible — they are filtered to score = -inf before ranking.
-- `priority` is an optional ordered list of aliases — the i-th
-- entry adds (len - i) * 100 to its score so the first listed
-- candidate wins whenever multiple are healthy.
function M.pick_leader(replicaset_probes, max_lag_sec, disabled, priority)
    local priority_index = {}
    if type(priority) == 'table' then
        local n = #priority
        for i, alias in ipairs(priority) do
            priority_index[alias] = (n - i + 1) * 100
        end
    end
    local best_alias, best_score = nil, -math.huge
    local aliases = {}
    for alias in pairs(replicaset_probes) do table.insert(aliases, alias) end
    table.sort(aliases)
    for _, alias in ipairs(aliases) do
        local score
        if disabled ~= nil and disabled[alias] == true then
            score = -math.huge
        else
            score = M.score_candidate(
                replicaset_probes[alias], max_lag_sec)
            if score > -math.huge and priority_index[alias] ~= nil then
                score = score + priority_index[alias]
            end
        end
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

local function write_appointment(client, rs_name, leader_alias, previous,
                                 manual_override_until, by_user, prev_vclock)
    local key = string.format(M.KEY_APPOINTMENT, rs_name)
    local payload = json.encode({
        leader = leader_alias, ts = fiber.time(),
        coordinator = STATE.self_alias, previous = previous,
        manual_override_until = manual_override_until,
        by_user = by_user,
        -- Previous leader's vclock (FO-3): the new leader waits until
        -- its own vclock dominates this before going read-write, so a
        -- switchover does not silently drop the old leader's confirmed
        -- transactions. nil on a cold first appointment.
        prev_vclock = prev_vclock,
        -- Failover term (FO-4 control-plane fencing token): the
        -- mod_revision of OUR coordinator key. etcd revisions are
        -- strictly monotonic, so a newer coordinator stamps a higher
        -- term; the watcher rejects appointments whose term is lower
        -- than the highest it has applied (defense-in-depth on top of
        -- the CAS below).
        term = STATE.coordinator_revision,
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

-- Manual override entry point for promoteInstance in supervised
-- mode. Writes a plain (non-CAS) appointment with a TTL flag so
-- the coordinator stops auto-promoting somebody else until the
-- window expires. Any peer can call this — we deliberately do NOT
-- bind to the coordinator's lease here because the operator might
-- be acting from a follower-only API instance.
function M.appoint_manually(client, rs_name, alias, ttl_sec, by_user)
    if client == nil then return nil, 'etcd unavailable' end
    if type(rs_name) ~= 'string' or rs_name == '' then
        return nil, 'replicaset name required'
    end
    if type(alias) ~= 'string' or alias == '' then
        return nil, 'alias required'
    end
    local now = fiber.time()
    local override_until = now + math.max(30, tonumber(ttl_sec) or 300)
    local key = string.format(M.KEY_APPOINTMENT, rs_name)
    local payload = json.encode({
        leader = alias, ts = now,
        coordinator = 'manual',
        manual_override_until = override_until,
        by_user = by_user or '?',
    })
    local _, put_err = client:put(key, payload)
    if put_err ~= nil then return nil, put_err end
    logger.warn('manual appointment override', {
        replicaset = rs_name, leader = alias,
        until_ts = override_until, by_user = by_user,
    })
    return { leader = alias, manual_override_until = override_until }
end

-- Previous leader's vclock for the new leader to catch up to (FO-3).
-- Only meaningful on a real leader change where we can still probe the
-- outgoing leader; nil otherwise (cold appointment / unreachable peer).
local function prev_leader_vclock(probes, previous, leader)
    if previous == nil or previous == leader then return nil end
    local pp = probes[previous]
    if pp and pp.reachable then return pp.vclock end
    return nil
end

local function appointment_cycle(client)
    -- Maintenance-window pause (Task 5.11). When active, the
    -- coordinator stops issuing new promotions but keeps its lease
    -- alive — so it remains the authoritative observer through the
    -- maintenance window and reads the pause flag itself on the
    -- next tick after expiry. We deliberately do NOT call probe /
    -- pick_leader when paused: cheaper and avoids spurious lag /
    -- replication warnings while peers are intentionally down.
    do
        local ok_p, pause_mod = pcall(require, 'webui.failover.pause')
        if ok_p then
            local entry = pause_mod.read(client)
            if entry ~= nil then
                STATE.paused_until = entry.until_ts
                logger.debug('failover paused; skipping cycle',
                    { until_ts = entry.until_ts,
                      by_user = entry.by_user })
                return
            end
            STATE.paused_until = nil
        end
    end

    local rs_map = probe_replicasets()
    local now = fiber.time()
    -- Operator-controlled disabled set (Task 5.7). Read every cycle
    -- — cheap (one etcd range-prefix call per second on the
    -- coordinator only) and lets the agent react within a second
    -- of `setInstanceState(disabled=true)` without restarts.
    local disabled
    do
        local ok_d, mod = pcall(require, 'webui.failover.disabled')
        if ok_d then disabled = select(1, mod.aliases_set(client)) end
    end

    -- Per-replicaset failover_priority list (Task 5.12), pulled
    -- straight from the live cluster YAML. When unset for a given
    -- rs, pick_leader falls back to alphabetical ordering — the
    -- current behaviour, so existing clusters keep working
    -- unchanged.
    local priority_by_rs = {}
    do
        local ok_yaml, yaml_mod = pcall(require, 'yaml')
        local kv = ok_yaml and select(1, client:read_cluster_config()) or nil
        if kv ~= nil and kv.value ~= nil then
            local ok, parsed = pcall(yaml_mod.decode, kv.value)
            if ok and type(parsed) == 'table' then
                for _, group in pairs(parsed.groups or {}) do
                    for rs_name, rs in pairs(group.replicasets or {}) do
                        if type(rs.failover_priority) == 'table' then
                            priority_by_rs[rs_name] = rs.failover_priority
                        end
                    end
                end
            end
        end
    end
    -- Global hysteresis: any promotion (across any replicaset)
    -- in the last min_promotion_interval seconds blocks the next
    -- one. Cheap and prevents flapping when two candidates have
    -- nearly-equal scores.
    local can_change = (now - STATE.last_promotion_at)
        >= STATE.config.min_promotion_interval
    -- Re-read the live appointment row before deciding whether to
    -- write a new one. The coordinator memory (STATE.last_appointments)
    -- lags reality when another process manually appointed via
    -- M.appoint_manually — without this re-read we would overwrite
    -- the override on the very next tick.
    local function read_live_appointment(rs)
        local key = string.format(M.KEY_APPOINTMENT, rs)
        local kv, get_err = client:get(key)
        if get_err ~= nil or kv == nil or kv.value == nil then return nil end
        local ok, decoded = pcall(json.decode, kv.value)
        if not ok or type(decoded) ~= 'table' then return nil end
        return decoded
    end

    for rs_name, probes in pairs(rs_map) do
        local live = read_live_appointment(rs_name)
        if live ~= nil
            and tonumber(live.manual_override_until) ~= nil
            and live.manual_override_until > now then
            -- A manual override is in effect. Keep our memory in
            -- sync and skip score-based re-evaluation for this rs.
            STATE.last_appointments[rs_name] = {
                leader = live.leader, ts = live.ts or now,
                previous = live.previous,
                manual_override_until = live.manual_override_until,
            }
            logger.debug('manual override active; skipping score cycle',
                { replicaset = rs_name, leader = live.leader,
                  expires_at = live.manual_override_until })
        else
        -- Auto-return throttle (Task 5.12 part B): don't swap a
        -- working leader back to priority[0] for at least
        -- `autoreturn_delay` seconds after the current leader was
        -- appointed. Without this guard, a flapping primary that
        -- recovers and re-fails inside seconds would ping-pong the
        -- queue across the cluster on every cycle.
        local priority_for_pick = priority_by_rs[rs_name]
        do
            local current = STATE.last_appointments[rs_name]
            local autoreturn_delay = tonumber(
                STATE.config.autoreturn_delay) or 60
            if current ~= nil
                and (now - (current.ts or 0)) < autoreturn_delay then
                priority_for_pick = nil
            end
        end

        local leader = M.pick_leader(probes,
            STATE.config.max_replication_lag_sec, disabled,
            priority_for_pick)
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
                local prev_vclock = prev_leader_vclock(probes, previous, leader)
                local ok, write_err = write_appointment(
                    client, rs_name, leader, previous, nil, nil, prev_vclock)
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
        end -- manual-override else
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

-- Build STATE.config from opts (defaults for missing/invalid values).
local function build_config(opts)
    local cfg = {}
    for k, default in pairs(M.DEFAULTS) do
        local v = tonumber(opts[k])
        cfg[k] = (v and v > 0) and v or default
    end
    return cfg
end

function M.start(opts)
    if STATE.enabled then return end
    opts = opts or {}
    STATE.config = build_config(opts)
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

-- Live-reconfigure tunables without restarting the coordinator fiber.
-- coordinator_loop reads STATE.config every tick, so new timings apply
-- on the next iteration — no lease drop, no re-election. No-op if the
-- agent is not running.
function M.reconfigure(opts)
    if not STATE.enabled then return false end
    STATE.config = build_config(opts or {})
    logger.info('failover agent reconfigured (live)', {
        lease_ttl_sec = STATE.config.lease_ttl_sec,
        keepalive_interval = STATE.config.keepalive_interval,
    })
    return true
end

function M.stop()
    if not STATE.enabled then return end
    STATE.stop_flag = true
    STATE.enabled = false

    -- ── Graceful synchro queue handover (split-brain prevention) ──
    -- Drain the limbo BEFORE revoking the coordinator lease. Shared
    -- with lifecycle/stop (FO-9) so the drain runs on every shutdown
    -- path, agent or not. Best-effort + bounded.
    pcall(function()
        require('webui.failover.drain').drain_synchro_queue(3)
    end)

    -- Best-effort SYNCHRONOUS release: if we hold the coordinator
    -- lease, revoke it here so a surviving peer can claim the
    -- vacancy on its next election tick (~1s) instead of waiting
    -- for the full TTL to expire. The coordinator_loop also runs
    -- release_lease on its way out, but that path is racy under
    -- a fast SIGTERM — Tarantool may exit before the fiber wakes
    -- from its sleep. Doing the revoke synchronously here closes
    -- the window: even if the loop never gets to its cleanup, the
    -- lease is already gone.
    if STATE.is_coordinator and STATE.lease_id ~= nil then
        local client = etcd_client.get_client()
        if client ~= nil then
            local lease_id = STATE.lease_id
            local ok, err = pcall(function()
                return client:lease_revoke(lease_id)
            end)
            if ok then
                logger.info('coordinator lease revoked on stop',
                    { lease_id = lease_id })
            else
                logger.warn('lease revoke on stop failed',
                    { lease_id = lease_id, err = tostring(err) })
            end
        end
        STATE.lease_id = nil
        STATE.is_coordinator = false
        STATE.coordinator_revision = nil
    end
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
        paused_until    = STATE.paused_until,
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
