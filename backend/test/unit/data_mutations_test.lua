local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local types = require('webui.data_explorer.types')
local mut   = require('webui.graphql.resolvers.data_mutations')

local g = t.group('data_mutations')

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

-- ── coerce_field type matrix ───────────────────────────────────────

g.test_coerce_unsigned_from_string = function()
    t.assert_equals(types.coerce_field('42', 'unsigned'), 42)
end

g.test_coerce_unsigned_from_number_passes_through = function()
    t.assert_equals(types.coerce_field(42, 'unsigned'), 42)
end

g.test_coerce_unsigned_rejects_garbage = function()
    local v, err = types.coerce_field('not-a-number', 'unsigned')
    t.assert_equals(v, nil)
    t.assert_str_contains(err, 'unsigned')
end

g.test_coerce_number_from_string = function()
    t.assert_equals(types.coerce_field('3.14', 'number'), 3.14)
end

g.test_coerce_boolean_accepts_strings_and_ints = function()
    t.assert_equals(types.coerce_field('true', 'boolean'),  true)
    t.assert_equals(types.coerce_field('false', 'boolean'), false)
    t.assert_equals(types.coerce_field(1, 'boolean'),       true)
    t.assert_equals(types.coerce_field(0, 'boolean'),       false)
    t.assert_equals(types.coerce_field(true, 'boolean'),    true)
end

g.test_coerce_uuid_roundtrip = function()
    local uuid = require('uuid')
    local str = uuid.str()  -- e.g. "550e8400-e29b-41d4-a716-446655440000"
    local v, err = types.coerce_field(str, 'uuid')
    t.assert_equals(err, nil)
    t.assert_type(v, 'cdata')
    t.assert_equals(tostring(v), str)
end

g.test_coerce_uuid_rejects_garbage = function()
    local v, err = types.coerce_field('not-a-uuid', 'uuid')
    t.assert_equals(v, nil)
    t.assert_str_contains(err, 'uuid')
end

g.test_coerce_decimal_from_string = function()
    local v, err = types.coerce_field('3.14', 'decimal')
    t.assert_equals(err, nil)
    t.assert_type(v, 'cdata')
    t.assert_equals(tostring(v), '3.14')
end

g.test_coerce_binary_envelope = function()
    -- {_binary_base64} envelope decodes to raw bytes.
    local digest = require('digest')
    local raw    = '\x00\xff\x42'
    local enc    = digest.base64_encode(raw)
    local v, err = types.coerce_field({ _binary_base64 = enc }, 'string')
    t.assert_equals(err, nil)
    t.assert_equals(v, raw)
end

g.test_coerce_map_from_json_string = function()
    local v, err = types.coerce_field('{"k":1}', 'map')
    t.assert_equals(err, nil)
    t.assert_equals(v, { k = 1 })
end

g.test_coerce_map_passes_table = function()
    t.assert_equals(types.coerce_field({ a = 1 }, 'map'), { a = 1 })
end

g.test_coerce_string_passes_through = function()
    t.assert_equals(types.coerce_field('hi', 'string'), 'hi')
end

g.test_coerce_field_nil_returns_nil = function()
    t.assert_equals(types.coerce_field(nil, 'unsigned'), nil)
end

-- ── coerce_tuple + null padding ────────────────────────────────────

g.test_coerce_tuple_basic = function()
    local fmt = {
        { name = 'id',  type = 'unsigned' },
        { name = 'tag', type = 'string'   },
    }
    local out, err = types.coerce_tuple({ '42', 'hello' }, fmt)
    t.assert_equals(err, nil)
    t.assert_equals(out, { 42, 'hello' })
end

g.test_coerce_tuple_pads_non_trailing_null_with_box_null = function()
    local fmt = {
        { name = 'id',   type = 'unsigned' },
        { name = 'mid',  type = 'string', is_nullable = true },
        { name = 'tail', type = 'string' },
    }
    -- json.NULL (== box.NULL) is how the wire format represents
    -- "explicit null" — it survives the table border where plain
    -- Lua nil would create a hole.
    local out, err = types.coerce_tuple({ 42, box.NULL, 'x' }, fmt)
    t.assert_equals(err, nil)
    t.assert_equals(#out, 3)
    t.assert_equals(out[1], 42)
    -- Position 2 must remain box.NULL so insert() writes a NULL
    -- field instead of truncating the tuple to length 1.
    t.assert(out[2] == box.NULL, 'middle null must stay as box.NULL')
    t.assert_equals(out[3], 'x')
end

g.test_coerce_tuple_recovers_lua_nil_hole = function()
    -- Defensive: even if a caller smuggled a plain Lua nil into a
    -- table border (creating a hole), the coercion layer must
    -- still pad it back to box.NULL so we never silently corrupt
    -- the storage shape.
    local fmt = {
        { name = 'id',   type = 'unsigned' },
        { name = 'mid',  type = 'string', is_nullable = true },
        { name = 'tail', type = 'string' },
    }
    local with_hole = { [1] = 42, [3] = 'x' }
    local out, err = types.coerce_tuple(with_hole, fmt)
    t.assert_equals(err, nil)
    t.assert_equals(out[1], 42)
    t.assert(out[2] == box.NULL, 'pairs() must discover the gap')
    t.assert_equals(out[3], 'x')
end

g.test_coerce_tuple_drops_trailing_nulls = function()
    local fmt = {
        { name = 'id',  type = 'unsigned' },
        { name = 'opt', type = 'string', is_nullable = true },
    }
    local out, err = types.coerce_tuple({ 42, nil }, fmt)
    t.assert_equals(err, nil)
    -- Trailing nulls become absent so the tuple stays compact.
    t.assert_equals(#out, 1)
    t.assert_equals(out[1], 42)
end

g.test_coerce_tuple_returns_field_index_in_error = function()
    local fmt = {
        { name = 'id',  type = 'unsigned' },
        { name = 'cnt', type = 'unsigned' },
    }
    local out, err = types.coerce_tuple({ 1, 'not-a-number' }, fmt)
    t.assert_equals(out, nil)
    t.assert_str_contains(err, 'field 2')
    t.assert_str_contains(err, 'cnt')
end

-- ── coerce_key ─────────────────────────────────────────────────────

g.test_coerce_key_single_part = function()
    local fmt = { { name = 'id', type = 'unsigned' } }
    local pk_parts = { { fieldno = 1, type = 'unsigned' } }
    local out, err = types.coerce_key({ '42' }, pk_parts, fmt)
    t.assert_equals(err, nil)
    t.assert_equals(out, { 42 })
end

g.test_coerce_key_composite = function()
    local fmt = {
        { name = 'gid', type = 'unsigned' },
        { name = 'sid', type = 'string'   },
    }
    local pk_parts = {
        { fieldno = 1, type = 'unsigned' },
        { fieldno = 2, type = 'string'   },
    }
    local out, err = types.coerce_key({ '7', 'abc' }, pk_parts, fmt)
    t.assert_equals(err, nil)
    t.assert_equals(out, { 7, 'abc' })
end

-- ── sensitive-space deny-list ──────────────────────────────────────

g.test_sensitive_spaces_set_well_known_entries = function()
    t.assert(mut.SENSITIVE_SPACES._user)
    t.assert(mut.SENSITIVE_SPACES._priv)
    t.assert(mut.SENSITIVE_SPACES._func)
    t.assert(mut.SENSITIVE_SPACES._schema)
    t.assert(mut.SENSITIVE_SPACES._cluster)
    t.assert(mut.SENSITIVE_SPACES._session_settings)
end

g.test_tuple_insert_blocks_user_space = function()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.tuple_insert, root,
        { space = '_user', fields = { 99, 'evil' } })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
    t.assert_str_contains(tostring(err), '_user')
end

g.test_tuple_update_blocks_priv_space = function()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.tuple_update, root, {
        space = '_priv',
        key   = { 1 },
        ops   = { { op = 'SET', field = 'name', value = 'pwn' } },
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
end

g.test_tuple_delete_blocks_cluster_space = function()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.tuple_delete, root,
        { space = '_cluster', key = { 1 } })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
end

g.test_remote_entry_re_enforces_deny_list = function()
    -- A misbehaving follower could call the receiver directly,
    -- skipping the resolver's deny-list. The receiver must
    -- re-check.
    local res = mut.remote_entry('insert', '_user',
        { fields = { 99, 'evil' } }, { user = 'attacker' })
    t.assert_type(res, 'table')
    t.assert_str_contains(tostring(res._error), 'FORBIDDEN')
end

g.test_rbac_forbids_non_admin = function()
    -- Viewer/operator must NOT be able to call tupleInsert.
    local root_viewer = { user = 'someone', roles = { 'viewer' } }
    local ok, err = pcall(mut.tuple_insert, root_viewer,
        { space = 'safe_space', fields = { 1, 'x' } })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
    t.assert_str_contains(tostring(err), 'tupleInsert')
end

-- ── end-to-end on a real user space ────────────────────────────────

local USER_SPACE_NAME = 'data_mut_test'

local function ensure_test_space()
    if box.space[USER_SPACE_NAME] then
        box.space[USER_SPACE_NAME]:truncate()
        return
    end
    -- pcall: a previous test run may have already created it.
    pcall(function()
        local s = box.schema.space.create(USER_SPACE_NAME)
        s:format({
            { name = 'id',   type = 'unsigned'                          },
            { name = 'opt',  type = 'string', is_nullable = true        },
            { name = 'tail', type = 'string'                            },
        })
        s:create_index('primary', { parts = { 'id' } })
    end)
end

g.test_e2e_insert_replace_update_delete = function()
    ensure_test_space()
    local root = { user = 'admin_dev', roles = { 'admin' } }

    -- insert with non-trailing null → box.NULL padding kicks in
    local r1 = mut.tuple_insert(root,
        { space = USER_SPACE_NAME, fields = { 1, box.NULL, 'first' } })
    t.assert_equals(r1.ok, true)
    -- before is absent (no audit before), after present
    t.assert_equals(#r1.after, 3)

    -- replace with non-null middle
    local r2 = mut.tuple_replace(root,
        { space = USER_SPACE_NAME, fields = { 1, 'mid', 'second' } })
    t.assert_equals(r2.ok, true)
    t.assert_equals(r2.after[2], 'mid')
    t.assert_equals(r2.before[3], 'first')

    -- update by name
    local r3 = mut.tuple_update(root, {
        space = USER_SPACE_NAME,
        key   = { 1 },
        ops   = { { op = 'SET', field = 'tail', value = 'third' } },
    })
    t.assert_equals(r3.after[3], 'third')

    -- delete
    local r4 = mut.tuple_delete(root,
        { space = USER_SPACE_NAME, key = { 1 } })
    t.assert_equals(r4.ok, true)
    t.assert_equals(box.space[USER_SPACE_NAME]:get({ 1 }), nil)
end

g.test_update_unknown_field_rejected = function()
    ensure_test_space()
    box.space[USER_SPACE_NAME]:insert({ 1, 'a', 'b' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.tuple_update, root, {
        space = USER_SPACE_NAME,
        key   = { 1 },
        ops   = { { op = 'SET', field = 'no_such_field', value = 'x' } },
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'unknown field')
end

g.test_delete_missing_tuple_reports_not_found = function()
    ensure_test_space()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.tuple_delete, root,
        { space = USER_SPACE_NAME, key = { 9999 } })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
end
