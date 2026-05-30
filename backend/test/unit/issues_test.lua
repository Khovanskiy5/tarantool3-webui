-- Unit tests for backend/webui/cluster/issues.lua
--
-- All four scanner rules + the aggregation are covered without
-- spinning up box. The fiber lifecycle (start / stop / scan tick)
-- needs a live Tarantool instance and lands with the integration
-- suite.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local issues = require('webui.cluster.issues')

local g = t.group('issues')


-- ── make_id contract ────────────────────────────────────────────────

g.test_make_id_format = function()
    t.assert_equals(
        issues.make_id('replication', 'instance', 'tt-1', 'lag-uuid-x'),
        'replication:instance:tt-1:lag-uuid-x')
end

g.test_make_id_nil_target_and_key_become_underscore = function()
    t.assert_equals(issues.make_id('clock', 'cluster', nil, nil),
        'clock:cluster:_:_')
end

-- ── check_replication ───────────────────────────────────────────────

g.test_replication_upstream_status_not_follow_is_critical = function()
    local out = issues.check_replication({
        servers = {
            ['tt-1'] = {
                reachable = true,
                replicaset_name = 'rs-1',
                replication = {
                    ['2'] = {
                        id = 2, uuid = 'peer-uuid',
                        upstream = { status = 'disconnected', message = 'EOF' },
                    },
                },
            },
        },
    }, nil, 100)
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].severity, 'critical')
    t.assert_equals(out[1].category, 'replication')
    t.assert_equals(out[1].instance, 'tt-1')
    t.assert_equals(out[1].replicaset, 'rs-1')
    t.assert_str_contains(out[1].message, 'disconnected')
end

g.test_replication_lag_above_threshold_is_warning = function()
    local out = issues.check_replication({
        servers = {
            ['tt-1'] = {
                reachable = true,
                replication = {
                    ['2'] = {
                        id = 2, uuid = 'peer',
                        upstream = { status = 'follow', lag = 15 },
                    },
                },
            },
        },
    }, { replication_sync_lag = 10, replication_idle_factor = 2,
         default_replication_timeout = 1 }, 100)
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].severity, 'warning')
    t.assert_str_contains(out[1].message, 'lag')
end

g.test_replication_idle_above_threshold_is_warning = function()
    local out = issues.check_replication({
        servers = {
            ['tt-1'] = {
                reachable = true,
                replication = {
                    ['2'] = {
                        id = 2, uuid = 'peer',
                        upstream = { status = 'follow', lag = 0, idle = 5 },
                    },
                },
            },
        },
    }, { replication_sync_lag = 10, replication_idle_factor = 2,
         default_replication_timeout = 1 }, 100)
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].severity, 'warning')
    t.assert_str_contains(out[1].message, 'idle')
end

g.test_replication_local_entry_with_nil_status_is_skipped = function()
    -- box.info.replication[<self_id>].upstream.status is nil.
    -- The scanner must not raise an issue for it.
    local out = issues.check_replication({
        servers = {
            ['tt-1'] = {
                reachable = true,
                replication = {
                    ['1'] = { id = 1, uuid = 'self', upstream = {} },
                },
            },
        },
    }, nil, 100)
    t.assert_equals(#out, 0)
end

g.test_replication_unreachable_peer_is_not_scanned = function()
    -- An unreachable peer has stale replication data; the issues
    -- here would just be noise. Reachability is the upstream's
    -- own pollster's responsibility.
    local out = issues.check_replication({
        servers = {
            ['tt-1'] = {
                reachable = false,
                replication = {
                    ['2'] = { id = 2, upstream = { status = 'stopped' } },
                },
            },
        },
    }, nil, 100)
    t.assert_equals(#out, 0)
end

-- ── check_memory ────────────────────────────────────────────────────

g.test_memory_warn_threshold = function()
    local out = issues.check_memory({
        servers = {
            ['tt-1'] = {
                reachable = true, replicaset_name = 'rs',
                arena_used_ratio = 0.9,
                items_used_ratio = 0.5,
                quota_used_ratio = 0.5,
            },
        },
    }, nil, 100)
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].severity, 'warning')
    t.assert_str_contains(out[1].message, 'arena')
    t.assert_str_contains(out[1].message, '90.0%')
end

g.test_memory_critical_threshold = function()
    local out = issues.check_memory({
        servers = {
            ['tt-1'] = {
                reachable = true,
                arena_used_ratio = 0.5,
                items_used_ratio = 0.97,
                quota_used_ratio = 0.5,
            },
        },
    }, nil, 100)
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].severity, 'critical')
    t.assert_str_contains(out[1].message, 'items')
end

g.test_memory_below_warn_is_silent = function()
    local out = issues.check_memory({
        servers = {
            ['tt-1'] = {
                reachable = true,
                arena_used_ratio = 0.1,
                items_used_ratio = 0.2,
                quota_used_ratio = 0.3,
            },
        },
    }, nil, 100)
    t.assert_equals(#out, 0)
end

g.test_memory_three_separate_issues_when_all_critical = function()
    local out = issues.check_memory({
        servers = {
            ['tt-1'] = {
                reachable = true,
                arena_used_ratio = 0.99,
                items_used_ratio = 0.99,
                quota_used_ratio = 0.99,
            },
        },
    }, nil, 100)
    t.assert_equals(#out, 3)
end

-- ── check_clock ─────────────────────────────────────────────────────

g.test_clock_skew_above_threshold = function()
    local out = issues.check_clock({
        self_alias = 'tt-1',
        servers = {
            ['tt-1'] = { clock = 1000.0, reachable = true },
            ['tt-2'] = { clock = 1010.0, reachable = true,
                         replicaset_name = 'rs' },
        },
    }, { clock_delta_sec = 5 }, 100)
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].severity, 'warning')
    t.assert_equals(out[1].instance, 'tt-2')
end

g.test_clock_within_threshold_silent = function()
    local out = issues.check_clock({
        self_alias = 'tt-1',
        servers = {
            ['tt-1'] = { clock = 1000.0, reachable = true },
            ['tt-2'] = { clock = 1002.5, reachable = true },
        },
    }, { clock_delta_sec = 5 }, 100)
    t.assert_equals(#out, 0)
end

g.test_clock_no_self_clock_returns_empty = function()
    local out = issues.check_clock({
        self_alias = 'tt-1',
        servers = {
            ['tt-1'] = { reachable = true },     -- clock missing
            ['tt-2'] = { clock = 999.0, reachable = true },
        },
    }, nil, 100)
    t.assert_equals(#out, 0)
end

-- ── check_config ────────────────────────────────────────────────────

g.test_config_alerts_become_issues = function()
    local out = issues.check_config({
        servers = {
            ['tt-1'] = {
                reachable = true,
                replicaset_name = 'rs',
                alerts = {
                    { type = 'warn',     message = 'unknown role' },
                    { type = 'critical', message = 'invalid uri' },
                },
            },
        },
    }, nil, 100)
    t.assert_equals(#out, 2)
    -- find by category map
    local by_msg = {}
    for _, i in ipairs(out) do by_msg[i.message] = i.severity end
    t.assert_equals(by_msg['unknown role'], 'warning')
    t.assert_equals(by_msg['invalid uri'], 'critical')
end

-- ── scan + summarise + sort ─────────────────────────────────────────

g.test_scan_combines_all_rules_and_sorts = function()
    local out = issues.scan({
        self_alias = 'tt-1',
        servers = {
            ['tt-1'] = {
                reachable = true,
                clock = 1000.0,
                arena_used_ratio = 0.99,  -- critical mem
                alerts = { { type = 'warn', message = 'a' } },
            },
            ['tt-2'] = {
                reachable = true,
                clock = 1100.0,  -- clock skew
            },
        },
    }, { now = 50 })
    -- Expect at least: 1 memory critical, 1 config warn, 1 clock warn
    t.assert(#out >= 3, 'scan produced fewer issues than expected: ' .. #out)
    -- Critical-first ordering: severity field sorts alphabetically,
    -- so critical < warning is what `table.sort` produces.
    t.assert_equals(out[1].severity, 'critical')
end

g.test_summarise_counts = function()
    local list = {
        { id = '1', severity = 'critical' },
        { id = '2', severity = 'critical' },
        { id = '3', severity = 'warning' },
    }
    local s = issues.summarise(list)
    t.assert_equals(s.critical, 2)
    t.assert_equals(s.warning, 1)
    t.assert_equals(s.total, 3)
end

g.test_summarise_empty = function()
    local s = issues.summarise({})
    t.assert_equals(s.total, 0)
    t.assert_equals(s.warning, 0)
    t.assert_equals(s.critical, 0)
end

-- ── stable IDs across ticks ─────────────────────────────────────────

g.test_make_id_stable_for_same_inputs = function()
    -- Two ticks on the same broken upstream must produce the same
    -- ID so the UI does not see a phantom appear/disappear cycle.
    local a = issues.make_id('memory', 'instance', 'tt-1', 'arena')
    local b = issues.make_id('memory', 'instance', 'tt-1', 'arena')
    t.assert_equals(a, b)
end

-- ── module constants ────────────────────────────────────────────────

g.test_constants_publicly_exposed = function()
    t.assert_equals(issues.CATEGORIES.REPLICATION, 'replication')
    t.assert_equals(issues.SEVERITY.WARNING, 'warning')
    t.assert_equals(issues.SEVERITY.CRITICAL, 'critical')
    t.assert(issues.SCAN_INTERVAL_SEC > 0)
end
