-- Unit tests for backend/webui/graphql/resolvers/cluster.lua
--
-- Covers the pure helpers (sort_servers, paginate, build_replicasets).
-- The top-level resolver functions need a populated state cache and
-- are exercised via the integration suite once the cluster query is
-- callable end-to-end.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local cluster = require('webui.graphql.resolvers.cluster')

local g = t.group('graphql_cluster')

local function aliases(items)
    local out = {}
    for _, s in ipairs(items) do table.insert(out, s.alias) end
    return out
end

-- ── sort_servers ─────────────────────────────────────────────────────

g.test_sort_servers_uuid_lexicographic = function()
    local sorted = cluster.sort_servers({
        ['tt-2'] = { alias = 'tt-2', uuid = 'bbb' },
        ['tt-1'] = { alias = 'tt-1', uuid = 'aaa' },
        ['tt-3'] = { alias = 'tt-3', uuid = 'ccc' },
    })
    t.assert_equals(aliases(sorted), { 'tt-1', 'tt-2', 'tt-3' })
end

g.test_sort_servers_nil_uuid_goes_last = function()
    local sorted = cluster.sort_servers({
        ['fresh'] = { alias = 'fresh', uuid = nil },
        ['probed'] = { alias = 'probed', uuid = 'aaa' },
    })
    t.assert_equals(aliases(sorted), { 'probed', 'fresh' })
end

g.test_sort_servers_secondary_by_alias = function()
    -- Two peers without a UUID yet must still be deterministic.
    local sorted = cluster.sort_servers({
        ['second']  = { alias = 'second', uuid = nil },
        ['first']   = { alias = 'first', uuid = nil },
        ['middle']  = { alias = 'middle', uuid = nil },
    })
    t.assert_equals(aliases(sorted), { 'first', 'middle', 'second' })
end

g.test_sort_servers_handles_nil = function()
    t.assert_equals(cluster.sort_servers(nil), {})
end

-- ── paginate ─────────────────────────────────────────────────────────

local function make_list(n)
    local out = {}
    for i = 1, n do
        table.insert(out, { alias = 'tt-' .. i, uuid = string.format('%03d', i) })
    end
    return out
end

g.test_paginate_default_size = function()
    local sorted = make_list(120)
    local page = cluster.paginate(sorted, nil, nil)
    t.assert_equals(#page.items, cluster.DEFAULT_PAGE_SIZE)
    t.assert_equals(page.items[1].alias, 'tt-1')
    t.assert_equals(page.items[#page.items].uuid, '050')
    t.assert_equals(page.next_cursor, '050')
    t.assert_equals(page.total_count, 120)
end

g.test_paginate_explicit_limit = function()
    local sorted = make_list(10)
    local page = cluster.paginate(sorted, nil, 3)
    t.assert_equals(#page.items, 3)
    t.assert_equals(page.next_cursor, page.items[#page.items].uuid)
end

g.test_paginate_caps_limit_at_max = function()
    local sorted = make_list(1000)
    local page = cluster.paginate(sorted, nil, 10000)
    t.assert_equals(#page.items, cluster.MAX_PAGE_SIZE)
end

g.test_paginate_limit_zero_falls_back_to_default = function()
    local sorted = make_list(120)
    local page = cluster.paginate(sorted, nil, 0)
    t.assert_equals(#page.items, cluster.DEFAULT_PAGE_SIZE)
end

g.test_paginate_after_cursor = function()
    local sorted = make_list(10)
    local page = cluster.paginate(sorted, '003', 3)
    t.assert_equals(#page.items, 3)
    t.assert_equals(page.items[1].uuid, '004')
    t.assert_equals(page.items[3].uuid, '006')
    t.assert_equals(page.next_cursor, '006')
end

g.test_paginate_after_unknown_cursor_returns_full_page_from_start = function()
    -- Unknown cursor → behave as if `after` was nil (start_idx stays 1).
    local sorted = make_list(5)
    local page = cluster.paginate(sorted, 'nonexistent', 2)
    t.assert_equals(page.items[1].uuid, '001')
end

g.test_paginate_last_page_has_null_cursor = function()
    local sorted = make_list(3)
    local page = cluster.paginate(sorted, nil, 5)
    t.assert_equals(#page.items, 3)
    t.assert_equals(page.next_cursor, nil)
    t.assert_equals(page.total_count, 3)
end

g.test_paginate_empty_input = function()
    local page = cluster.paginate({}, nil, 10)
    t.assert_equals(#page.items, 0)
    t.assert_equals(page.next_cursor, nil)
    t.assert_equals(page.total_count, 0)
end

-- ── build_replicasets ────────────────────────────────────────────────

g.test_build_replicasets_groups_members = function()
    local replicasets = cluster.build_replicasets({
        servers = {
            ['tt-1'] = { alias = 'tt-1', reachable = true, is_ro = false },
            ['tt-2'] = { alias = 'tt-2', reachable = true, is_ro = true },
            ['tt-3'] = { alias = 'tt-3', reachable = false },
        },
        replicasets = {
            ['rs-1'] = { name = 'rs-1', group_name = 'default',
                instances = { 'tt-1', 'tt-2', 'tt-3' } },
        },
    })
    t.assert_equals(#replicasets, 1)
    t.assert_equals(replicasets[1].name, 'rs-1')
    t.assert_equals(replicasets[1].group_name, 'default')
    t.assert_equals(aliases(replicasets[1].servers), { 'tt-1', 'tt-2', 'tt-3' })
end

g.test_build_replicasets_status_rollup = function()
    -- all reachable → healthy
    local healthy = cluster.build_replicasets({
        servers = {
            ['a'] = { alias = 'a', reachable = true },
            ['b'] = { alias = 'b', reachable = true },
        },
        replicasets = { ['rs'] = { instances = { 'a', 'b' } } },
    })
    t.assert_equals(healthy[1].status, 'healthy')

    -- mixed → degraded
    local degraded = cluster.build_replicasets({
        servers = {
            ['a'] = { alias = 'a', reachable = true },
            ['b'] = { alias = 'b', reachable = false },
        },
        replicasets = { ['rs'] = { instances = { 'a', 'b' } } },
    })
    t.assert_equals(degraded[1].status, 'degraded')

    -- none reachable → unhealthy
    local unhealthy = cluster.build_replicasets({
        servers = {
            ['a'] = { alias = 'a', reachable = false },
        },
        replicasets = { ['rs'] = { instances = { 'a' } } },
    })
    t.assert_equals(unhealthy[1].status, 'unhealthy')

    -- no members → unknown
    local empty = cluster.build_replicasets({
        servers = {},
        replicasets = { ['rs'] = { instances = {} } },
    })
    t.assert_equals(empty[1].status, 'unknown')
end

g.test_build_replicasets_active_leader_is_rw_member = function()
    local result = cluster.build_replicasets({
        servers = {
            ['tt-1'] = { alias = 'tt-1', is_ro = true,  reachable = true },
            ['tt-2'] = { alias = 'tt-2', is_ro = false, reachable = true },
            ['tt-3'] = { alias = 'tt-3', is_ro = true,  reachable = true },
        },
        replicasets = { ['rs'] = { instances = { 'tt-1', 'tt-2', 'tt-3' } } },
    })
    t.assert_equals(result[1].active_leader, 'tt-2')
end

g.test_build_replicasets_active_leader_nil_when_no_rw = function()
    -- All RO members → no current leader (Raft mid-election).
    local result = cluster.build_replicasets({
        servers = {
            ['a'] = { alias = 'a', is_ro = true, reachable = true },
            ['b'] = { alias = 'b', is_ro = true, reachable = true },
        },
        replicasets = { ['rs'] = { instances = { 'a', 'b' } } },
    })
    t.assert_equals(result[1].active_leader, nil)
end

g.test_build_replicasets_sorts_by_name = function()
    local result = cluster.build_replicasets({
        servers = {
            ['a'] = { alias = 'a' },
            ['b'] = { alias = 'b' },
        },
        replicasets = {
            ['rs-z'] = { instances = { 'b' } },
            ['rs-a'] = { instances = { 'a' } },
        },
    })
    t.assert_equals(result[1].name, 'rs-a')
    t.assert_equals(result[2].name, 'rs-z')
end

g.test_build_replicasets_handles_nil_input = function()
    t.assert_equals(cluster.build_replicasets(nil), {})
end

-- ── pagination contract constants ───────────────────────────────────

g.test_module_constants_are_sane = function()
    -- Pin the public contract so a careless edit shows up.
    t.assert_equals(cluster.DEFAULT_PAGE_SIZE, 50)
    t.assert_equals(cluster.MAX_PAGE_SIZE, 500)
end
