-- Unit tests for the failover version-guard (Task FO-0).
--
-- The guard detects whether the running Tarantool build accepts
-- `replication.failover: supervised` and exposes the verdict via
-- M.status().version_guard. In a standalone unit context there is no
-- applied cluster config, so the schema probe returns nil (unknown) —
-- the contract is that it degrades gracefully and never throws.

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_version_guard')

local failover = require('webui.failover')

g.test_supervised_supported_never_throws = function()
    local ok, result = pcall(failover.supervised_supported)
    t.assert(ok, 'supervised_supported must not throw')
    -- true / false / nil are all valid: nil means "unknown" (schema
    -- shape unexpected or config not loaded in this context).
    t.assert(result == true or result == false or result == nil,
        'supervised_supported must return boolean or nil')
end

g.test_status_carries_version_guard_field = function()
    -- Before start, version_guard is nil; status() must still be a
    -- well-formed table exposing the field key.
    local status = failover.status()
    t.assert_type(status, 'table')
    t.assert_type(status.agent, 'table')
    t.assert_type(status.watcher, 'table')
    -- version_guard is nil until M.start runs; assert the call shape is
    -- stable (no error reading the field).
    t.assert(status.version_guard == nil or type(status.version_guard) == 'table')
end
