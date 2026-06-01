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
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.takeover')

local M = {}

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
