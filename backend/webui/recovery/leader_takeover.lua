--
-- Leader takeover (Phase 6 Task DR-3).
--
-- Use case: every peer reports `box.info.synchro.queue.owner = 0`
-- (or owner pointing at an unreachable / dead peer). Synchronous
-- writes are blocked cluster-wide; the operator needs to nominate
-- a new writer.
--
-- Dispatcher: call `box.ctl.promote()` on the chosen peer via
-- net.box. The peer's box.cfg ensures it runs as RW after the
-- promote takes effect. The Phase 5 supervised-agent appointment
-- (etcd key `/failover/replicasets/<rs>/leader`) is ALSO updated
-- when we detect an etcd client + supervised mode, so the agent
-- on every other peer converges quickly instead of fighting
-- back the manual promote.
--

local audit    = require('webui.audit.log')
local assess   = require('webui.recovery.assess')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.takeover')

local M = {}

-- Bounded wait for reachable peers to replicate up to the candidate
-- before the promote (see M.wait_peers_caught_up).
M.PEER_CATCHUP_TIMEOUT = 15      -- seconds
M.CATCHUP_POLL_STEP    = 0.5     -- seconds

-- Reachable peers whose vclock does NOT yet dominate the candidate's —
-- they have not replicated everything the candidate confirmed. A
-- box.ctl.promote on the candidate then looks like a "future lsn" to such
-- a peer and wedges its applier (ER_SPLIT_BRAIN, terminal). This is the
-- limbo-lag the vclock-DOMINANCE check (candidate-vs-peer) does NOT catch:
-- there the candidate is AHEAD and "dominates", yet the lagging peer still
-- rejects the promote until it catches up. Pure for tests.
-- peer_vclocks: { [alias] = vclock }. -> sorted array of laggard aliases.
function M._peers_behind(cand_vclock, peer_vclocks)
    local out = {}
    for alias, vc in pairs(peer_vclocks or {}) do
        if not assess.dominates(vc, cand_vclock) then
            table.insert(out, alias)
        end
    end
    table.sort(out)
    return out
end

-- assess(payload, root) → Assessment (read-only). Classifies a leader
-- takeover by vclock dominance: promoting a candidate that already
-- applied everything the queue owner confirmed loses nothing (safe);
-- promoting a laggard rolls back the owner's un-replicated tail
-- (dangerous). With NO queue owner the candidate must dominate every
-- reachable peer instead.
function M.assess(payload, _root, snap)
    payload = payload or {}
    local target = payload.target_alias
    snap = snap or require('webui.recovery.snapshot').build()
    local idx = assess.index_peers(snap)
    local cand = target and idx.by_alias[target] or nil
    local fp = assess.fingerprint(snap, target and { target } or {})

    local b = assess.new('leader_takeover')
        .with_docs('runbooks/leader-takeover.md')
        .effect('Calls box.ctl.promote() on ' .. tostring(target)
            .. ' (bumps the synchro term and claims the queue).')
        .effect('promote waits for quorum/catch-up and FAILS on timeout — '
            .. 'a failed promote means leadership was NOT transferred.')
        .precondition(not assess.any_queue_busy(snap),
            'Synchro queue not busy',
            'A PROMOTE/CONFIRM/ROLLBACK in flight (queue.busy) means retry '
                .. 'instead of acting.')

    if type(target) ~= 'string' or target == '' then
        return b.summary('target_alias is required').risk(assess.DANGEROUS)
            .warning('No target selected.').build(fp)
    end

    local owner = idx.owner
    local dangerous, laggard
    if owner ~= nil then
        b.summary('Take over leadership from current queue owner '
            .. tostring(owner.alias) .. ' onto ' .. tostring(target))
        b.precondition(true, 'Compared against queue owner ' .. tostring(owner.alias))
        dangerous = not (cand and assess.dominates(cand.vclock, owner.vclock))
        if dangerous then laggard = owner.alias end
    else
        -- No owner: the candidate must dominate every reachable peer.
        b.summary('Nominate ' .. tostring(target)
            .. ' as queue owner (no owner currently)')
        dangerous = (cand == nil)
        for _, p in ipairs(idx.peers) do
            if p.reachable and p.alias ~= target
                and not assess.dominates(cand and cand.vclock, p.vclock) then
                dangerous, laggard = true, p.alias
                break
            end
        end
        b.precondition(not dangerous,
            'Candidate dominates all reachable peers',
            laggard and ('peer ' .. laggard .. ' is more advanced') or nil)
    end

    if dangerous then
        b.risk(assess.DANGEROUS).data_loss(true)
            .warning('Candidate ' .. tostring(target) .. ' does not dominate '
                .. tostring(laggard) .. ' — its un-replicated tail is lost.')
            .manual('Prefer a graceful switchover: drive ' .. tostring(laggard)
                .. ' to read-only, let ' .. tostring(target)
                .. ' catch up to its LSN, then promote (no loss).')
            .manual('Or read box.info.synchro.queue on ' .. tostring(laggard)
                .. ' and replay it before promoting.')
            .failure_cmd('check promotion state',
                'box.info.election; box.info.synchro')
            .confirm('TAKEOVER ' .. tostring(target),
                'I accept losing the un-replicated tail of ' .. tostring(laggard))
        for _, pc in ipairs(assess.universal_preconditions()) do
            b.precondition(pc.ok, pc.label, pc.detail)
        end
    else
        b.risk(assess.CAUTION)
            .effect('Candidate dominates the confirmed state — no committed '
                .. 'data is lost.')
    end

    -- Limbo-lag awareness: even when the candidate dominates, a reachable
    -- peer that has NOT yet replicated up to the candidate's vclock will
    -- reject the promote as a "future lsn" and wedge its applier. Surface
    -- such peers — informational, not data loss; the takeover waits for
    -- them to catch up before promoting (see M.promote).
    if cand ~= nil then
        local peer_vclocks = {}
        for _, p in ipairs(idx.peers) do
            if assess.is_reachable(p) and p.alias ~= target then
                peer_vclocks[p.alias] = p.vclock
            end
        end
        local behind = M._peers_behind(cand.vclock, peer_vclocks)
        if #behind > 0 then
            b.precondition(true, 'Peers will catch up to candidate first',
                'reachable peer(s) ' .. table.concat(behind, ', ') .. ' are '
                .. 'behind ' .. tostring(target) .. '; the takeover waits for '
                .. 'them to replicate up before promoting, otherwise their '
                .. 'applier wedges on "future lsn" (recover via rebootstrap).')
        end
    end

    logger.debug('leader_takeover.assess', { target = target, danger = dangerous })
    return b.build(fp)
end

local function self_alias()
    if not (rawget(_G, 'box') and box.info) then return nil end
    return box.info.name
end

-- Bounded wait until every reachable peer has replicated up to the
-- candidate's vclock, so the upcoming promote is not a "future lsn" to a
-- lagging peer (which would wedge its applier, ER_SPLIT_BRAIN). Re-polls
-- live vclocks each tick. Unreachable peers are ignored (they are not
-- replicating, so they cannot wedge — they rebootstrap/catch up later).
-- -> (true) | (false, laggards) on timeout.
function M.wait_peers_caught_up(cand_vclock, peers, opts)
    opts = opts or {}
    local timeout = opts.timeout or M.PEER_CATCHUP_TIMEOUT
    local step    = opts.step or M.CATCHUP_POLL_STEP
    if type(peers) ~= 'table' or #peers == 0 or type(cand_vclock) ~= 'table' then
        return true
    end
    local fiber = require('fiber')
    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    if not rpc_ok then return true end          -- can't poll → don't block
    local started = fiber.clock()
    while true do
        local res = nil
        pcall(function()
            res = rpc.map_eval('return box.info.vclock', {},
                { timeout = 5, peers = peers })
        end)
        local vclocks = {}
        for _, alias in ipairs(peers) do
            local r = res and res[alias]
            if type(r) == 'table' and r.ok == true and type(r.value) == 'table' then
                vclocks[alias] = r.value
            end
        end
        local behind = M._peers_behind(cand_vclock, vclocks)
        if #behind == 0 then return true end
        if (fiber.clock() - started) >= timeout then
            return false, behind
        end
        fiber.sleep(step)
    end
end

-- promote(payload, root) → { ok, action, results }
function M.promote(payload, root)
    payload = payload or {}
    local target = payload.target_alias
    if type(target) ~= 'string' or target == '' then
        return { ok = false, action = 'leader_takeover',
            results = {}, error = 'target_alias is required' }
    end

    -- Limbo-lag guard: wait for reachable peers to catch up to the
    -- candidate's vclock BEFORE claiming the queue. Promoting while a peer
    -- is behind makes the promote look like a "future lsn" and wedges that
    -- peer's applier (terminal ER_SPLIT_BRAIN). Best-effort + bounded — a
    -- peer that can't catch up in time is surfaced as a warning, not a hard
    -- block (the gate already accepted the takeover).
    local catchup_warning = nil
    do
        local ok_s, snap = pcall(function()
            return require('webui.recovery.snapshot').build()
        end)
        if ok_s and type(snap) == 'table' then
            local idx = assess.index_peers(snap)
            local cand = idx.by_alias[target]
            local wait_peers = {}
            for _, p in ipairs(idx.peers) do
                if assess.is_reachable(p) and p.alias ~= target then
                    table.insert(wait_peers, p.alias)
                end
            end
            if cand ~= nil and cand.vclock ~= nil and #wait_peers > 0 then
                local caught, laggards =
                    M.wait_peers_caught_up(cand.vclock, wait_peers)
                if not caught then
                    catchup_warning = 'peers still behind ' .. tostring(target)
                        .. ' at promote time: ' .. table.concat(laggards, ',')
                        .. ' — their applier may wedge on "future lsn"; '
                        .. 'rebootstrap them if it persists'
                    logger.warn('leader_takeover: peers not caught up before '
                        .. 'promote', { target = target, laggards = laggards })
                end
            end
        end
    end

    -- Drive the actual box.ctl.promote on the target.
    local me = self_alias()
    local results = {}
    local ok, msg
    if target == me then
        local ok_local, err_local = pcall(box.ctl.promote)
        if not ok_local then
            ok, msg = false, tostring(err_local)
        else
            ok, msg = true, 'promote dispatched on self'
        end
    else
        local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
        if not rpc_ok then
            ok, msg = false, 'rpc module unavailable'
        else
            local call_ok, res = pcall(rpc.map_eval,
                'local ok, err = pcall(box.ctl.promote);' ..
                ' return { ok = ok, err = err and tostring(err) or nil }',
                {}, { timeout = 5, peers = { target } })
            if not call_ok then
                ok, msg = false, tostring(res)
            elseif type(res) ~= 'table' or res[target] == nil then
                ok, msg = false, 'no response from ' .. target
            else
                local r = res[target]
                if r and r.ok and r.value and r.value.ok then
                    ok, msg = true, 'promote dispatched on ' .. target
                else
                    ok = false
                    msg = (r and r.value and r.value.err)
                        or (r and r.err) or 'promote failed'
                end
            end
        end
    end
    table.insert(results, { peer = target, ok = ok, msg = msg })

    -- Best-effort etcd appointment update for the supervised
    -- failover agent. Failure here is non-fatal; on next tick
    -- the watcher on the promoted peer notices its queue
    -- ownership and reports back regardless.
    if ok and payload.update_etcd_appointment ~= false then
        pcall(function()
            local agent = require('webui.failover.agent')
            local etcd_client = require('webui.config_store.client')
            local client = etcd_client.get_client()
            if client == nil then return end
            local replicaset = payload.replicaset
            if replicaset == nil then
                if box.info and box.info.replicaset then
                    replicaset = box.info.replicaset.name
                end
            end
            if type(replicaset) == 'string' then
                agent.appoint_manually(client, replicaset, target,
                    tonumber(payload.ttl_sec) or 300,
                    (root and root.user) or 'recovery')
            end
        end)
    end

    pcall(audit.record, {
        user   = root and root.user,
        action = 'recovery.leader_takeover',
        scope  = 'cluster',
        payload = { target = target, ok = ok, msg = msg },
        request_id = root and root.request_id,
    })
    logger.info('leader_takeover', {
        target = target, ok = ok, msg = msg,
        catchup_warning = catchup_warning,
    })
    return { ok = ok, action = 'leader_takeover', results = results,
        warning = catchup_warning }
end

return M
