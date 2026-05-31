-- Unit tests for backend/webui/cluster/suggestions.lua
--
-- Covers the pure detectors and the target resolver. The fiber
-- lifecycle and the apply() round-trip over net.box are exercised
-- against the live cluster by the integration suite.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local sg = require('webui.cluster.suggestions')

local g = t.group('suggestions')

-- ── detect_force_apply ──────────────────────────────────────────────

g.test_force_apply_emits_one_per_non_ready_peer = function()
    local out = sg.detect_force_apply({
        servers = {
            ['tt-1'] = { reachable = true, uuid = 'u-1', config_status = 'ready' },
            ['tt-2'] = { reachable = true, uuid = 'u-2',
                config_status = 'check_warnings' },
            ['tt-3'] = { reachable = true, uuid = 'u-3',
                config_status = 'check_errors' },
        },
    })
    t.assert_equals(#out, 2)
    -- alphabetic alias order
    t.assert_equals(out[1].alias, 'tt-2')
    t.assert_equals(out[2].alias, 'tt-3')
    t.assert_str_contains(out[1].reason, 'check_warnings')
    t.assert_str_contains(out[1].id, 'force_apply:u-2')
end

g.test_force_apply_skips_unreachable_and_unknown_status = function()
    local out = sg.detect_force_apply({
        servers = {
            ['tt-1'] = { reachable = false, uuid = 'u',
                config_status = 'check_errors' },
            ['tt-2'] = { reachable = true,  uuid = 'u-2' }, -- no status
        },
    })
    t.assert_equals(#out, 0)
end

g.test_force_apply_uses_alias_when_uuid_missing = function()
    local out = sg.detect_force_apply({
        servers = {
            ['tt-1'] = { reachable = true, config_status = 'reloading' },
        },
    })
    t.assert_equals(out[1].id, 'force_apply:tt-1')
end

-- ── detect_restart_replication ──────────────────────────────────────

g.test_restart_replication_emits_for_broken_upstream = function()
    local out = sg.detect_restart_replication({
        servers = {
            ['tt-1'] = {
                reachable = true, uuid = 'u-1',
                replication = {
                    ['2'] = { uuid = 'peer-uuid',
                        upstream = { status = 'stopped', message = 'EOF' } },
                },
            },
        },
    })
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].alias, 'tt-1')
    t.assert_str_contains(out[1].reason, 'stopped')
    t.assert_str_contains(out[1].reason, 'EOF')
end

g.test_restart_replication_groups_per_alias = function()
    -- Even if multiple upstreams are broken on the same peer, we
    -- only emit one suggestion targeted at that peer — the action
    -- restarts the whole replication URI set.
    local out = sg.detect_restart_replication({
        servers = {
            ['tt-1'] = {
                reachable = true, uuid = 'u-1',
                replication = {
                    ['2'] = { upstream = { status = 'stopped' } },
                    ['3'] = { upstream = { status = 'disconnected' } },
                },
            },
        },
    })
    t.assert_equals(#out, 1)
end

g.test_restart_replication_skips_local_self_entry = function()
    -- The self entry has upstream.status == nil.
    local out = sg.detect_restart_replication({
        servers = {
            ['tt-1'] = {
                reachable = true,
                replication = { ['1'] = { upstream = {} } },
            },
        },
    })
    t.assert_equals(#out, 0)
end

g.test_restart_replication_skips_unreachable = function()
    local out = sg.detect_restart_replication({
        servers = {
            ['tt-1'] = {
                reachable = false,
                replication = {
                    ['2'] = { upstream = { status = 'stopped' } },
                },
            },
        },
    })
    t.assert_equals(#out, 0)
end

g.test_restart_replication_silent_on_healthy_follow = function()
    local out = sg.detect_restart_replication({
        servers = {
            ['tt-1'] = {
                reachable = true,
                replication = {
                    ['2'] = { upstream = { status = 'follow' } },
                },
            },
        },
    })
    t.assert_equals(#out, 0)
end

-- ── scan combines + stable shape ────────────────────────────────────

g.test_scan_returns_all_seven_lists = function()
    local out = sg.scan({ servers = {} })
    t.assert_equals(#out.force_apply, 0)
    t.assert_equals(#out.restart_replication, 0)
    t.assert_equals(#out.refresh_vshard, 0)
    t.assert_equals(#out.disable_server, 0)
    t.assert_equals(#out.refine_uri, 0)
    t.assert_equals(#out.restart_failover, 0)
    t.assert_equals(#out.bootstrap_vshard, 0)
end

g.test_scan_with_mixed_signals = function()
    local out = sg.scan({
        servers = {
            ['tt-1'] = { reachable = true, uuid = 'u-1',
                config_status = 'check_errors' },
            ['tt-2'] = {
                reachable = true, uuid = 'u-2',
                replication = {
                    ['1'] = { upstream = { status = 'stopped' } },
                },
            },
        },
    })
    t.assert_equals(#out.force_apply, 1)
    t.assert_equals(#out.restart_replication, 1)
end

-- ── resolve_targets ────────────────────────────────────────────────

g.test_resolve_targets_uuid_to_alias = function()
    local out = sg.resolve_targets({
        servers = {
            ['tt-1'] = { uuid = 'u-1' },
            ['tt-2'] = { uuid = 'u-2' },
        },
    }, { 'u-1', 'u-2' })
    t.assert_equals(out.aliases, { 'tt-1', 'tt-2' })
    t.assert_equals(out.unknown, {})
end

g.test_resolve_targets_alias_passthrough = function()
    -- If the operator passed an alias instead of UUID, accept it.
    local out = sg.resolve_targets({
        servers = { ['tt-1'] = { uuid = 'u-1' } },
    }, { 'tt-1' })
    t.assert_equals(out.aliases, { 'tt-1' })
end

g.test_resolve_targets_self_alias_accepted = function()
    local out = sg.resolve_targets({
        self_alias = 'tt-1',
        servers = { ['tt-1'] = { uuid = 'u-1' } },
    }, { 'tt-1' })
    t.assert_equals(out.aliases, { 'tt-1' })
end

g.test_resolve_targets_unknown_collected = function()
    local out = sg.resolve_targets({
        servers = { ['tt-1'] = { uuid = 'u-1' } },
    }, { 'u-1', 'u-999' })
    t.assert_equals(out.aliases, { 'tt-1' })
    t.assert_equals(out.unknown, { 'u-999' })
end

g.test_resolve_targets_empty_input = function()
    local out = sg.resolve_targets({ servers = {} }, {})
    t.assert_equals(out.aliases, {})
    t.assert_equals(out.unknown, {})
end

-- ── apply contract for unimplemented types ──────────────────────────

g.test_apply_returns_error_for_unimplemented_type = function()
    local result, err = sg.apply(sg.TYPES.REFRESH_VSHARD,
        { instance_uuids = {} }, { snapshot = { servers = {} } })
    t.assert_equals(result, nil)
    t.assert_str_contains(err, 'not implemented')
end

g.test_apply_force_apply_with_empty_targets_returns_ok = function()
    -- With no aliases resolved the dispatcher must still return
    -- a well-formed result rather than erroring out.
    local result, err = sg.apply(sg.TYPES.FORCE_APPLY,
        { instance_uuids = {} }, { snapshot = { servers = {} } })
    t.assert_equals(err, nil)
    t.assert_equals(result.ok, true)
    t.assert_equals(next(result.results), nil)
end

-- ── constants / probe expressions ───────────────────────────────────

g.test_module_constants = function()
    t.assert_equals(sg.TYPES.FORCE_APPLY, 'force_apply')
    t.assert_equals(sg.TYPES.RESTART_REPLICATION, 'restart_replication')
    t.assert(sg.SCAN_INTERVAL_SEC > 0)
end

g.test_action_expressions_present = function()
    t.assert_type(sg._FORCE_APPLY_EXPR, 'string')
    t.assert_type(sg._RESTART_REPLICATION_EXPR, 'string')
    t.assert_str_contains(sg._FORCE_APPLY_EXPR, 'cfg:reload')
    -- The restart-replication expression saves the current
    -- `box.cfg.replication`, blanks it, and then re-applies it.
    -- We assert on the structural pieces rather than a single
    -- substring so a future refactor (e.g. wrapping in pcall)
    -- does not silently break this guard.
    t.assert_str_contains(sg._RESTART_REPLICATION_EXPR,
        'box.cfg.replication')
    t.assert_str_contains(sg._RESTART_REPLICATION_EXPR,
        'replication = saved')
    t.assert_str_contains(sg._RESTART_REPLICATION_EXPR,
        'replication = {}')
end
