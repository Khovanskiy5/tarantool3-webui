--
-- Failover timing discipline (FO-5).
--
-- Pure, side-effect-free validation + auto-correction of the lease /
-- keepalive / probe timings, mirroring Patroni's
-- `_validate_and_adjust_timeouts` (config.py:293-331) and the
-- Kubernetes leader-election ordering `RetryPeriod < RenewDeadline <
-- LeaseDuration`.
--
-- Terminology is aligned with Patroni so the invariants read the same:
--   * ttl           (= roles_cfg.webui.failover.lease_ttl_sec)
--                   — lifetime of the coordinator / RW lease.
--   * loop_wait     (= keepalive_interval)
--                   — coordinator cycle / lease-renew period.
--   * retry_timeout (= probe_timeout_sec)
--                   — budget for a single etcd request.
--
-- Canonical invariants (replace the old approximate `keepalive*3` rule):
--   1. loop_wait + 2*retry_timeout <= ttl
--      — the leader gets two full renew attempts before the lease can
--        expire, so a short etcd blip does not cause a false failover.
--   2. ttl >= 2*loop_wait
--      — required to arm the dead-man watchdog (FO-15); otherwise the
--        hard deadline is too close to the renew deadline.
--
-- Auto-correction order matches Patroni (config.py:322-329): when the
-- triple does not fit, shrink loop_wait first, then retry_timeout. If
-- even the minimums do not fit the ttl, validation fails and the caller
-- refuses to start the agent with a clear error.
--
-- This module performs NO logging and reads NO global state — the caller
-- (failover/init.lua) logs the returned warnings and reacts to the error.
--

local math = require('math')

local M = {}

-- Recommended ttl floor. Below this we WARN but still start: the math
-- can still hold for a fast LAN cluster, but false failovers grow more
-- likely once etcd round-trips climb under load.
M.RECOMMENDED_TTL = 20

-- Hard minimums. Values below these are clamped up (with a WARN) rather
-- than rejected, so a careless tunable never produces a degenerate loop.
M.MINS = {
    loop_wait     = 1,
    retry_timeout = 3,
}

-- Defaults used when an opt is missing or non-positive. They satisfy
-- both invariants on their own (5 + 2*3 = 11 <= 20, and 20 >= 2*5).
M.DEFAULTS = {
    ttl           = 20,
    loop_wait     = 5,
    retry_timeout = 3,
    safety_margin = 5,
}

local function positive_or(value, fallback)
    local n = tonumber(value)
    if n ~= nil and n > 0 then
        return n
    end
    return fallback
end

-- Validate and auto-correct the role timings.
--
-- opts is the raw `roles_cfg.webui.failover` table (only the timing
-- keys are read: lease_ttl_sec, keepalive_interval, probe_timeout_sec /
-- probe_interval, safety_margin).
--
-- Returns:
--   adjusted, warnings, nil   — on success (adjusted is the canonical
--                               triple + safety_margin + renew_deadline)
--   nil, warnings, err        — when the invariant cannot be satisfied
--                               even at the minimum timings.
function M.validate_and_adjust(opts)
    opts = opts or {}
    local warnings = {}

    local ttl       = positive_or(opts.lease_ttl_sec, M.DEFAULTS.ttl)
    local loop_wait = positive_or(opts.keepalive_interval, M.DEFAULTS.loop_wait)
    local retry     = positive_or(opts.probe_timeout_sec
        or opts.probe_interval, M.DEFAULTS.retry_timeout)
    local safety    = positive_or(opts.safety_margin, M.DEFAULTS.safety_margin)

    -- Clamp the hard minimums up first so the rest of the math operates
    -- on sane inputs.
    if loop_wait < M.MINS.loop_wait then
        warnings[#warnings + 1] = string.format(
            'keepalive_interval %g below minimum %d; raised to %d',
            loop_wait, M.MINS.loop_wait, M.MINS.loop_wait)
        loop_wait = M.MINS.loop_wait
    end
    if retry < M.MINS.retry_timeout then
        warnings[#warnings + 1] = string.format(
            'probe_timeout_sec %g below minimum %d; raised to %d',
            retry, M.MINS.retry_timeout, M.MINS.retry_timeout)
        retry = M.MINS.retry_timeout
    end

    -- Soft recommended floor on ttl.
    if ttl < M.RECOMMENDED_TTL then
        warnings[#warnings + 1] = string.format(
            'lease_ttl_sec %g below recommended %d; false failovers more '
            .. 'likely under etcd latency', ttl, M.RECOMMENDED_TTL)
    end

    -- Invariant 2: ttl >= 2*loop_wait (watchdog arming). Shrink loop_wait
    -- to fit, never below its minimum.
    if ttl < 2 * loop_wait then
        local new_loop = math.max(M.MINS.loop_wait, math.floor(ttl / 2))
        warnings[#warnings + 1] = string.format(
            'keepalive_interval %g too large for lease_ttl_sec %g '
            .. '(needs lease_ttl >= 2*keepalive); reduced to %g',
            loop_wait, ttl, new_loop)
        loop_wait = new_loop
    end

    -- Invariant 1: loop_wait + 2*retry_timeout <= ttl. Shrink loop_wait
    -- first, then retry_timeout (Patroni order). Each step clamps at the
    -- minimum; if the minimums still do not fit, fail.
    if loop_wait + 2 * retry > ttl then
        local fitted_loop = math.max(M.MINS.loop_wait, ttl - 2 * retry)
        if fitted_loop < loop_wait then
            warnings[#warnings + 1] = string.format(
                'reduced keepalive_interval %g -> %g to satisfy '
                .. 'keepalive + 2*probe <= lease_ttl', loop_wait, fitted_loop)
            loop_wait = fitted_loop
        end

        if loop_wait + 2 * retry > ttl then
            local fitted_retry = math.max(M.MINS.retry_timeout,
                math.floor((ttl - loop_wait) / 2))
            if fitted_retry < retry then
                warnings[#warnings + 1] = string.format(
                    'reduced probe_timeout_sec %g -> %g to satisfy '
                    .. 'keepalive + 2*probe <= lease_ttl', retry, fitted_retry)
                retry = fitted_retry
            end
        end

        if loop_wait + 2 * retry > ttl then
            local floor_ttl = M.MINS.loop_wait + 2 * M.MINS.retry_timeout
            return nil, warnings, string.format(
                'failover timings unsatisfiable: keepalive(%g) + 2*probe(%g) '
                .. '> lease_ttl(%g) even at minimums; raise lease_ttl_sec to '
                .. '>= %d', loop_wait, retry, ttl, floor_ttl)
        end
    end

    -- renew_deadline = ttl - safety_margin (FO-1 self-fences here, before
    -- the lease can expire). Must stay strictly inside (0, ttl).
    if safety >= ttl then
        local new_safety = math.max(1, math.floor(ttl / 2))
        warnings[#warnings + 1] = string.format(
            'safety_margin %g >= lease_ttl_sec %g; reduced to %g',
            safety, ttl, new_safety)
        safety = new_safety
    end
    local renew_deadline = ttl - safety
    if renew_deadline < 1 then
        renew_deadline = math.max(1, ttl - 1)
    end

    -- Near-boundary heads-up: when the slack is thinner than one probe
    -- budget, a single slow etcd round-trip could still trip a failover.
    local slack = ttl - (loop_wait + 2 * retry)
    if slack >= 0 and slack < retry then
        warnings[#warnings + 1] = string.format(
            'timings near boundary (slack %gs < probe %gs); a single slow '
            .. 'etcd round could trigger failover', slack, retry)
    end

    return {
        ttl            = ttl,
        loop_wait      = loop_wait,
        retry_timeout  = retry,
        safety_margin  = safety,
        renew_deadline = renew_deadline,
    }, warnings, nil
end

-- Map the canonical triple back onto the role-opt names the agent and
-- watcher consume, so the caller can forward the corrected timings
-- without re-deriving the field names.
function M.to_role_opts(adjusted)
    return {
        lease_ttl_sec      = adjusted.ttl,
        keepalive_interval = adjusted.loop_wait,
        probe_timeout_sec  = adjusted.retry_timeout,
        safety_margin      = adjusted.safety_margin,
    }
end

return M
