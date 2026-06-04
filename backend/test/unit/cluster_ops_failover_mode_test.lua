local t = require('luatest')
local fio = require('fio')
local yaml = require('yaml')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local cluster_ops = require('webui.graphql.resolvers.cluster_ops')

local g = t.group('cluster_ops.failover_transform')

-- Characterization of the pure YAML-transformation helpers extracted
-- from mutation_set_failover_mode / mutation_set_instance_state. These
-- lock the deterministic config rewrite (replication.failover, agent
-- toggle, database.mode / rs.leader strips, replication params,
-- election_mode) so the split is verified behaviour-preserving. The
-- 2PC / RPC / audit side-effects stay covered by the mandatory
-- dev-cluster check in the refactor task.

-- ── build_failover_repl_config ───────────────────────────────────────

g.test_build_supervised = function()
    local np = { replication = {} }
    cluster_ops._build_failover_repl_config(np, 'supervised', {})
    t.assert_equals(np.replication.failover, 'supervised')
    t.assert_equals(np.replication.bootstrap_strategy, 'auto')
    t.assert_equals(np.database.use_mvcc_engine, true)
    t.assert_equals(np.roles_cfg.webui.failover.agent, true)
end

g.test_build_supervised_merges_agent_params = function()
    local np = { replication = {} }
    cluster_ops._build_failover_repl_config(np, 'supervised',
        { agent_params = { lease_ttl_sec = 12 } })
    t.assert_equals(np.roles_cfg.webui.failover.lease_ttl_sec, 12)
    t.assert_equals(np.roles_cfg.webui.failover.agent, true)
end

g.test_build_election_forces_agent_off = function()
    local np = { replication = {} }
    cluster_ops._build_failover_repl_config(np, 'election', {})
    t.assert_equals(np.replication.failover, 'election')
    t.assert_equals(np.roles_cfg.webui.failover.agent, false)
end

g.test_build_manual_forces_agent_off = function()
    local np = { replication = {} }
    cluster_ops._build_failover_repl_config(np, 'manual', {})
    t.assert_equals(np.roles_cfg.webui.failover.agent, false)
end

g.test_build_off_defaults_agent_on = function()
    local np = { replication = {} }
    cluster_ops._build_failover_repl_config(np, 'off', {})
    t.assert_equals(np.replication.failover, 'off')
    t.assert_equals(np.roles_cfg.webui.failover.agent, true)
end

g.test_build_off_agent_false_disables = function()
    local np = { replication = {} }
    cluster_ops._build_failover_repl_config(np, 'off', { agent = false })
    t.assert_equals(np.roles_cfg.webui.failover.agent, false)
end

-- ── strip_instance_database_mode ─────────────────────────────────────

local function parsed_with_db_mode(mode_value, extra)
    local inst_db = { mode = mode_value }
    if extra then inst_db.use_mvcc_engine = true end
    return {
        groups = { g1 = { replicasets = { rs1 = {
            instances = { i1 = { database = inst_db } },
        } } } },
    }
end

g.test_strip_db_mode_election_removes_empty_database = function()
    local np = parsed_with_db_mode('rw')
    cluster_ops._strip_instance_database_mode(np, 'election')
    local inst = np.groups.g1.replicasets.rs1.instances.i1
    t.assert_equals(inst.database, nil)
end

g.test_strip_db_mode_keeps_non_empty_database = function()
    local np = parsed_with_db_mode('rw', true)
    cluster_ops._strip_instance_database_mode(np, 'supervised')
    local inst = np.groups.g1.replicasets.rs1.instances.i1
    t.assert_equals(inst.database.mode, nil)
    t.assert_equals(inst.database.use_mvcc_engine, true)
end

g.test_strip_db_mode_off_is_noop = function()
    local np = parsed_with_db_mode('rw')
    cluster_ops._strip_instance_database_mode(np, 'off')
    local inst = np.groups.g1.replicasets.rs1.instances.i1
    t.assert_equals(inst.database.mode, 'rw')
end

-- ── strip_replicaset_leaders ─────────────────────────────────────────

local function parsed_with_leader()
    return {
        groups = { g1 = { replicasets = {
            rs1 = { leader = 'i1', instances = { i1 = {} } },
        } } },
    }
end

g.test_strip_leaders_election = function()
    local np = parsed_with_leader()
    cluster_ops._strip_replicaset_leaders(np, 'election')
    t.assert_equals(np.groups.g1.replicasets.rs1.leader, nil)
end

g.test_strip_leaders_off = function()
    local np = parsed_with_leader()
    cluster_ops._strip_replicaset_leaders(np, 'off')
    t.assert_equals(np.groups.g1.replicasets.rs1.leader, nil)
end

g.test_strip_leaders_manual_is_noop = function()
    local np = parsed_with_leader()
    cluster_ops._strip_replicaset_leaders(np, 'manual')
    t.assert_equals(np.groups.g1.replicasets.rs1.leader, 'i1')
end

-- ── apply_replication_params ─────────────────────────────────────────

g.test_apply_replication_params_sets_supplied = function()
    local np = { replication = {} }
    cluster_ops._apply_replication_params(np, {
        synchro_quorum = 2,
        synchro_timeout = 5,
        election_timeout = 4,
        election_fencing_mode = 'soft',
    })
    t.assert_equals(np.replication.synchro_quorum, 2)
    t.assert_equals(np.replication.synchro_timeout, 5)
    t.assert_equals(np.replication.election_timeout, 4)
    t.assert_equals(np.replication.election_fencing_mode, 'soft')
end

g.test_apply_replication_params_skips_absent = function()
    local np = { replication = { synchro_quorum = 9 } }
    cluster_ops._apply_replication_params(np, {})
    t.assert_equals(np.replication.synchro_quorum, 9)
    t.assert_equals(np.replication.synchro_timeout, nil)
end

-- ── compute_new_election_mode ────────────────────────────────────────

g.test_election_mode_disabled_is_voter = function()
    t.assert_equals(cluster_ops._compute_new_election_mode(
        { enabled = false }), 'voter')
end

g.test_election_mode_not_electable_is_voter = function()
    t.assert_equals(cluster_ops._compute_new_election_mode(
        { electable = false }), 'voter')
end

g.test_election_mode_enabled_is_candidate = function()
    t.assert_equals(cluster_ops._compute_new_election_mode(
        { enabled = true }), 'candidate')
end

g.test_election_mode_electable_is_candidate = function()
    t.assert_equals(cluster_ops._compute_new_election_mode(
        { electable = true }), 'candidate')
end

g.test_election_mode_neither_is_nil = function()
    t.assert_equals(cluster_ops._compute_new_election_mode({}), nil)
end

-- ── patch_instance_election_mode ─────────────────────────────────────

g.test_patch_election_mode_sets_field = function()
    -- The helper now patches the RAW YAML text; feed it the source and
    -- assert the decoded result carries the new election_mode.
    local raw = table.concat({
        'groups:',
        '  g1:',
        '    replicasets:',
        '      rs1:',
        '        instances:',
        '          i1:',
        '            iproto:',
        '              advertise:',
        '                peer:',
        '                  uri: i1:3301',
        '',
    }, '\n')
    local new_yaml = cluster_ops._patch_instance_election_mode(
        raw, 'g1', 'rs1', 'i1', 'voter')
    local decoded = yaml.decode(new_yaml)
    t.assert_equals(
        decoded.groups.g1.replicasets.rs1.instances.i1.replication.election_mode,
        'voter')
end
