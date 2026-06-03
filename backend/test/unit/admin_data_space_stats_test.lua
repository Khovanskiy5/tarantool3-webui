-- Unit tests for `query_space_stats`.
--
-- DE-1.7's stats resolver projects per-space numbers + engine-wide
-- context. Tests verify:
--   * NOT_FOUND on unknown space
--   * VALIDATION_ERROR on empty name
--   * RBAC viewer passes, unknown role rejected
--   * happy path on a memtx space populates `memtx_tuple` and
--     leaves `vinyl_engine` nil, with sane numeric fields
--   * slab ratios are parsed from `"x.xx%"` strings to floats
--   * `byte_size` and `row_count` track real insertions

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local admin_data = require('webui.graphql.resolvers.admin_data')

local g = t.group('admin_data.space_stats')

local TEST_SPACE = 'admin_data_space_stats_test'

g.before_all(function()
    if box.info.status == 'unconfigured' then
        local tmp = fio.tempdir()
        box.cfg({
            memtx_dir   = tmp,
            wal_dir     = tmp,
            wal_mode    = 'none',
            listen      = box.NULL,
            log_level   = 0,
            background  = false,
        })
    end
end)

g.before_each(function()
    pcall(function()
        if box.space[TEST_SPACE] then box.space[TEST_SPACE]:drop() end
    end)
end)

g.after_all(function()
    pcall(function()
        if box.space[TEST_SPACE] then box.space[TEST_SPACE]:drop() end
    end)
end)

local function make_space(rows)
    local s = box.schema.space.create(TEST_SPACE, { engine = 'memtx' })
    s:format({
        { name = 'id',  type = 'unsigned' },
        { name = 'tag', type = 'string'   },
    })
    s:create_index('primary', { parts = { 'id' } })
    for i = 1, rows do s:insert({ i, 'row-' .. i }) end
    return s
end

g.test_validation_error_when_name_missing = function()
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local ok, err = pcall(admin_data.query_space_stats, root, { name = '' })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'VALIDATION_ERROR')
end

g.test_not_found_when_space_absent = function()
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local ok, err = pcall(admin_data.query_space_stats, root,
        { name = '___no_such_space___' })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
end

g.test_rbac_viewer_passes = function()
    make_space(1)
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local ok = pcall(admin_data.query_space_stats, root, { name = TEST_SPACE })
    t.assert_equals(ok, true)
end

g.test_rbac_unknown_role_rejected = function()
    make_space(1)
    local root = { user = 'nobody', roles = { 'guest' } }
    local ok, err = pcall(admin_data.query_space_stats, root,
        { name = TEST_SPACE })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
    t.assert_str_contains(tostring(err), 'spaceStats')
end

g.test_memtx_happy_path_populates_tuple_and_omits_vinyl = function()
    make_space(50)
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_space_stats(root, { name = TEST_SPACE })

    -- Per-space identity
    t.assert_equals(res.name, TEST_SPACE)
    t.assert_equals(res.engine, 'memtx')
    t.assert_type(res.id, 'number')

    -- Counters match what we inserted
    t.assert_equals(res.row_count, 50)
    t.assert(res.byte_size > 0,
        'byte_size must be positive after 50 inserts')

    -- Memtx branch is populated, vinyl is intentionally nil so the
    -- SPA can pick which sub-panel to render off the engine flag.
    t.assert_type(res.memtx_tuple, 'table')
    t.assert(res.memtx_tuple.data_size > 0,
        'memtx tuple data_size must reflect inserted rows')
    t.assert_equals(res.vinyl_engine, nil)
end

g.test_slab_ratios_are_floats = function()
    make_space(10)
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_space_stats(root, { name = TEST_SPACE })

    -- The raw `box.slab.info()` returns ratios as printable strings
    -- like "30.08%" — the resolver must convert them to floats so
    -- the SPA can drive a progress bar directly.
    t.assert_type(res.slab, 'table')
    for _, key in ipairs({ 'quota_used_ratio', 'items_used_ratio', 'arena_used_ratio' }) do
        local v = res.slab[key]
        t.assert_type(v, 'number',
            'slab.' .. key .. ' must be a number, got ' .. type(v))
        -- Percentages live on [0, 100]; the converter must not
        -- accidentally divide by anything.
        t.assert(v >= 0 and v <= 100,
            'slab.' .. key .. ' = ' .. tostring(v) .. ' is out of range')
    end
    -- Numeric bytes pass through untouched.
    t.assert(res.slab.quota_size > 0)
    t.assert(res.slab.arena_size >= 0)
end

g.test_memtx_data_summary_present = function()
    make_space(5)
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_space_stats(root, { name = TEST_SPACE })
    t.assert_type(res.memtx_data, 'table')
    t.assert_type(res.memtx_data.total, 'number')
    t.assert_type(res.memtx_data.garbage, 'number')
    t.assert_type(res.memtx_data.read_view, 'number')
end

g.test_byte_size_grows_with_inserts = function()
    -- Sanity: inserting more rows produces a strictly larger
    -- `byte_size`. Catches a regression where we'd accidentally
    -- return a constant (e.g. quota_size) instead of `:bsize()`.
    make_space(5)
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local small = admin_data.query_space_stats(root, { name = TEST_SPACE }).byte_size
    for i = 6, 100 do box.space[TEST_SPACE]:insert({ i, 'row-' .. i }) end
    local big = admin_data.query_space_stats(root, { name = TEST_SPACE }).byte_size
    t.assert(big > small,
        'byte_size must grow after additional inserts, got '
        .. small .. ' → ' .. big)
end
