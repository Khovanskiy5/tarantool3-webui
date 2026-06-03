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
local fencing     = require('webui.failover.fencing')
local failsafe    = require('webui.failover.failsafe')
local watchdog    = require('webui.failover.watchdog')
local log_util    = require('webui.log_util')
local logger      = log_util.with_tag('failover.watcher')

local M = {}

M.DEFAULTS = {
    poll_interval_sec = 1,
    -- Self-fencing (FO-1). renew_deadline = lease_ttl_sec - safety_margin
    -- and MUST be < lease_ttl_sec so a partitioned leader goes RO before
    -- the coordinator lease can be regranted.
    lease_ttl_sec  = 15,
    safety_margin  = 5,
    probe_interval = 2,
    -- FO-3: how long the new leader waits to catch up to the previous
    -- leader's vclock before promoting anyway (best-effort).
    waitlsn_timeout = 3,
}
M.KEY_APPOINTMENT = '/failover/replicasets/%s/leader'
M.KEY_VCLOCKKEEPER = '/failover/replicasets/%s/vclockkeeper'

local STATE = {
    enabled     = false,
    config      = nil,
    self_alias  = nil,
    replicaset  = nil,
    fiber       = nil,
    fencing_fiber = nil,
    config_watch = nil,   -- box.watch('config.info') handle
    last_seen   = nil,    -- { leader, ts }
    last_applied = nil,   -- { read_only, ts }
    last_error  = nil,
    -- Self-fencing bookkeeping (monotonic clock):
    last_leader_confirm_mono = nil, -- last successful self-as-leader read
    last_etcd_ok = false,
    last_applied_term = 0,          -- FO-4: highest appointment term applied
    react_in_progress = false,      -- re-entrancy guard for react_once
    -- Guards against the watcher loop and the fencing loop calling
    -- box.ctl.promote/demote at the same time (Tarantool rejects
    -- "simultaneous invocations"). A plain boolean is safe: fibers only
    -- yield at the box.ctl call itself, never between the check and set.
    ctl_in_progress = false,
    stop_flag   = false,
}

-- Run box.ctl.promote/demote under the single-flight guard. Returns
-- (ok, err) like pcall; returns (false, 'busy') if another fiber is
-- already mid promote/demote (caller retries on its next tick).
local function guarded_ctl(ctl_fn)
    if STATE.ctl_in_progress then
        return false, 'ctl busy'
    end
    STATE.ctl_in_progress = true
    local ok, err = pcall(ctl_fn)
    STATE.ctl_in_progress = false
    return ok, err
end

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
        term   = tonumber(parsed.term),  -- FO-4 fencing token (nil for manual)
        prev_vclock = parsed.prev_vclock, -- FO-3 catch-up target
        revision = kv.revision,
    }
end

-- Determine whether we're "really" the leader from Tarantool's
-- perspective. `box.info.ro == false` alone is not enough — the
-- single source of truth for "who is the leader" is synchronous-queue
-- ownership: only the owner can append to synchro spaces; everyone
-- else waits (synchro_quorum) or hits `ro_reason='synchro'`.
--
-- An owner of 0 means NO ONE currently owns the queue — that is the
-- post-bootstrap state before the first box.ctl.promote() claim (under
-- supervised mode the fresh bootstrap leader comes up RW but does not
-- own the queue yet). Treating "no owner" as "I am leader" was a bug:
-- it skipped the initial promote(), leaving the appointed leader never
-- actually claiming the queue.
local function effectively_leader()
    if box.info.ro then return false end
    local synchro = box.info.synchro
    if synchro == nil or synchro.queue == nil then
        -- Old build without synchro info — fall back to the ro flag.
        return true
    end
    return synchro.queue.owner == box.info.id
end

-- FO-3 consistent switchover: before a newly-appointed leader goes
-- read-write it (1) waits until its vclock dominates the previous
-- leader's confirmed vclock (best-effort, bounded by waitlsn_timeout)
-- so committed rows are not dropped, and (2) CAS-claims the
-- vclockkeeper key so two instances cannot both promote. Returns
-- (true) when safe to promote, or (false, reason) to defer.
local function prepare_to_promote(appt, client)
    -- (1) Catch up to the previous leader.
    if type(appt.prev_vclock) == 'table' then
        local deadline = fiber.clock() + (STATE.config.waitlsn_timeout or 3)
        while not fencing.vclock_dominates(box.info.vclock, appt.prev_vclock) do
            if fiber.clock() >= deadline then
                -- The remaining gap is an unreplicated tail from the
                -- (likely dead) previous leader — unrecoverable. Promote
                -- anyway; the limbo term fence + is_sync protect
                -- committed sync data. Log loudly.
                logger.warn('promoting without full catch-up to previous '
                    .. 'leader; unreplicated tail may be lost', {
                    previous = appt.previous })
                break
            end
            fiber.sleep(0.1)
        end
    end
    -- (2) CAS-claim the vclockkeeper. expected=0 creates it if absent.
    if client ~= nil then
        local key = string.format(M.KEY_VCLOCKKEEPER, STATE.replicaset)
        local kv, get_err = client:get(key)
        if get_err ~= nil then
            -- Don't guess the revision on a transient etcd error: defer
            -- and retry next tick rather than risk a wrong CAS baseline.
            return false, 'vclockkeeper read: ' .. tostring(get_err)
        end
        local expected = (kv and kv.revision) or 0
        local payload = json.encode({
            keeper = STATE.self_alias, ts = fiber.time(),
        })
        local _, cas_err = client:txn_cas(key, payload, expected)
        if cas_err ~= nil then
            return false, 'vclockkeeper CAS lost: ' .. tostring(cas_err)
        end
    end
    return true
end

local function apply_appointment(appt, client)
    if appt == nil then return end
    STATE.last_seen = appt
    local should_be_leader = (appt.leader == STATE.self_alias)
    local am_leader = effectively_leader()
    -- Skip if already in the right state. The guard considers both
    -- `box.cfg.read_only` AND synchro queue ownership so we do not
    -- spam `box.ctl.promote()` once per second on the steady
    -- leader.
    if should_be_leader and not am_leader then
        -- FO-3: catch up + claim vclockkeeper before going RW. Defer
        -- (retry next tick) if we lost the keeper CAS to another peer.
        local prep_ok, prep_reason = prepare_to_promote(appt, client)
        if not prep_ok then
            STATE.last_error = prep_reason
            logger.warn('deferring promote', { reason = prep_reason })
            return
        end
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
        local ok, err = guarded_ctl(box.ctl.promote)
        if ok then
            STATE.last_applied = { read_only = false, ts = fiber.time() }
            logger.info('promoted to leader by appointment',
                { coordinator = appt.coordinator, ts = appt.ts })
        else
            STATE.last_error = 'promote: ' .. tostring(err)
            logger.error('failed to apply promotion', { err = tostring(err) })
        end
    elseif not should_be_leader and am_leader then
        -- box.ctl.demote() releases the synchronous queue. In supervised
        -- mode it freezes the limbo but does NOT clear read_only, so
        -- pair it with an explicit read_only=true (see fencing_loop).
        local ok, err = guarded_ctl(box.ctl.demote)
        pcall(function() box.cfg({ read_only = true }) end)
        if ok then
            STATE.last_applied = { read_only = true, ts = fiber.time() }
            logger.info('demoted to follower by appointment',
                { coordinator = appt.coordinator,
                  new_leader = appt.leader, ts = appt.ts })
        else
            STATE.last_error = 'demote: ' .. tostring(err)
            logger.error('failed to apply demotion', { err = tostring(err) })
        end
    elseif not should_be_leader and not box.info.ro then
        -- We are NOT the appointed leader, do not own the synchro
        -- queue (effectively_leader() was false), yet we are still
        -- read-write. This is the fresh-bootstrap leader (minimal
        -- name, came up RW to bootstrap the replicaset) before the
        -- agent appointed someone else, or a leftover RW peer. Drop
        -- to read-only so it cannot accept async writes while another
        -- instance is the real leader — closing the two-writable
        -- window. No box.ctl.demote() here: we never owned the queue,
        -- so a plain read_only flip is the correct, cheaper move.
        local ok, err = pcall(function()
            box.cfg({ read_only = true })
        end)
        if ok then
            STATE.last_applied = { read_only = true, ts = fiber.time() }
            logger.info('set read_only on non-appointed RW instance',
                { appointed_leader = appt.leader,
                  coordinator = appt.coordinator })
        else
            STATE.last_error = 'read_only=true: ' .. tostring(err)
            logger.error('failed to RO non-appointed instance',
                { err = tostring(err) })
        end
    end
end

-- One read-appointment + apply cycle. Shared by the poll loop and the
-- `box.watch('config.info')` callback so a config reload re-asserts the
-- target RO/RW state immediately, without waiting for the next poll
-- tick.
local function react_once_inner()
    local client, err = etcd_client.get_client()
    if client == nil then
        STATE.last_error = 'etcd unavailable: ' .. tostring(err)
        STATE.last_etcd_ok = false
        return
    end
    local appt, get_err = read_appointment(client)
    if get_err ~= nil then
        STATE.last_error = 'get: ' .. tostring(get_err)
        STATE.last_etcd_ok = false
    elseif appt == nil then
        -- No appointment yet — the coordinator hasn't written one.
        -- Wait quietly; do NOT clear last_error from a previous
        -- transient failure until we actually succeed at applying.
        STATE.last_error = nil
        STATE.last_etcd_ok = true
    else
        STATE.last_error = nil
        STATE.last_etcd_ok = true
        if fencing.appointment_is_stale(appt.term, STATE.last_applied_term) then
            -- An older coordinator's decision raced in (lower term).
            -- Ignore it; do NOT apply and do NOT treat it as a
            -- leadership confirmation. The current coordinator will
            -- re-stamp the right appointment at its (higher) term.
            logger.warn('ignoring stale appointment (lower failover term)', {
                appt_term = appt.term,
                last_applied_term = STATE.last_applied_term,
                leader = appt.leader,
            })
        else
            if appt.term ~= nil then
                STATE.last_applied_term =
                    math.max(STATE.last_applied_term or 0, appt.term)
            end
            -- A fresh (non-stale) read naming us leader re-confirms our
            -- RW lease on OUR monotonic clock — the heartbeat the
            -- self-fence watches.
            if appt.leader == STATE.self_alias then
                STATE.last_leader_confirm_mono = fiber.clock()
            end
            local ok, ap_err = pcall(apply_appointment, appt, client)
            if not ok then
                STATE.last_error = 'apply: ' .. tostring(ap_err)
            end
        end
    end
end

-- Re-entrancy guard around react_once_inner. The poll loop calls it
-- sequentially, but the box.watch('config.info') callback runs in a
-- separate fiber and could overlap a poll-loop call that is parked in
-- the prepare_to_promote catch-up (up to waitlsn_timeout). When that
-- happens the second caller just skips — the in-flight one is already
-- reconciling. The flag is safe without a mutex: fibers only yield
-- inside the inner body, never between this check and set.
local function react_once()
    if STATE.react_in_progress then return end
    STATE.react_in_progress = true
    local ok, err = pcall(react_once_inner)
    STATE.react_in_progress = false
    if not ok then
        STATE.last_error = 'react: ' .. tostring(err)
    end
end

-- Self-fencing loop (FO-1). Independent of the appointment poll: even
-- if etcd is unreachable (so react_once can't update the confirm
-- timestamp), this fiber keeps ticking on the local monotonic clock
-- and demotes us once the renew_deadline elapses.
local function fencing_loop()
    fiber.self():name('webui_failover_fence', { truncate = true })
    while not STATE.stop_flag do
        local reason = fencing.should_fence({
            is_leader = effectively_leader(),
            now_mono = fiber.clock(),
            last_confirm_mono = STATE.last_leader_confirm_mono,
            renew_deadline = STATE.config.renew_deadline,
        })
        if reason ~= nil then
            local ctx = STATE.last_etcd_ok and 'lost_lease' or 'dcs_down'
            -- FO-16 failsafe: on DCS loss only, if enabled and EVERY
            -- peer still defers to us, stay read-write instead of
            -- demoting (availability without split-brain). `lost_lease`
            -- (etcd reachable, our appointment/CAS was taken over)
            -- always demotes — someone else is the leader.
            local held_by_failsafe = false
            if ctx == 'dcs_down' and STATE.config.failsafe_enabled then
                local ok_fs, stay = pcall(failsafe.check, STATE.self_alias)
                if ok_fs and stay == true then
                    held_by_failsafe = true
                    -- Reset the confirm clock so neither self-fence nor
                    -- the watchdog fires while failsafe holds.
                    STATE.last_leader_confirm_mono = fiber.clock()
                    logger.warn('failsafe: all peers confirm leadership; '
                        .. 'staying read-write despite DCS loss')
                end
            end
            if not held_by_failsafe then
                logger.warn('self-fencing: demoting to read-only', {
                    reason = reason, context = ctx,
                    since_confirm = fiber.clock()
                        - (STATE.last_leader_confirm_mono or 0),
                })
                local ok, derr = guarded_ctl(box.ctl.demote)
                -- box.ctl.demote() freezes the synchro limbo (blocks sync
                -- writes) but in supervised mode does NOT clear read_only
                -- — verified live: post-demote box.info.ro stayed false
                -- and an async write to a non-sync space was still
                -- accepted. Force read_only=true so the fence is COMPLETE
                -- (async writes blocked too), regardless of whether
                -- demote itself succeeded or was skipped (ctl busy).
                local ro_ok, ro_err = pcall(function()
                    box.cfg({ read_only = true })
                end)
                if ro_ok then
                    pcall(function() box.ctl.wait_ro(3) end)
                    STATE.last_applied = { read_only = true, ts = fiber.time() }
                    -- Reset the clock so we don't re-fire every probe
                    -- tick while waiting for the next appointment.
                    STATE.last_leader_confirm_mono = fiber.clock()
                    logger.info('self-fenced: now read-only',
                        { context = ctx, demote_ok = ok })
                else
                    STATE.last_error = 'self-fence read_only: '
                        .. tostring(ro_err)
                    logger.error('self-fence read_only failed', {
                        err = tostring(ro_err), demote_err = tostring(derr) })
                end
            end
        end
        fiber.sleep(STATE.config.probe_interval)
    end
end

local function loop()
    fiber.self():name('webui_failover_watch', { truncate = true })
    while not STATE.stop_flag do
        react_once()
        fiber.sleep(STATE.config.poll_interval_sec)
    end
end

function M.start(opts)
    if STATE.enabled then return end
    opts = opts or {}
    local lease_ttl = tonumber(opts.lease_ttl_sec) or M.DEFAULTS.lease_ttl_sec
    local safety = tonumber(opts.safety_margin) or M.DEFAULTS.safety_margin
    -- renew_deadline = lease_ttl - safety_margin, clamped to a sane floor
    -- so a misconfigured (too-small) lease still leaves a positive window.
    local renew_deadline = lease_ttl - safety
    if renew_deadline < 1 then renew_deadline = math.max(1, lease_ttl - 1) end
    STATE.config = {
        poll_interval_sec = tonumber(opts.poll_interval_sec)
            or M.DEFAULTS.poll_interval_sec,
        probe_interval = tonumber(opts.probe_interval)
            or M.DEFAULTS.probe_interval,
        renew_deadline = renew_deadline,
        waitlsn_timeout = tonumber(opts.waitlsn_timeout)
            or M.DEFAULTS.waitlsn_timeout,
        -- FO-15 dead-man hard deadline: the full lease_ttl, strictly
        -- greater than renew_deadline so self-fence (FO-1) acts first.
        watchdog_enabled = opts.watchdog_enabled ~= false,
        hard_deadline = lease_ttl,
        -- FO-16 failsafe: opt-in (default off → safe CP demote on DCS loss).
        failsafe_enabled = opts.failsafe_enabled == true,
    }
    STATE.self_alias = box.info.name
    STATE.replicaset = box.info.replicaset and box.info.replicaset.name
    if STATE.self_alias == nil or STATE.replicaset == nil then
        return nil, 'box.info.name / replicaset.name unavailable'
    end
    STATE.stop_flag = false
    STATE.enabled = true
    -- Seed the confirm clock to now so a freshly-started leader is not
    -- fenced before its first successful appointment read.
    STATE.last_leader_confirm_mono = fiber.clock()
    STATE.last_etcd_ok = false
    STATE.last_applied_term = 0
    STATE.react_in_progress = false
    STATE.fiber = fiber.create(loop)
    STATE.fencing_fiber = fiber.create(fencing_loop)
    -- FO-15: dead-man switch as a backstop to self-fence. Watches the
    -- same monotonic confirm clock; forces process exit if a leader
    -- stays unconfirmed past the full lease (self-fence acts earlier).
    if STATE.config.watchdog_enabled then
        watchdog.start({
            is_leader = effectively_leader,
            last_confirm = function() return STATE.last_leader_confirm_mono end,
            hard_deadline = STATE.config.hard_deadline,
            probe_interval = STATE.config.probe_interval,
        })
    end
    -- React immediately on every config apply/reload. In supervised
    -- mode the applier re-evaluates RO/RW on reload; the watch lets us
    -- re-assert the appointed state within the same tick instead of
    -- waiting up to poll_interval_sec. Guarded: never let a watch
    -- callback error escape, and stop reacting once disabled.
    do
        local ok, handle = pcall(function()
            return box.watch('config.info', function()
                if STATE.stop_flag or not STATE.enabled then return end
                pcall(react_once)
            end)
        end)
        if ok then
            STATE.config_watch = handle
        else
            logger.warn('config.info watch unavailable; relying on poll',
                { err = tostring(handle) })
        end
    end
    logger.info('failover watcher started', {
        self = STATE.self_alias,
        replicaset = STATE.replicaset,
        interval_sec = STATE.config.poll_interval_sec,
        renew_deadline = STATE.config.renew_deadline,
        probe_interval = STATE.config.probe_interval,
    })
    return true
end

function M.stop()
    if not STATE.enabled then return end
    STATE.stop_flag = true
    STATE.enabled = false
    -- Both loop() and fencing_loop() exit on the next tick via stop_flag.
    STATE.fiber = nil
    STATE.fencing_fiber = nil
    pcall(function() watchdog.stop() end)
    if STATE.config_watch ~= nil then
        pcall(function() STATE.config_watch:unregister() end)
        STATE.config_watch = nil
    end
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
    if STATE.config_watch ~= nil then
        pcall(function() STATE.config_watch:unregister() end)
        STATE.config_watch = nil
    end
    STATE.fiber = nil
    STATE.fencing_fiber = nil
    pcall(function() watchdog.stop() end)
    STATE.last_leader_confirm_mono = nil
    STATE.last_etcd_ok = false
    STATE.last_applied_term = 0
    STATE.react_in_progress = false
    STATE.last_seen = nil
    STATE.last_applied = nil
    STATE.last_error = nil
end

return M
