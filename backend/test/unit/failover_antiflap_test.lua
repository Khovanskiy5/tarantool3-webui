-- Unit tests for the anti-flap circuit-breaker (Task FO-6).

local t = require('luatest')
local fio = require('fio')
local fiber = require('fiber')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_antiflap')

local antiflap = require('webui.failover.antiflap')

-- Deterministic, tight config for the tests.
local CFG = {
    lease_ttl_sec         = 20,   -- caps backoff at 20
    dampen_cycles         = 3,
    primary_start_timeout = 10,
    suppress_threshold    = 4,
    suppress_window       = 60,
    suppress_cooldown     = 60,
    promote_backoff_base  = 2,
}

g.before_each(function()
    antiflap._reset()
    antiflap.configure(CFG)
end)

-- ── Multi-cycle dampening (flow 2) ──────────────────────────────────

g.test_failover_blocked_until_dampen_cycles = function()
    local rs = 'rs1'
    local old_ts = 900 -- well past primary_start grace relative to `now`
    antiflap.observe(rs, false, 1000)
    local ok1 = antiflap.failover_allowed(rs, 1000, old_ts)
    t.assert_equals(ok1, false, '1 miss < 3 cycles → blocked')

    antiflap.observe(rs, false, 1001)
    antiflap.observe(rs, false, 1002)
    local ok3, why3 = antiflap.failover_allowed(rs, 1002, old_ts)
    t.assert_equals(ok3, true, '3 misses → allowed')
    t.assert_equals(why3, 'ok')
end

g.test_healthy_observation_resets_misses = function()
    local rs = 'rs1'
    antiflap.observe(rs, false, 1000)
    antiflap.observe(rs, false, 1001)
    antiflap.observe(rs, false, 1002)
    antiflap.observe(rs, true, 1003) -- recovered
    local ok = antiflap.failover_allowed(rs, 1003, 900)
    t.assert_equals(ok, false, 'a single healthy cycle disarms dampening')
end

g.test_single_miss_never_failovers = function()
    local rs = 'rs1'
    antiflap.observe(rs, false, 1000)
    local ok = antiflap.failover_allowed(rs, 1000, 900)
    t.assert_equals(ok, false, 'min_misses floor blocks a single-blip failover')
end

-- ── φ-accrual failure detector (flow 1) ─────────────────────────────

g.test_phi_pure_is_monotonic_and_adaptive = function()
    -- Same elapsed, tighter σ ⇒ higher suspicion (faster detection);
    -- wider σ ⇒ lower suspicion (more patient under jitter).
    local stable  = antiflap._phi(10, 5, 0.5)
    local jittery = antiflap._phi(10, 5, 3.27)
    t.assert(stable > jittery, 'stable heartbeat is suspected sooner')
    t.assert(stable >= 8, 'a steady 5s beat 10s overdue is clearly dead')
    t.assert(jittery < 8, 'a jittery beat 10s out is still plausible')
    -- φ grows with elapsed time.
    t.assert(antiflap._phi(12, 5, 0.5) > antiflap._phi(8, 5, 0.5))
end

g.test_mean_std_helper = function()
    local mu, sd = antiflap._mean_std({ 5, 5, 5 })
    t.assert_equals(mu, 5)
    t.assert_equals(sd, 0)
    local mu2, sd2 = antiflap._mean_std({ 1, 5, 9 })
    t.assert_equals(mu2, 5)
    t.assert_almost_equals(sd2, 3.2659, 0.01)
end

g.test_phi_detector_gates_failover = function()
    local rs = 'rs1'
    -- Build a steady 5s heartbeat history (3 intervals).
    antiflap.observe(rs, true, 0)
    antiflap.observe(rs, true, 5)
    antiflap.observe(rs, true, 10)
    antiflap.observe(rs, true, 15)
    -- Leader goes silent. misses climb; elapsed measured from t=15.
    antiflap.observe(rs, false, 18) -- miss 1
    antiflap.observe(rs, false, 20) -- miss 2, elapsed 5s ≈ μ → φ low
    local ok, why = antiflap.failover_allowed(rs, 20, -100)
    t.assert_equals(ok, false)
    t.assert_str_contains(why, 'phi', 'φ below threshold holds the failover')
    -- Suspicion builds as the gap widens past the mean.
    antiflap.observe(rs, false, 23) -- miss 3
    local ok2 = antiflap.failover_allowed(rs, 25, -100) -- elapsed 10s → φ high
    t.assert_equals(ok2, true, 'φ over threshold releases the failover')
end

-- ── primary_start grace (flow 4) ────────────────────────────────────

g.test_primary_start_grace_blocks_fresh_leader = function()
    local rs = 'rs1'
    antiflap.observe(rs, false, 1000)
    antiflap.observe(rs, false, 1000)
    antiflap.observe(rs, false, 1000)
    -- current leader appointed 5s ago, grace is 10s.
    local ok, why = antiflap.failover_allowed(rs, 1000, 995)
    t.assert_equals(ok, false)
    t.assert_str_contains(why, 'primary_start')
    -- 20s after appointment → grace passed.
    local ok2 = antiflap.failover_allowed(rs, 1000, 980)
    t.assert_equals(ok2, true)
end

-- ── Suppression circuit-breaker (flow 3) ────────────────────────────

g.test_suppression_trips_after_threshold = function()
    local rs = 'rs1'
    local now = 1000
    for i = 1, 4 do
        local newly, n = antiflap.record_change(rs, now + i)
        t.assert_equals(newly, false, '4 changes is at threshold, not over')
        t.assert_equals(n, i)
    end
    local newly5, n5 = antiflap.record_change(rs, now + 5)
    t.assert_equals(n5, 5)
    t.assert_equals(newly5, true, '5th change > threshold 4 → suppressed')
    t.assert_equals(antiflap.is_suppressed(rs, now + 5), true)
end

g.test_suppressed_blocks_failover_then_clears = function()
    local rs = 'rs1'
    local now = 1000
    for i = 1, 5 do antiflap.record_change(rs, now + i) end
    -- re-arm dampening (record_change reset misses)
    antiflap.observe(rs, false, now + 5)
    antiflap.observe(rs, false, now + 5)
    antiflap.observe(rs, false, now + 5)
    local ok, why = antiflap.failover_allowed(rs, now + 5, 900)
    t.assert_equals(ok, false)
    t.assert_str_contains(why, 'suppressed')
    -- after the cooldown (60s) suppression lifts
    local ok2 = antiflap.failover_allowed(rs, now + 5 + 61, 900)
    t.assert_equals(ok2, true)
end

g.test_change_window_prunes_old_entries = function()
    local rs = 'rs1'
    for _ = 1, 4 do antiflap.record_change(rs, 1000) end
    -- a 5th change far outside the window: the four at t=1000 expire.
    local newly, n = antiflap.record_change(rs, 1000 + 70)
    t.assert_equals(n, 1, 'only the in-window change counts')
    t.assert_equals(newly, false)
end

-- ── Per-candidate backoff (flow 5) ──────────────────────────────────

g.test_backoff_is_exponential_and_capped = function()
    -- base 2, cap 20 (= lease_ttl). failures 1..N → 2,4,8,16,20(capped).
    t.assert_equals(antiflap.note_promote_failure('a', 1000), 2)
    t.assert_equals(antiflap.note_promote_failure('a', 1000), 4)
    t.assert_equals(antiflap.note_promote_failure('a', 1000), 8)
    t.assert_equals(antiflap.note_promote_failure('a', 1000), 16)
    t.assert_equals(antiflap.note_promote_failure('a', 1000), 20, 'capped at lease_ttl')
end

g.test_backoff_set_membership_and_expiry = function()
    antiflap.note_promote_failure('a', 1000) -- until 1002
    t.assert_equals(antiflap.backoff_set(1001)['a'], true)
    local empty = antiflap.backoff_set(1003)
    t.assert_equals(empty['a'], nil, 'expired backoff is dropped')
end

g.test_promote_success_clears_backoff = function()
    antiflap.note_promote_failure('a', 1000)
    antiflap.note_promote_success('rs1', 'a')
    t.assert_equals(antiflap.backoff_set(1001)['a'], nil)
end

-- ── Appointment reconciliation (flow 4/5 glue) ──────────────────────

g.test_check_appointment_confirms_rw_leader = function()
    local rs = 'rs1'
    antiflap.note_appointed(rs, 'a', 1000)
    local verdict = antiflap.check_appointment(rs,
        { reachable = true, status = 'running', ro = false }, 1005)
    t.assert_equals(verdict, 'confirmed')
end

g.test_check_appointment_pending_within_grace = function()
    local rs = 'rs1'
    antiflap.note_appointed(rs, 'a', 1000)
    local verdict = antiflap.check_appointment(rs,
        { reachable = true, status = 'running', ro = true }, 1005)
    t.assert_equals(verdict, 'pending', 'still booting, within grace')
end

g.test_check_appointment_stalls_past_grace = function()
    local rs = 'rs1'
    antiflap.note_appointed(rs, 'a', 1000)
    -- still read-only 11s after appointment (grace 10) → stalled + backoff
    local verdict = antiflap.check_appointment(rs,
        { reachable = true, status = 'running', ro = true }, 1011)
    t.assert_equals(verdict, 'stalled')
    t.assert_equals(antiflap.backoff_set(1012)['a'], true)
end

-- ── Manual override clears state (flow 7) ───────────────────────────

g.test_clear_resets_replicaset_state = function()
    local rs = 'rs1'
    antiflap.observe(rs, false, 1000)
    antiflap.observe(rs, false, 1001)
    antiflap.observe(rs, false, 1002)
    antiflap.clear(rs)
    local ok, why = antiflap.failover_allowed(rs, 1003, 900)
    t.assert_equals(ok, false)
    t.assert_str_contains(why, 'dampening 0/3', 'misses reset to 0')
end

-- ── Snapshot shape (used by status + issues) ────────────────────────

g.test_snapshot_reports_state = function()
    local now = fiber.time()
    local rs = 'rs1'
    -- trip suppression using the real clock so the snapshot's
    -- fiber.time()-based `suppressed` flag agrees.
    for i = 1, 5 do antiflap.record_change(rs, now + i) end
    antiflap.note_promote_failure('b', now)
    local snap = antiflap.snapshot()
    t.assert_type(snap.replicasets, 'table')
    t.assert_type(snap.backoff, 'table')
    local found
    for _, e in ipairs(snap.replicasets) do
        if e.replicaset == rs then found = e end
    end
    t.assert_not_equals(found, nil)
    t.assert_equals(found.suppressed, true)
    t.assert_equals(found.changes_in_window, 5)
    t.assert_equals(snap.backoff[1].alias, 'b')
end

g.test_snapshot_elevated_before_suppression = function()
    local now = fiber.time()
    local rs = 'rs1'
    -- 3 changes: under the threshold of 4 → not suppressed, but the
    -- transition rate is elevated (>= threshold-1).
    antiflap.record_change(rs, now + 1)
    antiflap.record_change(rs, now + 2)
    antiflap.record_change(rs, now + 3)
    local function find(snap)
        for _, e in ipairs(snap.replicasets) do
            if e.replicaset == rs then return e end
        end
    end
    local e1 = find(antiflap.snapshot())
    t.assert_equals(e1.suppressed, false)
    t.assert_equals(e1.elevated, true, 'early-warning before the freeze')
    -- Two more trip suppression; elevated then yields to suppressed.
    antiflap.record_change(rs, now + 4)
    antiflap.record_change(rs, now + 5)
    local e2 = find(antiflap.snapshot())
    t.assert_equals(e2.suppressed, true)
    t.assert_equals(e2.elevated, false, 'suppressed and elevated are exclusive')
end
