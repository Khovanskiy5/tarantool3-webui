local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local topo = require('webui.recovery.topology_fix')

local g = t.group('recovery.topology_fix')

-- Minimal cluster config with three peers.
local function sample_cfg(uris)
    local instances = {}
    for alias, uri in pairs(uris) do
        instances[alias] = {
            iproto = {
                advertise = { peer = { uri = uri } },
            },
        }
    end
    return {
        groups = {
            default = {
                replicasets = {
                    ['rs-1'] = { instances = instances },
                },
            },
        },
    }
end

g.test_walk_declared_lists_all_aliases = function()
    local cfg = sample_cfg({
        ['tt-1'] = 'tt-1:3301',
        ['tt-2'] = 'tt-2:3301',
        ['tt-3'] = 'tt-3:3301',
    })
    local out = topo.walk_declared(cfg)
    t.assert_equals(#out, 3)
    -- Sorted by alias.
    t.assert_equals(out[1].alias, 'tt-1')
    t.assert_equals(out[1].declared_uri, 'tt-1:3301')
    t.assert_equals(out[3].alias, 'tt-3')
end

g.test_walk_declared_emits_nil_uri_for_missing_advertise = function()
    local cfg = {
        groups = {
            default = {
                replicasets = {
                    ['rs-1'] = {
                        instances = {
                            ['tt-1'] = {},  -- no iproto block at all
                        },
                    },
                },
            },
        },
    }
    local out = topo.walk_declared(cfg)
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].declared_uri, nil)
end

g.test_cross_check_suggests_fix_when_observed_differs_and_reachable = function()
    local declared = {
        { alias = 'tt-1', declared_uri = 'old-host:3301' },
    }
    local observed = {
        ['tt-1'] = { uri = 'new-host:3301', reachable = true },
    }
    local out = topo.cross_check(declared, observed)
    t.assert_equals(out[1].suggestion, 'new-host:3301')
    t.assert_equals(out[1].reachable, true)
end

g.test_cross_check_no_suggestion_when_observed_unreachable = function()
    -- Suggesting an unreachable URI would replace one dead
    -- pointer with another. The cross-check must hold off on the
    -- auto-suggestion, but it MUST still flag the peer so the
    -- operator can correct a typo by hand.
    local declared = {
        { alias = 'tt-1', declared_uri = 'old-host:3301' },
    }
    local observed = {
        ['tt-1'] = { uri = 'new-host:3301', reachable = false },
    }
    local out = topo.cross_check(declared, observed)
    t.assert_equals(out[1].suggestion, nil)
    t.assert_equals(out[1].needs_fix, true)
end

g.test_cross_check_flags_unreachable_declared_peer = function()
    -- A wrong host:port leaves the peer unreachable with no observed
    -- address to suggest — still a fix candidate (operator edits the
    -- declared URI). This is the canonical "typo in cluster.yaml" case.
    local declared = {
        { alias = 'tt-3', declared_uri = 'tt-3:3399' },
    }
    local out = topo.cross_check(declared, {
        ['tt-3'] = { uri = 'tt-3:3399', reachable = false },
    })
    t.assert_equals(out[1].needs_fix, true)
    t.assert_equals(out[1].suggestion, nil)
end

g.test_cross_check_reachable_match_needs_no_fix = function()
    local out = topo.cross_check(
        { { alias = 'tt-1', declared_uri = 'tt-1:3301' } },
        { ['tt-1'] = { uri = 'tt-1:3301', reachable = true } })
    t.assert_equals(out[1].needs_fix, false)
end

g.test_cross_check_no_suggestion_when_uris_match = function()
    local declared = {
        { alias = 'tt-1', declared_uri = 'tt-1:3301' },
    }
    local observed = {
        ['tt-1'] = { uri = 'tt-1:3301', reachable = true },
    }
    local out = topo.cross_check(declared, observed)
    t.assert_equals(out[1].suggestion, nil)
end

g.test_cross_check_handles_missing_observed_alias = function()
    local declared = {
        { alias = 'ghost-peer', declared_uri = 'ghost:3301' },
    }
    -- ghost-peer is in the YAML but not in the running pool.
    -- We have no observed URI to compare against — leave the
    -- row unchanged so the operator sees the declared state
    -- and can decide.
    local out = topo.cross_check(declared, {})
    t.assert_equals(out[1].suggestion, nil)
    t.assert_equals(out[1].observed_uri, nil)
    t.assert_equals(out[1].reachable, false)
end

-- ── apply() routing through the two-phase config pipeline ─────────
--
-- apply() must drive the config resolver's prepare → commit pair
-- (the same path the config editor uses). A regression here once
-- referenced a non-existent `commit_config`, so the button could
-- never apply. These tests pin the contract by mocking the resolver.

local yaml = require('yaml')

-- Modules apply() pulls in lazily via require(); we swap them in
-- package.loaded so the real cluster is never touched.
local CLIENT_MOD   = 'webui.config_store.client'
local RESOLVER_MOD = 'webui.graphql.resolvers.config'
local TWOPHASE_MOD = 'webui.config_store.twophase'

-- fetch_current_yaml() reads the live config through the etcd client
-- (client:read_cluster_config().value), so the mock mirrors that shape.
local function install_config_mock(raw_yaml)
    package.loaded[CLIENT_MOD] = {
        get_client = function()
            return {
                read_cluster_config = function()
                    return { value = raw_yaml }
                end,
            }
        end,
    }
end

-- apply() waits for the prepared row to replicate before commit;
-- stub get_prepared so the wait resolves immediately (no box here).
local function install_prepared_visible()
    package.loaded[TWOPHASE_MOD] = {
        get_prepared = function()
            return { id = 'prep-1' }
        end,
    }
end

local function restore_mocks()
    package.loaded[CLIENT_MOD] = nil
    package.loaded[RESOLVER_MOD] = nil
    package.loaded[TWOPHASE_MOD] = nil
end

g.after_each(restore_mocks)

g.test_apply_requires_fixes = function()
    local res = topo.apply({ fixes = {} }, { roles = { 'admin' } })
    t.assert_equals(res.ok, false)
    t.assert_str_contains(res.error, 'fixes is required')
end

g.test_apply_routes_through_prepare_and_commit = function()
    local raw = yaml.encode(sample_cfg({
        ['tt-1'] = 'tt-1:3301',
        ['tt-2'] = 'tt-2:3301',
        ['tt-3'] = 'tt-3:3399',  -- the broken URI to be fixed
    }))
    install_config_mock(raw)
    install_prepared_visible()

    local prepared_with, committed_with
    package.loaded[RESOLVER_MOD] = {
        mutation_prepare = function(_root, args)
            prepared_with = args
            return { prepared_id = 'prep-1' }
        end,
        mutation_commit = function(_root, args)
            committed_with = args
            return { ok = true, revision = 42 }
        end,
    }

    local res = topo.apply(
        { fixes = { ['tt-3'] = 'tt-3:3301' } },
        { roles = { 'admin' } })

    t.assert_equals(res.ok, true)
    t.assert_equals(res.action, 'topology_fix')
    -- Result rows MUST match the recoveryAction GraphQL contract
    -- ({ peer, ok, msg }) — a missing `peer` crashes serialization.
    t.assert_equals(#res.results, 1)
    t.assert_equals(res.results[1].peer, 'tt-3')
    t.assert_equals(res.results[1].ok, true)
    t.assert_str_contains(res.results[1].msg, 'tt-3:3399')
    t.assert_str_contains(res.results[1].msg, 'tt-3:3301')
    -- prepare received the patched YAML carrying the corrected URI.
    t.assert_type(prepared_with.yaml, 'string')
    t.assert_str_contains(prepared_with.yaml, 'tt-3:3301')
    t.assert_not_str_contains(prepared_with.yaml, 'tt-3:3399')
    -- commit was driven with the prepared id from prepare.
    t.assert_equals(committed_with.prepared_id, 'prep-1')
end

g.test_apply_surfaces_prepare_error = function()
    install_config_mock(yaml.encode(sample_cfg({
        ['tt-3'] = 'tt-3:3399',
    })))
    package.loaded[RESOLVER_MOD] = {
        mutation_prepare = function()
            error('VALIDATION_FAILED: bad uri')
        end,
        mutation_commit = function()
            error('commit should never be reached')
        end,
    }

    local res = topo.apply(
        { fixes = { ['tt-3'] = 'tt-3:3301' } },
        { roles = { 'admin' } })

    t.assert_equals(res.ok, false)
    t.assert_str_contains(res.error, 'VALIDATION_FAILED')
end

g.test_apply_reports_missing_resolver = function()
    install_config_mock(yaml.encode(sample_cfg({
        ['tt-3'] = 'tt-3:3399',
    })))
    -- Resolver present but missing the prepare/commit pair.
    package.loaded[RESOLVER_MOD] = {}
    local res = topo.apply(
        { fixes = { ['tt-3'] = 'tt-3:3301' } },
        { roles = { 'admin' } })
    t.assert_equals(res.ok, false)
    t.assert_str_contains(res.error, 'config resolver unavailable')
end
