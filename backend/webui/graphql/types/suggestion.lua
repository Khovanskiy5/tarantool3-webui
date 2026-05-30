-- GraphQL types for the suggestions engine.
--
-- The Suggestions object aggregates every suggestion category
-- under a single field so the frontend can fetch the full set
-- with one query. Each list is empty when no suggestion of that
-- kind is active.
--
-- M1 only emits ForceApply and RestartReplication; the rest are
-- intentionally exposed with empty detectors so the schema is
-- stable for the UI when Task 46 / Task 47 land.

local types = require('graphql.types')

local M = {}

M.ForceApplySuggestion = types.object {
    name = 'ForceApplySuggestion',
    description = 'A peer whose config has not converged; apply config:reload() to recover.',
    fields = {
        id = { kind = types.string.nonNull,
            description = 'Stable identifier across ticks.' },
        instanceAlias = { kind = types.string.nonNull,
            description = 'Affected instance alias.',
            resolve = function(root) return root.alias end },
        instanceUuid = { kind = types.string,
            description = 'Affected instance UUID; null when not yet probed.',
            resolve = function(root) return root.uuid end },
        reason = { kind = types.string.nonNull },
    },
}

M.RestartReplicationSuggestion = types.object {
    name = 'RestartReplicationSuggestion',
    description = 'A peer with a broken upstream; restart its replication URIs.',
    fields = {
        id = { kind = types.string.nonNull },
        instanceAlias = { kind = types.string.nonNull,
            resolve = function(root) return root.alias end },
        instanceUuid = { kind = types.string,
            resolve = function(root) return root.uuid end },
        reason = { kind = types.string.nonNull },
    },
}

M.RefreshVshardSuggestion = types.object {
    name = 'RefreshVshardSuggestion',
    description = 'Recommendation to wake up vshard.router.discovery; populated in Task 47.',
    fields = {
        id = { kind = types.string.nonNull },
        routerUuid = { kind = types.string,
            resolve = function(root) return root.uuid end },
        reason = { kind = types.string.nonNull },
    },
}

M.DisableServerSuggestion = types.object {
    name = 'DisableServerSuggestion',
    description = 'Recommendation to take an instance out of the RW set; '
        .. 'populated once cluster-config edit ships (Task 30+).',
    fields = {
        id = { kind = types.string.nonNull },
        instanceUuid = { kind = types.string,
            resolve = function(root) return root.uuid end },
        reason = { kind = types.string.nonNull },
    },
}

M.RefineUriSuggestion = types.object {
    name = 'RefineUriSuggestion',
    description = 'Peer URI does not match the advertise URI in config; '
        .. 'populated once config-edit ships.',
    fields = {
        id = { kind = types.string.nonNull },
        instanceUuid = { kind = types.string,
            resolve = function(root) return root.uuid end },
        currentUri = { kind = types.string,
            resolve = function(root) return root.current_uri end },
        suggestedUri = { kind = types.string,
            resolve = function(root) return root.suggested_uri end },
    },
}

M.RestartFailoverSuggestion = types.object {
    name = 'RestartFailoverSuggestion',
    description = 'Supervised failover coordinator is unresponsive; '
        .. 'populated in Task 46.',
    fields = {
        id = { kind = types.string.nonNull },
        coordinatorEndpoint = { kind = types.string,
            resolve = function(root) return root.coordinator_endpoint end },
        reason = { kind = types.string.nonNull },
    },
}

M.BootstrapVshardSuggestion = types.object {
    name = 'BootstrapVshardSuggestion',
    description = 'A vshard group is not bootstrapped yet but every required '
        .. 'role is present; populated in Task 47.',
    fields = {
        id = { kind = types.string.nonNull },
        group = { kind = types.string.nonNull },
    },
}

M.Suggestions = types.object {
    name = 'Suggestions',
    description = 'All active suggestions, grouped by category.',
    fields = {
        forceApply = {
            kind = types.list(M.ForceApplySuggestion.nonNull).nonNull,
            resolve = function(root) return root.force_apply or {} end,
        },
        restartReplication = {
            kind = types.list(M.RestartReplicationSuggestion.nonNull).nonNull,
            resolve = function(root) return root.restart_replication or {} end,
        },
        refreshVshard = {
            kind = types.list(M.RefreshVshardSuggestion.nonNull).nonNull,
            resolve = function(root) return root.refresh_vshard or {} end,
        },
        disableServer = {
            kind = types.list(M.DisableServerSuggestion.nonNull).nonNull,
            resolve = function(root) return root.disable_server or {} end,
        },
        refineUri = {
            kind = types.list(M.RefineUriSuggestion.nonNull).nonNull,
            resolve = function(root) return root.refine_uri or {} end,
        },
        restartFailover = {
            kind = types.list(M.RestartFailoverSuggestion.nonNull).nonNull,
            resolve = function(root) return root.restart_failover or {} end,
        },
        bootstrapVshard = {
            kind = types.list(M.BootstrapVshardSuggestion.nonNull).nonNull,
            resolve = function(root) return root.bootstrap_vshard or {} end,
        },
    },
}

M.PeerActionResult = types.object {
    name = 'PeerActionResult',
    description = 'Per-peer outcome of an applySuggestion mutation.',
    fields = {
        peer = { kind = types.string.nonNull },
        ok   = { kind = types.boolean.nonNull },
        err  = { kind = types.string },
    },
}

M.SuggestionApplyResult = types.object {
    name = 'SuggestionApplyResult',
    description = 'Result of running an automated recovery against a set of peers.',
    fields = {
        ok = { kind = types.boolean.nonNull,
            description = 'True when the call was dispatched; '
                .. 'per-peer status lives in `results`. False when the '
                .. 'suggestion type is not implemented yet — see `message`.' },
        message = {
            kind = types.string,
            description = 'Diagnostic message when `ok=false`; null on success.' },
        unknown = {
            kind = types.list(types.string.nonNull).nonNull,
            description = 'Target UUIDs / aliases the resolver could not match.' },
        results = {
            kind = types.list(M.PeerActionResult.nonNull).nonNull,
            resolve = function(root)
                local out = {}
                for peer, res in pairs(root.results or {}) do
                    table.insert(out, {
                        peer = peer,
                        ok   = res.ok and true or false,
                        err  = res.ok and nil or res.err,
                    })
                end
                table.sort(out, function(a, b) return a.peer < b.peer end)
                return out
            end },
    },
}

return M
