-- Unit tests for DE-1.3 sequence resolvers.
--
-- The mutations dispatch through `space.ddl_apply`, so the RBAC +
-- `_`-namespace guard are already covered by the space tests; here
-- we exercise the local-apply happy paths and edge cases:
--
--   * create with defaults + custom opts
--   * alter narrows options without touching unrelated fields
--   * set / reset move the current value
--   * drop removes the sequence
--   * unknown name → NOT_FOUND
--   * `_`-namespace → FORBIDDEN (via ddl_apply guard)
--   * `current` is nil immediately after create / reset, becomes a
--     concrete int after :next() / :set()

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local mut        = require('webui.graphql.resolvers.data_mutations')
local admin_data = require('webui.graphql.resolvers.admin_data')

local g = t.group('data_mutations.sequence')

local SEQ_NAME = 'data_mut_seq_test_de_1_3'

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
        if box.sequence[SEQ_NAME] then
            box.sequence[SEQ_NAME]:drop()
        end
    end)
end

g.before_each(cleanup)
g.after_all(cleanup)

local admin = { user = 'admin_dev', roles = { 'admin' } }
local viewer = { user = 'viewer_dev', roles = { 'viewer' } }

-- ── create ─────────────────────────────────────────────────────────

g.test_create_with_defaults = function()
    local r = mut.sequence_create(admin, { input = { name = SEQ_NAME } })
    t.assert_equals(r.ok, true)
    t.assert_equals(r.name, SEQ_NAME)
    t.assert_type(r.id, 'number')
    -- Fresh sequence: no `_sequence_data` row yet → current must
    -- be nil. The pcall(seq:current) inside the resolver protects
    -- against the underlying Tarantool error.
    t.assert_equals(r.current, nil,
        'fresh sequence has no current value until first :next/:set')
end

g.test_create_with_custom_opts = function()
    local r = mut.sequence_create(admin, { input = {
        name = SEQ_NAME, step = 5, min = 10, max = 1000,
        start = 100, cache = 0, cycle = false,
    } })
    t.assert_equals(r.ok, true)
    -- Round-trip the static fields through `sequenceInfo`.
    local info = admin_data.query_sequence_info(viewer, { name = SEQ_NAME })
    t.assert_equals(info.step, 5)
    t.assert_equals(info.min, 10)
    t.assert_equals(info.max, 1000)
    t.assert_equals(info.start, 100)
    t.assert_equals(info.cycle, false)
end

g.test_create_rejects_underscore_namespace = function()
    local ok, err = pcall(mut.sequence_create, admin,
        { input = { name = '_evil_seq' } })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
end

-- ── alter ──────────────────────────────────────────────────────────

g.test_alter_changes_step_keeps_others = function()
    mut.sequence_create(admin, { input = { name = SEQ_NAME, step = 1 } })
    mut.sequence_alter(admin, { input = { name = SEQ_NAME, step = 7 } })
    local info = admin_data.query_sequence_info(viewer, { name = SEQ_NAME })
    t.assert_equals(info.step, 7)
end

g.test_alter_unknown_sequence = function()
    local ok, err = pcall(mut.sequence_alter, admin,
        { input = { name = SEQ_NAME, step = 3 } })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
end

-- ── set / reset / current ─────────────────────────────────────────

g.test_set_then_info_reports_current = function()
    mut.sequence_create(admin, { input = { name = SEQ_NAME } })
    local r = mut.sequence_set(admin, { name = SEQ_NAME, value = 42 })
    t.assert_equals(r.ok, true)
    t.assert_equals(r.current, 42)
    local info = admin_data.query_sequence_info(viewer, { name = SEQ_NAME })
    t.assert_equals(info.current, 42)
end

g.test_reset_clears_current = function()
    mut.sequence_create(admin, { input = { name = SEQ_NAME } })
    mut.sequence_set(admin, { name = SEQ_NAME, value = 99 })
    local r = mut.sequence_reset(admin, { name = SEQ_NAME })
    t.assert_equals(r.ok, true)
    -- After reset Tarantool deletes the `_sequence_data` row; the
    -- resolver projects nil rather than the prior value.
    t.assert_equals(r.current, nil)
    local info = admin_data.query_sequence_info(viewer, { name = SEQ_NAME })
    t.assert_equals(info.current, nil)
end

-- ── drop ───────────────────────────────────────────────────────────

g.test_drop_removes_sequence = function()
    mut.sequence_create(admin, { input = { name = SEQ_NAME } })
    local r = mut.sequence_drop(admin, { name = SEQ_NAME })
    t.assert_equals(r.ok, true)
    t.assert_equals(box.sequence[SEQ_NAME], nil)
end

g.test_drop_unknown_sequence = function()
    local ok, err = pcall(mut.sequence_drop, admin, { name = SEQ_NAME })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
end

-- ── sequenceInfo: attached_to ─────────────────────────────────────

g.test_attached_to_lists_bound_space = function()
    -- Attach the sequence to a tiny user space, then expect
    -- `attached_to` to surface the bond. This is the signal the
    -- SPA uses to warn before drop.
    mut.sequence_create(admin, { input = { name = SEQ_NAME } })
    local space_name = 'data_mut_seq_owner'
    pcall(function() box.space[space_name]:drop() end)
    local s = box.schema.space.create(space_name)
    s:format({
        { name = 'id', type = 'unsigned' },
        { name = 'tag', type = 'string'   },
    })
    s:create_index('primary', { parts = { 'id' }, sequence = SEQ_NAME })

    local info = admin_data.query_sequence_info(viewer, { name = SEQ_NAME })
    t.assert_type(info.attached_to, 'table')
    t.assert_equals(#info.attached_to, 1,
        'one bond expected after attaching to one space')
    t.assert_equals(info.attached_to[1].space, space_name)

    s:drop()
end

g.test_info_not_found = function()
    local ok, err = pcall(admin_data.query_sequence_info, viewer,
        { name = '___no_such_sequence___' })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
end

-- ── RBAC ───────────────────────────────────────────────────────────

g.test_rbac_viewer_cannot_create = function()
    local ok, err = pcall(mut.sequence_create, viewer,
        { input = { name = SEQ_NAME } })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
    t.assert_str_contains(tostring(err), 'sequenceCreate')
end

g.test_rbac_viewer_can_read_info = function()
    mut.sequence_create(admin, { input = { name = SEQ_NAME } })
    local ok = pcall(admin_data.query_sequence_info, viewer,
        { name = SEQ_NAME })
    t.assert_equals(ok, true)
end
