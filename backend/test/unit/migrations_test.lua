-- Unit tests for backend/webui/storage/migrations.lua

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local migrations = require('webui.storage.migrations')

local g = t.group('migrations')

local catalog = {
    [2] = function() end,
    [3] = function() end,
    [4] = function() end,
}

g.test_plan_zero_when_versions_match = function()
    local steps = migrations.plan(2, 2, catalog)
    t.assert_equals(steps, {})
end

g.test_plan_lists_ordered_steps = function()
    local steps = migrations.plan(1, 4, catalog)
    t.assert_equals(steps, { 2, 3, 4 })
end

g.test_plan_refuses_downgrade = function()
    local steps, err = migrations.plan(3, 1, catalog)
    t.assert_equals(steps, nil)
    t.assert_str_contains(err, 'refuse downgrade')
end

g.test_plan_errors_on_missing_step = function()
    local sparse = { [2] = function() end, [4] = function() end }
    local steps, err = migrations.plan(1, 4, sparse)
    t.assert_equals(steps, nil)
    t.assert_str_contains(err, 'missing migration step 3')
end

g.test_plan_validates_inputs = function()
    local _, err = migrations.plan('a', 1, catalog)
    t.assert_str_contains(err, 'must be numbers')
end

g.test_run_requires_meta_space = function()
    local _, err = migrations.run({ current_version = 0, target_version = 1 })
    t.assert_str_contains(err, 'meta_space is required')
end

g.test_run_requires_target_version = function()
    local _, err = migrations.run({ meta_space = {}, current_version = 0 })
    t.assert_str_contains(err, 'target_version is required')
end

g.test_run_refuses_when_stored_newer_than_target = function()
    local _, err = migrations.run({
        meta_space = {}, current_version = 5, target_version = 3,
    })
    t.assert_str_contains(err, 'refusing to start')
    t.assert_str_contains(err, 'downgrade is unsafe')
end

g.test_run_noop_when_versions_equal = function()
    local result = migrations.run({
        meta_space = {}, current_version = 1, target_version = 1,
        migrations = catalog,
    })
    t.assert_equals(result.from, 1)
    t.assert_equals(result.to, 1)
    t.assert_equals(#result.applied, 0)
end
