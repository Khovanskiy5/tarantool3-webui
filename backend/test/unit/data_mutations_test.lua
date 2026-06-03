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

-- ── varbinary + box.NULL wire roundtrip (DE-1.2) ───────────────────

local BIN_SPACE_NAME = 'data_mut_binary_test'

local function ensure_bin_space()
    if box.space[BIN_SPACE_NAME] then
        box.space[BIN_SPACE_NAME]:truncate()
        return
    end
    local s = box.schema.space.create(BIN_SPACE_NAME)
    s:format({
        { name = 'id',      type = 'unsigned'                       },
        { name = 'payload', type = 'varbinary', is_nullable = true  },
        { name = 'label',   type = 'string'                         },
    })
    s:create_index('primary', { parts = { 'id' } })
end

g.test_varbinary_insert_via_envelope_roundtrips = function()
    ensure_bin_space()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    -- bytes 0xde 0xad 0xbe 0xef 0x00 0x01 0x02 — base64 of which is
    -- "3q2+7wABAg==". coerce_field must wrap this into a varbinary
    -- cdata or Tarantool rejects the insert with FIELD_TYPE.
    local b64 = require('digest').base64_encode(
        string.char(0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02))
    local r = mut.tuple_insert(root, {
        space  = BIN_SPACE_NAME,
        fields = { 1, { _binary_base64 = b64 }, 'bin' },
    })
    t.assert_equals(r.ok, true)
    -- The stored field must come back as the envelope, not a raw
    -- string (varbinary reads back as cdata; encode_field base64s it).
    t.assert_type(r.after[2], 'table')
    t.assert_equals(r.after[2]._binary_base64, b64)
    -- And the bytes on disk match what we sent.
    local stored = box.space[BIN_SPACE_NAME]:get({ 1 })[2]
    t.assert_equals(tostring(stored),
        string.char(0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02))
end

g.test_varbinary_null_roundtrips_as_json_null = function()
    ensure_bin_space()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local r = mut.tuple_insert(root, {
        space  = BIN_SPACE_NAME,
        fields = { 2, box.NULL, 'no-payload' },
    })
    t.assert_equals(r.ok, true)
    -- The list must keep all three positions (a Lua-nil in the
    -- middle would truncate it to length 1).
    t.assert_equals(#r.after, 3)
    -- The NULL position is the box.NULL sentinel, which json.encode
    -- renders as `null` — NOT the string "cdata<void *>: NULL".
    t.assert_equals(r.after[2], box.NULL)
    t.assert_equals(r.after[3], 'no-payload')
end

-- ── update operator matrix (build_update_ops covers each op code) ──

local OP_SPACE_NAME = 'data_mut_ops_test'

local function ensure_ops_space()
    if box.space[OP_SPACE_NAME] then
        box.space[OP_SPACE_NAME]:truncate()
    else
        local s = box.schema.space.create(OP_SPACE_NAME)
        s:format({
            { name = 'id',   type = 'unsigned' },
            { name = 'num',  type = 'unsigned' },
            { name = 'flag', type = 'unsigned' },
            { name = 'text', type = 'string'   },
        })
        s:create_index('primary', { parts = { 'id' } })
    end
end

g.test_update_op_assign = function()
    ensure_ops_space()
    box.space[OP_SPACE_NAME]:insert({ 1, 10, 0, 'a' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local r = mut.tuple_update(root, {
        space = OP_SPACE_NAME, key = { 1 },
        ops = { { op = '=', field = 'text', value = 'b' } },
    })
    t.assert_equals(r.after[4], 'b')
end

g.test_update_op_add = function()
    ensure_ops_space()
    box.space[OP_SPACE_NAME]:insert({ 1, 10, 0, 'a' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local r = mut.tuple_update(root, {
        space = OP_SPACE_NAME, key = { 1 },
        ops = { { op = '+', field = 'num', value = 5 } },
    })
    t.assert_equals(r.after[2], 15)
end

g.test_update_op_sub = function()
    ensure_ops_space()
    box.space[OP_SPACE_NAME]:insert({ 1, 10, 0, 'a' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local r = mut.tuple_update(root, {
        space = OP_SPACE_NAME, key = { 1 },
        ops = { { op = '-', field = 'num', value = 3 } },
    })
    t.assert_equals(r.after[2], 7)
end

g.test_update_op_band = function()
    ensure_ops_space()
    box.space[OP_SPACE_NAME]:insert({ 1, 10, 0xff, 'a' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local r = mut.tuple_update(root, {
        space = OP_SPACE_NAME, key = { 1 },
        ops = { { op = '&', field = 'flag', value = 0x0f } },
    })
    t.assert_equals(r.after[3], 0x0f)
end

g.test_update_op_bor = function()
    ensure_ops_space()
    box.space[OP_SPACE_NAME]:insert({ 1, 10, 0x0f, 'a' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local r = mut.tuple_update(root, {
        space = OP_SPACE_NAME, key = { 1 },
        ops = { { op = '|', field = 'flag', value = 0xf0 } },
    })
    t.assert_equals(r.after[3], 0xff)
end

g.test_update_op_bxor = function()
    ensure_ops_space()
    box.space[OP_SPACE_NAME]:insert({ 1, 10, 0xaa, 'a' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local r = mut.tuple_update(root, {
        space = OP_SPACE_NAME, key = { 1 },
        ops = { { op = '^', field = 'flag', value = 0xff } },
    })
    t.assert_equals(r.after[3], 0x55)
end

g.test_update_op_splice_known_limitation = function()
    -- Known limitation of the current resolver: ':' (splice) takes a
    -- {position, length, replacement} triple in Tarantool's wire
    -- protocol but the resolver passes `value` through as a single
    -- coerced field, so Tarantool rejects with "wrong number of
    -- arguments". This baseline test pins that behaviour so we
    -- notice if the refactor accidentally fixes (or worsens) it —
    -- proper splice support is out of scope for DE-1.0.
    ensure_ops_space()
    box.space[OP_SPACE_NAME]:insert({ 1, 10, 0, 'abcdef' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.tuple_update, root, {
        space = OP_SPACE_NAME, key = { 1 },
        ops = { { op = ':', field = 'text', value = { 2, 2, 'XX' } } },
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'wrong number of arguments')
end

g.test_update_op_unknown_rejected = function()
    ensure_ops_space()
    box.space[OP_SPACE_NAME]:insert({ 1, 10, 0, 'a' })
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.tuple_update, root, {
        space = OP_SPACE_NAME, key = { 1 },
        ops = { { op = 'magic', field = 'num', value = 1 } },
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'unsupported update op')
end

-- ── DDL: create / alter / drop space + indexes ──────────────────────

local DDL_SPACE_NAME = 'data_mut_ddl_test'
local DDL_SPACE_RENAMED = 'data_mut_ddl_test_renamed'

local function cleanup_ddl_spaces()
    for _, n in ipairs({ DDL_SPACE_NAME, DDL_SPACE_RENAMED }) do
        if box.space[n] ~= nil then pcall(function() box.space[n]:drop() end) end
    end
end

g.test_e2e_create_space_with_format_and_pk = function()
    cleanup_ddl_spaces()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local r = mut.create_space(root, {
        name   = DDL_SPACE_NAME,
        engine = 'memtx',
        format = {
            { name = 'id',   type = 'unsigned' },
            { name = 'text', type = 'string'   },
        },
        primary_key = { 'id' },
    })
    t.assert_equals(r.ok, true)
    t.assert_equals(r.name, DDL_SPACE_NAME)
    t.assert(box.space[DDL_SPACE_NAME] ~= nil)
    -- Primary index must exist so the space is insertable.
    t.assert(box.space[DDL_SPACE_NAME].index[0] ~= nil)
    cleanup_ddl_spaces()
end

g.test_e2e_create_space_uses_first_field_as_default_pk = function()
    cleanup_ddl_spaces()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    -- No primary_key passed → resolver picks the first format field.
    mut.create_space(root, {
        name   = DDL_SPACE_NAME,
        format = {
            { name = 'id',  type = 'unsigned' },
            { name = 'tag', type = 'string'   },
        },
    })
    local idx = box.space[DDL_SPACE_NAME].index[0]
    t.assert(idx ~= nil)
    t.assert_equals(idx.parts[1].fieldno, 1)
    cleanup_ddl_spaces()
end

g.test_e2e_alter_space_format_and_rename = function()
    cleanup_ddl_spaces()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    mut.create_space(root, {
        name   = DDL_SPACE_NAME,
        format = {
            { name = 'id',   type = 'unsigned' },
            { name = 'text', type = 'string'   },
        },
        primary_key = { 'id' },
    })
    local r = mut.alter_space(root, {
        name     = DDL_SPACE_NAME,
        new_name = DDL_SPACE_RENAMED,
        format   = {
            { name = 'id',   type = 'unsigned' },
            { name = 'note', type = 'string', is_nullable = true },
        },
    })
    t.assert_equals(r.ok, true)
    t.assert_equals(r.name, DDL_SPACE_RENAMED)
    t.assert(box.space[DDL_SPACE_RENAMED] ~= nil)
    t.assert(box.space[DDL_SPACE_NAME] == nil)
    cleanup_ddl_spaces()
end

g.test_e2e_drop_space = function()
    cleanup_ddl_spaces()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    mut.create_space(root, {
        name = DDL_SPACE_NAME,
        format = { { name = 'id', type = 'unsigned' } },
        primary_key = { 'id' },
    })
    local r = mut.drop_space(root, { name = DDL_SPACE_NAME })
    t.assert_equals(r.ok, true)
    t.assert(box.space[DDL_SPACE_NAME] == nil)
end

g.test_e2e_truncate_space_clears_tuples = function()
    cleanup_ddl_spaces()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    mut.create_space(root, {
        name = DDL_SPACE_NAME,
        format = {
            { name = 'id',  type = 'unsigned' },
            { name = 'tag', type = 'string'   },
        },
        primary_key = { 'id' },
    })
    box.space[DDL_SPACE_NAME]:insert({ 1, 'a' })
    box.space[DDL_SPACE_NAME]:insert({ 2, 'b' })
    box.space[DDL_SPACE_NAME]:insert({ 3, 'c' })
    t.assert_equals(box.space[DDL_SPACE_NAME]:count(), 3)
    local r = mut.truncate_space(root, { name = DDL_SPACE_NAME })
    t.assert_equals(r.ok, true)
    t.assert_equals(r.name, DDL_SPACE_NAME)
    -- sequence_reset must be false when no sequence is attached AND
    -- the operator did not ask for a reset — confirms the default.
    t.assert_equals(r.sequence_reset, false)
    t.assert_equals(box.space[DDL_SPACE_NAME]:count(), 0)
    cleanup_ddl_spaces()
end

g.test_truncate_space_blocks_system_space = function()
    -- _user is in SENSITIVE_SPACES + sits in the `_` namespace, so
    -- both guards in assert_safe_ddl fire. The error must reference
    -- the operation and the offending name so the UI can surface it.
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.truncate_space, root, { name = '_user' })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
    t.assert_str_contains(tostring(err), '_user')
end

g.test_truncate_space_blocks_underscore_namespace = function()
    -- Any name starting with `_` is rejected even when it is not in
    -- the explicit deny-list — `_` belongs to Tarantool.
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.truncate_space, root,
        { name = '_does_not_exist_but_underscored' })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
end

g.test_truncate_space_rejects_inside_txn = function()
    -- The guard fires BEFORE Tarantool's own cryptic message so the
    -- UI can show "commit your txn first" instead of an internal
    -- error. We wrap the call in box.atomic so the resolver runs
    -- with box.is_in_txn() == true.
    cleanup_ddl_spaces()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    mut.create_space(root, {
        name = DDL_SPACE_NAME,
        format = { { name = 'id', type = 'unsigned' } },
        primary_key = { 'id' },
    })
    local ok, err = pcall(function()
        box.atomic(function()
            mut.truncate_space(root, { name = DDL_SPACE_NAME })
        end)
    end)
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'TRUNCATE_INSIDE_TXN')
    cleanup_ddl_spaces()
end

g.test_truncate_space_resets_attached_sequence = function()
    -- End-to-end: attach a sequence so the next insert auto-fills
    -- the PK, fill some rows, then truncate with reset_sequence:
    -- the next insert must restart from 1.
    cleanup_ddl_spaces()
    local seq_name = 'data_mut_truncate_seq'
    pcall(function() box.schema.sequence.drop(seq_name) end)
    box.schema.sequence.create(seq_name)
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local s = box.schema.space.create(DDL_SPACE_NAME)
    s:format({
        { name = 'id',  type = 'unsigned' },
        { name = 'tag', type = 'string'   },
    })
    s:create_index('primary', { parts = { 'id' }, sequence = seq_name })
    s:insert({ nil, 'a' }); s:insert({ nil, 'b' }); s:insert({ nil, 'c' })
    t.assert_equals(box.sequence[seq_name]:next() >= 3, true)
    local r = mut.truncate_space(root, {
        name = DDL_SPACE_NAME, reset_sequence = true,
    })
    t.assert_equals(r.sequence_reset, true)
    -- After reset the next call to :next() starts from the sequence's
    -- `start` (default 1). Compare strictly so a regression that no-ops
    -- the reset fails the test.
    t.assert_equals(box.sequence[seq_name]:next(), 1)
    pcall(function() s:drop() end)
    pcall(function() box.schema.sequence.drop(seq_name) end)
end

g.test_e2e_create_index_then_drop_index = function()
    cleanup_ddl_spaces()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    mut.create_space(root, {
        name = DDL_SPACE_NAME,
        format = {
            { name = 'id',   type = 'unsigned' },
            { name = 'tag',  type = 'string'   },
        },
        primary_key = { 'id' },
    })
    local r_create = mut.create_index(root, {
        space = DDL_SPACE_NAME,
        name  = 'by_tag',
        parts = { { field = 'tag', type = 'string' } },
        unique = false,
    })
    t.assert_equals(r_create.ok, true)
    t.assert(box.space[DDL_SPACE_NAME].index.by_tag ~= nil)
    local r_drop = mut.drop_index(root, {
        space = DDL_SPACE_NAME, name = 'by_tag',
    })
    t.assert_equals(r_drop.ok, true)
    t.assert(box.space[DDL_SPACE_NAME].index.by_tag == nil)
    cleanup_ddl_spaces()
end

g.test_create_space_rejects_underscore_namespace = function()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.create_space, root, {
        name = '_evil_user',
        format = { { name = 'id', type = 'unsigned' } },
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
    t.assert_str_contains(tostring(err), '_evil_user')
end

g.test_alter_space_rejects_sensitive_target = function()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.alter_space, root, {
        name = '_user',
        format = { { name = 'id', type = 'unsigned' } },
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
end

g.test_create_index_rejects_sensitive_space = function()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.create_index, root, {
        space = '_priv',
        name  = 'evil',
        parts = { { field = 'id', type = 'unsigned' } },
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
end

g.test_drop_space_reports_not_found = function()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    local ok, err = pcall(mut.drop_space, root, {
        name = 'this_space_does_not_exist_anywhere',
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
end

g.test_drop_index_reports_not_found = function()
    cleanup_ddl_spaces()
    local root = { user = 'admin_dev', roles = { 'admin' } }
    mut.create_space(root, {
        name = DDL_SPACE_NAME,
        format = { { name = 'id', type = 'unsigned' } },
        primary_key = { 'id' },
    })
    local ok, err = pcall(mut.drop_index, root, {
        space = DDL_SPACE_NAME, name = 'ghost_index',
    })
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'NOT_FOUND')
    cleanup_ddl_spaces()
end
