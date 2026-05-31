--
-- Operator-controlled "disabled" set for the supervised-OS
-- failover agent.
--
-- An instance whose alias is in this set is skipped by
-- `pick_leader` (score → -inf), so the coordinator never
-- appoints it as a replicaset leader. The set is persistent
-- across restarts because it lives in etcd, not in agent
-- memory; the same applies when the coordinator role moves to
-- a different peer.
--
-- Storage layout (under the same etcd_writer prefix):
--   <prefix>/failover/disabled/<alias>  → JSON {at, by_user}
--
-- We deliberately store one key per alias (not a single
-- aggregate JSON blob) so two operators acting concurrently
-- never race on the same revision. Reads are batched via
-- range_prefix.
--

local json = require('json')

local M = {}

local function client_get(client)
    if client == nil then return nil, 'etcd client unavailable' end
    return client, nil
end

local function alias_key(alias)
    return string.format('failover/disabled/%s', tostring(alias or ''))
end

-- list(client) → ({alias = {at, by_user}, ...}, nil) or (nil, err)
function M.list(client)
    local c, err = client_get(client)
    if c == nil then return nil, err end
    -- range_prefix returns a list of {key, value, revision}.
    local entries, range_err = c:range_prefix('failover/disabled/')
    if range_err ~= nil then return nil, range_err end
    local out = {}
    for _, kv in ipairs(entries or {}) do
        local alias = (kv.key or ''):match('failover/disabled/(.+)$')
        if alias ~= nil and alias ~= '' and kv.value ~= nil then
            local ok, decoded = pcall(json.decode, kv.value)
            if ok and type(decoded) == 'table' then
                out[alias] = decoded
            else
                out[alias] = { at = 0, by_user = '?' }
            end
        end
    end
    return out, nil
end

-- aliases_set(client) → ({alias=true,...}, nil) — flat set, optimised
-- for the agent's per-cycle "skip disabled" filter.
function M.aliases_set(client)
    local list, err = M.list(client)
    if list == nil then return nil, err end
    local out = {}
    for alias in pairs(list) do out[alias] = true end
    return out, nil
end

-- set(client, alias, by_user) — atomic single-key write. Adds an
-- entry or refreshes its timestamp/user fields. Idempotent.
function M.set(client, alias, by_user)
    local c, err = client_get(client)
    if c == nil then return nil, err end
    if type(alias) ~= 'string' or alias == '' then
        return nil, 'alias is required'
    end
    local payload = json.encode({
        at      = math.floor(require('fiber').time()),
        by_user = by_user or '?',
    })
    return c:put(alias_key(alias), payload)
end

-- clear(client, alias) — removes the entry. Idempotent (no-op when
-- absent). Returns (true, nil) on success.
function M.clear(client, alias)
    local c, err = client_get(client)
    if c == nil then return nil, err end
    if type(alias) ~= 'string' or alias == '' then
        return nil, 'alias is required'
    end
    local res, derr = c:delete(alias_key(alias))
    if derr ~= nil then return nil, derr end
    return res or true, nil
end

return M
