--
-- Cluster identity guard (Task FO-17).
--
-- Two different clusters that share one etcd prefix (e.g. the same
-- cluster cookie copied by mistake) must not cross-promote each other's
-- instances. We pin the replicaset's identity — its UUID — under
-- `<prefix>/failover/replicasets/<rs>/sysid` the first time a leader is
-- about to be promoted, then refuse to promote any instance whose live
-- replicaset UUID does not match the pinned one.
--
-- Softer than Patroni's `exit(1)` on a sysid mismatch: we just refuse
-- to act as leader (defer promote) and surface it, so an alien instance
-- cannot take leadership but the operator can still inspect/repair it.
--
-- Note on reads: etcd v3 GET is linearizable by default (the client
-- does not request serializable reads), so the leader/sysid reads on
-- the promote path observe the latest committed value.
--

local M = {}

M.KEY_SYSID = '/failover/replicasets/%s/sysid'

-- Pure verdict: is `mine` an alien relative to the `recorded` identity?
-- nil/empty recorded means "not pinned yet" → not alien (we may pin it).
-- A mismatch between two non-empty values is alien.
function M.is_alien(recorded, mine)
    if recorded == nil or recorded == '' then return false end
    if mine == nil or mine == '' then return false end
    return recorded ~= mine
end

-- Ensure the replicaset's sysid is pinned and matches us.
--   * absent  → CAS-create it with `my_uuid` (we are the first leader).
--   * present → compare.
-- Returns (ok, info) where ok=false means "alien — do not promote".
-- info = { recorded = <uuid|nil>, created = bool }. On a transient etcd
-- error returns (false, {error=...}) so the caller defers (safe).
function M.ensure_sysid(client, replicaset, my_uuid)
    if client == nil then return false, { error = 'etcd unavailable' } end
    if type(replicaset) ~= 'string' or replicaset == '' then
        return false, { error = 'replicaset required' }
    end
    if type(my_uuid) ~= 'string' or my_uuid == '' then
        -- No local identity yet (very early boot) — cannot validate;
        -- defer rather than pin a bogus value.
        return false, { error = 'local replicaset uuid unavailable' }
    end
    local key = string.format(M.KEY_SYSID, replicaset)
    local kv, get_err = client:get(key)
    if get_err ~= nil then
        return false, { error = 'sysid read: ' .. tostring(get_err) }
    end
    if kv == nil or kv.value == nil or kv.value == '' then
        -- Not pinned yet — claim it atomically (create-if-absent).
        local _, put_err = client:txn_create(key, my_uuid)
        if put_err ~= nil then
            -- Lost the race to another instance of THIS replicaset;
            -- re-read to compare on the next tick. Treat as defer.
            return false, { error = 'sysid create raced: ' .. tostring(put_err) }
        end
        return true, { recorded = my_uuid, created = true }
    end
    if M.is_alien(kv.value, my_uuid) then
        return false, { recorded = kv.value, alien = true }
    end
    return true, { recorded = kv.value, created = false }
end

return M
