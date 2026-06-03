--
-- Orphan resolver (Phase 6 Task DR-2).
--
-- A peer is `orphan` when `box.info.status == 'orphan'`: it
-- joined a replicaset but cannot find the writable leader.
-- Three recovery options:
--
--   * `force_reconnect`  — `box.cfg{ replication = box.cfg.replication }`
--     with a brief detach to drop every applier, then re-attach.
--     Recovers from transient network blips where the upstream
--     is reachable but the applier got stuck mid-handshake.
--
--   * `rebootstrap`      — wipe WAL/snap and cold-boot. Routes
--     through the existing `webui_rebootstrap_remote` global, so
--     the contract from Phase 5 still applies (refuses if the
--     target is the synchro queue owner — we cannot lose data
--     that the cluster believes was committed).
--
--   * `solo_promote`     — `box.ctl.promote()` on the orphan,
--     turning it into a writable standalone. Operator's
--     escape-hatch when no quorum can be reached but reads must
--     keep flowing on a particular peer.
--

local audit    = require('webui.audit.log')
local assess   = require('webui.recovery.assess')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.orphan')

local M = {}

local function self_alias()
    if not (rawget(_G, 'box') and box.info) then return nil end
    return box.info.name
end

local function fanout(expr, alias)
    local me = self_alias()
    if alias == me then
        -- Inline executor for the self path. We compile and run
        -- the same expression body so behaviour stays in sync.
        local fn, err = loadstring('return (function() ' .. expr .. ' end)()')
        if fn == nil then return false, tostring(err) end
        local ok, res = pcall(fn)
        if not ok then return false, tostring(res) end
        if type(res) == 'table' and res.err ~= nil then
            return false, tostring(res.err)
        end
        return true, 'dispatched on self'
    end
    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    if not rpc_ok then return false, 'rpc module unavailable' end
    local ok_call, res = pcall(rpc.map_eval, expr, {},
        { timeout = 10, peers = { alias } })
    if not ok_call then return false, tostring(res) end
    if type(res) ~= 'table' or res[alias] == nil then
        return false, 'no response from ' .. alias
    end
    local r = res[alias]
    if not (r and r.ok) then return false, (r and r.err) or 'unknown error' end
    if type(r.value) == 'table' and r.value.err ~= nil then
        return false, tostring(r.value.err)
    end
    return true, 'dispatched on ' .. alias
end

-- assess(payload, root) → Assessment (read-only). force_reconnect never
-- loses commits (safe) but cannot heal a diverged orphan; rebootstrap
-- wipes the node (dangerous); solo_promote forks a partitioned node
-- (dangerous).
function M.assess(payload, _root, snap)
    payload = payload or {}
    local action = payload.action or 'force_reconnect'
    local target = payload.target_alias
    snap = snap or require('webui.recovery.snapshot').build()
    local fp = assess.fingerprint(snap, target and { target } or {})
    local b = assess.new('orphan_resolve')
        .with_docs('runbooks/recovery-overview.md')
        .summary('Resolve orphan ' .. tostring(target) .. ' via ' .. tostring(action))

    if action == 'force_reconnect' then
        b.risk(assess.SAFE)
            .effect('Detaches and re-attaches replication on ' .. tostring(target)
                .. ' — no committed data is touched.')
            .precondition(true, 'Reconnect does not erase data')
            .effect('Will NOT heal a diverged orphan; if it fails, rebootstrap '
                .. '(dangerous) is required.')
    elseif action == 'rebootstrap' then
        b.risk(assess.DANGEROUS).data_loss(true)
            .effect('Wipes WAL/snap on ' .. tostring(target)
                .. ' and re-joins it from a healthy peer.')
            .warning('All local data on ' .. tostring(target) .. ' is erased.')
            .manual('Dump any local-only spaces on ' .. tostring(target)
                .. ' before rebootstrap; keep instance_uuid stable.')
            .failure_cmd('inspect replication',
                'box.info.replication; box.info.status')
            .confirm('ORPHAN ' .. tostring(target),
                'I accept wiping ' .. tostring(target))
        for _, pc in ipairs(assess.universal_preconditions()) do
            b.precondition(pc.ok, pc.label, pc.detail)
        end
    elseif action == 'solo_promote' then
        b.risk(assess.DANGEROUS).data_loss(true)
            .effect('Promotes the isolated orphan to writable.')
            .warning('A partitioned writable node diverges from the cluster.')
            .manual('Confirm the orphan is truly isolated; dump its data first.')
            .confirm('ORPHAN ' .. tostring(target),
                'I accept divergence risk')
        for _, pc in ipairs(assess.universal_preconditions()) do
            b.precondition(pc.ok, pc.label, pc.detail)
        end
    else
        b.risk(assess.DANGEROUS).warning('Unsupported action ' .. tostring(action))
    end
    logger.debug('orphan.assess', { target = target, action = action })
    return b.build(fp)
end

-- resolve(payload, root) → { ok, action, results }
function M.resolve(payload, root)
    payload = payload or {}
    local action = payload.action or 'force_reconnect'
    local target = payload.target_alias
    if type(target) ~= 'string' or target == '' then
        return { ok = false, action = action, results = {},
            error = 'target_alias is required' }
    end

    local expr
    if action == 'force_reconnect' then
        expr = [[
            local saved = box.cfg.replication
            pcall(function() box.cfg{ replication = {} } end)
            pcall(function() box.cfg{ replication = saved } end)
            return { ok = true }
        ]]
    elseif action == 'rebootstrap' then
        expr = [[
            return _G.webui_rebootstrap_remote
                and _G.webui_rebootstrap_remote()
                or { err = 'no rebootstrap rpc' }
        ]]
    elseif action == 'solo_promote' then
        expr = [[
            local ok, err = pcall(box.ctl.promote)
            return { ok = ok, err = err and tostring(err) or nil }
        ]]
    else
        return { ok = false, action = action, results = {},
            error = 'unsupported action ' .. tostring(action) }
    end

    local ok, msg = fanout(expr, target)
    local results = { { peer = target, ok = ok, msg = msg } }
    pcall(audit.record, {
        user   = root and root.user,
        action = 'orphan.' .. action,
        scope  = 'cluster',
        payload = { target = target, ok = ok, msg = msg },
        request_id = root and root.request_id,
    })
    logger.info('orphan resolve', {
        target = target, action = action, ok = ok, msg = msg,
    })
    return { ok = ok, action = 'orphan_' .. action, results = results }
end

return M
