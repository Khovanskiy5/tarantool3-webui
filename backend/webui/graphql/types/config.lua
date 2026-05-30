--
-- GraphQL types for the config-editor surface.
--

local types = require('graphql.types')

local M = {}

M.ConfigCurrent = types.object({
    name = 'ConfigCurrent',
    fields = {
        yaml      = types.string.nonNull,
        revision  = types.long,
        source    = types.string.nonNull, -- "etcd" | "file" | "memory"
    },
})

M.ConfigValidationIssue = types.object({
    name = 'ConfigValidationIssue',
    fields = {
        path    = types.string.nonNull,
        message = types.string.nonNull,
    },
})

M.ConfigDiffOp = types.object({
    name = 'ConfigDiffOp',
    fields = {
        op    = types.string.nonNull,
        path  = types.string.nonNull,
        from  = types.string,
        to    = types.string,
    },
})

M.ConfigPrepareResult = types.object({
    name = 'ConfigPrepareResult',
    fields = {
        prepared_id = types.string.nonNull,
        expires_at  = types.long.nonNull,
        diff        = types.list(M.ConfigDiffOp.nonNull),
        warnings    = types.list(M.ConfigValidationIssue.nonNull),
    },
})

M.ConfigCommitResult = types.object({
    name = 'ConfigCommitResult',
    fields = {
        revision = types.long.nonNull,
        applied  = types.boolean.nonNull,
        message  = types.string,
    },
})

M.ConfigHistoryEntry = types.object({
    name = 'ConfigHistoryEntry',
    fields = {
        revision  = types.long.nonNull,
        ts        = types.long,
        user      = types.string,
        size      = types.long,
    },
})

return M
