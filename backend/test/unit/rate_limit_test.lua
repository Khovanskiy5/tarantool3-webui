local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local rl = require('webui.auth.rate_limit')

local g = t.group('rate_limit')

g.before_each(function() rl._reset() end)

g.test_check_allows_until_max_failures = function()
    for i = 1, rl.MAX_FAILURES do
        t.assert_equals(rl.check('1.2.3.4', 'login'), true,
            'attempt ' .. i .. ' should be allowed')
        rl.fail('1.2.3.4', 'login')
    end
    local allowed = rl.check('1.2.3.4', 'login')
    t.assert_equals(allowed, false)
end

g.test_success_clears_counter = function()
    rl.fail('1.2.3.4', 'login')
    rl.fail('1.2.3.4', 'login')
    rl.success('1.2.3.4', 'login')
    t.assert_equals(rl.check('1.2.3.4', 'login'), true)
end

g.test_prune_entry_resets_after_window = function()
    local entry = { count = 3, last = 100 }
    -- 100 + 60 (window) > 159 → kept
    t.assert_equals(rl.prune_entry(entry, 159, 60), entry)
    -- 100 + 60 ≤ 161 → reset
    t.assert_equals(rl.prune_entry(entry, 161, 60), nil)
    t.assert_equals(rl.prune_entry(nil, 0, 60), nil)
end

g.test_per_ip_isolation = function()
    for _ = 1, rl.MAX_FAILURES do
        rl.fail('1.1.1.1', 'login')
    end
    t.assert_equals(rl.check('1.1.1.1', 'login'), false)
    t.assert_equals(rl.check('2.2.2.2', 'login'), true)
end

g.test_per_action_isolation = function()
    for _ = 1, rl.MAX_FAILURES do
        rl.fail('1.1.1.1', 'login')
    end
    t.assert_equals(rl.check('1.1.1.1', 'login'), false)
    t.assert_equals(rl.check('1.1.1.1', 'csrf'), true)
end
