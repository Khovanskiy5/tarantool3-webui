--
-- Config revision history backed by etcd keys:
--
--   <prefix>/history/<010d-rev>        — full YAML snapshot
--   <prefix>/history-meta/<010d-rev>   — JSON metadata
--                                        {ts, user, hash, size, action}
--
-- Hard cap at 200 revisions; the oldest pair (snapshot + metadata) is
-- dropped when a new one is added. Storage uses our own keys (NOT etcd
-- mod_revision history) because etcd auto-compaction would erase the
-- timeline at unpredictable moments — own-storage gives a deterministic
-- `oldest_available_revision`.
--

local json   = require('json')
local digest = require('digest')

local M = {}

M.MAX_HISTORY = 200

-- ── Pure helpers ─────────────────────────────────────────────────────

-- Full-path form (with the configured client prefix) — used by parse
-- helpers and tests that match against fully-qualified etcd keys.
function M.history_key(prefix, revision)
    return string.format('%s/history/%010d', prefix or '/webui', revision or 0)
end

function M.metadata_key(prefix, revision)
    return string.format('%s/history-meta/%010d',
        prefix or '/webui', revision or 0)
end

-- Relative-path form (NO leading prefix) — what every `etcd:*` method
-- on the client expects, because the client adds the configured
-- `state.prefix` itself via `full_key()`. Passing the full path here
-- would double-prefix the write and the matching `list()` reader
-- would never find it.
local function rel_history_key(revision)
    return string.format('history/%010d', revision or 0)
end

local function rel_metadata_key(revision)
    return string.format('history-meta/%010d', revision or 0)
end

-- Extract the integer revision from a `<prefix>/history/<010d-rev>`
-- key. Returns nil for malformed keys so callers can defensively skip
-- them instead of crashing.
function M.parse_revision(key)
    if type(key) ~= 'string' then return nil end
    local digits = key:match('/history/(%d+)$')
    if digits == nil then return nil end
    local n = tonumber(digits)
    if n == nil or n <= 0 then return nil end
    return n
end

-- Build the list to delete given the current keys (sorted ascending
-- by revision) and the cap. Returns the list of keys to prune.
function M.prune_plan(keys, max)
    max = max or M.MAX_HISTORY
    if #keys <= max then return {} end
    local n = #keys - max
    local out = {}
    for i = 1, n do table.insert(out, keys[i]) end
    return out
end

-- ── etcd-bound helpers ───────────────────────────────────────────────

-- Persist a full YAML snapshot under `<prefix>/history/<010d-rev>`.
function M.record(etcd, revision, yaml)
    if etcd == nil then return nil, 'NO_ETCD' end
    local _, err = etcd:put(rel_history_key(revision), yaml)
    if err then return nil, err end
    return true
end

-- Persist metadata for a revision under `<prefix>/history-meta/<rev>`.
-- `meta` is a plain table; we json-encode it so the storage stays
-- human-inspectable via `etcdctl get`. Soft-fail: history list still
-- works without metadata (fields surface as nil), so a transient etcd
-- error on the metadata write does not corrupt the timeline.
function M.record_metadata(etcd, revision, meta)
    if etcd == nil then return nil, 'NO_ETCD' end
    local ok, encoded = pcall(json.encode, meta or {})
    if not ok then return nil, 'ENCODE_FAILED' end
    local _, err = etcd:put(rel_metadata_key(revision), encoded)
    if err then return nil, err end
    return true
end

function M.get(etcd, revision)
    if etcd == nil then return nil, 'NO_ETCD' end
    return etcd:get(rel_history_key(revision))
end

-- Read metadata for a revision; returns (table, nil) on success,
-- (nil, nil) when no metadata recorded, (nil, err) on transport
-- error. JSON decode failure surfaces as (nil, 'DECODE_FAILED').
function M.get_metadata(etcd, revision)
    if etcd == nil then return nil, 'NO_ETCD' end
    local kv, err = etcd:get(rel_metadata_key(revision))
    if err then return nil, err end
    if kv == nil or kv.value == nil then return nil, nil end
    local ok, decoded = pcall(json.decode, kv.value)
    if not ok or type(decoded) ~= 'table' then
        return nil, 'DECODE_FAILED'
    end
    return decoded
end

-- list(etcd, opts) — return the timeline in descending order of
-- revision, with metadata merged in when available.
--
-- opts:
--   * limit      max rows to return (default 50, hard cap 200)
--   * after      revision (int); return only rows with rev < after
--                — used by the SPA for "load more" pagination
--
-- Returns
--   {
--     revisions = [
--       { revision, ts, user, hash, size, action },
--       ...
--     ],
--     oldest_available_revision = <int>,   -- min(history_keys), nil if empty
--     more = <bool>                         -- true if list was truncated
--   }
--
-- Pure-ish — the etcd round-trip happens once via range_prefix, then
-- everything else is in-memory.
function M.list(etcd, opts)
    if etcd == nil then return nil, 'NO_ETCD' end
    opts = opts or {}
    local limit = tonumber(opts.limit) or 50
    if limit > M.MAX_HISTORY then limit = M.MAX_HISTORY end
    if limit < 1 then limit = 1 end

    -- Pull every history snapshot key with its mod_revision; we
    -- don't need the YAML body here, but the v3 gateway does not
    -- support `keys-only` per-call — we accept the over-fetch
    -- (cap = MAX_HISTORY items, payload of one YAML each is small
    -- enough to be negligible at admin scale).
    --
    -- range_prefix accepts a prefix RELATIVE to the configured
    -- client prefix (mirroring :get() / :put()), so we pass plain
    -- 'history/' — the client adds `state.prefix` itself.
    local range, err = etcd:range_prefix('history/')
    if range == nil then return nil, err end

    local rows = {}
    local oldest_revision
    for _, kv in ipairs(range.items or {}) do
        local rev = M.parse_revision(kv.key)
        if rev ~= nil then
            local size = kv.value and #kv.value or 0
            local hash = kv.value
                and digest.sha1_hex(kv.value):sub(1, 16)
                or nil
            table.insert(rows, {
                revision = rev,
                size     = size,
                hash     = hash,
            })
            if oldest_revision == nil or rev < oldest_revision then
                oldest_revision = rev
            end
        end
    end

    table.sort(rows, function(a, b) return a.revision > b.revision end)

    if opts.after ~= nil then
        local cutoff = tonumber(opts.after) or 0
        local filtered = {}
        for _, r in ipairs(rows) do
            if r.revision < cutoff then table.insert(filtered, r) end
        end
        rows = filtered
    end

    local more = #rows > limit
    if more then
        local truncated = {}
        for i = 1, limit do truncated[i] = rows[i] end
        rows = truncated
    end

    -- Best-effort metadata merge: fan-out N gets, swallow per-row
    -- errors so a missing meta key doesn't blank out the whole
    -- timeline. Audit-style metadata only — full YAML is on demand.
    for _, r in ipairs(rows) do
        local meta = select(1, M.get_metadata(etcd, r.revision))
        if type(meta) == 'table' then
            r.ts       = meta.ts
            r.user     = meta.user
            r.action   = meta.action
            -- If the recorded metadata hash matches what we computed
            -- from the YAML body, surface meta's; otherwise keep the
            -- computed one (the body is authoritative).
            if meta.hash and meta.hash == r.hash then
                r.hash = meta.hash
            end
        end
    end

    return {
        revisions                 = rows,
        oldest_available_revision = oldest_revision,
        more                      = more,
    }
end

return M
