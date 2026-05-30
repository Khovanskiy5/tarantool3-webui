-- Integration test for the M1 cluster view pipeline.
--
-- Brings together cluster.state (the cache), cluster.issues (the
-- scanner) and cluster.suggestions (the engine). Each rule lives
-- in its own unit-test file already; this test wires them
-- together against a synthesised topology so a future refactor
-- that breaks the contract between modules surfaces here.
--
-- The scenario:
--
--   1. Three peers (tt-1, tt-2, tt-3) all reachable, no issues,
--      no suggestions.
--   2. tt-2 drops off the network. The poller would normally
--      detect that; here we feed the equivalent signals into
--      state.apply_tick directly so the test stays hermetic.
--   3. The scenario also drops tt-2's upstream on tt-1 and
--      tt-3, which is what cluster.state would have learnt from
--      the probe payload. The issues scanner should now produce
--      `replication` issues and the suggestions engine should
--      produce `restart_replication` items.
--   4. tt-2 comes back online. State, issues and suggestions
--      should all converge back to empty.
--
-- The test runs without spinning up a real Tarantool cluster:
-- it relies on the pure scan / build_next_state APIs every M1
-- module exposes.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local state       = require('webui.cluster.state')
local issues      = require('webui.cluster.issues')
local suggestions = require('webui.cluster.suggestions')

local g = t.group('integration.cluster_view')

g.before_each(function() state._reset() end)

-- ── helpers ─────────────────────────────────────────────────────────

local function topology()
    return {
        ['tt-1'] = { replicaset_name = 'rs-1', group_name = 'default' },
        ['tt-2'] = { replicaset_name = 'rs-1', group_name = 'default' },
        ['tt-3'] = { replicaset_name = 'rs-1', group_name = 'default' },
    }
end

local function probe(alias, opts)
    opts = opts or {}
    return {
        alias        = alias,
        uuid         = alias .. '-uuid',
        version      = '3.7.0',
        uptime       = 100,
        ro           = opts.ro or false,
        status       = 'running',
        vclock       = { [1] = 10, [2] = 5, [3] = 7 },
        clock        = opts.clock,
        replication  = opts.replication,
        config_status = 'ready',
        config_alerts = {},
        replicaset   = { name = 'rs-1', uuid = 'rs-uuid' },
    }
end

local function healthy_replication(self_alias)
    -- Synthetic box.info.replication map: one entry per peer.
    local repl = {}
    local id = 0
    for _, alias in ipairs({ 'tt-1', 'tt-2', 'tt-3' }) do
        id = id + 1
        if alias == self_alias then
            repl[tostring(id)] = {
                id = id, uuid = alias .. '-uuid',
                upstream = {},  -- self entry has no upstream
            }
        else
            repl[tostring(id)] = {
                id = id, uuid = alias .. '-uuid',
                upstream = { status = 'follow', lag = 0, idle = 0.1 },
            }
        end
    end
    return repl
end

local function broken_replication(self_alias, dead_alias)
    local repl = healthy_replication(self_alias)
    -- Mark `dead_alias`'s upstream as disconnected.
    for _, entry in pairs(repl) do
        if entry.uuid == dead_alias .. '-uuid' then
            entry.upstream = {
                status = 'disconnected',
                message = 'EOF',
            }
        end
    end
    return repl
end

-- Apply a tick using the synthesised probe data. Mirrors what
-- the poller does when every peer responded successfully.
local function apply(scenario)
    local results = {}
    for alias, probe_data in pairs(scenario.peer_probes or {}) do
        if alias ~= scenario.self_alias then
            results[alias] = { ok = true, value = probe_data }
        end
    end
    for _, alias in ipairs(scenario.unreachable or {}) do
        results[alias] = { ok = false, err = 'not connected' }
    end
    state.apply_tick({
        self_alias   = scenario.self_alias,
        local_probe  = scenario.local_probe,
        peer_results = results,
        topology     = topology(),
        backoff      = scenario.backoff or {},
        now          = scenario.now or 0,
    })
end

-- ── scenarios ──────────────────────────────────────────────────────

g.test_healthy_cluster_produces_no_issues_or_suggestions = function()
    apply({
        self_alias = 'tt-1',
        local_probe = probe('tt-1', { ro = true,
            replication = healthy_replication('tt-1') }),
        peer_probes = {
            ['tt-2'] = probe('tt-2', { ro = false,
                replication = healthy_replication('tt-2') }),
            ['tt-3'] = probe('tt-3', { ro = true,
                replication = healthy_replication('tt-3') }),
        },
        now = 1,
    })

    local snap = state.snapshot()
    t.assert_equals(snap.generation, 1)
    for _, alias in ipairs({ 'tt-1', 'tt-2', 'tt-3' }) do
        t.assert_equals(snap.servers[alias].reachable, true,
            alias .. ' must be reachable')
    end

    local found_issues = issues.scan(snap)
    t.assert_equals(#found_issues, 0)

    local sg = suggestions.scan(snap)
    t.assert_equals(#sg.force_apply, 0)
    t.assert_equals(#sg.restart_replication, 0)
end

g.test_dropped_peer_surfaces_unreachable_state = function()
    apply({
        self_alias = 'tt-1',
        local_probe = probe('tt-1', { ro = true,
            replication = broken_replication('tt-1', 'tt-2') }),
        peer_probes = {
            ['tt-3'] = probe('tt-3', { ro = false,
                replication = broken_replication('tt-3', 'tt-2') }),
        },
        unreachable = { 'tt-2' },
        now = 2,
    })

    local snap = state.snapshot()
    t.assert_equals(snap.servers['tt-2'].reachable, false)
    t.assert_equals(snap.servers['tt-2'].status, 'unreachable')
    t.assert_equals(snap.servers['tt-2'].last_error, 'not connected')

    -- Replicasets still group all three by name; status comes
    -- from the rollup in build_next_state.
    t.assert_equals(snap.replicasets['rs-1'].instances,
        { 'tt-1', 'tt-2', 'tt-3' })
end

g.test_broken_replication_produces_critical_issue_and_suggestion = function()
    apply({
        self_alias = 'tt-1',
        local_probe = probe('tt-1', { ro = true,
            replication = broken_replication('tt-1', 'tt-2') }),
        peer_probes = {
            ['tt-3'] = probe('tt-3', { ro = false,
                replication = broken_replication('tt-3', 'tt-2') }),
        },
        unreachable = { 'tt-2' },
        now = 3,
    })

    local snap = state.snapshot()

    -- Issues: tt-1 and tt-3 both report upstream from tt-2
    -- disconnected. Stable IDs encode (category:scope:target:key)
    -- so they correlate across ticks.
    local found = issues.scan(snap)
    t.assert(#found >= 2,
        'expected at least 2 replication issues, got ' .. #found)
    local critical_count = 0
    for _, issue in ipairs(found) do
        t.assert_equals(issue.category, 'replication')
        if issue.severity == 'critical' then
            critical_count = critical_count + 1
        end
        t.assert_str_contains(issue.id, 'replication:instance:')
    end
    t.assert(critical_count >= 2)

    -- Suggestions: one restart_replication entry per affected
    -- peer (tt-1 and tt-3). force_apply stays empty because
    -- config status is still 'ready'.
    local sg = suggestions.scan(snap)
    t.assert_equals(#sg.force_apply, 0)
    t.assert_equals(#sg.restart_replication, 2)
    local aliases = {}
    for _, s in ipairs(sg.restart_replication) do
        table.insert(aliases, s.alias)
    end
    table.sort(aliases)
    t.assert_equals(aliases, { 'tt-1', 'tt-3' })
end

g.test_recovery_clears_issues_and_suggestions = function()
    -- First tick: degraded.
    apply({
        self_alias = 'tt-1',
        local_probe = probe('tt-1', {
            replication = broken_replication('tt-1', 'tt-2') }),
        peer_probes = {
            ['tt-3'] = probe('tt-3', {
                replication = broken_replication('tt-3', 'tt-2') }),
        },
        unreachable = { 'tt-2' },
        now = 5,
    })
    t.assert(#issues.scan(state.snapshot()) > 0)

    -- Second tick: everyone healthy again.
    apply({
        self_alias = 'tt-1',
        local_probe = probe('tt-1', { ro = true,
            replication = healthy_replication('tt-1') }),
        peer_probes = {
            ['tt-2'] = probe('tt-2', { ro = false,
                replication = healthy_replication('tt-2') }),
            ['tt-3'] = probe('tt-3', { ro = true,
                replication = healthy_replication('tt-3') }),
        },
        now = 6,
    })

    local snap = state.snapshot()
    t.assert_equals(snap.servers['tt-2'].reachable, true)
    t.assert_equals(#issues.scan(snap), 0)
    local sg = suggestions.scan(snap)
    t.assert_equals(#sg.restart_replication, 0)
end

g.test_config_not_ready_drives_force_apply_suggestion = function()
    local p = probe('tt-2', { replication = healthy_replication('tt-2') })
    p.config_status = 'check_warnings'
    apply({
        self_alias = 'tt-1',
        local_probe = probe('tt-1', { replication = healthy_replication('tt-1') }),
        peer_probes = {
            ['tt-2'] = p,
            ['tt-3'] = probe('tt-3', { replication = healthy_replication('tt-3') }),
        },
        now = 7,
    })

    local sg = suggestions.scan(state.snapshot())
    t.assert_equals(#sg.force_apply, 1)
    t.assert_equals(sg.force_apply[1].alias, 'tt-2')
    t.assert_str_contains(sg.force_apply[1].reason, 'check_warnings')
end

g.test_summary_counts_match_scanned_issues = function()
    apply({
        self_alias = 'tt-1',
        local_probe = probe('tt-1', {
            replication = broken_replication('tt-1', 'tt-2') }),
        peer_probes = {
            ['tt-3'] = probe('tt-3', {
                replication = broken_replication('tt-3', 'tt-2') }),
        },
        unreachable = { 'tt-2' },
        now = 8,
    })

    local found = issues.scan(state.snapshot())
    local summary = issues.summarise(found)
    t.assert_equals(summary.total, #found)
    t.assert_equals(summary.critical + summary.warning, #found)
end
