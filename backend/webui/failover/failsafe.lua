--
-- Failsafe mode (Task FO-16).
--
-- The default reaction to losing the DCS (etcd) is safe but strict:
-- the leader self-fences to read-only (FO-1, context `dcs_down`),
-- trading availability for guaranteed single-writer. Failsafe is the
-- principled middle ground (Patroni `dcs_failsafe_mode`): when etcd is
-- unreachable, the leader asks every peer directly "do you still defer
-- to me?" and stays read-write ONLY if EVERY peer confirms.
--
-- Why this is safe: a peer confirms iff it is itself read-only (not a
-- competing writer). If all peers are read-only and reachable, then no
-- other partition holds a majority of the replicaset, so no new leader
-- can be appointed elsewhere — staying RW keeps exactly one writer.
-- If any peer is unreachable or claims to be a writer, we cannot prove
-- that, so we demote.
--
-- Opt-in (`failover.failsafe_enabled: true`); the default stays CP/safe.
--

local M = {}

-- Pure verdict over the map_call results.
--   results       — { [alias] = { ok = bool, value = { accepted = bool } } }
--   expected_peers — how many peers we polled (excl. self)
--
-- Stay RW only if we heard back from EVERY expected peer and all of
-- them accepted. expected_peers == 0 means a single-instance replicaset
-- (no possible competing writer) → safe to stay RW.
function M.all_accepted(results, expected_peers)
    local expected = tonumber(expected_peers) or 0
    if expected < 1 then return true end
    if type(results) ~= 'table' then return false end
    local n = 0
    for _, r in pairs(results) do
        if not (r and r.ok and type(r.value) == 'table'
            and r.value.accepted == true) then
            return false
        end
        n = n + 1
    end
    return n >= expected
end

-- Poll every peer (except self) for acceptance. Returns (stay_rw, results).
-- Defensive: any module/RPC failure → false (demote), the safe default.
function M.check(self_alias)
    local ok_rpc, rpc = pcall(require, 'webui.cluster.rpc')
    local ok_peers, peers = pcall(require, 'webui.cluster.peers')
    if not (ok_rpc and ok_peers) then return false end
    local conns = peers.connections() or {}
    local aliases = {}
    for alias in pairs(conns) do
        if alias ~= self_alias then aliases[#aliases + 1] = alias end
    end
    if #aliases == 0 then
        -- Single-instance replicaset: nobody else can be a writer.
        return true
    end
    local ok_call, res = pcall(rpc.map_call, 'webui_failsafe_accept',
        { self_alias }, { timeout = 2, peers = aliases })
    if not ok_call then return false end
    return M.all_accepted(res, #aliases), res
end

return M
