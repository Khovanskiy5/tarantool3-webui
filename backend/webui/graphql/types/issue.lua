-- GraphQL Issue / IssuesSummary / IssuePage types.
--
-- An issue is a single finding produced by the issues scanner
-- (cluster/issues.lua) — short, structured, identified by a
-- stable ID across ticks. The GraphQL surface mirrors the Lua
-- shape one-to-one so the resolver does not need to translate
-- fields.

local types = require('graphql.types')

local M = {}

M.IssueSeverity = types.enum {
    name = 'IssueSeverity',
    values = {
        WARNING  = { value = 'warning' },
        CRITICAL = { value = 'critical' },
    },
    description = 'Issue severity. The scanner only emits these two levels.',
}

M.IssueScope = types.enum {
    name = 'IssueScope',
    values = {
        CLUSTER    = { value = 'cluster' },
        REPLICASET = { value = 'replicaset' },
        INSTANCE   = { value = 'instance' },
    },
    description = 'Where the issue applies.',
}

M.IssueCategory = types.enum {
    name = 'IssueCategory',
    values = {
        REPLICATION = { value = 'replication' },
        MEMORY      = { value = 'memory' },
        CLOCK       = { value = 'clock' },
        CONFIG      = { value = 'config' },
        SYNCHRO     = { value = 'synchro' },
        FAILOVER    = { value = 'failover' },
    },
    description = 'Category of issue. New rules add values here.',
}

M.Issue = types.object {
    name = 'Issue',
    description = 'A single finding emitted by the issues scanner.',
    fields = {
        id = {
            kind = types.string.nonNull,
            description = 'Stable identifier across ticks — '
                .. 'format `category:scope:target:key`.',
        },
        severity = {
            kind = M.IssueSeverity.nonNull,
        },
        category = {
            kind = M.IssueCategory.nonNull,
        },
        scope = {
            kind = M.IssueScope.nonNull,
        },
        message = {
            kind = types.string.nonNull,
            description = 'Human-readable description of the issue.',
        },
        instance = {
            kind = types.string,
            description = 'Instance alias when the issue scope is INSTANCE.',
        },
        replicaset = {
            kind = types.string,
            description = 'Replicaset name for INSTANCE / REPLICASET scopes.',
        },
        createdAt = {
            kind = types.float,
            description = 'fiber.clock() of the first observation.',
            resolve = function(root) return root.created_at end,
        },
        updatedAt = {
            kind = types.float,
            description = 'fiber.clock() of the most recent observation.',
            resolve = function(root) return root.updated_at end,
        },
    },
}

M.IssuePage = types.object {
    name = 'IssuePage',
    description = 'Cursor-paginated slice of issues.',
    fields = {
        items = {
            kind = types.list(M.Issue.nonNull).nonNull,
            description = 'Page contents.',
        },
        nextCursor = {
            kind = types.string,
            description = 'Issue ID of the last item in the returned page; '
                .. 'pass as `after` to fetch the next page. Null on the '
                .. 'final page.',
            resolve = function(root) return root.next_cursor end,
        },
        totalCount = {
            kind = types.int.nonNull,
            description = 'Total number of issues matching the current filter.',
            resolve = function(root) return root.total_count end,
        },
    },
}

M.IssuesSummary = types.object {
    name = 'IssuesSummary',
    description = 'Severity-level counts used by the TopBar badge.',
    fields = {
        warning = {
            kind = types.int.nonNull,
            description = 'Total warning-level issues.',
        },
        critical = {
            kind = types.int.nonNull,
            description = 'Total critical-level issues.',
        },
        total = {
            kind = types.int.nonNull,
            description = 'Sum of warning + critical.',
        },
    },
}

return M
