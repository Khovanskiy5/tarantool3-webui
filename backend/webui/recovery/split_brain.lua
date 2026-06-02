--
-- Split-brain resolution dispatcher (Phase 6 Task DR-1).
--
-- Three action options:
--
--   * `manual` — write `split_brain.manual_chosen` to audit and
--     close. The operator commits to fixing it via docker exec.
--
--   * `rebootstrap_losing` — wipe WAL+snap on every losing peer
--     so it bootstraps fresh from the winner. Uses the existing
--     `webui_rebootstrap_remote` global (registered by Phase 5).
--     Self-loop is honoured: if THE current instance is in the
--     losing set, we call the global directly rather than going
--     through rpc.map_eval (which excludes self).
--
--   * `force_promote_winner` — flip `_session_settings
--     .synchro_quorum` to 1 briefly, call box.ctl.promote on the
--     winner via net.box, restore the original quorum. Pushes
--     the writer term forward so applier-stopped losers can
--     legitimately bootstrap on the next reconnect.
--

local audit = require('webui.audit.log')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.split_brain')

local M = {}

local function find_rpc_module()
    local ok, rpc = pcall(require, 'webui.cluster.rpc')
    if not ok then return nil end
    return rpc
end

local function self_alias()
    if not (rawget(_G, 'box') and box.info) then return nil end
    return box.info.name
end

-- Call `webui_rebootstrap_remote` either via net.box (foreign
-- peer) or directly (self). Returns (ok, message_or_err).
function M.rebootstrap_one(alias)
    local me = self_alias()
    if alias == me then
        local fn = rawget(_G, 'webui_rebootstrap_remote')
        if type(fn) ~= 'function' then
            return false, 'no rebootstrap rpc on self'
        end
        local ok, res = pcall(fn)
        if not ok then return false, tostring(res) end
        if type(res) == 'table' and res.err ~= nil then
            return false, tostring(res.err)
        end
        return true, 'rebootstrap dispatched on self'
    end
    local rpc = find_rpc_module()
    if rpc == nil then return false, 'rpc module unavailable' end
    -- Use map_call (per-function privilege) instead of map_eval
    -- (universe execute) — the peer user `webui_peer` is granted
    -- EXECUTE on the named function only. map_eval over an
    -- arbitrary Lua string would require `execute on universe`
    -- which is intentionally withheld from peer users.
    local ok_call, res = pcall(rpc.map_call,
        'webui_rebootstrap_remote', {}, {
            timeout = 5, peers = { alias },
        })
    if not ok_call then return false, tostring(res) end
    if type(res) ~= 'table' or res[alias] == nil then
        return false, 'no response from ' .. alias
    end
    local r = res[alias]
    if not (r and r.ok) then
        return false, (r and r.err) or 'unknown error'
    end
    local v = r.value
    if type(v) == 'table' and v.err ~= nil then
        -- Surface the full message (e.g. "this instance owns the
        -- synchronous queue; promote another peer first") instead
        -- of the bare error code — the operator reads it from the
        -- last-action panel and needs the remediation hint.
        local msg = v.message and (tostring(v.err) .. ': ' .. tostring(v.message))
            or tostring(v.err)
        return false, msg
    end
    return true, 'rebootstrap dispatched on ' .. alias
end

-- Push synchro_quorum=1 transiently and promote the winner peer.
-- Used when the losing side cannot rebootstrap (e.g. operator
-- wants to recover writes ASAP and accept the divergent rows on
-- losers will get wiped on the next reconnect anyway).
function M.force_promote(winner_alias, opts)
    opts = opts or {}
    local rpc = find_rpc_module()
    if rpc == nil then return false, 'rpc module unavailable' end
    local me = self_alias()
    if winner_alias == me then
        -- Local promote: flip quorum, promote, restore.
        local settings = box.space and box.space._session_settings or nil
        if settings ~= nil then
            pcall(function()
                settings:update('synchro_quorum', { { '=', 'value', 1 } })
            end)
        end
        local ok, err = pcall(box.ctl.promote)
        if settings ~= nil then
            pcall(function()
                settings:update('synchro_quorum',
                    { { '=', 'value', tonumber(opts.original_quorum) or 2 } })
            end)
        end
        if not ok then return false, tostring(err) end
        return true, 'promote dispatched on self'
    end
    local expr = [[
        local prev
        local settings = box.space and box.space._session_settings or nil
        if settings ~= nil then
            local t = settings:get('synchro_quorum')
            if t then prev = t.value end
            pcall(function()
                settings:update('synchro_quorum', { { '=', 'value', 1 } })
            end)
        end
        local ok, err = pcall(box.ctl.promote)
        if settings ~= nil and prev then
            pcall(function()
                settings:update('synchro_quorum', { { '=', 'value', prev } })
            end)
        end
        return { ok = ok, err = err and tostring(err) or nil }
    ]]
    local ok_call, res = pcall(rpc.map_eval, expr, {},
        { timeout = 5, peers = { winner_alias } })
    if not ok_call then return false, tostring(res) end
    local r = res and res[winner_alias]
    if not (r and r.ok and r.value and r.value.ok) then
        return false, (r and r.value and r.value.err)
            or (r and r.err) or 'force_promote failed'
    end
    return true, 'promote dispatched on ' .. winner_alias
end

-- resolve(payload, root) → { ok, action, results: [{peer, ok, msg}] }
function M.resolve(payload, root)
    payload = payload or {}
    local action = payload.action
    local winner = payload.winner_alias
    local losers = payload.losing_aliases or {}
    local results = {}

    if action == 'manual' then
        pcall(audit.record, {
            user   = root and root.user,
            action = 'split_brain.manual_chosen',
            scope  = 'cluster',
            payload = { winner = winner, losers = losers },
            request_id = root and root.request_id,
        })
        return {
            ok = true, action = action,
            results = { { peer = '*', ok = true, msg = 'operator handles manually' } },
        }
    end

    if action == 'rebootstrap_losing' then
        if type(losers) ~= 'table' or #losers == 0 then
            return { ok = false, action = action,
                results = {}, error = 'losing_aliases is required' }
        end
        -- If any losing peer is the current synchro queue owner,
        -- rebootstrap_handler will reject it (would lose
        -- uncommitted synchro writes). Auto-promote the winner
        -- first to move ownership off the loser. The winner is
        -- required for this two-step path.
        local state = require('webui.cluster.state')
        local snap = state.snapshot() or {}
        local servers = snap.servers or {}
        local loser_owns_queue = false
        for _, peer in ipairs(losers) do
            local s = servers[peer]
            local info = s and s.box_info
            local syn = info and info.synchro
            if type(syn) == 'table' and type(syn.queue) == 'table'
                and syn.queue.owner == info.id then
                loser_owns_queue = true
            end
        end
        if loser_owns_queue then
            if type(winner) ~= 'string' or winner == '' then
                return { ok = false, action = action, results = {},
                    error = 'winner_alias is required to move queue '
                        .. 'ownership off a losing peer before rebootstrap' }
            end
            local pok, pmsg = M.force_promote(winner, payload)
            table.insert(results, {
                peer = winner, ok = pok,
                msg = 'pre-rebootstrap promote: ' .. tostring(pmsg),
            })
            if not pok then
                -- Bail out — rebootstrapping the loser without a
                -- new queue owner would just hit FORBIDDEN.
                return { ok = false, action = action, results = results,
                    error = 'pre-rebootstrap promote failed' }
            end
            -- Give the cluster a moment for the new owner to take
            -- effect before re-trying rebootstrap.
            require('fiber').sleep(1)
        end
        for _, peer in ipairs(losers) do
            local ok, msg = M.rebootstrap_one(peer)
            table.insert(results, { peer = peer, ok = ok, msg = msg })
        end
        pcall(audit.record, {
            user   = root and root.user,
            action = 'split_brain.rebootstrap',
            scope  = 'cluster',
            payload = { winner = winner, losers = losers, results = results },
            request_id = root and root.request_id,
        })
        local any_fail = false
        for _, r in ipairs(results) do
            if not r.ok then any_fail = true end
        end
        return { ok = not any_fail, action = action, results = results }
    end

    if action == 'force_promote_winner' then
        if type(winner) ~= 'string' or winner == '' then
            return { ok = false, action = action,
                results = {}, error = 'winner_alias is required' }
        end
        local ok, msg = M.force_promote(winner, payload)
        table.insert(results, { peer = winner, ok = ok, msg = msg })
        pcall(audit.record, {
            user   = root and root.user,
            action = 'split_brain.force_promote',
            scope  = 'cluster',
            payload = { winner = winner, ok = ok, msg = msg },
            request_id = root and root.request_id,
        })
        logger.info('split_brain.force_promote', {
            winner = winner, ok = ok, msg = msg,
        })
        return { ok = ok, action = action, results = results }
    end

    return { ok = false, action = action or 'unknown',
        results = {}, error = 'unsupported action' }
end

return M
