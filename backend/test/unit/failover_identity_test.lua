-- Unit tests for the cluster identity (alien) guard (Task FO-17).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_identity')

local identity = require('webui.failover.identity')

g.test_not_pinned_is_not_alien = function()
    t.assert_equals(identity.is_alien(nil, 'uuid-a'), false)
    t.assert_equals(identity.is_alien('', 'uuid-a'), false)
end

g.test_matching_is_not_alien = function()
    t.assert_equals(identity.is_alien('uuid-a', 'uuid-a'), false)
end

g.test_mismatch_is_alien = function()
    t.assert_equals(identity.is_alien('uuid-a', 'uuid-b'), true)
end

g.test_missing_mine_is_not_alien = function()
    -- Cannot judge without a local identity → not alien (defer instead).
    t.assert_equals(identity.is_alien('uuid-a', nil), false)
    t.assert_equals(identity.is_alien('uuid-a', ''), false)
end

g.test_ensure_sysid_defers_without_client = function()
    local ok, info = identity.ensure_sysid(nil, 'rs-1', 'uuid-a')
    t.assert_equals(ok, false)
    t.assert_str_contains(info.error, 'etcd unavailable')
end

g.test_ensure_sysid_requires_local_uuid = function()
    local ok, info = identity.ensure_sysid({}, 'rs-1', nil)
    t.assert_equals(ok, false)
    t.assert_str_contains(info.error, 'uuid unavailable')
end
