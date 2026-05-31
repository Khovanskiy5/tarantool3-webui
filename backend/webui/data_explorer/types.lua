--
-- Pure helpers shared by the data-explorer GraphQL surface.
--
-- Two responsibilities:
--
--   * Cursor encode/decode. The `tuples` query is cursor-paginated;
--     a cursor is the base64 of the last tuple's primary key encoded
--     via msgpack. Opaque to the SPA, but stable on the wire (no
--     escaping headaches) and round-trip safe for binary keys.
--
--   * Tuple-to-GraphQL conversion. Lua strings can carry arbitrary
--     bytes — JSON cannot. Any field that fails a UTF-8 sanity check
--     is emitted as the envelope `{_binary_base64 = "..."}` so the
--     SPA can render it as `[binary 0xab12...]` instead of crashing
--     the JSON encoder. UUID / decimal / map types are stringified
--     in obvious ways so the wire format stays JSON-friendly.
--
-- Pure module on purpose: every function here is unit-testable
-- without spinning up Tarantool's box or fiber. The resolver glue
-- lives next door in `admin_data.lua`.
--

local digest    = require('digest')
local json      = require('json')
local msgpack   = require('msgpack')

local M = {}

-- ── binary / UTF-8 ─────────────────────────────────────────────────

-- Walk a byte string, reject any invalid UTF-8 continuation. Faster
-- than `utf8.len` because we can bail out on the first bad byte.
local function is_valid_utf8(s)
    if type(s) ~= 'string' then return false end
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then
            i = i + 1
        elseif b < 0xC2 then
            return false                       -- stray continuation
        elseif b < 0xE0 then
            if i + 1 > n then return false end
            local c2 = s:byte(i + 1)
            if c2 < 0x80 or c2 > 0xBF then return false end
            i = i + 2
        elseif b < 0xF0 then
            if i + 2 > n then return false end
            local c2 = s:byte(i + 1); local c3 = s:byte(i + 2)
            if c2 < 0x80 or c2 > 0xBF then return false end
            if c3 < 0x80 or c3 > 0xBF then return false end
            i = i + 3
        elseif b < 0xF5 then
            if i + 3 > n then return false end
            local c2 = s:byte(i + 1); local c3 = s:byte(i + 2); local c4 = s:byte(i + 3)
            if c2 < 0x80 or c2 > 0xBF then return false end
            if c3 < 0x80 or c3 > 0xBF then return false end
            if c4 < 0x80 or c4 > 0xBF then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end
M._is_valid_utf8 = is_valid_utf8

-- ── cursor encode/decode ───────────────────────────────────────────

-- Encode a primary key (Lua table representing the key parts) into
-- an opaque, URL-safe-ish base64 string. We use msgpack because:
--   * It preserves the exact key shape (numbers vs strings vs binary).
--   * It is what Tarantool itself uses on the wire, so we never have
--     to invent a parallel "string form" for uuid/decimal/binary keys.
function M.cursor_encode(key)
    if key == nil then return nil end
    local ok, packed = pcall(msgpack.encode, key)
    if not ok then return nil end
    return digest.base64_encode(packed)
end

-- Decode the cursor back into the key table. Returns nil on any
-- malformed input — callers MUST treat that as "no cursor" rather
-- than a fatal error, so a tampered cursor degrades to a fresh scan
-- instead of a 500.
function M.cursor_decode(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local ok_b64, raw = pcall(digest.base64_decode, s)
    if not ok_b64 or type(raw) ~= 'string' or raw == '' then return nil end
    local ok_mp, decoded = pcall(msgpack.decode, raw)
    if not ok_mp then return nil end
    return decoded
end

-- ── field-level encoding ───────────────────────────────────────────

-- Convert one tuple field into a JSON-friendly form.
--   * cdata uuid / decimal → tostring  (cdata never survives json.encode)
--   * non-UTF-8 string     → {_binary_base64 = "..."}
--   * everything else      → as-is
local function encode_field(v)
    local tp = type(v)
    if tp == 'string' then
        if is_valid_utf8(v) then return v end
        return { _binary_base64 = digest.base64_encode(v) }
    elseif tp == 'cdata' then
        return tostring(v)
    end
    return v
end
M.encode_field = encode_field

-- Format a primary key as a compact, human-readable string for the
-- UI's "PK" column. The cursor (msgpack) is opaque on purpose; this
-- one is meant to be eyeballed by the operator, so we render it as
-- JSON of the encoded fields.
function M.format_pk(key)
    if key == nil then return '' end
    local out = {}
    for i, v in ipairs(key) do out[i] = encode_field(v) end
    local ok, s = pcall(json.encode, out)
    if not ok then return tostring(key) end
    return s
end

-- ── space metadata helpers ─────────────────────────────────────────

-- Tarantool stores the format as an array of {name, type, ...} maps
-- inside `_space[id][7]`. We project it into a simple list the SPA
-- can render without knowing the internal layout.
function M.normalize_format(raw_format)
    if type(raw_format) ~= 'table' then return {} end
    local out = {}
    for i, f in ipairs(raw_format) do
        if type(f) == 'table' then
            table.insert(out, {
                name        = f.name or ('field_' .. tostring(i)),
                type        = f.type or 'any',
                is_nullable = f.is_nullable == true,
                collation   = f.collation,
            })
        end
    end
    return out
end

return M
