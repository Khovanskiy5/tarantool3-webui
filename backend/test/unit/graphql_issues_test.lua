-- Unit tests for backend/webui/graphql/resolvers/issues.lua
--
-- Covers the pure filter + paginate helpers. The top-level resolver
-- is exercised end-to-end against the running cluster.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local resolver = require('webui.graphql.resolvers.issues')

local g = t.group('graphql_issues')

local function make(id, sev, scope, category, instance)
    return {
        id = id, severity = sev, scope = scope,
        category = category, instance = instance,
    }
end

-- ── filter ──────────────────────────────────────────────────────────

g.test_filter_severity = function()
    local list = {
        make('a', 'warning', 'instance', 'memory'),
        make('b', 'critical', 'instance', 'memory'),
    }
    local out = resolver.filter(list, { severity = 'critical' })
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].id, 'b')
end

g.test_filter_scope = function()
    local list = {
        make('a', 'warning', 'cluster', 'config'),
        make('b', 'warning', 'instance', 'config'),
    }
    local out = resolver.filter(list, { scope = 'cluster' })
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].id, 'a')
end

g.test_filter_category = function()
    local list = {
        make('a', 'warning', 'instance', 'memory'),
        make('b', 'warning', 'instance', 'replication'),
    }
    local out = resolver.filter(list, { category = 'replication' })
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].id, 'b')
end

g.test_filter_instance = function()
    local list = {
        make('a', 'warning', 'instance', 'memory', 'tt-1'),
        make('b', 'warning', 'instance', 'memory', 'tt-2'),
    }
    local out = resolver.filter(list, { instance = 'tt-2' })
    t.assert_equals(out[1].id, 'b')
end

g.test_filter_combines_dimensions = function()
    local list = {
        make('a', 'warning', 'instance', 'memory', 'tt-1'),
        make('b', 'critical', 'instance', 'memory', 'tt-1'),
        make('c', 'critical', 'instance', 'replication', 'tt-1'),
    }
    local out = resolver.filter(list, {
        severity = 'critical', category = 'memory', instance = 'tt-1',
    })
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].id, 'b')
end

g.test_filter_nil_opts_returns_all = function()
    local list = { make('a', 'warning'), make('b', 'critical') }
    t.assert_equals(#resolver.filter(list, nil), 2)
end

-- ── paginate ────────────────────────────────────────────────────────

local function make_list(n)
    local out = {}
    for i = 1, n do
        table.insert(out, { id = string.format('id-%03d', i) })
    end
    return out
end

g.test_paginate_default_size = function()
    local page = resolver.paginate(make_list(80), nil, nil)
    t.assert_equals(#page.items, resolver.DEFAULT_PAGE_SIZE)
    t.assert_equals(page.next_cursor, 'id-050')
    t.assert_equals(page.total_count, 80)
end

g.test_paginate_explicit_limit = function()
    local page = resolver.paginate(make_list(5), nil, 2)
    t.assert_equals(#page.items, 2)
    t.assert_equals(page.next_cursor, 'id-002')
end

g.test_paginate_cap_at_max = function()
    local page = resolver.paginate(make_list(1000), nil, 9999)
    t.assert_equals(#page.items, resolver.MAX_PAGE_SIZE)
end

g.test_paginate_after_cursor = function()
    local page = resolver.paginate(make_list(5), 'id-002', 2)
    t.assert_equals(page.items[1].id, 'id-003')
    t.assert_equals(page.items[2].id, 'id-004')
    t.assert_equals(page.next_cursor, 'id-004')
end

g.test_paginate_unknown_cursor_starts_from_top = function()
    -- Graceful degradation: unknown cursor → treat as no cursor.
    local page = resolver.paginate(make_list(3), 'no-such-id', 2)
    t.assert_equals(page.items[1].id, 'id-001')
end

g.test_paginate_last_page_null_cursor = function()
    local page = resolver.paginate(make_list(2), nil, 5)
    t.assert_equals(#page.items, 2)
    t.assert_equals(page.next_cursor, nil)
end

g.test_paginate_empty = function()
    local page = resolver.paginate({}, nil, 10)
    t.assert_equals(#page.items, 0)
    t.assert_equals(page.next_cursor, nil)
    t.assert_equals(page.total_count, 0)
end

g.test_paginate_zero_limit_falls_back = function()
    local page = resolver.paginate(make_list(120), nil, 0)
    t.assert_equals(#page.items, resolver.DEFAULT_PAGE_SIZE)
end

g.test_module_constants = function()
    t.assert_equals(resolver.DEFAULT_PAGE_SIZE, 50)
    t.assert_equals(resolver.MAX_PAGE_SIZE, 500)
end
