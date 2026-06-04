-- Unit tests for the pure decision helpers in
-- backend/webui/recovery/identity_reset.lua. The box-touching wrappers
-- (snapshot_master / wait_peer_disconnected / expel_cluster_row) are
-- exercised by the integration recipe; here we cover the logic that
-- decides id lookup and connection state without a live box.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local ir = require('webui.recovery.identity_reset')

local g = t.group('recovery.identity_reset.find_cluster_row')

local ROWS = {
    { id = 1, uuid = 'uuid-1', name = 'tt-1' },
    { id = 2, uuid = 'uuid-2', name = 'tt-2' },
    { id = 3, uuid = 'uuid-3', name = 'tt-3' },
}

g.test_finds_row_by_name = function()
    t.assert_equals(ir._find_cluster_row(ROWS, 'tt-2'), { id = 2, uuid = 'uuid-2' })
end

g.test_returns_nil_for_absent_name = function()
    t.assert_equals(ir._find_cluster_row(ROWS, 'tt-404'), nil)
end

g.test_handles_bad_input = function()
    t.assert_equals(ir._find_cluster_row(nil, 'tt-1'), nil)
    t.assert_equals(ir._find_cluster_row(ROWS, nil), nil)
end

local g2 = t.group('recovery.identity_reset.is_disconnected')

g2.test_nil_entry_is_disconnected = function()
    -- No replication entry at all → the peer is gone.
    t.assert_equals(ir._is_disconnected(nil), true)
end

g2.test_active_upstream_is_connected = function()
    t.assert_equals(ir._is_disconnected({
        upstream = { status = 'follow' },
    }), false)
end

g2.test_active_downstream_is_connected = function()
    -- The incoming relay (downstream) is the one that wedges the name;
    -- a live relay means NOT yet safe to expel.
    t.assert_equals(ir._is_disconnected({
        downstream = { status = 'follow' },
    }), false)
end

g2.test_stopped_both_is_disconnected = function()
    t.assert_equals(ir._is_disconnected({
        upstream = { status = 'stopped' },
        downstream = { status = 'stopped' },
    }), true)
end

g2.test_disconnected_upstream_no_downstream = function()
    t.assert_equals(ir._is_disconnected({
        upstream = { status = 'disconnected' },
    }), true)
end

g2.test_connecting_counts_as_connected = function()
    -- A reconnecting applier is still a live link; wait it out.
    t.assert_equals(ir._is_disconnected({
        upstream = { status = 'connecting' },
    }), false)
end

g2.test_empty_entry_is_disconnected = function()
    t.assert_equals(ir._is_disconnected({}), true)
end

-- run() input guard runs before any box/leader access, so it is unit
-- testable. The full phase machine (expel -> wipe -> re-add -> verify)
-- is exercised by the integration recipe on the dev cluster (it is too
-- tightly coupled to box / rpc to mock meaningfully), matching how the
-- other recovery executors (orphan.lua, ops.lua) are tested.
local g3 = t.group('recovery.identity_reset.run_guard')

g3.test_run_rejects_missing_target = function()
    local res = ir.run({})
    t.assert_equals(res.ok, false)
    t.assert_equals(res.action, 'rebootstrap')
    t.assert_str_contains(res.error, 'target_alias')
end

g3.test_run_rejects_empty_target = function()
    local res = ir.run({ target_alias = '' })
    t.assert_equals(res.ok, false)
    t.assert_str_contains(res.error, 'target_alias')
end

g3.test_module_exposes_orchestrator_surface = function()
    t.assert_type(ir.run, 'function')
    t.assert_type(ir._run_on_leader, 'function')
    t.assert_type(ir.snapshot_master, 'function')
    t.assert_type(ir.expel_cluster_row, 'function')
    t.assert_type(ir.wait_peer_disconnected, 'function')
end
