--
-- WebSocket frame codec (RFC 6455).
--
-- The codec is intentionally minimal — text frames out, control
-- frames in, no extensions, no fragmentation across messages.
-- Receiving side handles ping / pong / close, plus single-frame
-- text messages from the client (we use them only for ad-hoc
-- subscribe requests; the public protocol is one-way server →
-- client today).
--
-- Server-sent frames are never masked (RFC 6455 §5.1); client
-- frames MUST be masked or we close the connection per the spec.
--

local bit = require('bit')

local M = {}

M.OPCODE = {
    CONTINUATION = 0x0,
    TEXT         = 0x1,
    BINARY       = 0x2,
    CLOSE        = 0x8,
    PING         = 0x9,
    PONG         = 0xA,
}

-- Close codes the public protocol uses. The full RFC list is large;
-- these four cover every reason this module ever sends.
M.CLOSE = {
    NORMAL        = 1000,
    GOING_AWAY    = 1001,
    PROTOCOL_ERR  = 1002,
    POLICY_VIOL   = 1008,
    MESSAGE_TOO_BIG = 1009,
    INTERNAL_ERR  = 1011,
}

-- 64-bit length emitted by encode is the spec value 127. Tarantool's
-- fiber-based readers handle this fine but the codec caps frames at
-- 16 MiB to keep memory predictable.
M.MAX_FRAME_BYTES = 16 * 1024 * 1024

-- ─────────────────────────────────────────────────────────────────────
-- Pure encoders
-- ─────────────────────────────────────────────────────────────────────

local function pack_length(len)
    if len < 126 then
        return string.char(len)
    elseif len < 65536 then
        return string.char(126,
            bit.band(bit.rshift(len, 8), 0xff),
            bit.band(len, 0xff))
    end
    -- 64-bit big-endian. Lua 5.1 has no 64-bit ints, but our messages
    -- are bounded above; pack the high four bytes as 0.
    return string.char(127, 0, 0, 0, 0,
        bit.band(bit.rshift(len, 24), 0xff),
        bit.band(bit.rshift(len, 16), 0xff),
        bit.band(bit.rshift(len, 8), 0xff),
        bit.band(len, 0xff))
end

local function encode(opcode, payload)
    payload = payload or ''
    if #payload > M.MAX_FRAME_BYTES then
        error('payload exceeds MAX_FRAME_BYTES', 2)
    end
    -- FIN=1, RSV1..3=0, opcode in low nibble.
    local b1 = string.char(bit.bor(0x80, bit.band(opcode, 0x0f)))
    -- MASK=0 on server frames; length encoded as above.
    return b1 .. pack_length(#payload) .. payload
end

function M.encode_text(payload)
    return encode(M.OPCODE.TEXT, tostring(payload or ''))
end

function M.encode_ping(payload)
    return encode(M.OPCODE.PING, payload or '')
end

function M.encode_pong(payload)
    return encode(M.OPCODE.PONG, payload or '')
end

-- Encode a close frame. RFC 6455 §5.5.1: payload starts with a
-- 2-byte status code, followed by an optional UTF-8 reason.
function M.encode_close(code, reason)
    code = code or M.CLOSE.NORMAL
    reason = reason or ''
    local payload = string.char(
        bit.band(bit.rshift(code, 8), 0xff),
        bit.band(code, 0xff)
    ) .. reason
    return encode(M.OPCODE.CLOSE, payload)
end

-- ─────────────────────────────────────────────────────────────────────
-- Pure decoder
-- ─────────────────────────────────────────────────────────────────────

-- Decode raw bytes into a single frame. Returns:
--   { fin, opcode, masked, payload, consumed }   on success
--   nil, 'incomplete'                            when more bytes needed
--   nil, '<message>'                             on protocol error
function M.decode(buf)
    if type(buf) ~= 'string' then
        return nil, 'buf must be a string'
    end
    if #buf < 2 then return nil, 'incomplete' end
    local b1 = string.byte(buf, 1)
    local b2 = string.byte(buf, 2)
    local fin = bit.band(b1, 0x80) ~= 0
    local opcode = bit.band(b1, 0x0f)
    local masked = bit.band(b2, 0x80) ~= 0
    local len = bit.band(b2, 0x7f)
    local offset = 3

    if len == 126 then
        if #buf < offset + 1 then return nil, 'incomplete' end
        len = bit.lshift(string.byte(buf, offset), 8)
            + string.byte(buf, offset + 1)
        offset = offset + 2
    elseif len == 127 then
        if #buf < offset + 7 then return nil, 'incomplete' end
        -- Skip the high four bytes; refuse frames above 2^31 — we
        -- have neither the memory budget nor the use case for them.
        local hi = 0
        for i = 0, 3 do
            hi = hi + string.byte(buf, offset + i)
        end
        if hi ~= 0 then
            return nil, 'frame too big'
        end
        len = bit.lshift(string.byte(buf, offset + 4), 24)
            + bit.lshift(string.byte(buf, offset + 5), 16)
            + bit.lshift(string.byte(buf, offset + 6), 8)
            + string.byte(buf, offset + 7)
        offset = offset + 8
    end

    if len > M.MAX_FRAME_BYTES then
        return nil, 'frame exceeds MAX_FRAME_BYTES'
    end

    local mask_key
    if masked then
        if #buf < offset + 3 then return nil, 'incomplete' end
        mask_key = { string.byte(buf, offset),
                     string.byte(buf, offset + 1),
                     string.byte(buf, offset + 2),
                     string.byte(buf, offset + 3) }
        offset = offset + 4
    end

    if #buf < offset + len - 1 then return nil, 'incomplete' end

    local payload = buf:sub(offset, offset + len - 1)

    if masked then
        local unmasked = {}
        for i = 1, #payload do
            local b = string.byte(payload, i)
            local m = mask_key[((i - 1) % 4) + 1]
            table.insert(unmasked, string.char(bit.bxor(b, m)))
        end
        payload = table.concat(unmasked)
    end

    return {
        fin      = fin,
        opcode   = opcode,
        masked   = masked,
        payload  = payload,
        consumed = offset + len - 1,
    }
end

-- ─────────────────────────────────────────────────────────────────────
-- Pure handshake helper
-- ─────────────────────────────────────────────────────────────────────

local digest = require('digest')

-- RFC 6455 §4.2.2 magic constant.
local WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

function M.compute_accept(client_key)
    if type(client_key) ~= 'string' then return nil end
    local hash = digest.sha1(client_key .. WS_MAGIC)
    return digest.base64_encode(hash, { nowrap = true })
end

-- Build the HTTP/1.1 101 Switching Protocols response. The caller
-- writes the result raw to the socket.
function M.handshake_response(client_key)
    local accept = M.compute_accept(client_key)
    if accept == nil then
        return nil, 'missing or invalid Sec-WebSocket-Key'
    end
    return table.concat({
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Accept: ' .. accept,
        '', '',
    }, '\r\n')
end

return M
