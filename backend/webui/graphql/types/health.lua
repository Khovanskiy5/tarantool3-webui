-- GraphQL object types describing the role's own health surface.
-- Lives in graphql/types/* because future entity types follow the same
-- "one type per slice" layout described in the plan.

local types = require('graphql.types')

local M = {}

M.RoleStatus = types.object {
    name = 'RoleStatus',
    description = 'Snapshot of the local webui role lifecycle.',
    fields = {
        state = {
            kind = types.string.nonNull,
            description = 'One of: uninitialized, starting, ready, stopping, stopped.',
        },
        version = {
            kind = types.string.nonNull,
            description = 'WebUI rock SemVer.',
        },
        tarantool = {
            kind = types.string.nonNull,
            description = 'Tarantool runtime version (matches _TARANTOOL).',
        },
        instance = {
            kind = types.string,
            description = 'Instance alias from box.info, or null pre-bootstrap.',
        },
        startedAt = {
            kind = types.float,
            description = 'Epoch seconds when the role transitioned to ready.',
            resolve = function(root) return root.started_at end,
        },
        uptimeSec = {
            kind = types.float.nonNull,
            description = 'Seconds since the role transitioned to ready.',
            resolve = function(root) return root.uptime_sec end,
        },
        logLevel = {
            kind = types.string.nonNull,
            description = 'Current effective log level.',
            resolve = function(root) return root.log_level end,
        },
    },
}

return M
