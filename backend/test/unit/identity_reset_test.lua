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

local g4 = t.group('recovery.identity_reset.pick_fresh_id')

g4.test_picks_lowest_free_clean_id = function()
    -- ids 1,2 registered; vclock has history only for them → next clean id is 3.
    t.assert_equals(ir._pick_fresh_id({ [1] = true, [2] = true },
        { [1] = 100, [2] = 50 }), 3)
end

g4.test_skips_freed_id_with_vclock_history = function()
    -- id 3 was expelled (not in _cluster) but its vclock component is
    -- non-zero — reusing it would resurrect a stale relay position, so it
    -- must be skipped in favour of a truly unused id (4).
    t.assert_equals(ir._pick_fresh_id({ [1] = true, [2] = true },
        { [1] = 100, [2] = 50, [3] = 7 }), 4)
end

g4.test_zero_vclock_component_is_reusable = function()
    -- A registered-then-removed id whose vclock reads 0 never wrote
    -- anything and is safe to assign.
    t.assert_equals(ir._pick_fresh_id({ [1] = true },
        { [1] = 100, [2] = 0 }), 2)
end

g4.test_returns_nil_when_exhausted = function()
    local used, vclock = {}, {}
    for id = 1, 31 do used[id] = true; vclock[id] = id end
    t.assert_equals(ir._pick_fresh_id(used, vclock), nil)
end

g4.test_handles_nil_input = function()
    -- Empty cluster / fresh vclock → id 1 is the first clean slot.
    t.assert_equals(ir._pick_fresh_id(nil, nil), 1)
end

local g5 = t.group('recovery.identity_reset.limbo_settled')

g5.test_owned_and_writable_is_settled = function()
    -- Leader owns the queue (owner == self id) and is writable → settled.
    t.assert_equals(ir._limbo_settled({ queue = { owner = 1 } }, 1, false), true)
end

g5.test_read_only_is_not_settled = function()
    -- A frozen/demoted leader is RO; its checkpoint would poison the join.
    t.assert_equals(ir._limbo_settled({ queue = { owner = 1 } }, 1, true), false)
end

g5.test_foreign_owner_is_not_settled = function()
    -- Queue owned by another node (or 0 after a demote) → not settled.
    t.assert_equals(ir._limbo_settled({ queue = { owner = 3 } }, 1, false), false)
    t.assert_equals(ir._limbo_settled({ queue = { owner = 0 } }, 1, false), false)
end

g5.test_busy_limbo_is_not_settled = function()
    -- An in-flight limbo operation → wait it out.
    t.assert_equals(ir._limbo_settled({ queue = { owner = 1, busy = true } },
        1, false), false)
end

g5.test_handles_missing_synchro = function()
    t.assert_equals(ir._limbo_settled(nil, 1, false), false)
    t.assert_equals(ir._limbo_settled({}, 1, false), false)
end

local g6 = t.group('recovery.identity_reset.laggards')

g6.test_no_laggards_when_all_reached_full_topology = function()
    -- want=3: both peers report 3 replication URIs → caught up.
    local res = {
        ['tt-2'] = { ok = true, value = 3 },
        ['tt-4'] = { ok = true, value = 3 },
    }
    t.assert_equals(ir._laggards({ 'tt-2', 'tt-4' }, res, 3), {})
end

g6.test_peer_below_full_size_is_a_laggard = function()
    -- tt-4 still at 2 URIs (stuck in the EXPEL view, target missing).
    local res = {
        ['tt-2'] = { ok = true, value = 3 },
        ['tt-4'] = { ok = true, value = 2 },
    }
    t.assert_equals(ir._laggards({ 'tt-2', 'tt-4' }, res, 3), { 'tt-4' })
end

g6.test_rpc_failure_counts_as_laggard = function()
    -- No response / rpc error → can't confirm, treat as laggard so we retry.
    local res = { ['tt-2'] = { ok = false, err = 'timeout' } }
    t.assert_equals(ir._laggards({ 'tt-2', 'tt-5' }, res, 3), { 'tt-2', 'tt-5' })
end

g6.test_empty_result_all_laggards = function()
    t.assert_equals(ir._laggards({ 'tt-2', 'tt-3' }, nil, 3), { 'tt-2', 'tt-3' })
end

g6.test_no_peers_no_laggards = function()
    t.assert_equals(ir._laggards({}, {}, 3), {})
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
    t.assert_type(ir.wait_peer_connected, 'function')
    t.assert_type(ir.pick_fresh_id, 'function')
    t.assert_type(ir.preregister_row, 'function')
    t.assert_type(ir.wait_limbo_settled, 'function')
    t.assert_type(ir.ensure_peers_replicating, 'function')
    t.assert_type(ir._laggards, 'function')
    t.assert_type(ir._run_phases, 'function')
end
