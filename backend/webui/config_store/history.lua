--
-- Config revision history backed by etcd keys
-- `<prefix>/webui/history/<rev>`. Hard cap at 200 revisions; the
-- oldest is dropped when a new one is added.
--

local M = {}

M.MAX_HISTORY = 200

-- ── Pure helpers ─────────────────────────────────────────────────────

function M.history_key(prefix, revision)
    return string.format('%s/history/%010d', prefix or '/webui', revision or 0)
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

function M.record(etcd, revision, yaml)
    if etcd == nil then return nil, 'NO_ETCD' end
    local _, err = etcd:put(M.history_key(etcd.prefix, revision), yaml)
    if err then return nil, err end
    return true
end

function M.get(etcd, revision)
    if etcd == nil then return nil, 'NO_ETCD' end
    return etcd:get(M.history_key(etcd.prefix, revision))
end

return M
