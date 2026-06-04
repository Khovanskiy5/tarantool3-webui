-- Unit tests for backend/webui/cluster/state.lua
--
-- All assertions hit the pure helpers (blank_server, group_by_replicaset,
-- merge_probe, build_next_state) and the snapshot deep-copy guarantee.
-- The fiber-driven write path is covered by the integration suite via
-- backend/webui/cluster/poller.lua.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local state = require('webui.cluster.state')

local g = t.group('state')

g.before_each(function() state._reset() end)

-- ── blank_server ────────────────────────────────────────────────────

g.test_blank_server_initial_shape = function()
    local s = state.blank_server('tt-1')
    t.assert_equals(s.alias, 'tt-1')
    t.assert_equals(s.status, 'unknown')
    t.assert_equals(s.reachable, false)
    t.assert_equals(s.alerts, {})
    t.assert_equals(s.labels, {})
end

g.test_blank_server_carries_topology_fields = function()
    local s = state.blank_server('tt-2', {
        replicaset_name = 'rs-1',
        group_name = 'default',
        zone = 'eu-central',
    })
    t.assert_equals(s.replicaset_name, 'rs-1')
    t.assert_equals(s.group_name, 'default')
    t.assert_equals(s.zone, 'eu-central')
end

-- ── group_by_replicaset ─────────────────────────────────────────────

g.test_group_by_replicaset_buckets_by_name = function()
    local servers = {
        ['tt-1'] = { replicaset_name = 'rs-a' },
        ['tt-2'] = { replicaset_name = 'rs-a' },
        ['tt-3'] = { replicaset_name = 'rs-b' },
    }
    local rs = state.group_by_replicaset(servers)
    t.assert_equals(rs['rs-a'].instances, { 'tt-1', 'tt-2' })
    t.assert_equals(rs['rs-b'].instances, { 'tt-3' })
end

g.test_group_by_replicaset_orphan_bucket = function()
    -- Servers without a replicaset name (orphaned via stale config)
    -- land in a fixed bucket so the UI never drops them silently.
    local rs = state.group_by_replicaset({
        ['stranger'] = {},
    })
    t.assert_equals(rs['_orphan'].instances, { 'stranger' })
end

g.test_group_by_replicaset_instances_are_sorted = function()
    local rs = state.group_by_replicaset({
        ['c'] = { replicaset_name = 'rs' },
        ['a'] = { replicaset_name = 'rs' },
        ['b'] = { replicaset_name = 'rs' },
    })
    t.assert_equals(rs['rs'].instances, { 'a', 'b', 'c' })
end

g.test_group_by_replicaset_handles_nil = function()
    t.assert_equals(state.group_by_replicaset(nil), {})
end

-- ── merge_probe ─────────────────────────────────────────────────────

g.test_merge_probe_copies_fields_over_blanks = function()
    local s = state.blank_server('tt-1')
    state.merge_probe(s, {
        uuid    = 'abc',
        version = '3.7.0',
        uptime  = 42,
        status  = 'running',
        ro      = false,
        ro_reason = nil,
        config_status = 'ready',
        config_alerts = { { type = 'warn', message = 'orphan' } },
    })
    t.assert_equals(s.uuid, 'abc')
    t.assert_equals(s.version, '3.7.0')
    t.assert_equals(s.uptime, 42)
    t.assert_equals(s.status, 'running')
    t.assert_equals(s.is_ro, false)
    t.assert_equals(s.config_status, 'ready')
    t.assert_equals(s.alerts[1].message, 'orphan')
    t.assert_equals(s.reachable, true)
end

g.test_merge_probe_with_nil_returns_server_unchanged = function()
    local s = state.blank_server('tt-1')
    state.merge_probe(s, nil)
    t.assert_equals(s.reachable, false)
    t.assert_equals(s.status, 'unknown')
end

g.test_merge_probe_carries_failover_health = function()
    -- The restart_failover detector reads server.failover off the
    -- snapshot, so merge_probe must carry the probe's failover block.
    local s = state.blank_server('tt-1')
    state.merge_probe(s, {
        failover = { config_enabled = true,
            agent_enabled = false, agent_running = false },
    })
    t.assert_type(s.failover, 'table')
    t.assert_equals(s.failover.config_enabled, true)
    t.assert_equals(s.failover.agent_enabled, false)
end

-- ── build_next_state ────────────────────────────────────────────────

g.test_build_next_state_with_only_topology = function()
    local built = state.build_next_state({
        topology = {
            ['tt-1'] = { replicaset_name = 'rs', group_name = 'default' },
            ['tt-2'] = { replicaset_name = 'rs', group_name = 'default' },
        },
        now = 100,
    })
    t.assert_equals(built.servers['tt-1'].status, 'unknown')
    t.assert_equals(built.servers['tt-2'].reachable, false)
    t.assert_equals(built.replicasets['rs'].instances, { 'tt-1', 'tt-2' })
end

g.test_build_next_state_overlays_local_probe = function()
    local built = state.build_next_state({
        self_alias  = 'tt-1',
        local_probe = { uuid = 'self-uuid', uptime = 12, version = '3.7.0' },
        topology = { ['tt-1'] = { replicaset_name = 'rs' } },
        now = 100,
    })
    t.assert_equals(built.servers['tt-1'].uuid, 'self-uuid')
    t.assert_equals(built.servers['tt-1'].uptime, 12)
    t.assert_equals(built.servers['tt-1'].reachable, true)
    t.assert_equals(built.servers['tt-1'].last_seen, 100)
end

g.test_build_next_state_overlays_peer_result_ok = function()
    local built = state.build_next_state({
        self_alias = 'tt-1',
        topology = {
            ['tt-1'] = { replicaset_name = 'rs' },
            ['tt-2'] = { replicaset_name = 'rs' },
        },
        peer_results = {
            ['tt-2'] = { ok = true, value = { uuid = 'peer-uuid', uptime = 99 } },
        },
        now = 200,
    })
    t.assert_equals(built.servers['tt-2'].uuid, 'peer-uuid')
    t.assert_equals(built.servers['tt-2'].uptime, 99)
    t.assert_equals(built.servers['tt-2'].reachable, true)
    t.assert_equals(built.servers['tt-2'].last_seen, 200)
end

g.test_build_next_state_marks_failing_peer_unreachable = function()
    local built = state.build_next_state({
        self_alias = 'tt-1',
        topology = {
            ['tt-1'] = { replicaset_name = 'rs' },
            ['tt-2'] = { replicaset_name = 'rs' },
        },
        peer_results = {
            ['tt-2'] = { ok = false, err = 'connection refused' },
        },
        now = 300,
    })
    t.assert_equals(built.servers['tt-2'].reachable, false)
    t.assert_equals(built.servers['tt-2'].status, 'unreachable')
    t.assert_equals(built.servers['tt-2'].last_error, 'connection refused')
end

g.test_build_next_state_carries_backoff = function()
    local built = state.build_next_state({
        self_alias = 'tt-1',
        topology = { ['tt-1'] = {}, ['tt-2'] = {} },
        backoff = { ['tt-2'] = { attempt = 2, next_retry_at = 500 } },
        now = 100,
    })
    t.assert_equals(built.servers['tt-2'].next_retry_at, 500)
end

g.test_build_next_state_self_excluded_from_peer_overlay = function()
    -- Even if a peer_results entry exists for self, it must not
    -- overwrite the in-process probe.
    local built = state.build_next_state({
        self_alias = 'tt-1',
        local_probe = { uuid = 'real-self' },
        peer_results = { ['tt-1'] = { ok = true, value = { uuid = 'tampered' } } },
        topology = { ['tt-1'] = { replicaset_name = 'rs' } },
        now = 100,
    })
    t.assert_equals(built.servers['tt-1'].uuid, 'real-self')
end

-- ── apply_tick + snapshot deep-copy ─────────────────────────────────

g.test_apply_tick_increments_generation = function()
    t.assert_equals(state.generation(), 0)
    state.apply_tick({ topology = { ['tt-1'] = {} }, now = 100 })
    state.apply_tick({ topology = { ['tt-1'] = {} }, now = 200 })
    t.assert_equals(state.generation(), 2)
end

g.test_snapshot_is_deep_copy = function()
    state.apply_tick({
        self_alias = 'tt-1',
        topology = { ['tt-1'] = { replicaset_name = 'rs' } },
        local_probe = { uuid = 'orig', alerts = { 'a1', 'a2' } },
        now = 100,
    })
    local s1 = state.snapshot()
    s1.servers['tt-1'].uuid = 'tampered'
    local s2 = state.snapshot()
    t.assert_equals(s2.servers['tt-1'].uuid, 'orig')
end

g.test_apply_tick_atomic_swap = function()
    -- Two consecutive ticks must each yield a complete snapshot —
    -- no field from tick N-1 leaking into tick N.
    state.apply_tick({
        self_alias  = 'tt-1',
        local_probe = { uuid = 'first' },
        topology    = { ['tt-1'] = {} },
        now         = 10,
    })
    state.apply_tick({
        self_alias  = 'tt-1',
        local_probe = { uuid = 'second' },
        topology    = { ['tt-1'] = {} },
        now         = 20,
    })
    local s = state.snapshot()
    t.assert_equals(s.servers['tt-1'].uuid, 'second')
    t.assert_equals(s.last_tick_at, 20)
end
