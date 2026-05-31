local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local types = require('webui.data_explorer.types')

local g = t.group('data_explorer.types')

-- ── cursor encode/decode ───────────────────────────────────────────

g.test_cursor_roundtrip_single_int = function()
    local enc = types.cursor_encode({ 42 })
    t.assert_type(enc, 'string')
    local dec = types.cursor_decode(enc)
    t.assert_equals(dec, { 42 })
end

g.test_cursor_roundtrip_composite = function()
    local key = { 'user-42', 100, 'idx' }
    local dec = types.cursor_decode(types.cursor_encode(key))
    t.assert_equals(dec, key)
end

g.test_cursor_roundtrip_binary_key = function()
    -- Keys with bytes > 0x7F must survive. base64 + msgpack
    -- handles it; plain-text would not.
    local key = { '\x00\xff\x7f\x80' }
    local dec = types.cursor_decode(types.cursor_encode(key))
    t.assert_equals(dec, key)
end

g.test_cursor_decode_rejects_garbage = function()
    -- Tampered cursor must degrade to nil, not raise.
    t.assert_equals(types.cursor_decode('not-base64!@#'), nil)
    t.assert_equals(types.cursor_decode(''), nil)
    t.assert_equals(types.cursor_decode(nil), nil)
end

g.test_cursor_encode_nil_returns_nil = function()
    t.assert_equals(types.cursor_encode(nil), nil)
end

-- ── UTF-8 / binary detection ───────────────────────────────────────

g.test_is_valid_utf8_ascii = function()
    t.assert_equals(types._is_valid_utf8('hello'), true)
end

g.test_is_valid_utf8_multibyte = function()
    -- "привет" in UTF-8.
    t.assert_equals(types._is_valid_utf8('привет'), true)
end

g.test_is_valid_utf8_rejects_binary = function()
    -- Lone continuation byte and high-bit-only bytes — both invalid.
    t.assert_equals(types._is_valid_utf8('\x80'), false)
    t.assert_equals(types._is_valid_utf8('\xff\xff'), false)
    -- Truncated 2-byte sequence.
    t.assert_equals(types._is_valid_utf8('\xc2'), false)
end

-- ── field encoding ─────────────────────────────────────────────────

g.test_encode_field_passes_clean_string = function()
    t.assert_equals(types.encode_field('plain'), 'plain')
end

g.test_encode_field_wraps_binary = function()
    local out = types.encode_field('\x00\xff\xab')
    t.assert_type(out, 'table')
    t.assert_type(out._binary_base64, 'string')
    t.assert(out._binary_base64 ~= '')
end

g.test_encode_field_passes_numbers_and_booleans = function()
    t.assert_equals(types.encode_field(42), 42)
    t.assert_equals(types.encode_field(true), true)
    t.assert_equals(types.encode_field(nil), nil)
end

-- ── format normalization ───────────────────────────────────────────

g.test_normalize_format_empty = function()
    t.assert_equals(types.normalize_format(nil), {})
    t.assert_equals(types.normalize_format({}), {})
end

g.test_normalize_format_extracts_fields = function()
    local fmt = types.normalize_format({
        { name = 'id',   type = 'unsigned' },
        { name = 'tag',  type = 'string', is_nullable = true },
    })
    t.assert_equals(#fmt, 2)
    t.assert_equals(fmt[1].name, 'id')
    t.assert_equals(fmt[2].is_nullable, true)
end

g.test_normalize_format_fills_missing_name = function()
    local fmt = types.normalize_format({ { type = 'unsigned' } })
    t.assert_equals(fmt[1].name, 'field_1')
    t.assert_equals(fmt[1].type, 'unsigned')
end

-- ── primary key formatting ─────────────────────────────────────────

g.test_format_pk_simple = function()
    t.assert_equals(types.format_pk({ 42 }), '[42]')
end

g.test_format_pk_composite = function()
    local pk = types.format_pk({ 'user', 100 })
    t.assert_str_contains(pk, 'user')
    t.assert_str_contains(pk, '100')
end

g.test_format_pk_binary_wraps = function()
    -- Binary in PK gets base64-wrapped just like any other field.
    local pk = types.format_pk({ '\x00\xff' })
    t.assert_str_contains(pk, '_binary_base64')
end
