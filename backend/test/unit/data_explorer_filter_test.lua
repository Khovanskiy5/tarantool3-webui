local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local filter = require('webui.data_explorer.filter')

local g = t.group('data_explorer.filter')

-- Build a mock space with the shape expected by pick_index.
local function mock_space(name, indexes, count)
    local self = {
        name  = name,
        index = {},
        count = function(_) return count or 0 end,
    }
    for _, idx in ipairs(indexes) do
        self.index[idx.id]   = idx
        self.index[idx.name] = idx
    end
    return self
end

local function pri(parts)
    return { id = 0, name = 'primary', unique = true, parts = parts }
end

local function sec(id, name, parts, unique)
    return { id = id, name = name, unique = unique == true, parts = parts }
end

-- ── pick_index ─────────────────────────────────────────────────────

g.test_pick_index_returns_primary_when_no_filter = function()
    local space = mock_space('s', { pri({ { field_name = 'id' } }) })
    local idx, cover = filter.pick_index(space, {})
    t.assert_equals(idx.name, 'primary')
    t.assert_equals(cover, 0)
end

g.test_pick_index_picks_best_covering_secondary = function()
    local space = mock_space('s', {
        pri({ { field_name = 'id' } }),
        sec(1, 'by_user', { { field_name = 'user_id' } }),
    })
    local idx, cover = filter.pick_index(space, {
        { field = 'user_id', op = 'eq', value = 42 },
    })
    t.assert_equals(idx.name, 'by_user')
    t.assert_equals(cover, 1)
end

g.test_pick_index_prefers_more_leading_parts = function()
    local space = mock_space('s', {
        pri({ { field_name = 'id' } }),
        sec(1, 'by_user', { { field_name = 'user_id' } }),
        sec(2, 'by_user_ts', {
            { field_name = 'user_id' },
            { field_name = 'ts' },
        }),
    })
    local idx, cover = filter.pick_index(space, {
        { field = 'user_id', op = 'eq', value = 42 },
        { field = 'ts',      op = 'eq', value = 100 },
    })
    t.assert_equals(idx.name, 'by_user_ts')
    t.assert_equals(cover, 2)
end

g.test_pick_index_ignores_non_eq_for_covering = function()
    local space = mock_space('s', {
        pri({ { field_name = 'id' } }),
        sec(1, 'by_user', { { field_name = 'user_id' } }),
    })
    local _, cover = filter.pick_index(space, {
        { field = 'user_id', op = 'gt', value = 10 },
    })
    t.assert_equals(cover, 0)
end

-- ── build_key ──────────────────────────────────────────────────────

g.test_build_key_assembles_eq_chain = function()
    local idx = sec(1, 'by_user_ts', {
        { field_name = 'user_id' },
        { field_name = 'ts' },
    }, true)
    local key, iter = filter.build_key(idx, 2, {
        { field = 'user_id', op = 'eq', value = 42 },
        { field = 'ts',      op = 'eq', value = 100 },
    })
    t.assert_equals(key, { 42, 100 })
    t.assert_equals(iter, 'EQ')
end

g.test_build_key_partial_cover_goes_to_ge = function()
    local idx = sec(1, 'by_user_ts', {
        { field_name = 'user_id' },
        { field_name = 'ts' },
    }, true)
    local key, iter = filter.build_key(idx, 1, {
        { field = 'user_id', op = 'eq', value = 42 },
    })
    t.assert_equals(key, { 42 })
    t.assert_equals(iter, 'GE')
end

g.test_build_key_no_cover_returns_all_iter = function()
    local key, iter = filter.build_key(nil, 0, {})
    t.assert_equals(key, {})
    t.assert_equals(iter, 'ALL')
end

-- ── residual ───────────────────────────────────────────────────────

g.test_residual_omits_pushed_eq_conditions = function()
    local idx = sec(1, 'by_user', { { field_name = 'user_id' } }, true)
    local r = filter.residual({
        { field = 'user_id', op = 'eq', value = 42 },
        { field = 'name',    op = 'eq', value = 'x' },
    }, idx, 1)
    t.assert_equals(#r, 1)
    t.assert_equals(r[1].field, 'name')
end

g.test_residual_keeps_non_eq_even_for_pushed_field = function()
    local idx = sec(1, 'by_user', { { field_name = 'user_id' } }, true)
    local r = filter.residual({
        { field = 'user_id', op = 'gt', value = 10 },
    }, idx, 1)
    -- gt on a pushed leading part still requires post-filter
    -- because build_key would have used GE on the same field.
    t.assert_equals(#r, 1)
end

-- ── apply_post_filter ──────────────────────────────────────────────

g.test_post_filter_eq_matches = function()
    local lookup = { id = 1, name = 2 }
    t.assert_equals(
        filter.apply_post_filter({ 42, 'alice' },
            { { field = 'name', op = 'eq', value = 'alice' } }, lookup),
        true)
end

g.test_post_filter_eq_fails = function()
    local lookup = { id = 1, name = 2 }
    t.assert_equals(
        filter.apply_post_filter({ 42, 'alice' },
            { { field = 'name', op = 'eq', value = 'bob' } }, lookup),
        false)
end

g.test_post_filter_combinators = function()
    local lookup = { v = 1 }
    local function call(op, target, val)
        return filter.apply_post_filter({ val },
            { { field = 'v', op = op, value = target } }, lookup)
    end
    t.assert_equals(call('gt', 10, 15), true)
    t.assert_equals(call('gt', 10, 10), false)
    t.assert_equals(call('ge', 10, 10), true)
    t.assert_equals(call('lt', 10, 5),  true)
    t.assert_equals(call('le', 10, 10), true)
    t.assert_equals(call('ne', 10, 11), true)
    t.assert_equals(call('ne', 10, 10), false)
end

g.test_post_filter_prefix = function()
    local lookup = { name = 1 }
    t.assert_equals(
        filter.apply_post_filter({ 'alice_smith' },
            { { field = 'name', op = 'prefix', value = 'alice' } }, lookup),
        true)
    t.assert_equals(
        filter.apply_post_filter({ 'bob' },
            { { field = 'name', op = 'prefix', value = 'alice' } }, lookup),
        false)
end

g.test_post_filter_like_with_percent = function()
    local lookup = { name = 1 }
    t.assert_equals(
        filter.apply_post_filter({ 'alice_smith' },
            { { field = 'name', op = 'like', value = 'alice%' } }, lookup),
        true)
    t.assert_equals(
        filter.apply_post_filter({ 'bob' },
            { { field = 'name', op = 'like', value = 'alice%' } }, lookup),
        false)
end

g.test_post_filter_combines_with_and = function()
    local lookup = { id = 1, name = 2 }
    -- Both conditions match → pass.
    t.assert_equals(
        filter.apply_post_filter({ 42, 'alice' }, {
            { field = 'id',   op = 'eq', value = 42 },
            { field = 'name', op = 'eq', value = 'alice' },
        }, lookup), true)
    -- Second condition fails → reject.
    t.assert_equals(
        filter.apply_post_filter({ 42, 'alice' }, {
            { field = 'id',   op = 'eq', value = 42 },
            { field = 'name', op = 'eq', value = 'bob' },
        }, lookup), false)
end

g.test_post_filter_missing_field_fails_unless_ne = function()
    local lookup = { id = 1 }
    -- name is field 2, but tuple has only one field → nil.
    t.assert_equals(
        filter.apply_post_filter({ 42 },
            { { field = 'name', op = 'eq', value = 'alice' } }, lookup),
        false)
    -- ne with absent field: in our semantics absent != value → pass
    -- (we treat nil as "any other value").
    t.assert_equals(
        filter.apply_post_filter({ 42 },
            { { field = 'name', op = 'ne', value = 'alice' } }, lookup),
        true)
end

-- ── check_full_scan ────────────────────────────────────────────────

g.test_check_full_scan_allows_when_index_covers = function()
    local space = mock_space('s', {
        pri({ { field_name = 'id' } }),
        sec(1, 'by_user', { { field_name = 'user_id' } }),
    }, 100000)
    local ok = filter.check_full_scan(space, {
        { field = 'user_id', op = 'eq', value = 42 },
    })
    t.assert_equals(ok, true)
end

g.test_check_full_scan_blocks_unindexed_on_large_space = function()
    local space = mock_space('s', { pri({ { field_name = 'id' } }) }, 100000)
    local ok, err = filter.check_full_scan(space, {})
    t.assert_equals(ok, false)
    t.assert_str_contains(err, 'allow_full_scan')
end

g.test_check_full_scan_allows_small_space = function()
    local space = mock_space('s', { pri({ { field_name = 'id' } }) }, 10)
    local ok = filter.check_full_scan(space, {})
    t.assert_equals(ok, true)
end

g.test_check_full_scan_explicit_override = function()
    local space = mock_space('s', { pri({ { field_name = 'id' } }) }, 100000)
    local ok = filter.check_full_scan(space, {},
        { allow_full_scan = true })
    t.assert_equals(ok, true)
end
