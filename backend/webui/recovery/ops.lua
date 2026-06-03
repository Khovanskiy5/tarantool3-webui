--
-- Risk assessment for the "analogous" recovery-adjacent actions
-- (Task RC-3): restart replication, restart failover, force apply,
-- rebootstrap, promote. These live in the suggestions / lifecycle /
-- cluster_ops subsystems but are brought under the same Assessment
-- contract so the UI gets one preflight model for every action.
--
-- Pure assessment functions take (payload, _root, snap) like the other
-- recovery modules. The execute adapters (exec_*) delegate to the
-- existing executors and normalize the result to the standard
-- { ok, action, results } shape so the guarded recoveryAction path can
-- drive them.
--
-- Lua simple/reliable rules: plain control flow, locals, pcall on every
-- external touch, no metatables.
--

local assess   = require('webui.recovery.assess')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.ops')

local M = {}

local function build_snap(snap)
    if snap ~= nil then return snap end
    local ok, s = pcall(function()
        return require('webui.recovery.snapshot').build()
    end)
    return ok and s or { peers = {} }
end

local function payload_uuids(payload)
    local u = payload.instanceUuids or payload.instance_uuids or {}
    if type(u) ~= 'table' then return {} end
    return u
end

-- ── assess() ─────────────────────────────────────────────────────────

-- restart_replication — re-establish stopped replication. Never loses
-- committed data (safe). Precondition: the targets must be reachable; a
-- reconnect aimed at a dead source is futile.
function M.assess_restart_replication(payload, _root, snap)
    payload = payload or {}
    snap = build_snap(snap)
    local idx = assess.index_peers(snap)
    local uuids = payload_uuids(payload)
    local all_reachable = true
    for _, p in ipairs(idx.peers) do all_reachable = all_reachable and p.reachable end
    local b = assess.new('restart_replication')
        .risk(assess.SAFE)
        .summary('Restart replication on ' .. tostring(#uuids) .. ' instance(s)')
        .with_docs('runbooks/failover-issues.md')
        .effect('Detaches and re-attaches replication; no committed data is '
            .. 'touched.')
        .precondition(all_reachable, 'Replication source(s) reachable',
            'Restarting replication at an unreachable upstream is futile.')
    logger.debug('ops.assess restart_replication', { count = #uuids })
    return b.build(assess.fingerprint(snap, {}))
end

-- restart_failover — restart the supervised agent fibers. Control-plane
-- only, no data loss (caution). The coordinator is re-elected on the next
-- tick.
function M.assess_restart_failover(payload, _root, snap)
    payload = payload or {}
    snap = build_snap(snap)
    local uuids = payload_uuids(payload)
    local b = assess.new('restart_failover')
        .risk(assess.CAUTION)
        .summary('Restart the failover agent on ' .. tostring(#uuids)
            .. ' instance(s)')
        .with_docs('runbooks/failover-issues.md')
        .effect('Stops and restarts the agent/watcher fibers; the coordinator '
            .. 'is re-elected on the next tick. No tuple data is changed.')
    logger.debug('ops.assess restart_failover', { count = #uuids })
    return b.build(assess.fingerprint(snap, {}))
end

-- force_apply — re-push the clusterwide config to an instance. Applies
-- CONFIG, not tuple data, so committed data is never lost (caution).
function M.assess_force_apply(payload, _root, snap)
    payload = payload or {}
    snap = build_snap(snap)
    local uuids = payload_uuids(payload)
    local b = assess.new('force_apply')
        .risk(assess.CAUTION)
        .summary('Force-apply the cluster config to ' .. tostring(#uuids)
            .. ' instance(s)')
        .with_docs('runbooks/rollback-config.md')
        .effect('Re-applies the clusterwide config (not data) and reloads the '
            .. 'roles on the target. No tuple data is changed.')
    logger.debug('ops.assess force_apply', { count = #uuids })
    return b.build(assess.fingerprint(snap, {}))
end

-- rebootstrap — wipe + re-join a follower. Always dangerous. Reuse the
-- orphan module's rebootstrap classification verbatim.
function M.assess_rebootstrap(payload, _root, snap)
    payload = payload or {}
    local alias = payload.alias or payload.target_alias
    return require('webui.recovery.orphan').assess(
        { action = 'rebootstrap', target_alias = alias }, _root, build_snap(snap))
end

-- promote — cluster_ops promoteInstance. A normal promote of a dominating
-- candidate is safe/caution; force_inconsistency rolls back unconfirmed
-- transactions (dangerous).
function M.assess_promote(payload, _root, snap)
    payload = payload or {}
    snap = build_snap(snap)
    local alias = payload.alias or payload.target_alias
    local idx = assess.index_peers(snap)
    local cand = alias and idx.by_alias[alias] or nil
    local owner = idx.owner
    local fp = assess.fingerprint(snap, alias and { alias } or {})
    local b = assess.new('promote')
        .summary('Promote ' .. tostring(alias) .. ' to leader')
        .with_docs('runbooks/promote.md')

    if payload.force_inconsistency == true then
        b.risk(assess.DANGEROUS).data_loss(true)
            .effect('Promotes ' .. tostring(alias)
                .. ' and rolls back unconfirmed transactions.')
            .warning('Unconfirmed synchronous transactions on ' .. tostring(alias)
                .. ' are rolled back — committed-but-unconfirmed writes are lost.')
            .manual('Dump box.info.synchro.queue on ' .. tostring(alias)
                .. ' before promoting.')
            .failure_cmd('inspect election/synchro',
                'box.info.election; box.info.synchro')
            .confirm('PROMOTE ' .. tostring(alias),
                'I accept rolling back unconfirmed transactions')
        for _, pc in ipairs(assess.universal_preconditions()) do
            b.precondition(pc.ok, pc.label, pc.detail)
        end
        return b.build(fp)
    end

    -- Normal promote: safe only if the candidate dominates the owner (or
    -- all reachable peers when there is no owner).
    local dominates
    if owner ~= nil then
        b.precondition(true, 'Compared against queue owner ' .. tostring(owner.alias))
        dominates = cand ~= nil and assess.dominates(cand.vclock, owner.vclock)
    else
        dominates = cand ~= nil
        for _, p in ipairs(idx.peers) do
            if p.reachable and p.alias ~= alias
                and not assess.dominates(cand and cand.vclock, p.vclock) then
                dominates = false
                break
            end
        end
        b.precondition(dominates, 'Candidate dominates all reachable peers')
    end

    if dominates then
        b.risk(assess.CAUTION)
            .effect('Candidate dominates the confirmed state — no committed '
                .. 'data is lost.')
    else
        b.risk(assess.DANGEROUS).data_loss(true)
            .warning('Candidate ' .. tostring(alias)
                .. ' does not dominate — its un-replicated tail is lost.')
            .manual('Prefer a graceful switchover (quiesce the owner, let the '
                .. 'candidate catch up) over a forced promote.')
            .confirm('PROMOTE ' .. tostring(alias),
                'I accept losing the un-replicated tail')
        for _, pc in ipairs(assess.universal_preconditions()) do
            b.precondition(pc.ok, pc.label, pc.detail)
        end
    end
    logger.debug('ops.assess promote', { alias = alias, dominates = dominates })
    return b.build(fp)
end

-- ── exec adapters ────────────────────────────────────────────────────
-- Normalize the existing executors to { ok, action, results }.

local function suggestion_result(action, ok, res)
    local results = {}
    if type(res) == 'table' and type(res.results) == 'table' then
        for peer, r in pairs(res.results) do
            results[#results + 1] = {
                peer = tostring(peer),
                ok   = type(r) == 'table' and (r.ok == true) or (r == true),
                msg  = type(r) == 'table' and (r.err or r.msg) or nil,
            }
        end
    end
    return {
        ok = ok and (res == nil or res.ok ~= false),
        action = action,
        error = (not ok) and tostring(res) or (res and res.error) or nil,
        results = results,
    }
end

local function exec_suggestion(type_, action, payload, root)
    local ok_s, suggestions = pcall(require, 'webui.cluster.suggestions')
    if not ok_s then
        return { ok = false, action = action, results = {},
            error = 'suggestions module unavailable' }
    end
    local ok, res = pcall(suggestions.apply, type_,
        { instance_uuids = payload_uuids(payload) },
        { user = root and root.user })
    return suggestion_result(action, ok, res)
end

function M.exec_restart_replication(payload, root)
    return exec_suggestion('restart_replication', 'restart_replication',
        payload or {}, root)
end

function M.exec_force_apply(payload, root)
    return exec_suggestion('force_apply', 'force_apply', payload or {}, root)
end

-- rebootstrap one alias via the existing remote shim (same path the
-- orphan/lifecycle rebootstrap uses).
function M.exec_rebootstrap(payload, root)
    payload = payload or {}
    local alias = payload.alias or payload.target_alias
    if type(alias) ~= 'string' or alias == '' then
        return { ok = false, action = 'rebootstrap', results = {},
            error = 'alias is required' }
    end
    local ok_r, rpc = pcall(require, 'webui.cluster.rpc')
    if not ok_r then
        return { ok = false, action = 'rebootstrap', results = {},
            error = 'rpc module unavailable' }
    end
    local ok, per = pcall(rpc.map_call, 'webui_rebootstrap_remote', {},
        { timeout = 5, peers = { alias } })
    local r = ok and type(per) == 'table' and per[alias] or nil
    local good = r ~= nil and r.ok == true
        and not (type(r.value) == 'table' and r.value.err)
    local msg
    if not ok then msg = tostring(per)
    elseif r == nil then msg = 'no response from ' .. alias
    elseif type(r.value) == 'table' and r.value.err then
        msg = tostring(r.value.message or r.value.err)
    else msg = 'rebootstrap dispatched on ' .. alias end
    local _ = root
    return { ok = good, action = 'rebootstrap',
        results = { { peer = alias, ok = good, msg = msg } } }
end

return M
