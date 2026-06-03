--
-- Dead-man switch / software STONITH (Task FO-15).
--
-- Self-fencing (FO-1) demotes a leader that lost its lease — but only
-- if the fencing fiber actually runs and box.ctl.demote / box.cfg can
-- complete. If those keep failing (a wedged box.ctl, a bug, a stuck
-- WAL) the instance could stay read-write past its lease. This is the
-- backstop: when an instance is STILL the effective leader a hard
-- deadline after its last leadership confirmation — longer than the
-- self-fence renew_deadline, so self-fence gets first crack — force the
-- process to exit. `restart: unless-stopped` brings it back, and under
-- the supervised model it comes back read-only (FO-0/FO-2).
--
-- LIMITATION (honest): this is a Lua fiber in the TX thread. A fully
-- hung TX thread (hard OOM, hypervisor pause) will not schedule this
-- fiber either, so it cannot save that case — only a kernel
-- `/dev/watchdog` (privileged container) can. That is left as an
-- opt-in enhancement; the portable dead-man here covers the common
-- "fencing can't complete but fibers still run" failures.
--
-- Mirrors Patroni's watchdog timing (timeout below the lease) and its
-- "feed only on successful renewal" coupling — here the feed is the
-- watcher updating last_leader_confirm_mono on a good appointment read.
--

local fiber    = require('fiber')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('failover.watchdog')

local M = {}

-- Pure decision: should the dead-man switch fire (force exit)?
--
-- `state` fields (monotonic clock):
--   * is_leader          — do we still own the synchro queue / RW?
--   * now_mono           — fiber.clock()
--   * last_confirm_mono  — last successful self-as-leader confirmation
--   * hard_deadline      — seconds; MUST be > self-fence renew_deadline
--
-- Returns true only when a leader has gone unconfirmed past the hard
-- deadline. Defensive: bad/missing inputs → false (never exit on noise).
function M.should_trigger(state)
    if type(state) ~= 'table' or not state.is_leader then return false end
    local now = tonumber(state.now_mono)
    local last = tonumber(state.last_confirm_mono)
    local hd = tonumber(state.hard_deadline)
    if now == nil or last == nil or hd == nil or hd <= 0 then return false end
    return (now - last) >= hd
end

local STATE = { enabled = false, fiber = nil, stop_flag = false }

-- Start the dead-man fiber. `opts`:
--   * is_leader        — function() -> bool (effective leadership)
--   * last_confirm     — function() -> monotonic ts of last confirm
--   * hard_deadline    — seconds
--   * probe_interval   — check cadence (seconds)
--   * exit_fn          — optional, injected for tests (default os.exit)
function M.start(opts)
    if STATE.enabled then return end
    opts = opts or {}
    local is_leader = opts.is_leader
    local last_confirm = opts.last_confirm
    local hard_deadline = tonumber(opts.hard_deadline) or 0
    local probe = tonumber(opts.probe_interval) or 2
    local exit_fn = opts.exit_fn or os.exit
    -- FO-19: optional maintenance-pause gate. Under a pause the dead-man
    -- switch must NOT force an exit — the operator is deliberately taking
    -- nodes offline. Defaults to "never paused" when not supplied.
    local is_paused = (type(opts.is_paused) == 'function' and opts.is_paused)
        or function() return false end
    if type(is_leader) ~= 'function' or type(last_confirm) ~= 'function'
        or hard_deadline <= 0 then
        return nil, 'watchdog: invalid options'
    end
    STATE.stop_flag = false
    STATE.enabled = true
    STATE.fiber = fiber.create(function()
        fiber.self():name('webui_failover_wdog', { truncate = true })
        while not STATE.stop_flag do
            local now = fiber.clock()
            local last = last_confirm() or now
            local leader = is_leader()
            if leader and (now - last) >= (hard_deadline * 0.8) then
                logger.warn('dead-man switch arming: leader unconfirmed', {
                    since_confirm = now - last, hard_deadline = hard_deadline,
                })
            end
            if M.should_trigger({
                is_leader = leader, now_mono = now,
                last_confirm_mono = last, hard_deadline = hard_deadline,
            }) and not is_paused() then
                logger.error('dead-man switch FIRED: still leader past hard '
                    .. 'deadline; forcing process exit so it restarts '
                    .. 'read-only', { since_confirm = now - last,
                    hard_deadline = hard_deadline })
                exit_fn(1)
                return  -- in tests exit_fn is a no-op; stop the loop
            end
            fiber.sleep(probe)
        end
    end)
    logger.info('failover watchdog (dead-man) started',
        { hard_deadline = hard_deadline })
    return true
end

function M.stop()
    if not STATE.enabled then return end
    STATE.stop_flag = true
    STATE.enabled = false
    STATE.fiber = nil
    logger.info('failover watchdog stop requested')
end

function M.status()
    return { enabled = STATE.enabled }
end

function M._reset()
    STATE.enabled = false
    STATE.stop_flag = true
    STATE.fiber = nil
end

return M
