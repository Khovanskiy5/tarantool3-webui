--
-- Vshard read-only surface. The write side (set weight, lock,
-- start/stop rebalancer) goes through config two-phase commit
-- and lands in a follow-up task once map_call_routers is wired.
--

local rbac = require('webui.auth.rbac')
local state = require('webui.cluster.state')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'viewer'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

function M.query_vshard(root)
    require_role(root, 'cluster')
    local snap = state.snapshot() or {}
    local groups = {}
    -- We project whatever the cluster.state poller managed to
    -- collect from `vshard.router.info()` on instances flagged
    -- with `config:is_router()`. Until that wiring lands, return
    -- an empty list — the SPA renders an empty state cleanly.
    local sharding = snap.sharding or {}
    for name, info in pairs(sharding.groups or {}) do
        table.insert(groups, {
            name = name,
            total_buckets = info.total_buckets,
            distribution  = info.distribution,
            rebalancer    = info.rebalancer_state,
            status        = info.status or 'unknown',
        })
    end
    return { groups = groups }
end

return M
