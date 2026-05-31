--
-- GraphQL types for audit-log entries.
--

local types = require('graphql.types')

local M = {}

M.AuditEntry = types.object({
    name = 'AuditEntry',
    description = 'A single immutable audit-log record.',
    fields = {
        id         = types.long.nonNull,
        ts         = types.long.nonNull, -- µs since epoch
        user       = types.string,
        action     = types.string.nonNull,
        scope      = types.string,
        request_id = types.string,
        payload    = types.string, -- JSON-encoded; SPA decodes on display
    },
})

M.AuditPage = types.object({
    name = 'AuditPage',
    fields = {
        entries     = types.list(M.AuditEntry.nonNull).nonNull,
        next_cursor = types.long, -- last id; pass back as `after`
        has_more    = types.boolean.nonNull,
    },
})

M.AuditFilter = types.inputObject({
    name = 'AuditFilter',
    fields = {
        user          = types.string,
        action        = types.string,
        action_prefix = types.string,
        scope         = types.string,
        from_ts       = types.long,
        to_ts         = types.long,
    },
})

M.AuditExport = types.object({
    name = 'AuditExport',
    fields = {
        format      = types.string.nonNull,
        body        = types.string.nonNull,
        record_count = types.long.nonNull,
    },
})

return M
