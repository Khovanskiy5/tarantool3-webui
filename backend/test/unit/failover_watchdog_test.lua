-- Unit tests for the dead-man switch decision (Task FO-15).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_watchdog')

local watchdog = require('webui.failover.watchdog')

g.test_not_leader_never_triggers = function()
    t.assert_equals(watchdog.should_trigger({
        is_leader = false, now_mono = 1000,
        last_confirm_mono = 0, hard_deadline = 15,
    }), false)
end

g.test_leader_within_deadline_does_not_trigger = function()
    t.assert_equals(watchdog.should_trigger({
        is_leader = true, now_mono = 110,
        last_confirm_mono = 100, hard_deadline = 15,
    }), false, 'gap 10 < hard_deadline 15')
end

g.test_leader_past_deadline_triggers = function()
    t.assert_equals(watchdog.should_trigger({
        is_leader = true, now_mono = 116,
        last_confirm_mono = 100, hard_deadline = 15,
    }), true, 'gap 16 >= hard_deadline 15')
end

g.test_bad_inputs_never_trigger = function()
    t.assert_equals(watchdog.should_trigger(nil), false)
    t.assert_equals(watchdog.should_trigger({}), false)
    t.assert_equals(watchdog.should_trigger({
        is_leader = true, now_mono = 200,
        last_confirm_mono = 100, hard_deadline = 0,
    }), false, 'non-positive hard_deadline → never trigger')
end

-- The injected exit_fn lets us assert the fiber fires without killing
-- the test process. We use a long hard_deadline=0-guard path indirectly
-- via should_trigger; here we just confirm start/stop are well-formed.
g.test_start_rejects_bad_options = function()
    local ok, err = watchdog.start({ hard_deadline = 0 })
    t.assert_equals(ok, nil)
    t.assert_str_contains(err, 'invalid options')
    watchdog._reset()
end
