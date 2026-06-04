local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local ops = require('webui.recovery.ops')

local g = t.group('recovery.ops')

local function peer(o)
    local base = { alias = 'tt-1', reachable = true, role = 'follower',
        current_term = 5, queue_owner = false, vclock = { [1] = 10 } }
    for k, v in pairs(o or {}) do base[k] = v end
    return base
end

-- ── restart_replication ──────────────────────────────────────────────

g.test_restart_replication_safe_when_reachable = function()
    local snap = { peers = { peer({ alias = 'tt-1' }), peer({ alias = 'tt-2' }) } }
    local a = ops.assess_restart_replication({ instanceUuids = { 'u1' } }, nil, snap)
    t.assert_equals(a.risk, 'safe')
    t.assert_equals(a.confirm.required, false)
end

g.test_restart_replication_precondition_fails_when_unreachable = function()
    local snap = { peers = { peer({ alias = 'tt-1' }),
        peer({ alias = 'tt-2', reachable = false }) } }
    local a = ops.assess_restart_replication({}, nil, snap)
    local pc
    for _, p in ipairs(a.preconditions) do
        if p.label:find('reachable') then pc = p end
    end
    t.assert_equals(pc.ok, false)
end

-- ── restart_failover / force_apply ───────────────────────────────────

g.test_restart_failover_is_caution = function()
    local a = ops.assess_restart_failover({ instanceUuids = { 'u1' } },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'caution')
    t.assert_equals(a.autoSafe, true)
    t.assert_equals(a.dataLoss, false)
end

g.test_force_apply_is_caution = function()
    local a = ops.assess_force_apply({ instanceUuids = { 'u1' } },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'caution')
    t.assert_equals(a.dataLoss, false)
end

-- ── rebootstrap (delegates to orphan) ────────────────────────────────

g.test_rebootstrap_is_dangerous = function()
    local a = ops.assess_rebootstrap({ alias = 'tt-2' }, nil, { peers = {} })
    t.assert_equals(a.risk, 'dangerous')
    t.assert_equals(a.dataLoss, true)
    t.assert_equals(a.confirm.token, 'ORPHAN tt-2')
end

-- ── promote ──────────────────────────────────────────────────────────

g.test_promote_dominating_is_caution = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, queue_owner_id = 1,
               vclock = { [1] = 10 } }),
        peer({ alias = 'tt-2', vclock = { [1] = 10 } }),
    } }
    local a = ops.assess_promote({ alias = 'tt-2' }, nil, snap)
    t.assert_equals(a.risk, 'caution')
    t.assert_equals(a.dataLoss, false)
end

g.test_promote_lagging_is_dangerous = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, queue_owner_id = 1,
               vclock = { [1] = 10 } }),
        peer({ alias = 'tt-2', vclock = { [1] = 9 } }),
    } }
    local a = ops.assess_promote({ alias = 'tt-2' }, nil, snap)
    t.assert_equals(a.risk, 'dangerous')
    t.assert_equals(a.confirm.token, 'PROMOTE tt-2')
end

g.test_promote_force_inconsistency_is_dangerous = function()
    local a = ops.assess_promote({ alias = 'tt-2', force_inconsistency = true },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'dangerous')
    t.assert_equals(a.dataLoss, true)
    t.assert_equals(a.confirm.token, 'PROMOTE tt-2')
end

-- ── exec_restart_failover (RC-7) — fan-out via rpc.map_call ──────────

local function install_rpc(map_fn)
    package.loaded['webui.cluster.rpc'] = { map_call = map_fn }
end

g.after_each(function()
    package.loaded['webui.cluster.rpc'] = nil
end)

g.test_exec_restart_failover_requires_aliases = function()
    local res = ops.exec_restart_failover({})
    t.assert_equals(res.ok, false)
    t.assert_str_contains(res.error, 'aliases is required')
end

g.test_exec_restart_failover_ok_for_each_peer = function()
    install_rpc(function(_fn, _args, opts)
        local out = {}
        for _, alias in ipairs(opts.peers) do
            out[alias] = { ok = true, value = { ok = true } }
        end
        return out
    end)
    local res = ops.exec_restart_failover({ aliases = { 'tt-1', 'tt-2' } })
    t.assert_equals(res.ok, true)
    t.assert_equals(res.action, 'restart_failover')
    t.assert_equals(#res.results, 2)
    -- Result rows match the recoveryAction contract { peer, ok, msg }.
    t.assert_equals(res.results[1].peer, 'tt-1')
    t.assert_equals(res.results[1].ok, true)
    t.assert_str_contains(res.results[1].msg, 'restarted')
end

g.test_exec_restart_failover_accepts_single_alias = function()
    install_rpc(function(_fn, _args, opts)
        return { [opts.peers[1]] = { ok = true, value = { ok = true } } }
    end)
    local res = ops.exec_restart_failover({ alias = 'tt-3' })
    t.assert_equals(res.ok, true)
    t.assert_equals(res.results[1].peer, 'tt-3')
end

g.test_exec_restart_failover_surfaces_shim_error = function()
    install_rpc(function(_fn, _args, opts)
        local out = {}
        for _, alias in ipairs(opts.peers) do
            out[alias] = { ok = true, value = { ok = false, err = 'failover agent not enabled here' } }
        end
        return out
    end)
    local res = ops.exec_restart_failover({ aliases = { 'tt-3' } })
    t.assert_equals(res.ok, false)
    t.assert_equals(res.results[1].ok, false)
    t.assert_str_contains(res.results[1].msg, 'not enabled')
end
