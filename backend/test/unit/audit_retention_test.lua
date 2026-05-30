local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local retention = require('webui.audit.retention')
local audit_resolver = require('webui.graphql.resolvers.audit')

local g = t.group('audit')

g.test_horizon_us_subtracts_retention = function()
    -- now=1000s, retention=86400s → horizon=(1000 - 86400) * 1e6
    local h = retention.horizon_us(1000, 86400)
    t.assert_equals(h, math.floor((1000 - 86400) * 1e6))
end

g.test_horizon_handles_zero_retention = function()
    t.assert_equals(retention.horizon_us(100, 0), math.floor(100 * 1e6))
end

g.test_matches_filter_each_field = function()
    local row = {
        user = 'alice', action = 'auth.login',
        scope = 'session', ts = 1500,
    }
    t.assert_equals(audit_resolver.matches_filter(row, nil), true)
    t.assert_equals(audit_resolver.matches_filter(row, {}), true)
    t.assert_equals(audit_resolver.matches_filter(row, { user = 'alice' }), true)
    t.assert_equals(audit_resolver.matches_filter(row, { user = 'bob'   }), false)
    t.assert_equals(audit_resolver.matches_filter(row, { action = 'auth.login' }), true)
    t.assert_equals(audit_resolver.matches_filter(row, { action = 'rbac.denied' }), false)
    t.assert_equals(audit_resolver.matches_filter(row, { scope = 'session' }), true)
    t.assert_equals(audit_resolver.matches_filter(row, { scope = 'other'   }), false)
    t.assert_equals(audit_resolver.matches_filter(row, { from_ts = 1000 }), true)
    t.assert_equals(audit_resolver.matches_filter(row, { from_ts = 2000 }), false)
    t.assert_equals(audit_resolver.matches_filter(row, { to_ts   = 2000 }), true)
    t.assert_equals(audit_resolver.matches_filter(row, { to_ts   = 1000 }), false)
end

g.test_collect_page_respects_limit_and_after = function()
    -- Sorted by id descending — newest first
    local rows = {}
    for i = 10, 1, -1 do
        rows[#rows + 1] = { id = i, user = 'u', action = 'a', scope = 's', ts = i }
    end
    local cursor_idx = 0
    local function next_row()
        cursor_idx = cursor_idx + 1
        local r = rows[cursor_idx]
        if r == nil then return nil end
        return cursor_idx, r
    end
    local got, more, cursor = audit_resolver.collect_page(next_row, nil, 3, nil)
    t.assert_equals(#got, 3)
    t.assert_equals(more, true)
    t.assert(cursor ~= nil)
end
