--
-- Audit hash chain primitives (Phase 4 Task 4.1).
--
-- Two responsibilities:
--
--   * `canonical(row)` — turn an audit tuple into a deterministic
--     byte string. The hash MUST be reproducible bit-for-bit on
--     any node that later wants to verify the chain (a follower
--     reading a replicated row, an offline verifier consuming an
--     exported JSONL), so the serialization is sorted-keys JSON
--     of an explicit subset of the row's fields. We deliberately
--     omit `prev_hash` / `current_hash` / `chain_seal` from the
--     canonical input — those are computed FROM the canonical
--     bytes, including them would be circular.
--
--   * `row_hash(prev, row)` — `sha256(prev || canonical(row))`.
--     `prev` is either the previous row's `current_hash` (regular
--     link) or nil (chain root or post-retention seal). The
--     concatenation order matters: prev first so that a verifier
--     walking forward can recompute and compare.
--
-- Pure module on purpose: no fiber, no box. Used by the writer
-- (`audit.log.record_local`), the migration backfill, and the
-- verifier — all three need exact byte-equivalence.
--

local digest  = require('digest')
local json    = require('json')
local ffi     = require('ffi')

local M = {}

-- canonical(row) → string
--
-- `row` is the audit tuple (either a box.tuple or a plain table
-- with the same field names). The hash MUST be reproducible
-- bit-for-bit, so we serialize ourselves with EXPLICIT key order
-- — Tarantool's `json.encode` does not guarantee it (LuaJIT
-- hashed iteration order varies between processes and even
-- between calls in the same process).
--
-- Format: `{"action":<j>,"id":<j>,"payload":<jp>,...}` —
-- alphabetically sorted top-level keys, json.encode-ed values.
-- Nested tables are also walked with sorted keys so a row whose
-- `payload` is `{a=1, b=2}` hashes the same as `{b=2, a=1}`.

local function encode_sorted(value)
    local tp = type(value)
    if tp == 'nil' then return 'null' end
    if value == nil then return 'null' end
    -- box.NULL is cdata equal to nil through `==`, but type() is
    -- 'cdata'. The line above already catches it.
    if tp == 'boolean' then return value and 'true' or 'false' end
    if tp == 'number' then
        -- json.encode handles inf/nan etc; mirror its output for
        -- consistency.
        return json.encode(value)
    end
    if tp == 'string' then return json.encode(value) end
    if tp == 'cdata' then
        -- int64 / uint64 stored by Tarantool (every unsigned
        -- field arrives as cdata, not Lua number). Encode the
        -- numeric value so the canonical form is the same as
        -- when the writer fed a plain Lua number into the
        -- projection. uuid / decimal / etc fall through to the
        -- string path so they survive in canonical form.
        local ok_n = pcall(ffi.cast, 'int64_t', value)
        if ok_n then
            -- json.encode of a int64 cdata writes the digits
            -- without quotes, matching Lua-number encoding.
            local ok_str, encoded = pcall(json.encode, value)
            if ok_str then return encoded end
        end
        return json.encode(tostring(value))
    end
    if tp == 'table' then
        -- Decide between array and object encoding. `#value` is
        -- 0 for string-keyed tables AND for empty tables, so we
        -- additionally probe via `next()` to tell them apart.
        local first_key = next(value)
        if first_key == nil then return '{}' end
        local len = #value
        local array_like = len > 0
        if array_like then
            -- Make sure every key is in 1..len. A mixed
            -- table (`{1, 2, x=3}`) falls back to object so
            -- the extra string key is preserved.
            for k in pairs(value) do
                if type(k) ~= 'number' or k < 1 or k > len
                    or math.floor(k) ~= k then
                    array_like = false
                    break
                end
            end
        end
        if array_like then
            local parts = {}
            for i = 1, len do parts[i] = encode_sorted(value[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(value) do table.insert(keys, tostring(k)) end
        table.sort(keys)
        local parts = {}
        for i, k in ipairs(keys) do
            parts[i] = json.encode(k) .. ':' .. encode_sorted(value[k])
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    -- Fallback (function, thread, userdata, ...): stringify so the
    -- chain never crashes on a weird payload.
    return json.encode(tostring(value))
end
M._encode_sorted = encode_sorted

function M.canonical(row)
    -- Project an explicit subset, then walk it with sorted keys.
    -- The projection itself uses string keys so encode_sorted's
    -- table branch produces the deterministic output.
    return encode_sorted({
        id         = row.id,
        ts         = row.ts,
        user       = row.user,
        action     = row.action,
        scope      = row.scope,
        payload    = row.payload,
        request_id = row.request_id,
    })
end

-- sha256_hex(bytes) → string
-- Wraps `digest.sha256_hex`; broken out so tests can mock it.
function M.sha256_hex(bytes)
    return digest.sha256_hex(bytes)
end

-- row_hash(prev_hash, row) → string
function M.row_hash(prev_hash, row)
    local canon = M.canonical(row)
    return M.sha256_hex((prev_hash or '') .. canon)
end

-- next_link(latest_tuple) → (prev_hash_for_new_row)
--
-- Convenience for the writer: returns the value to put in the
-- new row's `prev_hash` field given the latest persisted tuple.
-- Returns nil when there is no prior row (fresh space) or when
-- the latest row was sealed by retention (`chain_seal = true`
-- with cleared current_hash — the new row starts a new chain).
function M.next_link(latest_tuple)
    if latest_tuple == nil then return nil end
    if latest_tuple.chain_seal == true then return nil end
    if latest_tuple.current_hash == nil
        or latest_tuple.current_hash == '' then
        return nil
    end
    return latest_tuple.current_hash
end

return M
