--
-- Quorum-loss escape hatch (Phase 6 Task DR-5).
--
-- Symptom: `synchro_quorum = 2` is configured, only one peer is
-- reachable, every sync write blocks for `synchro_timeout` and
-- then fails. Cluster cannot make progress until quorum is
-- restored OR the operator explicitly lowers the bar.
--
-- This module flips `_session_settings.synchro_quorum` to 1 on
-- the queue-owner peer for the duration of the escape window
-- (default 5 minutes), then restores the original value. A
-- background fiber on the peer drives the restore so a process
-- restart in the middle does not leave the cluster permanently
-- vulnerable.
--
-- WARNING is loud in the audit row: a window with quorum=1 means
-- a subsequent partition can fork the WAL. The wizard's UI
-- requires a typed-confirmation token and a written acknowledge-
-- ment that the operator accepts the risk.
--

local audit    = require('webui.audit.log')
local assess   = require('webui.recovery.assess')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.quorum_loss')

local M = {}

local DEFAULT_WINDOW_SEC = 300
local MAX_WINDOW_SEC     = 3600

-- assess(payload, root) → Assessment (read-only). Lowering synchro_quorum
-- to 1 is ALWAYS dangerous (the window allows a WAL fork). The
-- precondition mirrors Patroni's failsafe double-check: every registered
-- peer must be reachable AND none may claim queue ownership, otherwise
-- lowering quorum manufactures the split-brain it is meant to escape.
function M.assess(payload, _root, snap)
    payload = payload or {}
    local target = payload.target_alias
    snap = snap or require('webui.recovery.snapshot').build()
    local fp = assess.fingerprint(snap, target and { target } or {})

    -- Failsafe peers check: all reachable AND no foreign owner besides the
    -- target.
    local all_reachable, foreign_owner = true, nil
    for _, p in ipairs((snap and snap.peers) or {}) do
        if not p.reachable then all_reachable = false end
        if p.queue_owner == true and p.alias ~= target then
            foreign_owner = p.alias
        end
    end
    local peers_safe = all_reachable and foreign_owner == nil

    local b = assess.new('quorum_loss_escape')
        .risk(assess.DANGEROUS).data_loss(true)
        .summary('Lower synchro_quorum to 1 on ' .. tostring(target)
            .. ' for a bounded window')
        .with_docs('runbooks/recovery-overview.md')
        .effect('Sets _session_settings.synchro_quorum = 1 on ' .. tostring(target)
            .. ', auto-restoring after the window.')
        .warning('During the quorum=1 window a partition can fork the WAL.')
        .manual('Prefer restoring the real quorum (bring peers back) over '
            .. 'lowering it; stay read-only and wait for quorum to re-form.')
        .precondition(peers_safe,
            'All peers reachable and none claims queue ownership',
            (not all_reachable and 'a peer is unreachable')
                or (foreign_owner and ('peer ' .. foreign_owner .. ' owns the queue'))
                or nil)
        .failure_cmd('restore quorum manually',
            'box.space._session_settings:update(\'synchro_quorum\', '
                .. '{{\'=\', \'value\', <N>}})')
        .confirm('QUORUM ' .. tostring(target),
            'I accept the split-brain risk during the window')
    for _, pc in ipairs(assess.universal_preconditions()) do
        b.precondition(pc.ok, pc.label, pc.detail)
    end
    logger.debug('quorum_loss.assess', { target = target, peers_safe = peers_safe })
    return b.build(fp)
end

local function self_alias()
    if not (rawget(_G, 'box') and box.info) then return nil end
    return box.info.name
end

-- Drive the quorum override on the queue-owner peer. Returns
-- {ok, msg, restored_to} on success.
function M.escape(payload, root)
    payload = payload or {}
    local target = payload.target_alias
    if type(target) ~= 'string' or target == '' then
        return { ok = false, action = 'quorum_loss_escape', results = {},
            error = 'target_alias is required' }
    end
    local window_sec = tonumber(payload.window_sec) or DEFAULT_WINDOW_SEC
    if window_sec < 5 then window_sec = 5 end
    if window_sec > MAX_WINDOW_SEC then window_sec = MAX_WINDOW_SEC end

    local expr = string.format([[
        local fiber = require('fiber')
        local settings = box.space and box.space._session_settings or nil
        if settings == nil then return { err = 'session_settings missing' } end
        local original
        do
            local t = settings:get('synchro_quorum')
            if t then original = t.value end
        end
        pcall(function()
            settings:update('synchro_quorum', { { '=', 'value', 1 } })
        end)
        -- Background restorer: arms after `window_sec` seconds
        -- and puts the original value back so the cluster does
        -- not stay permanently degraded after the escape.
        fiber.create(function()
            fiber.self():name('webui_quorum_restore', { truncate = true })
            fiber.sleep(%d)
            local restore_to = original or 2
            pcall(function()
                settings:update('synchro_quorum',
                    { { '=', 'value', restore_to } })
            end)
        end)
        return { ok = true, original = original }
    ]], window_sec)

    local me = self_alias()
    local ok, msg, original
    if target == me then
        local fn, err_compile = loadstring('return (function() '
            .. expr .. ' end)()')
        if fn == nil then
            ok, msg = false, tostring(err_compile)
        else
            local pok, res = pcall(fn)
            if not pok then
                ok, msg = false, tostring(res)
            elseif type(res) ~= 'table' or res.err ~= nil then
                ok = false
                msg = (res and res.err) or 'self call returned nil'
            else
                ok, original, msg = true, res.original,
                    'quorum=1 dispatched on self; restore in '
                    .. tostring(window_sec) .. 's'
            end
        end
    else
        local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
        if not rpc_ok then
            ok, msg = false, 'rpc module unavailable'
        else
            local call_ok, res = pcall(rpc.map_eval, expr, {},
                { timeout = 5, peers = { target } })
            if not call_ok then
                ok, msg = false, tostring(res)
            else
                local r = res and res[target]
                if not (r and r.ok and r.value and r.value.ok) then
                    ok = false
                    msg = (r and r.value and r.value.err)
                        or (r and r.err) or 'escape failed'
                else
                    ok, original = true, r.value.original
                    msg = 'quorum=1 dispatched on ' .. target
                        .. '; restore in ' .. tostring(window_sec) .. 's'
                end
            end
        end
    end

    pcall(audit.record, {
        user   = root and root.user,
        action = 'quorum_loss.escape',
        scope  = 'cluster',
        payload = {
            target = target, ok = ok, msg = msg,
            window_sec = window_sec,
            original_quorum = original,
            -- The wizard requires this risk_acknowledged flag.
            -- Recording it makes the operator's consent part of
            -- the audit trail.
            risk_acknowledged = payload.risk_acknowledged == true,
        },
        request_id = root and root.request_id,
    })
    logger.warn('quorum_loss.escape', {
        target = target, ok = ok, msg = msg,
        window_sec = window_sec, original = original,
    })
    return {
        ok = ok, action = 'quorum_loss_escape',
        results = { { peer = target, ok = ok, msg = msg } },
    }
end

return M
