--
-- Anti-flap circuit-breaker for the failover coordinator (FO-6).
--
-- During a restart storm a naive coordinator ping-pongs leadership:
-- it sees the primary miss one probe, promotes a replacement, the old
-- primary comes back, and the cycle repeats. This module adds four
-- dampening layers on top of the existing hysteresis
-- (`min_promotion_interval`) and auto-return throttle
-- (`autoreturn_delay`):
--
--   1. φ-accrual failure detection — the current leader is declared
--      dead from an adaptive suspicion level (Hayashibara φ), computed
--      from the distribution of recent healthy-observation intervals.
--      A stable heartbeat → fast detection; a jittery one → patient.
--      Before enough samples accumulate it falls back to a simple
--      `dampen_cycles` consecutive-miss counter, and a hard `min_misses`
--      floor means a single asymmetric blip never triggers a failover.
--   2. primary_start grace — a freshly-appointed leader gets
--      `primary_start_timeout` seconds to actually come up before it
--      can be failed over (it boots read-only and needs time to
--      promote).
--   3. Suppression circuit-breaker — more than `suppress_threshold`
--      leader changes inside `suppress_window` seconds freezes
--      auto-promotions for `suppress_cooldown` seconds and raises a
--      "failover suppressed: flapping" issue (Cartridge-style).
--   4. Per-candidate backoff — a deposed or stall-to-promote candidate
--      is excluded from the race for an exponentially growing window
--      (capped at the lease ttl), so the coordinator prefers a
--      different peer rather than re-appointing the flapping one.
--
-- State is module-local and keyed by replicaset name. The module does
-- no etcd / box access and reads only the wall clock (fiber.time), so
-- every decision is unit-testable by passing `now` explicitly.
--
-- Manual operator appointments bypass all of this: the coordinator's
-- manual-override branch calls M.clear(rs) so suppression and counters
-- never block a deliberate human action.
--

local fiber = require('fiber')

local M = {}

M.DEFAULTS = {
    dampen_cycles         = 3,    -- consecutive-miss fallback before failover
    min_misses            = 2,    -- hard floor: never failover under N misses
    primary_start_timeout = 10,   -- grace for a just-appointed leader to boot
    suppress_threshold    = 4,    -- changes-in-window that trip suppression
    suppress_window       = 60,   -- sliding window for the change counter
    suppress_cooldown     = 60,   -- how long auto-promotions stay frozen
    promote_backoff_base  = 2,    -- first backoff step, seconds
    promote_backoff_max   = 20,   -- cap (agent overrides with lease_ttl)
    -- φ-accrual failure detector:
    phi_threshold         = 8,    -- suspicion level that declares "dead"
    phi_min_samples       = 3,    -- intervals needed before φ is trusted
    phi_max_samples       = 100,  -- sliding sample window size
    phi_min_stddev        = 0.5,  -- σ floor (seconds) — guards jumpiness
}

local STATE = {
    config  = nil,
    per_rs  = {},   -- rs_name -> { misses, unhealthy_since, changes[], suppressed_until, appointed, intervals[], last_healthy_at }
    backoff = {},   -- alias -> { until_ts, failures }
}

local function config()
    return STATE.config or M.DEFAULTS
end

local function entry_for(rs)
    local e = STATE.per_rs[rs]
    if e == nil then
        e = { misses = 0, unhealthy_since = nil, changes = {},
              suppressed_until = nil, appointed = nil,
              intervals = {}, last_healthy_at = nil }
        STATE.per_rs[rs] = e
    end
    return e
end

-- Sample mean and population stddev of a numeric list.
local function mean_std(samples)
    local n = #samples
    if n == 0 then return 0, 0 end
    local sum = 0
    for _, v in ipairs(samples) do sum = sum + v end
    local mu = sum / n
    local var = 0
    for _, v in ipairs(samples) do
        local d = v - mu
        var = var + d * d
    end
    return mu, math.sqrt(var / n)
end
M._mean_std = mean_std

-- Hayashibara φ from a normal-distribution tail (Akka's logistic
-- approximation). Higher φ = exponentially more confident the heartbeat
-- is overdue. φ = -log10(P(interval >= elapsed)).
local function phi_value(elapsed, mu, sigma)
    if sigma < 1e-9 then sigma = 1e-9 end
    local y = (elapsed - mu) / sigma
    local e = math.exp(-y * (1.5976 + 0.070566 * y * y))
    local p
    if elapsed > mu then
        p = e / (1.0 + e)
    else
        p = 1.0 - 1.0 / (1.0 + e)
    end
    if p < 1e-300 then p = 1e-300 end
    return -(math.log(p) / math.log(10))
end
M._phi = phi_value

-- Current φ for a replicaset, or nil when there is not enough history
-- (caller falls back to the consecutive-miss counter).
local function compute_phi(e, now, cfg)
    if #e.intervals < cfg.phi_min_samples then return nil end
    if e.last_healthy_at == nil then return nil end
    local mu, sigma = mean_std(e.intervals)
    if sigma < cfg.phi_min_stddev then sigma = cfg.phi_min_stddev end
    return phi_value(now - e.last_healthy_at, mu, sigma)
end

-- Is the current leader suspected dead? Returns (bool, phi_or_nil,
-- misses). A hard `min_misses` floor blocks single-blip failovers; with
-- enough φ samples the adaptive detector decides, otherwise the
-- consecutive-miss counter does.
local function suspected_dead(e, now, cfg)
    local misses = e.misses or 0
    if misses < cfg.min_misses then return false, nil, misses end
    local phi = compute_phi(e, now, cfg)
    if phi == nil then
        return misses >= cfg.dampen_cycles, nil, misses
    end
    return phi >= cfg.phi_threshold, phi, misses
end

-- Pure: count timestamps in `list` newer than (now - window); also
-- compacts the list in place to drop expired entries.
local function prune_and_count(list, now, window)
    local kept = {}
    for _, ts in ipairs(list) do
        if (now - ts) < window then
            kept[#kept + 1] = ts
        end
    end
    for i = #list, 1, -1 do list[i] = nil end
    for i, ts in ipairs(kept) do list[i] = ts end
    return #kept
end

M._prune_and_count = prune_and_count

-- Apply role tunables. lease_ttl_sec caps the backoff window so a
-- backed-off candidate always rejoins within one lease lifetime.
function M.configure(opts)
    opts = opts or {}
    local d = M.DEFAULTS
    local function pos(v, default)
        local n = tonumber(v)
        if n ~= nil and n > 0 then return n end
        return default
    end
    local cfg = {
        dampen_cycles         = pos(opts.dampen_cycles, d.dampen_cycles),
        min_misses            = pos(opts.min_misses, d.min_misses),
        primary_start_timeout = pos(opts.primary_start_timeout,
            d.primary_start_timeout),
        suppress_threshold    = pos(opts.suppress_threshold,
            d.suppress_threshold),
        suppress_window       = pos(opts.suppress_window, d.suppress_window),
        suppress_cooldown     = pos(opts.suppress_cooldown,
            d.suppress_cooldown),
        promote_backoff_base  = pos(opts.promote_backoff_base,
            d.promote_backoff_base),
        promote_backoff_max   = pos(opts.lease_ttl_sec
            or opts.promote_backoff_max, d.promote_backoff_max),
        phi_threshold         = pos(opts.phi_threshold, d.phi_threshold),
        phi_min_samples       = pos(opts.phi_min_samples, d.phi_min_samples),
        phi_max_samples       = pos(opts.phi_max_samples, d.phi_max_samples),
        phi_min_stddev        = pos(opts.phi_min_stddev, d.phi_min_stddev),
    }
    STATE.config = cfg
    return cfg
end

-- Record one observation of the current appointed leader's health.
-- Healthy resets the miss counter and feeds the φ heartbeat-interval
-- window; unhealthy increments the miss counter and stamps the
-- first-unhealthy time.
function M.observe(rs, healthy, now)
    local e = entry_for(rs)
    if healthy then
        if e.last_healthy_at ~= nil then
            local interval = now - e.last_healthy_at
            if interval > 0 then
                e.intervals[#e.intervals + 1] = interval
                local cap = config().phi_max_samples
                while #e.intervals > cap do table.remove(e.intervals, 1) end
            end
        end
        e.last_healthy_at = now
        e.misses = 0
        e.unhealthy_since = nil
    else
        e.misses = (e.misses or 0) + 1
        if e.unhealthy_since == nil then e.unhealthy_since = now end
    end
end

-- Is a FAILOVER (replacing an unhealthy current leader) allowed right
-- now for this replicaset? Returns (bool, reason). A cold appointment
-- (no current leader) is NOT a failover — the caller skips this gate.
function M.failover_allowed(rs, now, current_ts)
    local cfg = config()
    local e = entry_for(rs)
    if e.suppressed_until ~= nil and now < e.suppressed_until then
        return false, string.format('suppressed for %.0fs more',
            e.suppressed_until - now)
    end
    local dead, phi, misses = suspected_dead(e, now, cfg)
    if not dead then
        if phi ~= nil then
            return false, string.format('phi %.1f < %g', phi, cfg.phi_threshold)
        end
        return false, string.format('dampening %d/%d cycles',
            misses, cfg.dampen_cycles)
    end
    if current_ts ~= nil and (now - current_ts) < cfg.primary_start_timeout then
        return false, string.format('primary_start grace %.0fs/%ds',
            now - current_ts, cfg.primary_start_timeout)
    end
    return true, 'ok'
end

-- Record a leadership change that actually happened. Updates the
-- sliding window and trips suppression when the rate is too high.
-- Returns (newly_suppressed_bool, changes_in_window).
function M.record_change(rs, now)
    local cfg = config()
    local e = entry_for(rs)
    e.changes[#e.changes + 1] = now
    local n = prune_and_count(e.changes, now, cfg.suppress_window)
    -- Resetting the dead-leader counters + φ history here keeps the next
    -- cycle from immediately re-arming suspicion against the freshly
    -- promoted leader (whose heartbeat history is now irrelevant).
    e.misses = 0
    e.unhealthy_since = nil
    e.intervals = {}
    e.last_healthy_at = nil
    local newly = false
    if n > cfg.suppress_threshold then
        local already = e.suppressed_until ~= nil and now < e.suppressed_until
        e.suppressed_until = now + cfg.suppress_cooldown
        newly = not already
    end
    return newly, n
end

function M.is_suppressed(rs, now)
    local e = STATE.per_rs[rs]
    return e ~= nil and e.suppressed_until ~= nil and now < e.suppressed_until
end

-- Wipe a replicaset's flap state. Called when a manual override takes
-- effect so operator action starts from a clean slate.
function M.clear(rs)
    STATE.per_rs[rs] = nil
end

-- Mark which alias the coordinator just appointed for `rs`, so a later
-- cycle can tell whether the promote actually took (success) or stalled
-- (backoff + try the next candidate).
function M.note_appointed(rs, alias, now)
    local e = entry_for(rs)
    e.appointed = { alias = alias, since = now }
end

-- The appointed leader is confirmed read-write — clear its backoff and
-- the pending appointment marker.
function M.note_promote_success(rs, alias)
    STATE.backoff[alias] = nil
    local e = STATE.per_rs[rs]
    if e ~= nil and e.appointed ~= nil and e.appointed.alias == alias then
        e.appointed = nil
    end
end

-- A candidate failed or stalled to promote — push it onto an
-- exponential backoff so the coordinator prefers a different peer.
function M.note_promote_failure(alias, now)
    local cfg = config()
    local b = STATE.backoff[alias] or { failures = 0 }
    b.failures = b.failures + 1
    local step = cfg.promote_backoff_base * (2 ^ (b.failures - 1))
    if step > cfg.promote_backoff_max then step = cfg.promote_backoff_max end
    b.until_ts = now + step
    STATE.backoff[alias] = b
    return step
end

-- Evaluate the pending appointment for `rs` against the current probe
-- of the appointed alias. Returns the action the caller should take:
--   'confirmed' — leader is read-write; success recorded
--   'stalled'   — past primary_start grace and still not RW; backed off
--   'pending'   — still within grace, keep waiting
--   nil         — nothing appointed
function M.check_appointment(rs, probe, now)
    local e = STATE.per_rs[rs]
    if e == nil or e.appointed == nil then return nil end
    local cfg = config()
    local alias = e.appointed.alias
    if probe ~= nil and probe.reachable
        and probe.status == 'running' and probe.ro == false then
        M.note_promote_success(rs, alias)
        return 'confirmed', alias
    end
    if (now - e.appointed.since) > cfg.primary_start_timeout then
        M.note_promote_failure(alias, now)
        e.appointed = nil
        return 'stalled', alias
    end
    return 'pending', alias
end

-- Set of aliases currently in backoff (for merging into pick_leader's
-- disabled set). Compacts expired entries as a side effect.
function M.backoff_set(now)
    local out = {}
    for alias, b in pairs(STATE.backoff) do
        if b.until_ts ~= nil and now < b.until_ts then
            out[alias] = true
        else
            STATE.backoff[alias] = nil
        end
    end
    return out
end

-- Diagnostic snapshot for agent.status() / issues. Uses fiber.time()
-- so the `suppressed` flag is evaluated against the same clock the rest
-- of the module uses — callers must NOT re-derive it from a different
-- clock.
function M.snapshot()
    local cfg = config()
    local now = fiber.time()
    local replicasets = {}
    for rs, e in pairs(STATE.per_rs) do
        local in_window = prune_and_count(e.changes, now, cfg.suppress_window)
        local suppressed = e.suppressed_until ~= nil
            and now < e.suppressed_until
        -- Elevated = transition rate climbing toward the suppression
        -- trip but not yet frozen (early warning, K8s-style).
        local elevated = (not suppressed)
            and in_window >= (cfg.suppress_threshold - 1)
        replicasets[#replicasets + 1] = {
            replicaset       = rs,
            misses           = e.misses or 0,
            phi              = compute_phi(e, now, cfg),
            changes_in_window = in_window,
            elevated         = elevated,
            suppressed       = suppressed,
            suppressed_until = e.suppressed_until,
            appointed        = e.appointed and e.appointed.alias,
        }
    end
    table.sort(replicasets, function(a, b)
        return (a.replicaset or '') < (b.replicaset or '')
    end)
    local backoff = {}
    for alias, b in pairs(STATE.backoff) do
        if b.until_ts ~= nil and now < b.until_ts then
            backoff[#backoff + 1] = {
                alias = alias, until_ts = b.until_ts, failures = b.failures,
            }
        end
    end
    table.sort(backoff, function(a, b) return (a.alias or '') < (b.alias or '') end)
    return { replicasets = replicasets, backoff = backoff }
end

-- Test hook.
function M._reset()
    STATE.config = nil
    STATE.per_rs = {}
    STATE.backoff = {}
end

return M
