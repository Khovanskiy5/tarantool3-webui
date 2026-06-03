--
-- Disaster recovery snapshot (Phase 6).
--
-- Reads the already-polled cluster state cache + drills into each
-- peer's box.info via the existing peer pool, then groups peers
-- by the kind of recovery they need:
--
--   * `split-brain`   — applier stopped with Split-Brain message
--   * `orphan`        — box.info.status == 'orphan'
--   * `queue-owner`   — synchro.queue.owner == self_id
--   * `follower`      — healthy, following a leader
--   * `unreachable`   — not in the poll snapshot at all
--
-- The snapshot is read-only: nothing here writes to etcd or any
-- peer. Wizards consume the recommendation to dispatch the right
-- handler.
--

local state = require('webui.cluster.state')

local M = {}

-- Build per-peer recovery view. Pure over the cluster snapshot so
-- unit tests can feed synthetic data.
function M.classify(servers)
    if type(servers) ~= 'table' then return {} end
    local out = {}
    for alias, srv in pairs(servers) do
        local entry = {
            alias        = alias,
            uuid         = srv.uuid,
            replicaset   = srv.replicaset_uuid,
            reachable    = srv.reachable == true,
            status       = srv.status,
            ro           = srv.ro,
            last_lsn     = nil,
            current_term = nil,
            queue_owner  = false,
            role         = 'follower',
            reasons      = {},
        }
        local info = srv.box_info
        if type(info) == 'table' then
            entry.status      = info.status or entry.status
            -- Live `box.info.ro` overrides the cached poll value
            -- — promotion / demotion takes effect immediately on
            -- the target peer but propagates to other peers only
            -- on the next replication tick.
            if info.ro ~= nil then entry.ro = info.ro end
            entry.current_term = info.election and info.election.term
            local synchro = info.synchro
            if type(synchro) == 'table' and type(synchro.queue) == 'table' then
                entry.queue_owner_id = synchro.queue.owner
                entry.queue_owner = synchro.queue.owner == info.id
                -- `busy` => a PROMOTE/CONFIRM/ROLLBACK is in flight; the
                -- assessment layer must not act on it (retry instead).
                -- `term` is the synchro-queue term (may lag election.term
                -- between an election round and the next PROMOTE).
                entry.queue_busy = synchro.queue.busy == true
                entry.queue_term = synchro.queue.term
            end
            local vclock = info.vclock
            if type(vclock) == 'table' then
                local max_lsn = 0
                for _, lsn in pairs(vclock) do
                    if lsn > max_lsn then max_lsn = lsn end
                end
                entry.last_lsn = max_lsn
                -- Keep the FULL vclock map (not just the max LSN scalar):
                -- the recovery risk-assessment layer needs the per-replica
                -- vector to run vclock_dominates for leader_takeover.
                entry.vclock = vclock
            end
        end
        -- Walk replication entries to detect split-brain or other
        -- stopped-applier failure modes.
        local replication = srv.replication or
            (type(info) == 'table' and info.replication) or {}
        local broken = {}
        for _, r in pairs(replication or {}) do
            if r.upstream and r.upstream.status ~= nil
                and r.upstream.status ~= 'follow' then
                table.insert(broken, {
                    peer_uuid = r.uuid,
                    status    = r.upstream.status,
                    message   = r.upstream.message,
                })
            end
        end
        entry.broken_upstreams = broken

        -- Role decision tree. Order matters — split-brain wins
        -- over orphan because the recovery path is different
        -- (rebootstrap vs reconnect).
        if not entry.reachable then
            entry.role = 'unreachable'
            table.insert(entry.reasons, 'not in poll snapshot')
        else
            local sb = nil
            for _, b in ipairs(broken) do
                if type(b.message) == 'string'
                    and b.message:lower():find('split.brain', 1, false) then
                    sb = b
                    break
                end
            end
            if sb ~= nil then
                entry.role = 'split-brain'
                table.insert(entry.reasons,
                    'upstream from ' .. tostring(sb.peer_uuid)
                    .. ' stopped: ' .. tostring(sb.message))
            elseif entry.status == 'orphan' then
                entry.role = 'orphan'
                table.insert(entry.reasons, 'box.info.status = orphan')
            elseif entry.queue_owner then
                entry.role = 'queue-owner'
            end
        end
        out[alias] = entry
    end
    return out
end

-- Pick a recommendation from the classified set.
function M.recommend(classified)
    local has_split_brain = false
    local has_orphan = false
    local has_queue_owner = false
    local has_unreachable = false
    for _, e in pairs(classified or {}) do
        if e.role == 'split-brain' then has_split_brain = true end
        if e.role == 'orphan' then has_orphan = true end
        if e.role == 'queue-owner' then has_queue_owner = true end
        if e.role == 'unreachable' then has_unreachable = true end
    end
    if has_split_brain then return 'split_brain_resolve' end
    if has_orphan then return 'orphan_resolve' end
    if not has_queue_owner then return 'leader_takeover' end
    -- Quorum is intact (queue owner present) but at least one peer
    -- is gone — flag the cluster as degraded so the operator sees
    -- a warning banner instead of the green "healthy" one. No
    -- automatic dispatch — the wizards remain available manually.
    if has_unreachable then return 'degraded' end
    return 'no_action_needed'
end

-- Group split-brain peers by who they diverged from (the peer
-- whose UUID shows up in the stopped upstream message). The UI
-- shows one card per group.
function M.split_brain_groups(classified)
    local groups = {}
    for alias, e in pairs(classified or {}) do
        if e.role == 'split-brain' then
            for _, b in ipairs(e.broken_upstreams or {}) do
                if type(b.message) == 'string'
                    and b.message:lower():find('split.brain', 1, false) then
                    local key = tostring(b.peer_uuid or '?')
                    if groups[key] == nil then
                        groups[key] = {
                            divergent_from = b.peer_uuid,
                            members        = {},
                        }
                    end
                    table.insert(groups[key].members, alias)
                end
            end
        end
    end
    local arr = {}
    for _, g in pairs(groups) do
        table.sort(g.members)
        table.insert(arr, g)
    end
    return arr
end

-- Live RPC sweep across reachable peers. The poller does not
-- collect synchro.queue / vclock / replication per peer (those
-- would balloon the snapshot we cache per tick), so DR diagnosis
-- pulls a fresh point-in-time view straight from box.info. The
-- payload is small (~1 KiB per peer) and the call is gated to
-- admins through the resolver.
local function fetch_box_info_per_peer(servers)
    local out = {}
    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    if not rpc_ok or type(rpc.map_eval) ~= 'function' then return out end

    -- Collect the live aliases and split self vs foreign so the
    -- foreign branch goes through map_eval and the self branch
    -- reads box.info directly (the peer pool excludes self).
    local foreign, self_alias = {}, nil
    if rawget(_G, 'box') and box.info then self_alias = box.info.name end
    for alias, srv in pairs(servers or {}) do
        if srv.reachable then
            if alias == self_alias then
                out[alias] = {
                    id     = box.info.id,
                    status = box.info.status,
                    ro     = box.info.ro,
                    election = box.info.election,
                    synchro  = box.info.synchro,
                    vclock   = box.info.vclock,
                    replication = box.info.replication,
                }
            else
                table.insert(foreign, alias)
            end
        end
    end

    if #foreign == 0 then return out end
    local expr = [[
        return {
            id          = box.info.id,
            status      = box.info.status,
            ro          = box.info.ro,
            election    = box.info.election,
            synchro     = box.info.synchro,
            vclock      = box.info.vclock,
            replication = box.info.replication,
        }
    ]]
    local ok, per_peer = pcall(rpc.map_eval, expr, {},
        { timeout = 3, peers = foreign })
    if not ok or type(per_peer) ~= 'table' then return out end
    for alias, r in pairs(per_peer) do
        if r and r.ok and type(r.value) == 'table' then
            out[alias] = r.value
        end
    end
    return out
end
M._fetch_box_info_per_peer = fetch_box_info_per_peer

-- Top-level snapshot used by the GraphQL resolver. Live cluster
-- snapshot from `webui.cluster.state` flows in here; everything
-- below is a pure projection over it.
function M.build()
    local snap = state.snapshot()
    local live_info = fetch_box_info_per_peer(snap.servers or {})
    -- Merge the live info into the cached server view so classify
    -- sees fresh synchro / vclock / replication. We deep-copy
    -- minimally — only the fields classify reads.
    local servers = {}
    for alias, srv in pairs(snap.servers or {}) do
        local copy = {}
        for k, v in pairs(srv) do copy[k] = v end
        copy.box_info = live_info[alias] or copy.box_info
        if copy.box_info and copy.box_info.replication then
            copy.replication = copy.box_info.replication
        end
        servers[alias] = copy
    end
    local classified = M.classify(servers)
    local peers_arr = {}
    for _, e in pairs(classified) do table.insert(peers_arr, e) end
    table.sort(peers_arr, function(a, b)
        return (a.alias or '') < (b.alias or '')
    end)
    return {
        self_alias        = snap.self_alias,
        generation        = snap.generation,
        peers             = peers_arr,
        split_brain_groups = M.split_brain_groups(classified),
        recommendation    = M.recommend(classified),
    }
end

return M
