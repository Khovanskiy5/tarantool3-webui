-- Unit tests for backend/webui/http/ws_frame.lua
--
-- Covers the pure handshake helper and the frame codec across the
-- three length classes RFC 6455 defines (small / medium / 64-bit).
-- The bytes-on-the-wire form is asserted directly so a future
-- refactor cannot quietly change framing.

local t = require('luatest')
local bit = require('bit')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local frame = require('webui.http.ws_frame')

local g = t.group('ws_frame')

-- ── handshake ───────────────────────────────────────────────────────

g.test_compute_accept_rfc6455_example = function()
    -- RFC 6455 §1.3 example: client key "dGhlIHNhbXBsZSBub25jZQ=="
    -- yields "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".
    t.assert_equals(
        frame.compute_accept('dGhlIHNhbXBsZSBub25jZQ=='),
        's3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
end

g.test_compute_accept_nil_input_returns_nil = function()
    t.assert_equals(frame.compute_accept(nil), nil)
end

g.test_handshake_response_includes_required_headers = function()
    local resp, err = frame.handshake_response('dGhlIHNhbXBsZSBub25jZQ==')
    t.assert_equals(err, nil)
    t.assert_str_contains(resp, 'HTTP/1.1 101 Switching Protocols')
    t.assert_str_contains(resp, 'Upgrade: websocket')
    t.assert_str_contains(resp, 'Connection: Upgrade')
    t.assert_str_contains(resp, 'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
    -- Headers must terminate with CRLFCRLF.
    t.assert(resp:sub(-4) == '\r\n\r\n', 'response must end with CRLFCRLF')
end

g.test_handshake_response_nil_key_is_error = function()
    local resp, err = frame.handshake_response(nil)
    t.assert_equals(resp, nil)
    t.assert(err, 'expected an error message')
end

-- ── encoders ────────────────────────────────────────────────────────

g.test_encode_text_short_payload = function()
    local bytes = frame.encode_text('hi')
    -- FIN=1, opcode=TEXT(1) → 0x81 ; MASK=0, len=2 → 0x02
    t.assert_equals(string.byte(bytes, 1), 0x81)
    t.assert_equals(string.byte(bytes, 2), 0x02)
    t.assert_equals(bytes:sub(3), 'hi')
end

g.test_encode_text_medium_uses_two_byte_length = function()
    local payload = string.rep('a', 200)
    local bytes = frame.encode_text(payload)
    t.assert_equals(string.byte(bytes, 1), 0x81)
    -- length indicator 126, then big-endian 16-bit length.
    t.assert_equals(string.byte(bytes, 2), 126)
    t.assert_equals(string.byte(bytes, 3), 0)
    t.assert_equals(string.byte(bytes, 4), 200)
    t.assert_equals(bytes:sub(5), payload)
end

g.test_encode_text_large_uses_eight_byte_length = function()
    local payload = string.rep('x', 70000)  -- > 65535
    local bytes = frame.encode_text(payload)
    t.assert_equals(string.byte(bytes, 1), 0x81)
    t.assert_equals(string.byte(bytes, 2), 127)
    -- High four bytes zero in our encoder.
    for i = 3, 6 do t.assert_equals(string.byte(bytes, i), 0) end
    local hi = string.byte(bytes, 7)
    local mid = string.byte(bytes, 8)
    local lo1 = string.byte(bytes, 9)
    local lo0 = string.byte(bytes, 10)
    local length = hi * 0x1000000 + mid * 0x10000 + lo1 * 0x100 + lo0
    t.assert_equals(length, 70000)
    t.assert_equals(#bytes, 10 + 70000)
end

g.test_encode_close_packs_status_code = function()
    local bytes = frame.encode_close(frame.CLOSE.GOING_AWAY, 'bye')
    t.assert_equals(string.byte(bytes, 1), bit.bor(0x80, frame.OPCODE.CLOSE))
    t.assert_equals(string.byte(bytes, 2), 5)  -- 2 status bytes + 'bye'
    t.assert_equals(string.byte(bytes, 3), 3)  -- 1001 high byte
    t.assert_equals(string.byte(bytes, 4), 0xe9)  -- 1001 low byte
    t.assert_equals(bytes:sub(5), 'bye')
end

g.test_encode_ping_pong_default_payload = function()
    local p = frame.encode_ping()
    t.assert_equals(string.byte(p, 1), 0x89)
    t.assert_equals(string.byte(p, 2), 0)
    local q = frame.encode_pong('x')
    t.assert_equals(string.byte(q, 1), 0x8a)
    t.assert_equals(string.byte(q, 2), 1)
    t.assert_equals(q:sub(3), 'x')
end

-- ── decoder ─────────────────────────────────────────────────────────

g.test_decode_returns_incomplete_for_short_buffers = function()
    local _, err = frame.decode('')
    t.assert_equals(err, 'incomplete')
    _, err = frame.decode('\x81')
    t.assert_equals(err, 'incomplete')
end

g.test_decode_unmasked_short_text = function()
    -- FIN=1, TEXT, len=3, "abc"
    local f, err = frame.decode('\x81\x03abc')
    t.assert_equals(err, nil)
    t.assert(f.fin)
    t.assert_equals(f.opcode, frame.OPCODE.TEXT)
    t.assert(not f.masked)
    t.assert_equals(f.payload, 'abc')
    t.assert_equals(f.consumed, 5)
end

g.test_decode_masked_short_text = function()
    -- FIN=1, TEXT, MASK=1, len=3, mask = 0x12 0x34 0x56 0x78
    -- raw payload "abc" → masked = a^0x12, b^0x34, c^0x56
    local mask = '\x12\x34\x56\x78'
    local raw = 'abc'
    local masked = {}
    local mb = { string.byte(mask, 1), string.byte(mask, 2),
                 string.byte(mask, 3), string.byte(mask, 4) }
    for i = 1, #raw do
        local b = string.byte(raw, i)
        masked[i] = string.char(bit.bxor(b, mb[((i - 1) % 4) + 1]))
    end
    local buf = '\x81\x83' .. mask .. table.concat(masked)
    local f, err = frame.decode(buf)
    t.assert_equals(err, nil)
    t.assert(f.masked)
    t.assert_equals(f.payload, 'abc')
end

g.test_decode_two_byte_length = function()
    local payload = string.rep('a', 200)
    -- FIN=1, TEXT, len=126, then 0x00 0xc8, then payload (unmasked)
    local buf = '\x81\x7e\x00\xc8' .. payload
    local f, err = frame.decode(buf)
    t.assert_equals(err, nil)
    t.assert_equals(#f.payload, 200)
end

g.test_decode_round_trip_with_encode = function()
    -- Sanity: bytes our encoder produced decode back to the same
    -- payload (mask off because the server never masks outbound).
    local bytes = frame.encode_text('hello world')
    local f, err = frame.decode(bytes)
    t.assert_equals(err, nil)
    t.assert_equals(f.payload, 'hello world')
    t.assert_equals(f.opcode, frame.OPCODE.TEXT)
end

g.test_decode_rejects_too_big_frame = function()
    -- 64-bit length frame whose high bytes are non-zero would
    -- claim > 2^32. The decoder must refuse rather than allocate.
    local buf = '\x82\x7f' .. '\x00\x00\x00\x01\x00\x00\x00\x00'
    local _, err = frame.decode(buf)
    t.assert_str_contains(err, 'frame too big')
end

-- ── module constants ────────────────────────────────────────────────

g.test_module_constants = function()
    t.assert_equals(frame.OPCODE.TEXT, 0x1)
    t.assert_equals(frame.OPCODE.PING, 0x9)
    t.assert_equals(frame.CLOSE.NORMAL, 1000)
    t.assert_equals(frame.CLOSE.GOING_AWAY, 1001)
    t.assert(frame.MAX_FRAME_BYTES >= 1024 * 1024)
end
