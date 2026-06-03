-- Unit tests for DE-1.5 `indexAction` resolver. Exercises every
-- supported action against a freshly built test space + verifies
-- the input-validation and RBAC paths.
--
-- The space carries 10 rows on a primary `id` index plus a
-- secondary `tag` index so we can also probe per-key COUNT and
-- the MIN/MAX boundary.

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local admin_data = require('webui.graphql.resolvers.admin_data')

local g = t.group('admin_data.index_action')

local SPACE_NAME = 'admin_data_index_action_test'

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

local function cleanup()
    pcall(function()
        if box.space[SPACE_NAME] then box.space[SPACE_NAME]:drop() end
    end)
end

g.before_each(function()
    cleanup()
    local s = box.schema.space.create(SPACE_NAME)
    s:format({
        { name = 'id',  type = 'unsigned' },
        { name = 'tag', type = 'string'   },
    })
    s:create_index('primary', { parts = { 'id' } })
    s:create_index('by_tag',  { parts = { 'tag' }, unique = false })
    -- 10 rows, tag bucketed into "a"/"b"/"c"
    local buckets = { 'a', 'b', 'c' }
    for i = 1, 10 do
        s:insert({ i, buckets[((i - 1) % 3) + 1] })
    end
end)

g.after_all(cleanup)

local viewer = { user = 'viewer_dev', roles = { 'viewer' } }
local guest  = { user = 'nobody',     roles = { 'guest'  } }

-- ── input validation ─────────────────────────────────────────────

g.test_validation_error_when_space_missing = function()
    local ok, err = pcall(admin_data.query_index_action, viewer,
        { space = '', index = 'primary', action = 'min' })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'VALIDATION_ERROR')
end

g.test_validation_error_when_index_missing = function()
    local ok, err = pcall(admin_data.query_index_action, viewer,
        { space = SPACE_NAME, index = '', action = 'min' })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'VALIDATION_ERROR')
end

g.test_unsupported_action_rejected = function()
    local ok, err = pcall(admin_data.query_index_action, viewer,
        { space = SPACE_NAME, index = 'primary', action = 'drop' })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'VALIDATION_ERROR')
end

g.test_unsupported_iterator_rejected = function()
    local ok, err = pcall(admin_data.query_index_action, viewer, {
        space = SPACE_NAME, index = 'primary',
        action = 'count', iterator = 'BOGUS',
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'VALIDATION_ERROR')
end

g.test_not_found_space = function()
    local ok, err = pcall(admin_data.query_index_action, viewer, {
        space = '___no_such_space___', index = 'primary', action = 'min',
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
end

g.test_not_found_index = function()
    local ok, err = pcall(admin_data.query_index_action, viewer, {
        space = SPACE_NAME, index = '___no_such_index___', action = 'min',
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
end

-- ── happy paths ──────────────────────────────────────────────────

g.test_min_returns_first_tuple = function()
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'primary', action = 'min',
    })
    t.assert_equals(res.action, 'min')
    t.assert_type(res.tuple, 'table')
    t.assert_equals(res.tuple[1], 1)
end

g.test_max_returns_last_tuple = function()
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'primary', action = 'max',
    })
    t.assert_equals(res.action, 'max')
    t.assert_equals(res.tuple[1], 10)
end

g.test_min_with_prefix_on_secondary_index = function()
    -- Smallest tuple with tag=='b' should be id=2 (rows 2,5,8).
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'by_tag',
        action = 'min', key = { 'b' },
    })
    t.assert_equals(res.tuple[1], 2)
    t.assert_equals(res.tuple[2], 'b')
end

g.test_random_returns_some_tuple = function()
    -- We do not assert which tuple lands — Tarantool's
    -- :random(seed) is intentionally non-deterministic — but the
    -- resolver must wrap it as a non-nil tuple of two fields.
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'primary', action = 'random',
    })
    t.assert_equals(res.action, 'random')
    t.assert_type(res.tuple, 'table')
    t.assert(res.tuple[1] >= 1 and res.tuple[1] <= 10,
        'random must return one of the 10 inserted rows')
end

g.test_count_all_returns_total = function()
    -- No key → default iterator ALL, count the whole index.
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'primary', action = 'count',
    })
    t.assert_equals(res.action, 'count')
    t.assert_equals(res.count, 10)
end

g.test_count_with_key_uses_eq_by_default = function()
    -- Rows where tag=='a' are 1, 4, 7, 10 → 4 rows.
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'by_tag',
        action = 'count', key = { 'a' },
    })
    t.assert_equals(res.count, 4)
end

g.test_count_with_iterator_gt = function()
    -- id > 5 → 5 rows (6..10).
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'primary',
        action = 'count', key = { 5 }, iterator = 'GT',
    })
    t.assert_equals(res.count, 5)
end

g.test_stat_returns_table = function()
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'primary', action = 'stat',
    })
    t.assert_equals(res.action, 'stat')
    t.assert_type(res.stat, 'table')
end

g.test_bsize_positive_after_inserts = function()
    local res = admin_data.query_index_action(viewer, {
        space = SPACE_NAME, index = 'primary', action = 'bsize',
    })
    t.assert_equals(res.action, 'bsize')
    t.assert_type(res.bytes, 'number')
    t.assert(res.bytes > 0, 'bsize must be > 0 after 10 inserts')
end

-- ── RBAC ─────────────────────────────────────────────────────────

g.test_rbac_unknown_role_rejected = function()
    local ok, err = pcall(admin_data.query_index_action, guest, {
        space = SPACE_NAME, index = 'primary', action = 'min',
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
    t.assert_str_contains(tostring(err), 'indexAction')
end
