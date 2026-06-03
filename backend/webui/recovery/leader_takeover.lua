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
    logger.debug('leader_takeover.assess', { target = target, danger = dangerous })
    return b.build(fp)
end

local function self_alias()
    if not (rawget(_G, 'box') and box.info) then return nil end
    return box.info.name
end

-- promote(payload, root) → { ok, action, results }
function M.promote(payload, root)
    payload = payload or {}
    local target = payload.target_alias
    if type(target) ~= 'string' or target == '' then
        return { ok = false, action = 'leader_takeover',
            results = {}, error = 'target_alias is required' }
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
    })
    return { ok = ok, action = 'leader_takeover', results = results }
end

return M
