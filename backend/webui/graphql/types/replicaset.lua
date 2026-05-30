-- GraphQL Replicaset type.
--
-- A replicaset is a group of servers sharing the same data and a
-- raft / classic master-replica relationship. Replicaset state is
-- derived from the per-server records in `cluster.state.snapshot()`
-- plus the cluster-config topology (config:instances()).
--
-- Fields that depend on subsystems not yet implemented (vshard
-- weight, roles, leader configuration) are exposed but resolve to
-- null / empty list for now. Doing so keeps the frontend schema
-- stable across the M1 series; later tasks fill the values without
-- breaking clients.

local types = require('graphql.types')

local server_types = require('webui.graphql.types.server')

local M = {}

M.Replicaset = types.object {
    name = 'Replicaset',
    description = 'A group of servers replicating the same data set.',
    fields = {
        name = {
            kind = types.string.nonNull,
            description = 'Replicaset name from cluster config.',
        },
        alias = {
            kind = types.string.nonNull,
            description = 'Display name. For Tarantool 3.x this is currently '
                .. 'identical to `name`; kept separate so the UI can render '
                .. 'a human-friendly label later without a schema change.',
        },
        uuid = {
            kind = types.string,
            description = 'Replicaset UUID. Null until at least one server in '
                .. 'the replicaset has been probed successfully.',
        },
        groupName = {
            kind = types.string,
            description = 'Cluster-config group name (e.g. "default", "storage", "router").',
            resolve = function(root) return root.group_name end,
        },
        status = {
            kind = types.string.nonNull,
            description = 'Aggregate health: healthy / degraded / unhealthy / unknown.',
        },
        roles = {
            kind = types.list(types.string.nonNull).nonNull,
            description = 'Roles enabled on this replicaset via cluster config. '
                .. 'Empty until the role-aware view lands in M2.',
        },
        weight = {
            kind = types.float,
            description = 'vshard storage weight. Null when vshard is not configured '
                .. '(filled in Task 47).',
        },
        leader = {
            kind = types.string,
            description = 'Alias of the configured leader. Null in election failover '
                .. 'mode because raft chooses the leader dynamically.',
        },
        activeLeader = {
            kind = types.string,
            description = 'Alias of the instance currently accepting writes; matches '
                .. '`box.info` of the read-write member.',
            resolve = function(root) return root.active_leader end,
        },
        allRw = {
            kind = types.boolean.nonNull,
            description = 'True when every member of the replicaset is read-write '
                .. '(asynchronous all-rw setup); false otherwise.',
            resolve = function(root) return root.all_rw end,
        },
        vshardGroup = {
            kind = types.string,
            description = 'Name of the vshard group when sharding is enabled.',
            resolve = function(root) return root.vshard_group end,
        },
        servers = {
            kind = types.list(server_types.Server.nonNull).nonNull,
            description = 'Members of the replicaset, sorted by alias.',
        },
    },
}

return M
