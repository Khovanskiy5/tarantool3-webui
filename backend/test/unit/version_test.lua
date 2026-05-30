-- Smoke unit test for the version module.
--
-- This is the seed test — its primary purpose is to verify that
-- luatest discovery, package.path wiring and the rockspec module
-- mapping are all sane in CI. Real per-module unit tests land alongside
-- their subjects as each feature task ships (Tasks 17, 19, 26, …).

local t = require('luatest')

-- Make the in-tree backend/ modules visible to require(). This mirrors
-- what the installed rock does at runtime but keeps the CI run
-- independent from `tt rocks install`.
-- Source path looks like `/<repo>/backend/test/unit/foo_test.lua`.
-- Strip four levels of dirname to reach the repo root, then add the
-- backend module tree to package.path.
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' ..
               repo_root .. '/backend/?/init.lua;' ..
               package.path

local g = t.group('version')

local version = require('webui.version')

g.test_semver_is_string = function()
    t.assert_type(version.SEMVER, 'string')
    t.assert(version.SEMVER:match('^%d+%.%d+%.%d+'),
        'SEMVER must look like X.Y.Z')
end

g.test_min_max_tarantool_pinned = function()
    t.assert_type(version.MIN_TARANTOOL, 'string')
    t.assert_type(version.MAX_TARANTOOL_EXCLUSIVE, 'string')
end

g.test_protocol_versions_present = function()
    t.assert_type(version.WS_PROTOCOL_VERSION, 'number')
    t.assert_type(version.GRAPHQL_SCHEMA_GENERATION, 'number')
end

g.test_parse_returns_triplet_for_valid_strings = function()
    local v = version.parse('3.7.0')
    t.assert_type(v, 'table')
    t.assert_equals(#v, 3)
    t.assert_equals(v[1], 3)
    t.assert_equals(v[2], 7)
    t.assert_equals(v[3], 0)
end

g.test_parse_returns_nil_for_garbage = function()
    t.assert_equals(version.parse(nil), nil)
    t.assert_equals(version.parse(''), nil)
    t.assert_equals(version.parse('not-a-version'), nil)
end

g.test_compare_orders_versions = function()
    local a = version.parse('3.7.0')
    local b = version.parse('3.7.1')
    local c = version.parse('4.0.0')
    t.assert_equals(version.compare(a, a), 0)
    t.assert_equals(version.compare(a, b), -1)
    t.assert_equals(version.compare(b, a), 1)
    t.assert_equals(version.compare(a, c), -1)
end

g.test_check_tarantool_passes_on_supported_range = function()
    -- Override _TARANTOOL temporarily to simulate different builds.
    local original = _G._TARANTOOL
    _G._TARANTOOL = '3.7.0-0-gabc'
    local ok, err = version.check_tarantool()
    t.assert(ok, 'expected check_tarantool() to accept ' ..
        version.MIN_TARANTOOL .. ', got: ' .. tostring(err))
    _G._TARANTOOL = original
end

g.test_check_tarantool_rejects_too_old = function()
    local original = _G._TARANTOOL
    _G._TARANTOOL = '3.6.0-0-gabc'
    local ok, err = version.check_tarantool()
    t.assert_equals(ok, nil, 'expected rejection of 3.6.0')
    t.assert(err and err:match('older than required'), 'expected min-version error')
    _G._TARANTOOL = original
end

g.test_check_tarantool_rejects_too_new = function()
    local original = _G._TARANTOOL
    _G._TARANTOOL = '4.0.0-0-gabc'
    local ok, err = version.check_tarantool()
    t.assert_equals(ok, nil, 'expected rejection of 4.0.0')
    t.assert(err and err:match('at or beyond'), 'expected max-version error')
    _G._TARANTOOL = original
end
