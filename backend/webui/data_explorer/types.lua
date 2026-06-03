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

-- `varbinary` is a 3.x core module; pcall-guard so the pure-module
-- unit tests (which never touch box) still load on stripped builds.
local ok_vb, varbinary = pcall(require, 'varbinary')
if not ok_vb then varbinary = nil end

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
--   * box.NULL             → nil (JSON null) — a stored NULL in a
--     nullable field reads back as the box.NULL cdata, not Lua nil
--   * varbinary cdata      → {_binary_base64 = "..."} — Tarantool 3.x
--     returns `varbinary` columns as a cdata, not a Lua string;
--     `tostring()` yields the raw bytes which we then base64
--   * non-UTF-8 string     → {_binary_base64 = "..."} — the escaped
--     form for byte strings stored in a plain `string` column
--   * uuid / decimal cdata → tostring  (cdata never survives json.encode)
--   * everything else      → as-is
local function encode_field(v)
    local tp = type(v)
    if tp == 'string' then
        if is_valid_utf8(v) then return v end
        return { _binary_base64 = digest.base64_encode(v) }
    elseif tp == 'cdata' then
        -- `box.NULL` is a cdata; guard the global lookup so the
        -- pure-module contract (encode_field callable without box)
        -- holds even though tuple data always implies box is up.
        local box_g = rawget(_G, 'box')
        if box_g ~= nil and v == box_g.NULL then return nil end
        if varbinary ~= nil and varbinary.is(v) then
            return { _binary_base64 = digest.base64_encode(tostring(v)) }
        end
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

-- ── type-aware coercion (mutations input) ──────────────────────────
--
-- The SPA sends every tuple field as a JSON value. Tarantool's
-- internal types (uuid / decimal / map / binary string) do not
-- survive JSON's lossy decoding — they arrive as plain strings or
-- nested tables, and box.space:insert() then rejects them with
-- "Tuple field type mismatch". This layer turns the wire-format
-- payload back into the cdata / table shape the storage engine
-- expects, based on the field's declared type from the space format.
--
-- The conversions mirror tarantool-admin/Row/Update.php so an
-- operator who used both tools sees the same behavior.

local function require_safe(name)
    local ok, mod = pcall(require, name)
    if not ok then return nil end
    return mod
end

local uuid_mod    = require_safe('uuid')
local decimal_mod = require_safe('decimal')

local function unwrap_binary(v)
    if type(v) == 'table' and type(v._binary_base64) == 'string' then
        return digest.base64_decode(v._binary_base64)
    end
    return v
end

-- coerce_field(value, declared_type) → (coerced_value, err?)
--
-- declared_type is the lowercase Tarantool field type from
-- `_space.format[i].type`. Unknown types pass through unchanged so
-- the caller can still attempt the mutation and let Tarantool's
-- own validator decide.
function M.coerce_field(value, declared_type)
    -- Explicit null stays as null. The caller decides whether to
    -- pad with box.NULL or to drop it as a trailing nil.
    if value == nil then return nil end

    declared_type = declared_type and tostring(declared_type):lower() or 'any'

    -- Always unwrap our binary envelope first, regardless of type.
    value = unwrap_binary(value)

    if declared_type == 'uuid' then
        if uuid_mod == nil then return nil, 'uuid module unavailable' end
        if type(value) ~= 'string' then
            return nil, 'uuid field requires RFC4122 string, got ' .. type(value)
        end
        local ok, parsed = pcall(uuid_mod.fromstr, value)
        if not ok or parsed == nil then
            return nil, 'invalid uuid string: ' .. tostring(value)
        end
        return parsed
    end

    if declared_type == 'decimal' then
        if decimal_mod == nil then return nil, 'decimal module unavailable' end
        local ok, parsed = pcall(decimal_mod.new, value)
        if not ok or parsed == nil then
            return nil, 'invalid decimal value: ' .. tostring(value)
        end
        return parsed
    end

    if declared_type == 'unsigned' or declared_type == 'integer'
        or declared_type == 'number' or declared_type == 'double'
        or declared_type == 'float' then
        if type(value) == 'number' then return value end
        if type(value) == 'string' then
            local n = tonumber(value)
            if n == nil then
                return nil, declared_type .. ' field needs numeric input, got ' .. value
            end
            return n
        end
        return nil, declared_type .. ' field needs number, got ' .. type(value)
    end

    if declared_type == 'boolean' then
        if type(value) == 'boolean' then return value end
        if value == 'true'  or value == 1 then return true end
        if value == 'false' or value == 0 then return false end
        return nil, 'boolean field needs true|false, got ' .. tostring(value)
    end

    if declared_type == 'varbinary' then
        -- After unwrap_binary, value is a plain Lua string of raw
        -- bytes. Tarantool rejects a plain string for a varbinary
        -- column ("expected varbinary, got string") — it must be a
        -- `varbinary` cdata. Wrap it. Strings that came in UTF-8
        -- (not via the envelope) are encoded byte-for-byte.
        if type(value) ~= 'string' then
            return nil, 'varbinary field needs bytes, got ' .. type(value)
        end
        if varbinary == nil then
            return nil, 'varbinary module unavailable'
        end
        return varbinary.new(value)
    end

    if declared_type == 'string' or declared_type == 'scalar' then
        -- After unwrap_binary, value is either a plain Lua string
        -- (UTF-8 or raw bytes) or, for `scalar`, any primitive.
        return value
    end

    if declared_type == 'map' or declared_type == 'array' or declared_type == 'any' then
        if type(value) == 'string' then
            local ok, parsed = pcall(json.decode, value)
            if ok and type(parsed) == 'table' then return parsed end
            -- Not JSON — for `any` we pass the string through.
            if declared_type == 'any' then return value end
            return nil, declared_type .. ' field needs JSON object/array, got string'
        end
        return value
    end

    return value
end

-- coerce_tuple(fields, format) → (tuple, err?)
--
-- Applies coerce_field across every position, then pads with
-- box.NULL to handle the trailing-nil hazard:
--
--   Lua arrays truncate trailing nils, so `{42, nil, "x"}` becomes
--   `{42}` when forwarded across function boundaries. If the
--   declared field at the truncated position is nullable, the
--   caller meant to insert NULL, not "absent". We replace null with
--   box.NULL up to the LAST non-nil position so the array length
--   matches the operator's intent.
function M.coerce_tuple(fields, format)
    if type(fields) ~= 'table' then return nil, 'fields must be a list' end
    -- `#fields` is undefined on arrays with holes (Lua spec), so we
    -- use pairs() to find the highest numeric index. Callers can
    -- pass either box.NULL or a plain Lua nil for null positions;
    -- only `box.NULL` survives the table border across function
    -- calls — plain nil collapses into a hole. Either way, this
    -- loop catches the largest real position.
    local last_real = 0
    for k, v in pairs(fields) do
        if type(k) == 'number' and v ~= nil and k > last_real then
            last_real = k
        end
    end
    local out = {}
    for i = 1, last_real do
        local v = fields[i]
        local fmt = format and format[i]
        local declared = fmt and fmt.type or 'any'
        if v == nil then
            out[i] = box.NULL
        else
            local coerced, err = M.coerce_field(v, declared)
            if err ~= nil then
                return nil, ('field %d (%s): %s'):format(
                    i, fmt and fmt.name or '?', err)
            end
            out[i] = coerced
        end
    end
    return out
end

-- coerce_key(key, pk_parts, format) → (key_list, err?)
--
-- Primary keys are short, never nullable; we just type-coerce each
-- part by its declared format type. `pk_parts` is the array from
-- `idx.parts` (each entry has {fieldno, type, ...}).
function M.coerce_key(key, pk_parts, format)
    if type(key) ~= 'table' then return nil, 'key must be a list' end
    local out = {}
    for i, raw in ipairs(key) do
        local part = pk_parts and pk_parts[i]
        local declared
        if part ~= nil then
            local fno = part.fieldno or part.field
            local fmt = (fno and format) and format[fno] or nil
            declared = (fmt and fmt.type) or part.type or 'any'
        end
        local coerced, err = M.coerce_field(raw, declared or 'any')
        if err ~= nil then
            return nil, ('key part %d: %s'):format(i, err)
        end
        out[i] = coerced
    end
    return out
end

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
