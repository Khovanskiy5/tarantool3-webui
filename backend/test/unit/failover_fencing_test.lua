-- Unit tests for the pure self-fencing decision (Task FO-1).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_fencing')

local fencing = require('webui.failover.fencing')

g.test_not_leader_never_fences = function()
    t.assert_equals(fencing.should_fence({
        is_leader = false, now_mono = 1000,
        last_confirm_mono = 0, renew_deadline = 10,
    }), nil)
end

g.test_leader_within_deadline_does_not_fence = function()
    t.assert_equals(fencing.should_fence({
        is_leader = true, now_mono = 105,
        last_confirm_mono = 100, renew_deadline = 10,
    }), nil, 'gap 5 < deadline 10 → no fence')
end

g.test_leader_past_deadline_fences = function()
    t.assert_equals(fencing.should_fence({
        is_leader = true, now_mono = 111,
        last_confirm_mono = 100, renew_deadline = 10,
    }), 'lease_renew_timeout', 'gap 11 >= deadline 10 → fence')
end

g.test_exactly_at_deadline_fences = function()
    t.assert_equals(fencing.should_fence({
        is_leader = true, now_mono = 110,
        last_confirm_mono = 100, renew_deadline = 10,
    }), 'lease_renew_timeout')
end

g.test_bad_inputs_never_fence = function()
    t.assert_equals(fencing.should_fence(nil), nil)
    t.assert_equals(fencing.should_fence({}), nil)
    t.assert_equals(fencing.should_fence({
        is_leader = true, now_mono = nil,
        last_confirm_mono = 100, renew_deadline = 10,
    }), nil)
    t.assert_equals(fencing.should_fence({
        is_leader = true, now_mono = 200,
        last_confirm_mono = 100, renew_deadline = 0,
    }), nil, 'non-positive deadline → never fence')
end

-- ── appointment_is_stale (FO-4 fencing token) ──────────────────────

g.test_lower_term_is_stale = function()
    t.assert_equals(fencing.appointment_is_stale(5, 7), true,
        'term 5 < applied 7 → stale')
end

g.test_equal_term_not_stale = function()
    t.assert_equals(fencing.appointment_is_stale(7, 7), false,
        'same coordinator re-writes at the same term → not stale')
end

g.test_higher_term_not_stale = function()
    t.assert_equals(fencing.appointment_is_stale(9, 7), false,
        'newer coordinator term → not stale')
end

g.test_nil_term_never_stale = function()
    t.assert_equals(fencing.appointment_is_stale(nil, 7), false,
        'manual/legacy appointment (no term) is always honoured')
    t.assert_equals(fencing.appointment_is_stale(5, nil), false,
        'no baseline yet → accept')
end

-- ── vclock_dominates (FO-3 consistent switchover) ──────────────────

g.test_vclock_dominates_equal = function()
    t.assert_equals(fencing.vclock_dominates({[1]=10,[2]=5}, {[1]=10,[2]=5}), true)
end

g.test_vclock_dominates_ahead = function()
    t.assert_equals(fencing.vclock_dominates({[1]=12,[2]=5}, {[1]=10,[2]=5}), true)
end

g.test_vclock_does_not_dominate_when_behind = function()
    t.assert_equals(fencing.vclock_dominates({[1]=9,[2]=5}, {[1]=10,[2]=5}), false,
        'behind on replica 1 → not dominating')
end

g.test_vclock_missing_component_is_zero = function()
    t.assert_equals(fencing.vclock_dominates({[1]=10}, {[1]=10,[2]=3}), false,
        'missing component 2 treated as 0 < 3')
    t.assert_equals(fencing.vclock_dominates({[1]=10,[2]=0}, {[1]=10}), true)
end

g.test_vclock_ignores_component_zero = function()
    t.assert_equals(fencing.vclock_dominates({[1]=10}, {[0]=999,[1]=10}), true,
        'local noop stream (id 0) is ignored')
end

g.test_vclock_nil_target_dominates = function()
    t.assert_equals(fencing.vclock_dominates({[1]=10}, nil), true,
        'nothing to catch up to')
    t.assert_equals(fencing.vclock_dominates(nil, {[1]=10}), false)
end
