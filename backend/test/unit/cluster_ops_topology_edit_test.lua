-- Unit tests for webui.cluster_ops.topology_edit.
--
-- Pure module: no etcd, no net.box. We assert that the resulting
-- config table reflects every documented kind of edit (add/change/
-- remove instance, replicaset roles/leader/failover_priority/weight,
-- vshard_group), that batches are atomic on validation failure, and
-- that the input table is never mutated in place.

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;backend/?/init.lua;' .. package.path

local topology_edit = require('webui.cluster_ops.topology_edit')

local g = t.group('cluster_ops_topology_edit')

-- Three-instance cluster blueprint matching docker/configs/cluster/40-topology.yaml.
-- Built by hand (rather than yaml.decode'd) so the test stays
-- hermetic — no yaml rock dependency, no fixture file drift.
local function base_cfg()
    return {
        groups = {
            ['default'] = {
                replicasets = {
                    ['rs-1'] = {
                        instances = {
                            ['tt-1'] = {
                                database = { mode = 'rw' },
                                iproto = {
                                    advertise = { peer = { uri = 'tt-1:3301' } },
                                },
                            },
                            ['tt-2'] = {
                                database = { mode = 'rw' },
                                iproto = {
                                    advertise = { peer = { uri = 'tt-2:3301' } },
                                },
                            },
                            ['tt-3'] = {
                                database = { mode = 'rw' },
                                iproto = {
                                    advertise = { peer = { uri = 'tt-3:3301' } },
                                },
                            },
                        },
                    },
                },
            },
        },
    }
end

g.test_no_edits_is_noop = function()
    local cfg = base_cfg()
    local new_cfg, ops, errs = topology_edit.apply(cfg, {})
    t.assert_not_equals(new_cfg, nil)
    t.assert_equals(#ops, 0)
    t.assert_equals(#errs, 0)
end

g.test_change_database_mode = function()
    local cfg = base_cfg()
    local new_cfg, ops, errs = topology_edit.apply(cfg, {
        servers = { { alias = 'tt-2', mode = 'ro' } },
    })
    t.assert_equals(#errs, 0)
    t.assert_equals(#ops, 1)
    t.assert_equals(ops[1].op, 'change')
    t.assert_equals(ops[1].before, 'rw')
    t.assert_equals(ops[1].after, 'ro')
    t.assert_equals(
        new_cfg.groups['default'].replicasets['rs-1'].instances['tt-2']
            .database.mode, 'ro')
    -- Input table must NOT be mutated.
    t.assert_equals(
        cfg.groups['default'].replicasets['rs-1'].instances['tt-2']
            .database.mode, 'rw')
end

g.test_set_replicaset_roles = function()
    local cfg = base_cfg()
    local new_cfg, ops, errs = topology_edit.apply(cfg, {
        replicasets = { {
            name  = 'rs-1',
            roles = { 'app.roles.storage', 'vshard-storage' },
        } },
    })
    t.assert_equals(#errs, 0)
    t.assert_equals(#ops, 1)
    t.assert_equals(ops[1].op, 'add')
    t.assert_equals(
        new_cfg.groups['default'].replicasets['rs-1'].roles,
        { 'app.roles.storage', 'vshard-storage' })
end

g.test_set_leader_must_be_in_replicaset = function()
    local cfg = base_cfg()
    local _, _, errs = topology_edit.apply(cfg, {
        replicasets = { { name = 'rs-1', leader = 'ghost' } },
    })
    t.assert_equals(#errs, 1)
    t.assert_str_contains(errs[1].message, 'not in the replicaset')
end

g.test_set_leader_in_replicaset = function()
    local cfg = base_cfg()
    local new_cfg, ops, errs = topology_edit.apply(cfg, {
        replicasets = { { name = 'rs-1', leader = 'tt-1' } },
    })
    t.assert_equals(#errs, 0)
    t.assert_equals(#ops, 1)
    t.assert_equals(
        new_cfg.groups['default'].replicasets['rs-1'].leader, 'tt-1')
end

g.test_failover_priority_list = function()
    local cfg = base_cfg()
    local new_cfg, _, errs = topology_edit.apply(cfg, {
        replicasets = { {
            name              = 'rs-1',
            failover_priority = { 'tt-2', 'tt-1', 'tt-3' },
        } },
    })
    t.assert_equals(#errs, 0)
    t.assert_equals(
        new_cfg.groups['default'].replicasets['rs-1'].failover_priority,
        { 'tt-2', 'tt-1', 'tt-3' })
end

g.test_join_new_instance_to_existing_replicaset = function()
    local cfg = base_cfg()
    local spec = {
        database = { mode = 'rw' },
        iproto = { advertise = { peer = { uri = 'tt-4:3301' } } },
    }
    local new_cfg, ops, errs = topology_edit.apply(cfg, {
        replicasets = { {
            name = 'rs-1',
            join_instances = { ['tt-4'] = spec },
        } },
    })
    t.assert_equals(#errs, 0)
    -- One op for the new instance.
    t.assert_equals(#ops, 1)
    t.assert_equals(ops[1].op, 'add')
    t.assert_equals(
        new_cfg.groups['default'].replicasets['rs-1'].instances['tt-4'], spec)
end

g.test_join_duplicate_alias_rejected = function()
    local cfg = base_cfg()
    local _, _, errs = topology_edit.apply(cfg, {
        replicasets = { {
            name = 'rs-1',
            join_instances = {
                ['tt-1'] = { database = { mode = 'rw' } },
            },
        } },
    })
    t.assert_equals(#errs, 1)
    t.assert_str_contains(errs[1].message, 'already present')
end

g.test_create_new_replicaset = function()
    local cfg = base_cfg()
    local new_cfg, ops, errs = topology_edit.apply(cfg, {
        replicasets = { {
            name           = 'rs-2',
            group          = 'default',
            roles          = { 'app.roles.router' },
            join_instances = {
                ['tt-r1'] = {
                    database = { mode = 'rw' },
                    iproto = {
                        advertise = { peer = { uri = 'tt-r1:3301' } },
                    },
                },
            },
            leader = 'tt-r1',
            weight = 0,
        } },
    })
    t.assert_equals(#errs, 0)
    t.assert(#ops >= 3)
    local rs2 = new_cfg.groups['default'].replicasets['rs-2']
    t.assert_not_equals(rs2, nil)
    t.assert_equals(rs2.roles, { 'app.roles.router' })
    t.assert_equals(rs2.leader, 'tt-r1')
    t.assert_equals(rs2.weight, 0)
    t.assert_not_equals(rs2.instances['tt-r1'], nil)
end

g.test_expel_instance_drops_from_failover_priority = function()
    local cfg = base_cfg()
    -- Seed a failover_priority list before expelling.
    cfg.groups['default'].replicasets['rs-1'].failover_priority =
        { 'tt-1', 'tt-2', 'tt-3' }
    local new_cfg, _, errs = topology_edit.apply(cfg, {
        replicasets = { {
            name = 'rs-1',
            expel_instances = { 'tt-2' },
        } },
    })
    t.assert_equals(#errs, 0)
    local rs = new_cfg.groups['default'].replicasets['rs-1']
    t.assert_equals(rs.instances['tt-2'], nil)
    t.assert_equals(rs.failover_priority, { 'tt-1', 'tt-3' })
end

g.test_expel_unknown_alias_rejected = function()
    local cfg = base_cfg()
    local _, _, errs = topology_edit.apply(cfg, {
        replicasets = { {
            name = 'rs-1',
            expel_instances = { 'ghost' },
        } },
    })
    t.assert_equals(#errs, 1)
    t.assert_str_contains(errs[1].message, 'not present')
end

g.test_atomic_failure_keeps_input_intact = function()
    local cfg = base_cfg()
    -- Two edits: the first one is fine, the second one fails — the
    -- whole batch must be discarded.
    local new_cfg, ops, errs = topology_edit.apply(cfg, {
        replicasets = {
            { name = 'rs-1', roles = { 'app.roles.storage' } },
            { name = 'rs-1', leader = 'ghost' },
        },
    })
    t.assert_equals(new_cfg, nil)
    t.assert_equals(#ops, 0)
    t.assert_equals(#errs, 1)
    -- Original cfg untouched.
    t.assert_equals(cfg.groups['default'].replicasets['rs-1'].roles, nil)
end

g.test_replicaset_weight_validates = function()
    local cfg = base_cfg()
    local _, _, errs = topology_edit.apply(cfg, {
        replicasets = { { name = 'rs-1', weight = -5 } },
    })
    t.assert_equals(#errs, 1)
    t.assert_str_contains(errs[1].message, 'non-negative')
end

g.test_server_mode_validates = function()
    local cfg = base_cfg()
    local _, _, errs = topology_edit.apply(cfg, {
        servers = { { alias = 'tt-1', mode = 'bogus' } },
    })
    t.assert_equals(#errs, 1)
    t.assert_str_contains(errs[1].message, 'rw')
end

g.test_unknown_alias_without_target_rejected = function()
    local cfg = base_cfg()
    local _, _, errs = topology_edit.apply(cfg, {
        servers = { { alias = 'ghost', mode = 'rw' } },
    })
    t.assert_equals(#errs, 1)
    t.assert_str_contains(errs[1].message, 'not found')
end

g.test_change_uri = function()
    local cfg = base_cfg()
    local new_cfg, _, errs = topology_edit.apply(cfg, {
        servers = { { alias = 'tt-1', uri = '10.0.0.1:3301' } },
    })
    t.assert_equals(#errs, 0)
    t.assert_equals(
        new_cfg.groups['default'].replicasets['rs-1'].instances['tt-1']
            .iproto.advertise.peer.uri, '10.0.0.1:3301')
end

g.test_set_vshard_group_on_replicaset = function()
    local cfg = base_cfg()
    local new_cfg, _, errs = topology_edit.apply(cfg, {
        replicasets = { { name = 'rs-1', vshard_group = 'hot' } },
    })
    t.assert_equals(#errs, 0)
    t.assert_equals(
        new_cfg.groups['default'].replicasets['rs-1'].sharding.group, 'hot')
end
