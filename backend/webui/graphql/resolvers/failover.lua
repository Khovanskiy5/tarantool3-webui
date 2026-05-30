--
-- Failover surface — read-only summary plus a `setLeader` stub
-- that defers to the config two-phase commit when wired.
--

local rbac = require('webui.auth.rbac')
local state = require('webui.cluster.state')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

function M.query_failover(root)
    require_role(root, 'failover')
    local snap = state.snapshot() or {}
    -- The election state lives on every server's `box.info.election`
    -- snapshot that peer_poller carries into state.snapshot().
    local elections = {}
    for alias, srv in pairs(snap.servers or {}) do
        if srv.election ~= nil then
            table.insert(elections, {
                instance = alias,
                state    = srv.election.state,
                term     = srv.election.term,
                leader_uuid = srv.election.leader_uuid,
            })
        end
    end
    return {
        mode      = snap.failover_mode or 'election',
        elections = elections,
    }
end

return M
