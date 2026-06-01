-- WebUI GraphQL schema composition.
--
-- The schema is rebuilt once per role start (graphql.server.init) and
-- held in module-level state. Resolvers are deliberately thin: they
-- read from already-prepared state (role status, config:jsonschema()),
-- never block on net.box or etcd. Heavier resolvers land in later
-- tasks (cluster, config, schema, etc.) and follow the same pattern:
-- read from cluster/state.lua, return immediately.
--
-- Naming follows the contract in plan/Iter 18:
--   * Object types and scalars   PascalCase
--   * Fields and arguments        camelCase
--   * Enum values                 UPPER_SNAKE_CASE
--   * Mutations                   verbObject (configCommit, expelInstance, …)
--
-- Resolver-level error policy: each resolver may return (nil, err)
-- where err is an errors-rock object. graphql.server.handler() catches
-- exec failures via pcall and maps them to the standard envelope.

local json = require('json')
local fiber = require('fiber')

local types = require('graphql.types')
local schema_mod = require('graphql.schema')

local version = require('webui.version')
local health_types     = require('webui.graphql.types.health')
local server_types     = require('webui.graphql.types.server')
local replicaset_types = require('webui.graphql.types.replicaset')
local issue_types      = require('webui.graphql.types.issue')
local suggestion_types = require('webui.graphql.types.suggestion')
local cluster_resolver = require('webui.graphql.resolvers.cluster')
local issues_resolver  = require('webui.graphql.resolvers.issues')
local suggestions_resolver = require('webui.graphql.resolvers.suggestions')
local audit_types          = require('webui.graphql.types.audit')
local audit_resolver       = require('webui.graphql.resolvers.audit')
local config_types         = require('webui.graphql.types.config')
local config_resolver      = require('webui.graphql.resolvers.config')
local lifecycle_resolver   = require('webui.graphql.resolvers.lifecycle')
local failover_resolver    = require('webui.graphql.resolvers.failover')
local vshard_resolver      = require('webui.graphql.resolvers.vshard')
local admin_data_resolver  = require('webui.graphql.resolvers.admin_data')
local data_explorer_types  = require('webui.graphql.types.data_explorer')
local saved_queries_resolver = require('webui.graphql.resolvers.saved_queries')
local bootstrap_resolver   = require('webui.graphql.resolvers.bootstrap')
local webhooks_resolver    = require('webui.graphql.resolvers.webhooks')
local cluster_ops_resolver = require('webui.graphql.resolvers.cluster_ops')

local M = {}

-- ── ISO 8601 helper ────────────────────────────────────────────────────
local function iso8601_now()
    local t64 = fiber.time64()
    local seconds = tonumber(t64 / 1000000ULL)
    local micros  = tonumber(t64 % 1000000ULL)
    return string.format('%s.%06dZ',
        os.date('!%Y-%m-%dT%H:%M:%S', seconds), micros)
end

-- ── Resolvers ──────────────────────────────────────────────────────────

local function resolve_role_status()
    -- Lazy require avoids a hard cycle: webui.init → graphql.server.init
    -- → graphql.schema (this file) → webui. The require returns the
    -- already-loaded module table, so cycle detection succeeds.
    local webui = require('webui')
    return webui.status()
end

local function resolve_config_jsonschema()
    -- Tarantool 3.x exposes the cluster config JSON Schema natively.
    -- The schema is the single source of truth for backend validation
    -- and Monaco autocomplete, so we serialise it as a JSON string for
    -- clients to parse with their preferred JSON library.
    local ok, cfg = pcall(require, 'config')
    if not ok or cfg == nil or cfg.jsonschema == nil then
        return nil
    end
    local jsok, js = pcall(cfg.jsonschema, cfg)
    if not jsok or js == nil then
        return nil
    end
    return json.encode(js)
end

-- ── Cluster query payload ─────────────────────────────────────────────
--
-- `cluster` returns an object that exposes self / servers /
-- replicasets / knownRoles / vshardGroups. The wrapper carries the
-- snapshot taken at the top-level resolver call so every sub-field
-- below sees the same state, even if the poller runs between fields.

local ClusterPayload = types.object {
    name = 'Cluster',
    description = 'Aggregated cluster view derived from cluster.state.snapshot().',
    fields = {
        self = {
            kind = server_types.Server,
            description = 'The instance answering this query. Null before bootstrap.',
            resolve = cluster_resolver.cluster_self,
        },
        servers = {
            kind = server_types.ServerPage.nonNull,
            description = 'Cursor-paginated list of servers (default page 50, max 500).',
            arguments = {
                after = types.string,
                limit = types.int,
            },
            resolve = cluster_resolver.cluster_servers,
        },
        replicasets = {
            kind = types.list(replicaset_types.Replicaset.nonNull).nonNull,
            description = 'All replicasets, sorted by name.',
            resolve = cluster_resolver.cluster_replicasets,
        },
        knownRoles = {
            kind = types.list(types.string.nonNull).nonNull,
            description = 'Role identifiers configurable on a replicaset. Populated in M2.',
            resolve = cluster_resolver.cluster_known_roles,
        },
        vshardGroups = {
            kind = types.list(types.string.nonNull).nonNull,
            description = 'Names of configured vshard groups. Populated in Task 47.',
            resolve = cluster_resolver.cluster_vshard_groups,
        },
    },
}

-- ── Query root ────────────────────────────────────────────────────────

local Query = types.object {
    name = 'Query',
    description = 'Read-only entry point of the WebUI admin API.',
    fields = {
        ping = {
            kind = types.string.nonNull,
            description = 'Liveness check; returns "pong".',
            resolve = function() return 'pong' end,
        },
        serverTime = {
            kind = types.string.nonNull,
            description = 'ISO 8601 UTC current time on the responding instance, microsecond precision.',
            resolve = function() return iso8601_now() end,
        },
        webuiVersion = {
            kind = types.string.nonNull,
            description = 'WebUI rock SemVer.',
            resolve = function() return version.SEMVER end,
        },
        roleStatus = {
            kind = health_types.RoleStatus.nonNull,
            description = 'Lifecycle status of this instance\'s webui role.',
            resolve = resolve_role_status,
        },
        configJsonSchema = {
            kind = types.string,
            description = 'JSON-encoded JSON Schema of the Tarantool cluster ' ..
                'config, taken from `config:jsonschema()`. Null when the ' ..
                'config module is unavailable.',
            resolve = resolve_config_jsonschema,
        },
        cluster = {
            kind = ClusterPayload.nonNull,
            description = 'Aggregated cluster view (self, servers, replicasets, '
                .. 'knownRoles, vshardGroups). Source: cluster.state.snapshot().',
            resolve = cluster_resolver.cluster,
        },
        issues = {
            kind = issue_types.IssuePage.nonNull,
            description = 'Findings produced by the issues scanner. Supports '
                .. 'severity / scope / category / instance / replicaset filters '
                .. 'and cursor pagination over the issue ID.',
            arguments = {
                severity   = issue_types.IssueSeverity,
                scope      = issue_types.IssueScope,
                category   = issue_types.IssueCategory,
                instance   = types.string,
                replicaset = types.string,
                after      = types.string,
                limit      = types.int,
            },
            resolve = issues_resolver.issues,
        },
        issuesSummary = {
            kind = issue_types.IssuesSummary.nonNull,
            description = 'Counts of issues by severity. Drives the TopBar badge.',
            resolve = issues_resolver.issues_summary,
        },
        suggestions = {
            kind = suggestion_types.Suggestions.nonNull,
            description = 'Automated recovery suggestions for the current '
                .. 'cluster state. Empty lists when no suggestion applies.',
            resolve = suggestions_resolver.suggestions,
        },
        failover = {
            kind = types.object({
                name = 'FailoverState',
                fields = {
                    mode = types.string.nonNull,
                    elections = types.list(types.object({
                        name = 'ElectionState',
                        fields = {
                            instance    = types.string.nonNull,
                            state       = types.string,
                            term        = types.long,
                            -- Alias of the elected raft leader (e.g.
                            -- "tt-1"). Sourced from `box.info.election
                            -- .leader_name`; Tarantool 3.x does not
                            -- expose a leader UUID directly.
                            leader_name = types.string,
                        },
                    })),
                },
            }).nonNull,
            description = 'Failover mode + per-server election state.',
            resolve = failover_resolver.query_failover,
        },
        failoverAgentStatus = {
            kind = types.object({
                name = 'FailoverAgentStatus',
                fields = {
                    enabled        = types.boolean.nonNull,
                    self_alias     = types.string,
                    coordinator    = types.string,
                    is_coordinator = types.boolean,
                    lease_id       = types.string,
                    last_error     = types.string,
                    paused_until   = types.float,
                    watcher_replicaset  = types.string,
                    watcher_last_leader = types.string,
                    watcher_current_ro  = types.boolean,
                    appointments   = types.list(types.object({
                        name = 'FailoverAppointment',
                        fields = {
                            replicaset = types.string.nonNull,
                            leader     = types.string,
                            previous   = types.string,
                            ts         = types.float,
                        },
                    })),
                },
            }).nonNull,
            description = 'Open-source supervised-failover agent state. '
                .. '`enabled=false` when roles_cfg.webui.failover.agent '
                .. 'is unset; the SPA hides the panel in that case.',
            resolve = failover_resolver.query_agent_status,
        },
        failoverCommands = {
            kind = types.object({
                name = 'FailoverCommandsPage',
                fields = {
                    entries = types.list(types.object({
                        name = 'FailoverCommand',
                        fields = {
                            id           = types.long.nonNull,
                            ts           = types.float.nonNull,
                            command_type = types.string.nonNull,
                            params       = types.string,
                            status       = types.string.nonNull,
                            user         = types.string,
                            coordinator  = types.string,
                            taken_at     = types.float,
                            completed_at = types.float,
                            error_reason = types.string,
                        },
                    })),
                },
            }).nonNull,
            arguments = {
                limit        = types.int,
                status       = types.string,
                command_type = types.string,
            },
            description = 'TCM-style commands history. One row per ' ..
                'operator-issued cluster mutation (promote, pause, ' ..
                'force_apply, expel, set_failover_mode, ...). ' ..
                'Replicated + sync — the row the API just confirmed ' ..
                'survives an immediate leader crash.',
            resolve = failover_resolver.query_commands,
        },
        failoverStateProviderStatus = {
            kind = types.object({
                name = 'FailoverStateProviderStatus',
                fields = {
                    kind = types.string.nonNull,
                    mode = types.string.nonNull,
                    endpoints = types.list(types.object({
                        name = 'FailoverStateProviderEndpoint',
                        fields = {
                            uri        = types.string.nonNull,
                            status     = types.string.nonNull,
                            latency_ms = types.float,
                            last_error = types.string,
                        },
                    })),
                    lease_active = types.boolean,
                    coordinator  = types.string,
                },
            }).nonNull,
            description = 'Per-endpoint probe of the supervised-failover state '
                .. 'provider. Returns kind=none for election/manual/off clusters.',
            resolve = failover_resolver.query_state_provider_status,
        },
        vshard = {
            kind = types.object({
                name = 'VshardSummary',
                fields = {
                    groups = types.list(types.object({
                        name = 'VshardGroupSummary',
                        fields = {
                            name = types.string.nonNull,
                            total_buckets = types.long,
                            distribution = types.string,
                            rebalancer = types.string,
                            status = types.string.nonNull,
                        },
                    })),
                },
            }).nonNull,
            description = 'Vshard groups summary. Empty until vshard wiring lands.',
            resolve = vshard_resolver.query_vshard,
        },
        vshardKnownGroups = {
            kind = types.object({
                name = 'VshardKnownGroups',
                fields = {
                    groups = types.list(types.string.nonNull),
                },
            }).nonNull,
            description = 'Names of vshard groups declared in cluster config.',
            resolve = vshard_resolver.query_known_groups,
        },
        canBootstrapVshard = {
            kind = types.object({
                name = 'VshardBootstrapCheck',
                fields = {
                    ok      = types.boolean.nonNull,
                    group   = types.string.nonNull,
                    reasons = types.list(types.string.nonNull),
                },
            }).nonNull,
            arguments = { group = types.string },
            description = 'Whether vshard.router.bootstrap() can succeed for the group '
                .. '(router + storage present and reachable).',
            resolve = vshard_resolver.query_can_bootstrap,
        },
        config = {
            kind = config_types.ConfigCurrent.nonNull,
            description = 'Current cluster YAML and its etcd revision. ' ..
                'Source = "etcd" when wired, "file" before.',
            resolve = config_resolver.query_current,
        },
        configHistory = {
            kind = types.object({
                name = 'ConfigHistoryPage',
                fields = {
                    revisions = types.list(types.object({
                        name = 'ConfigRevisionInfo',
                        fields = {
                            revision = types.long.nonNull,
                            ts       = types.float,
                            user     = types.string,
                            hash     = types.string,
                            size     = types.long,
                            action   = types.string,
                        },
                    })),
                    oldest_available_revision = types.long,
                    more = types.boolean.nonNull,
                },
            }).nonNull,
            arguments = {
                limit = types.int,
                after = types.long,
            },
            description = 'Timeline of committed config revisions ' ..
                '(newest first). Backed by webui own-storage under ' ..
                '<prefix>/history/, capped at MAX_HISTORY=200. ' ..
                '`oldest_available_revision` is the floor that this ' ..
                'cluster can still rollback to.',
            resolve = config_resolver.query_history,
        },
        configRevision = {
            kind = types.object({
                name = 'ConfigRevisionFull',
                fields = {
                    revision = types.long.nonNull,
                    yaml     = types.string.nonNull,
                    ts       = types.float,
                    user     = types.string,
                    action   = types.string,
                },
            }).nonNull,
            arguments = {
                revision = types.long.nonNull,
            },
            description = 'Full YAML payload of a single committed ' ..
                'revision. Raises REVISION_NOT_FOUND when the snapshot ' ..
                'has aged out of MAX_HISTORY or never existed.',
            resolve = config_resolver.query_revision,
        },
        spaces = {
            kind = types.object({
                name = 'SpacesPayload',
                fields = {
                    spaces = types.list(types.object({
                        name = 'SpaceInfo',
                        fields = {
                            id              = types.long.nonNull,
                            name            = types.string.nonNull,
                            engine          = types.string,
                            row_count       = types.long,
                            size_bytes      = types.long,
                            is_sync         = types.boolean,
                            triggers_count  = types.long,
                            sequence        = types.string,
                            format          = types.list(data_explorer_types.FieldFormat),
                            indexes = types.list(types.object({
                                name = 'IndexInfo',
                                fields = {
                                    id = types.long.nonNull,
                                    name = types.string.nonNull,
                                    type = types.string,
                                    unique = types.boolean,
                                    parts = types.list(types.string.nonNull),
                                },
                            })),
                        },
                    })),
                },
            }).nonNull,
            arguments = { include_system = types.boolean },
            description = 'Local spaces with row counts, format, sync flag, ' ..
                'attached sequence, on_replace trigger count, on-disk size ' ..
                '(bsize) and index definitions.',
            resolve = admin_data_resolver.query_spaces,
        },
        tuples = {
            kind = data_explorer_types.TupleConnection.nonNull,
            arguments = {
                space            = types.string.nonNull,
                -- inputObject does not auto-expose `.nonNull` like
                -- object/enum/scalar do — wrap explicitly.
                filter           = types.list(types.nonNull(data_explorer_types.TupleFilterInput)),
                index            = types.string,
                limit            = types.int,
                after            = types.string,
                allow_full_scan  = types.boolean,
            },
            description = 'Paged scan of a space. AND-combined filter; ' ..
                '`pick_index` chooses the best-covering index; residual ' ..
                'conditions apply post-scan and set `partial_scan: true`. ' ..
                'Hard cap 1000 rows / call; `truncated: true` + ' ..
                '`next_cursor` when more pages exist. `total` is set only ' ..
                'when the iterator collapses to EQ on a non-vinyl engine.',
            resolve = admin_data_resolver.query_tuples,
        },
        -- Phase 3 Task 3.4 — SQL workbench snippet library.
        savedQueries = {
            kind = types.object({
                name = 'SavedQueriesPayload',
                fields = {
                    items = types.list(types.object({
                        name = 'SavedQuery',
                        fields = {
                            id         = types.long.nonNull,
                            name       = types.string.nonNull,
                            sql        = types.string.nonNull,
                            owner      = types.string.nonNull,
                            created_at = types.float.nonNull,
                            shared     = types.boolean.nonNull,
                            tags       = types.list(types.string),
                        },
                    })).nonNull,
                },
            }).nonNull,
            description = 'SQL snippet library. Visibility: owner ' ..
                'always; admins always; everyone else only when ' ..
                '`shared = true`. Empty list when storage is not yet ' ..
                'bootstrapped (e.g. first boot before leader elects).',
            resolve = saved_queries_resolver.query_saved_queries,
        },
        users = {
            kind = types.object({
                name = 'UsersPayload',
                fields = {
                    users = types.list(types.object({
                        name = 'UserInfo',
                        fields = {
                            name = types.string.nonNull,
                            kind = types.string.nonNull,
                            roles_app = types.list(types.string.nonNull),
                        },
                    })),
                },
            }).nonNull,
            description = 'Tarantool users plus their WebUI RBAC roles. Admin only.',
            resolve = admin_data_resolver.query_users,
        },
        audit = {
            kind = audit_types.AuditPage.nonNull,
            description = 'Paginated audit log filtered by user/action/scope/time. '
                .. 'Requires the `admin` role.',
            arguments = {
                filter = audit_types.AuditFilter,
                limit  = types.int,
                after  = types.long,
            },
            resolve = audit_resolver.query_audit,
        },
        -- Phase 4 Task 4.3 — audit hash-chain verifier.
        -- Phase 6 Task DR — disaster recovery snapshot.
        recoverySnapshot = {
            kind = types.object({
                name = 'RecoverySnapshot',
                fields = {
                    self_alias    = types.string,
                    generation    = types.long,
                    recommendation = types.string.nonNull,
                    peers = types.list(types.object({
                        name = 'RecoveryPeer',
                        fields = {
                            alias        = types.string.nonNull,
                            uuid         = types.string,
                            replicaset   = types.string,
                            role         = types.string.nonNull,
                            status       = types.string,
                            ro           = types.boolean,
                            reachable    = types.boolean,
                            last_lsn     = types.long,
                            current_term = types.long,
                            queue_owner  = types.boolean,
                            reasons      = types.list(types.string.nonNull),
                        },
                    })).nonNull,
                    split_brain_groups = types.list(types.object({
                        name = 'SplitBrainGroup',
                        fields = {
                            divergent_from = types.string,
                            members = types.list(types.string.nonNull).nonNull,
                        },
                    })).nonNull,
                },
            }).nonNull,
            description = 'Disaster-recovery diagnostic snapshot. ' ..
                'Groups peers by recovery class (queue-owner / ' ..
                'follower / orphan / split-brain / unreachable) and ' ..
                'returns a high-level recommendation. Admin only.',
            resolve = function(root, _args)
                local rbac = require('webui.auth.rbac')
                if not rbac.allowed((root and root.roles) or {}, 'admin') then
                    error('FORBIDDEN: recoverySnapshot requires admin')
                end
                return require('webui.recovery.snapshot').build()
            end,
        },
        verifyAuditChain = {
            kind = types.object({
                name = 'AuditChainVerifyResult',
                fields = {
                    ok            = types.boolean.nonNull,
                    scanned       = types.long.nonNull,
                    seals         = types.long.nonNull,
                    broken_at     = types.long,
                    expected_hash = types.string,
                    actual_hash   = types.string,
                    reason        = types.string,
                },
            }).nonNull,
            arguments = {
                from_id = types.long,
                to_id   = types.long,
            },
            description = 'Walk the `_webui_audit` hash chain and ' ..
                'return the first broken row (or ok=true). ' ..
                'chain_seal rows are treated as legitimate restarts ' ..
                '(retention sweeps). Admin only.',
            resolve = function(root, args)
                local rbac = require('webui.auth.rbac')
                if not rbac.allowed((root and root.roles) or {}, 'admin') then
                    error('FORBIDDEN: verifyAuditChain requires admin')
                end
                local res = require('webui.audit.verifier').verify({
                    from_id = args.from_id,
                    to_id   = args.to_id,
                })
                -- The verifier returns `seals = nil` on certain
                -- error paths (no storage); GraphQL types insist
                -- on non-null. Default to 0 — the operator sees
                -- the descriptive `reason` field anyway.
                res.scanned = res.scanned or 0
                res.seals   = res.seals   or 0
                return res
            end,
        },
        bootstrapStatus = {
            kind = types.object({
                name = 'BootstrapStatus',
                fields = {
                    needed         = types.boolean.nonNull,
                    reason         = types.string,
                    source         = types.string,
                    etcd_available = types.boolean,
                    etcd_error     = types.string,
                },
            }).nonNull,
            description = 'Whether the initial bootstrap wizard should activate. '
                .. 'Returns `needed=false` when any existing config is detected.',
            resolve = bootstrap_resolver.query_status,
        },
        bootstrapTemplates = {
            kind = types.object({
                name = 'BootstrapTemplates',
                fields = {
                    templates = types.list(types.object({
                        name = 'BootstrapTemplate',
                        fields = {
                            name        = types.string.nonNull,
                            title       = types.string.nonNull,
                            description = types.string,
                        },
                    })).nonNull,
                },
            }).nonNull,
            description = 'Available wizard templates.',
            resolve = bootstrap_resolver.query_templates,
        },
        bootstrapRender = {
            kind = types.object({
                name = 'BootstrapRender',
                fields = {
                    yaml  = types.string,
                    error = types.string,
                },
            }).nonNull,
            arguments = {
                template     = types.string.nonNull,
                cluster_name = types.string,
            },
            description = 'Preview the YAML the wizard would commit, without writing it.',
            resolve = bootstrap_resolver.query_render,
        },
        webhooks = {
            kind = types.object({
                name = 'WebhookList',
                fields = {
                    webhooks = types.list(types.object({
                        name = 'Webhook',
                        fields = {
                            name           = types.string.nonNull,
                            type           = types.string.nonNull,
                            url            = types.string,
                            events         = types.list(types.string.nonNull),
                            enabled        = types.boolean.nonNull,
                            has_secret     = types.boolean.nonNull,
                            delivered      = types.long.nonNull,
                            failed         = types.long.nonNull,
                            retried        = types.long.nonNull,
                            dead_lettered  = types.long.nonNull,
                            last_error     = types.string,
                            last_ok_at     = types.long,
                        },
                    })),
                },
            }).nonNull,
            description = 'Configured webhooks plus per-webhook delivery stats.',
            resolve = webhooks_resolver.query_list,
        },
        webhookQueueDepth = {
            kind = types.object({
                name = 'WebhookQueueDepth',
                fields = {
                    queue       = types.long.nonNull,
                    dead_letter = types.long.nonNull,
                },
            }).nonNull,
            description = 'Pending and dead-lettered webhook deliveries.',
            resolve = webhooks_resolver.query_queue_depth,
        },
        webhookDeadLetter = {
            kind = types.object({
                name = 'WebhookDeadLetter',
                fields = {
                    entries = types.list(types.object({
                        name = 'WebhookDeadLetterEntry',
                        fields = {
                            id         = types.long.nonNull,
                            failed_at  = types.long.nonNull,
                            webhook    = types.string.nonNull,
                            event_type = types.string,
                            attempts   = types.long.nonNull,
                            last_error = types.string,
                        },
                    })),
                },
            }).nonNull,
            arguments = { limit = types.int },
            description = 'Recent entries in the dead-letter space, most recent first.',
            resolve = webhooks_resolver.query_dead_letter,
        },
    },
}

-- Shared result type for the Phase 5 atomic operator mutations.
-- `diff_summary` is a flat, bounded ('+50 more' tail) human-readable
-- list of `op path` strings. The full structured ops are kept in
-- the audit row and the internal API; we deliberately do not expose
-- them on the wire because the schema would force us to declare
-- the shape of arbitrary YAML values.
local TopologyEditResult = types.object {
    name = 'TopologyEditResult',
    fields = {
        prepared_id  = types.string,
        expires_at   = types.float,
        diff_summary = types.list(types.string.nonNull).nonNull,
        applied      = types.boolean.nonNull,
        revision     = types.long.nonNull,
        message      = types.string,
    },
}

-- Mutations.
--
-- M1 lands the seven applySuggestion fields — every suggestion
-- type gets a mutation now even though only two have working
-- handlers (force_apply, restart_replication). The others raise
-- "not implemented" errors when invoked; keeping them in the
-- schema means the frontend can render the action buttons
-- consistently and the GraphQL contract stays stable across
-- M5 / M6.
local Mutation = types.object {
    name = 'Mutation',
    description = 'Write operations. M1 wires the applySuggestion family.',
    fields = {
        applyForceApply = {
            kind = suggestion_types.SuggestionApplyResult.nonNull,
            description = 'Call config:reload() on the listed instances.',
            arguments = {
                instanceUuids = types.list(types.string.nonNull).nonNull,
            },
            resolve = suggestions_resolver.apply_force_apply,
        },
        applyRestartReplication = {
            kind = suggestion_types.SuggestionApplyResult.nonNull,
            description = 'Re-apply box.cfg.replication on the listed '
                .. 'instances to drop and rebuild upstreams.',
            arguments = {
                instanceUuids = types.list(types.string.nonNull).nonNull,
            },
            resolve = suggestions_resolver.apply_restart_replication,
        },
        applyRefreshVshard = {
            kind = suggestion_types.SuggestionApplyResult.nonNull,
            description = 'Wake up vshard.router discovery. Implemented in Task 47.',
            arguments = {
                instanceUuids = types.list(types.string.nonNull).nonNull,
            },
            resolve = suggestions_resolver.apply_refresh_vshard,
        },
        applyDisableServer = {
            kind = suggestion_types.SuggestionApplyResult.nonNull,
            description = 'Take an instance out of the RW set via config edit. '
                .. 'Implemented in Task 30+.',
            arguments = {
                instanceUuids = types.list(types.string.nonNull).nonNull,
            },
            resolve = suggestions_resolver.apply_disable_server,
        },
        applyRefineUri = {
            kind = suggestion_types.SuggestionApplyResult.nonNull,
            description = 'Reshape the peer URI in cluster config. '
                .. 'Implemented once config-edit ships.',
            arguments = {
                instanceUuids = types.list(types.string.nonNull).nonNull,
            },
            resolve = suggestions_resolver.apply_refine_uri,
        },
        applyRestartFailover = {
            kind = suggestion_types.SuggestionApplyResult.nonNull,
            description = 'Restart the supervised failover coordinator. '
                .. 'Implemented in Task 46.',
            arguments = {
                instanceUuids = types.list(types.string.nonNull).nonNull,
            },
            resolve = suggestions_resolver.apply_restart_failover,
        },
        applyBootstrapVshard = {
            kind = suggestion_types.SuggestionApplyResult.nonNull,
            description = 'Bootstrap a vshard group. Implemented in Task 47.',
            arguments = {
                instanceUuids = types.list(types.string.nonNull).nonNull,
            },
            resolve = suggestions_resolver.apply_bootstrap_vshard,
        },
        testWebhook = {
            kind = types.object({
                name = 'WebhookTestResult',
                fields = {
                    ok         = types.boolean.nonNull,
                    latency_ms = types.float,
                    error      = types.string,
                },
            }).nonNull,
            arguments = { name = types.string.nonNull },
            description = 'Send a synthetic event through the named webhook.',
            resolve = webhooks_resolver.mutation_test,
        },
        clearDeadLetter = {
            kind = types.object({
                name = 'WebhookClearDeadLetterResult',
                fields = { cleared = types.long.nonNull },
            }).nonNull,
            description = 'Truncate the webhook dead-letter space. Admin only.',
            resolve = webhooks_resolver.mutation_clear_dead_letter,
        },
        bootstrapInitialize = {
            kind = types.object({
                name = 'BootstrapInitResult',
                fields = {
                    ok          = types.boolean.nonNull,
                    yaml        = types.string,
                    revision    = types.long,
                    dry_run     = types.boolean,
                    etcd_used   = types.boolean,
                    etcd_error  = types.string,
                    error_code  = types.string,
                    message     = types.string,
                },
            }).nonNull,
            arguments = {
                template     = types.string.nonNull,
                cluster_name = types.string,
            },
            description = 'Render the chosen template and commit it through the '
                .. 'two-phase pipeline. Refuses to run when status.needed is false.',
            resolve = bootstrap_resolver.mutation_initialize,
        },
        bootstrapVshard = {
            kind = types.object({
                name = 'VshardBootstrapResult',
                fields = {
                    ok         = types.boolean.nonNull,
                    group      = types.string.nonNull,
                    router     = types.string,
                    latency_ms = types.float,
                    message    = types.string,
                },
            }).nonNull,
            arguments = { group = types.string },
            description = 'Invoke vshard.router.bootstrap() on a router instance '
                .. 'of the group. Admin only.',
            resolve = vshard_resolver.mutation_bootstrap,
        },
        exportAudit = {
            kind = audit_types.AuditExport.nonNull,
            description = 'Returns the filtered audit log as a JSON blob. '
                .. 'Requires the `admin` role.',
            arguments = { filter = audit_types.AuditFilter },
            resolve = audit_resolver.mutation_export_audit,
        },
        validateConfig = {
            kind = types.object({
                name = 'ConfigValidationResult',
                fields = { issues = types.list(config_types.ConfigValidationIssue.nonNull).nonNull },
            }).nonNull,
            arguments = { yaml = types.string.nonNull },
            resolve = config_resolver.mutation_validate,
        },
        proposeConfig = {
            kind = config_types.ConfigPrepareResult.nonNull,
            arguments = { yaml = types.string.nonNull },
            resolve = config_resolver.mutation_prepare,
        },
        commitConfig = {
            kind = config_types.ConfigCommitResult.nonNull,
            arguments = { prepared_id = types.string.nonNull },
            resolve = config_resolver.mutation_commit,
        },
        abortConfig = {
            kind = config_types.ConfigCommitResult.nonNull,
            arguments = { prepared_id = types.string.nonNull },
            resolve = config_resolver.mutation_abort,
        },
        rollbackConfig = {
            kind = config_types.ConfigCommitResult.nonNull,
            arguments = { revision = types.long.nonNull },
            description = 'Roll cluster YAML back to a previous revision ' ..
                'from the /history/ timeline. Pre-checks schema-compat: ' ..
                'raises ROLLBACK_INCOMPATIBLE if the target references ' ..
                'roles/users/keys removed since. Records a single audit ' ..
                'entry with from/to revisions + diff_summary, then fans ' ..
                'out config:reload to every peer.',
            resolve = config_resolver.mutation_rollback,
        },
        probeUri = {
            kind = types.object({
                name = 'ProbeResult',
                fields = {
                    reachable         = types.boolean.nonNull,
                    tarantool_version = types.string,
                    cluster_uuid      = types.string,
                    instance_uuid     = types.string,
                    ro                = types.boolean,
                    ro_reason         = types.string,
                    latency_ms        = types.long.nonNull,
                },
            }).nonNull,
            arguments = { uri = types.string.nonNull },
            resolve = lifecycle_resolver.mutation_probe_uri,
        },
        forceReapplyConfig = {
            kind = types.object({
                name = 'LifecycleResult',
                fields = {
                    results = types.list(types.object({
                        name = 'PeerResult',
                        fields = {
                            instance = types.string.nonNull,
                            ok       = types.boolean.nonNull,
                            err      = types.string,
                        },
                    })),
                    -- When `revision` was supplied, rollback first
                    -- and these three carry the resulting state so
                    -- the UI can render "rolled back to N, applied
                    -- as etcd revision M".
                    rollback_to       = types.long,
                    rollback_revision = types.long,
                    rollback_message  = types.string,
                },
            }).nonNull,
            arguments = {
                instances = types.list(types.string.nonNull),
                revision  = types.long,
            },
            description = 'Fan-out config:reload() on every (or selected) ' ..
                'peer. With `revision`, first rolls cluster YAML back to ' ..
                'that history snapshot (which itself triggers a reload), ' ..
                'so a single mutation call covers the "force apply ' ..
                'revision N" operator action.',
            resolve = lifecycle_resolver.mutation_force_reapply,
        },
        reloadRoles = {
            kind = types.object({
                name = 'ReloadRolesResult',
                fields = {
                    results = types.list(types.object({
                        name = 'PeerResultReload',
                        fields = {
                            instance = types.string.nonNull,
                            ok       = types.boolean.nonNull,
                            err      = types.string,
                        },
                    })),
                },
            }).nonNull,
            arguments = { instances = types.list(types.string.nonNull) },
            resolve = lifecycle_resolver.mutation_reload_roles,
        },
        rebootstrapInstance = {
            kind = types.object({
                name = 'RebootstrapResult',
                fields = {
                    ok            = types.boolean.nonNull,
                    alias         = types.string.nonNull,
                    deleted_count = types.long.nonNull,
                    message       = types.string,
                },
            }).nonNull,
            arguments = { alias = types.string.nonNull },
            description = 'Destructive recovery for a follower stuck in ' ..
                'split-brain. Wipes WAL/snap on the target and triggers ' ..
                'Docker restart-policy re-launch — replication catches up ' ..
                'fresh from healthy peers. Refused when the target owns ' ..
                'the synchro queue (would lose uncommitted txns); ' ..
                'promote another peer first.',
            resolve = lifecycle_resolver.mutation_rebootstrap_instance,
        },
        -- Phase 5 atomic cluster operator controls (Cartridge-pattern).
        -- editTopology is the primary mutation; the three alias
        -- mutations below compose `TopologyEdit` envelopes and route
        -- through the same pipeline so audit, validation, and reload
        -- behave identically.
        editTopology = {
            kind = TopologyEditResult.nonNull,
            arguments = { input = types.string.nonNull },
            description = 'Atomic cluster topology edit. Accepts a ' ..
                'JSON-encoded `{servers: [], replicasets: [], apply: ' ..
                'bool}` envelope. When `apply=true` the new YAML is ' ..
                'committed straight away; otherwise a prepared_id + ' ..
                'diff is returned for operator review (commit via ' ..
                'commitConfig). All-or-nothing: any per-edit failure ' ..
                'rolls the whole batch back. Admin only.',
            resolve = cluster_ops_resolver.mutation_edit_topology,
        },
        setReplicasetRoles = {
            kind = TopologyEditResult.nonNull,
            arguments = {
                replicaset = types.string.nonNull,
                roles      = types.list(types.string.nonNull).nonNull,
                apply      = types.boolean,
            },
            description = 'Alias over editTopology that swaps the role ' ..
                'list on a replicaset. Defaults to apply=true.',
            resolve = cluster_ops_resolver.mutation_set_replicaset_roles,
        },
        createReplicaset = {
            kind = TopologyEditResult.nonNull,
            arguments = { input = types.string.nonNull },
            description = 'Alias over editTopology that creates a fresh ' ..
                'replicaset with the supplied instances joined under it. ' ..
                'JSON input: `{name, group, instances?: {alias: spec}, ' ..
                'roles?, leader?, failover_priority?, weight?, ' ..
                'vshard_group?, apply?: bool}`.',
            resolve = cluster_ops_resolver.mutation_create_replicaset,
        },
        editReplicaset = {
            kind = TopologyEditResult.nonNull,
            arguments = { input = types.string.nonNull },
            description = 'Alias over editTopology for partial updates ' ..
                'on an existing replicaset (roles, leader, ' ..
                'failover_priority, weight, vshard_group, join_instances, ' ..
                'expel_instances). JSON input mirrors ReplicasetEdit.',
            resolve = cluster_ops_resolver.mutation_edit_replicaset,
        },
        addInstance = {
            kind = TopologyEditResult.nonNull,
            arguments = { input = types.string.nonNull },
            description = 'Alias over editTopology that joins a new ' ..
                'instance into an existing replicaset. JSON input: ' ..
                '`{alias, group, replicaset, uri, listen?, mode?, ' ..
                'roles?, apply?: bool}`. Probes the URI best-effort; ' ..
                'an unreachable URI emits a warning but does NOT block ' ..
                'the commit (fresh peers usually need replication to ' ..
                'join them before they answer iproto).',
            resolve = cluster_ops_resolver.mutation_add_instance,
        },
        expelInstance = {
            kind = TopologyEditResult.nonNull,
            arguments = {
                alias = types.string.nonNull,
                force = types.boolean,
            },
            description = 'Removes the alias from cluster YAML and ' ..
                'deletes the orphan `_cluster` row on every reachable ' ..
                'peer. Refuses to expel the last instance of a ' ..
                'replicaset unless `force=true`.',
            resolve = cluster_ops_resolver.mutation_expel_instance,
        },
        setInstanceState = {
            kind = TopologyEditResult.nonNull,
            arguments = {
                alias     = types.string.nonNull,
                enabled   = types.boolean,
                electable = types.boolean,
            },
            description = 'Per-mode enable/disable + electable knob for ' ..
                'a single instance. supervised/off+agent: writes ' ..
                '/failover/disabled/<alias> in etcd (agent picks up ' ..
                'within ~1s). off (no agent): editTopology mode=ro/rw. ' ..
                'election: editTopology election_mode=voter/candidate. ' ..
                'manual: refuses to disable the current leader.',
            resolve = cluster_ops_resolver.mutation_set_instance_state,
        },
        promoteInstance = {
            kind = TopologyEditResult.nonNull,
            arguments = {
                alias                = types.string.nonNull,
                force_inconsistency  = types.boolean,
                skip_error_on_change = types.boolean,
                timeout              = types.int,
                ttl_sec              = types.int,
            },
            description = 'Per-mode promote. off→editTopology mode=rw on ' ..
                'target / mode=ro on others; manual→editTopology leader; ' ..
                'election→box.ctl.promote() via net.box; supervised/' ..
                'off+agent→writes manual-override appointment in etcd ' ..
                '(default TTL 300s) AND calls box.ctl.promote on target ' ..
                'so the queue moves immediately. `ttl_sec` is only ' ..
                'consumed by the supervised path.',
            resolve = cluster_ops_resolver.mutation_promote_instance,
        },
        demoteInstance = {
            kind = TopologyEditResult.nonNull,
            arguments = { alias = types.string.nonNull },
            description = 'Per-mode demote. off→mode=ro; supervised→' ..
                'box.ctl.demote on target (agent picks new leader next ' ..
                'tick); election→election_mode=voter on target; manual ' ..
                'is rejected (promote elsewhere instead).',
            resolve = cluster_ops_resolver.mutation_demote_instance,
        },
        pauseFailover = {
            kind = TopologyEditResult.nonNull,
            arguments = { ttl_sec = types.int },
            description = 'Maintenance-window pause for the supervised ' ..
                'agent. While active, the coordinator stops issuing new ' ..
                'appointments (lease_keepalive continues). Default TTL ' ..
                '1h; hard cap 24h — anything longer should be a cluster-' ..
                'wide setFailoverMode "off" without our agent.',
            resolve = cluster_ops_resolver.mutation_pause_failover,
        },
        resumeFailover = {
            kind = TopologyEditResult.nonNull,
            description = 'Clear the failover pause flag; the agent ' ..
                'resumes its appointment cycle on the next tick.',
            resolve = cluster_ops_resolver.mutation_resume_failover,
        },
        setFailoverMode = {
            kind = TopologyEditResult.nonNull,
            arguments = {
                mode   = types.string.nonNull,
                params = types.string,
                apply  = types.boolean,
            },
            description = 'Switch cluster failover mode to one of ' ..
                'off|manual|election|supervised. `params` is a JSON ' ..
                'envelope: synchro_quorum, synchro_timeout, ' ..
                'election_timeout, election_fencing_mode, agent (for ' ..
                'off+agent), agent_params (for supervised). ' ..
                '`supervised` is shorthand for `off` + ' ..
                '`roles_cfg.webui.failover.agent: true`. ' ..
                'Rejects synchro_quorum < N/2+1 as critical.',
            resolve = cluster_ops_resolver.mutation_set_failover_mode,
        },
        -- ── data-explorer tuple mutations (Phase 2 Task 2.3) ────────
        tupleInsert = {
            kind = data_explorer_types.TupleMutationResult.nonNull,
            arguments = {
                space  = types.string.nonNull,
                fields = types.list(data_explorer_types.Json).nonNull,
            },
            description = 'Insert a new tuple into a user space. ' ..
                'Fields are type-coerced through the space format ' ..
                '(uuid/decimal/binary/map). Non-trailing nulls become ' ..
                'box.NULL. System spaces are blocked.',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .tuple_insert(root, args)
            end,
        },
        tupleReplace = {
            kind = data_explorer_types.TupleMutationResult.nonNull,
            arguments = {
                space  = types.string.nonNull,
                fields = types.list(data_explorer_types.Json).nonNull,
            },
            description = 'Insert-or-replace by primary key. Returns ' ..
                'before/after so the SPA can diff. System spaces ' ..
                'blocked.',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .tuple_replace(root, args)
            end,
        },
        tupleUpdate = {
            kind = data_explorer_types.TupleMutationResult.nonNull,
            arguments = {
                space = types.string.nonNull,
                key   = types.list(data_explorer_types.Json).nonNull,
                ops   = types.list(
                    types.nonNull(data_explorer_types.UpdateOpInput)).nonNull,
            },
            description = 'Atomic per-field update via space:update(). ' ..
                'Op kinds: SET, ADD, SUB, BAND, BOR, BXOR, SPLICE, ' ..
                'INSERT, DELETE. `field` accepts a string (resolved ' ..
                'through format) or 1-based numeric index. System ' ..
                'spaces blocked.',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .tuple_update(root, args)
            end,
        },
        tupleDelete = {
            kind = data_explorer_types.TupleMutationResult.nonNull,
            arguments = {
                space = types.string.nonNull,
                key   = types.list(data_explorer_types.Json).nonNull,
            },
            description = 'Delete one tuple by primary key. NOT_FOUND ' ..
                'when the tuple is absent. System spaces blocked.',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .tuple_delete(root, args)
            end,
        },
        createSpace = {
            kind = data_explorer_types.SpaceMutationResult.nonNull,
            arguments = {
                name          = types.string.nonNull,
                engine        = types.string,
                is_sync       = types.boolean,
                if_not_exists = types.boolean,
                format        = types.list(
                    types.nonNull(data_explorer_types.FieldFormatInput)),
                primary_key   = types.list(types.string.nonNull),
            },
            description = 'Create a new user space via box.schema.space.create(). ' ..
                'Names starting with `_` are blocked (system namespace). ' ..
                'Default engine is memtx; if no primary_key is given the ' ..
                'resolver picks the first format field. is_sync=true makes ' ..
                'the space synchronous (sync replication required).',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .create_space(root, args)
            end,
        },
        dropSpace = {
            kind = data_explorer_types.SpaceMutationResult.nonNull,
            arguments = { name = types.string.nonNull },
            description = 'Drop a user space. NOT_FOUND when the space is ' ..
                'absent. System spaces blocked.',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .drop_space(root, args)
            end,
        },
        alterSpace = {
            kind = data_explorer_types.SpaceMutationResult.nonNull,
            arguments = {
                name     = types.string.nonNull,
                new_name = types.string,
                is_sync  = types.boolean,
                format   = types.list(
                    types.nonNull(data_explorer_types.FieldFormatInput)),
            },
            description = 'Alter a user space: rename, replace the format, ' ..
                'or toggle is_sync. Absent fields keep the current value.',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .alter_space(root, args)
            end,
        },
        createIndex = {
            kind = data_explorer_types.SpaceMutationResult.nonNull,
            arguments = {
                space         = types.string.nonNull,
                name          = types.string.nonNull,
                parts         = types.list(types.string.nonNull).nonNull,
                type          = types.string,
                unique        = types.boolean,
                if_not_exists = types.boolean,
            },
            description = 'Create an additional index on a user space. ' ..
                '`parts` are field names. type defaults to tree, unique ' ..
                'defaults to true.',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .create_index(root, args)
            end,
        },
        dropIndex = {
            kind = data_explorer_types.SpaceMutationResult.nonNull,
            arguments = {
                space = types.string.nonNull,
                name  = types.string.nonNull,
            },
            description = 'Drop an index from a user space. NOT_FOUND when ' ..
                'space or index is absent.',
            resolve = function(root, args)
                return require('webui.graphql.resolvers.data_mutations')
                    .drop_index(root, args)
            end,
        },
        -- Phase 3 Task 3.4 — SQL workbench snippet save / delete.
        saveQuery = {
            kind = types.object({
                name = 'SaveQueryResult',
                fields = {
                    ok        = types.boolean.nonNull,
                    item      = types.object({
                        name = 'SaveQueryItem',
                        fields = {
                            id         = types.long.nonNull,
                            name       = types.string.nonNull,
                            sql        = types.string.nonNull,
                            owner      = types.string.nonNull,
                            created_at = types.float.nonNull,
                            shared     = types.boolean.nonNull,
                        },
                    }),
                    forwarded = types.boolean,
                    leader    = types.string,
                },
            }).nonNull,
            arguments = {
                name   = types.string.nonNull,
                sql    = types.string.nonNull,
                shared = types.boolean,
                tags   = types.list(types.string.nonNull),
            },
            description = 'Save a SQL snippet. Owner is the calling user; ' ..
                '`shared = true` makes it visible to every operator+.',
            resolve = saved_queries_resolver.mutation_save,
        },
        -- Phase 6 — disaster recovery dispatcher. Single entry
        -- point for split-brain / orphan / leader-takeover /
        -- future PITR + WAL repair wizards.
        recoveryAction = {
            kind = types.object({
                name = 'RecoveryActionResult',
                fields = {
                    ok      = types.boolean.nonNull,
                    action  = types.string.nonNull,
                    error   = types.string,
                    results = types.list(types.object({
                        name = 'RecoveryActionPeerResult',
                        fields = {
                            peer = types.string.nonNull,
                            ok   = types.boolean.nonNull,
                            msg  = types.string,
                        },
                    })).nonNull,
                },
            }).nonNull,
            arguments = {
                action  = types.string.nonNull,
                payload = types.string,  -- JSON-encoded; per-action shape
            },
            description = 'Disaster-recovery dispatch. `action` ∈ ' ..
                '{split_brain_resolve, leader_takeover}. ' ..
                '`payload` is a JSON envelope; see /cluster-recovery ' ..
                'page for per-action shape. Admin only; every call ' ..
                'is audited.',
            resolve = function(root, args)
                local rbac = require('webui.auth.rbac')
                if not rbac.allowed((root and root.roles) or {}, 'admin') then
                    error('FORBIDDEN: recoveryAction requires admin')
                end
                local payload = {}
                if type(args.payload) == 'string' and args.payload ~= '' then
                    local ok, parsed = pcall(require('json').decode, args.payload)
                    if not ok or type(parsed) ~= 'table' then
                        error('VALIDATION_ERROR: payload must be a JSON object')
                    end
                    payload = parsed
                end
                if args.action == 'split_brain_resolve' then
                    return require('webui.recovery.split_brain')
                        .resolve(payload, root)
                end
                if args.action == 'leader_takeover' then
                    return require('webui.recovery.leader_takeover')
                        .promote(payload, root)
                end
                if args.action == 'orphan_resolve' then
                    return require('webui.recovery.orphan')
                        .resolve(payload, root)
                end
                if args.action == 'quorum_loss_escape' then
                    return require('webui.recovery.quorum_loss')
                        .escape(payload, root)
                end
                if args.action == 'topology_fix' then
                    return require('webui.recovery.topology_fix')
                        .apply(payload, root)
                end
                -- DR-4 PITR — advisory only. `target_lsn` in
                -- payload picks the snapshot + xlog tail and
                -- returns commands the operator runs on the
                -- host (Tarantool 3.x PITR requires offline
                -- restart, which the WebUI cannot do for itself).
                if args.action == 'pitr_plan' then
                    local pitr = require('webui.recovery.pitr')
                    local target = tonumber(payload.target_lsn)
                    if target == nil then
                        return { ok = false, action = 'pitr_plan',
                            results = {},
                            error = 'target_lsn is required (number)' }
                    end
                    local plan, err = pitr.plan(target)
                    if plan == nil then
                        return { ok = false, action = 'pitr_plan',
                            results = {}, error = err }
                    end
                    -- Render the plan into the same wire shape
                    -- as the other recovery actions so the SPA
                    -- can reuse the result block. Each command
                    -- line is one "peer result" — easier than
                    -- introducing a parallel type per action.
                    local results = {}
                    for _, line in ipairs(plan.commands) do
                        table.insert(results, {
                            peer = plan.instance, ok = true, msg = line,
                        })
                    end
                    return { ok = true, action = 'pitr_plan',
                        results = results }
                end
                -- DR-6 WAL repair — diagnose returns one row per
                -- xlog with `ok` flag; quarantine renames a
                -- corrupted file out of the boot path.
                if args.action == 'wal_diagnose' then
                    local wr = require('webui.recovery.wal_repair')
                    local diag = wr.diagnose()
                    local results = {}
                    for _, f in ipairs(diag.files or {}) do
                        table.insert(results, {
                            peer = f.path:gsub('^.*/', ''),
                            ok   = f.ok,
                            msg  = f.ok
                                and ('last_lsn=' .. tostring(f.last_lsn)
                                    .. ' size=' .. f.size)
                                or tostring(f.error),
                        })
                    end
                    return { ok = true, action = 'wal_diagnose',
                        results = results }
                end
                if args.action == 'wal_quarantine' then
                    return require('webui.recovery.wal_repair')
                        .quarantine(payload, root)
                end
                if args.action == 'topology_fix_diagnose' then
                    -- Pseudo-action: returns the diagnostic
                    -- report wrapped in the standard result
                    -- shape so the SPA only has one mutation
                    -- contract to render.
                    local diag = require('webui.recovery.topology_fix')
                        .diagnose()
                    if diag.error then
                        return { ok = false, action = 'topology_fix_diagnose',
                            error = diag.error, results = {} }
                    end
                    local results = {}
                    for _, p in ipairs(diag.peers or {}) do
                        table.insert(results, {
                            peer = p.alias,
                            ok   = p.suggestion == nil,
                            msg  = p.suggestion ~= nil
                                and ('declared=' .. tostring(p.declared_uri)
                                    .. ' observed=' .. tostring(p.observed_uri))
                                or nil,
                        })
                    end
                    return {
                        ok = true, action = 'topology_fix_diagnose',
                        results = results,
                    }
                end
                error('VALIDATION_ERROR: unsupported action '
                    .. tostring(args.action))
            end,
        },
        deleteSavedQuery = {
            kind = types.object({
                name = 'DeleteSavedQueryResult',
                fields = {
                    ok        = types.boolean.nonNull,
                    item      = types.object({
                        name = 'DeleteSavedQueryItem',
                        fields = {
                            id    = types.long.nonNull,
                            name  = types.string.nonNull,
                            owner = types.string.nonNull,
                        },
                    }),
                    forwarded = types.boolean,
                    leader    = types.string,
                },
            }).nonNull,
            arguments = { id = types.long.nonNull },
            description = 'Delete one snippet by id. Only the owner or an ' ..
                'admin may delete; everyone else gets FORBIDDEN.',
            resolve = saved_queries_resolver.mutation_delete,
        },
    },
}

function M.build()
    return schema_mod.create({
        query = Query,
        mutation = Mutation,
    })
end

return M
