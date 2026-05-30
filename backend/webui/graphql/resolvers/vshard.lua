--
-- Vshard read-only surface. The write side (set weight, lock,
-- start/stop rebalancer) goes through config two-phase commit
-- and lands in a follow-up task once map_call_routers is wired.
--
-- Task 47a additions:
--   * `vshardKnownGroups`   — names of vshard groups from cluster config.
--   * `canBootstrapVshard`  — preconditions check (router + storage present).
--   * `bootstrapVshard`     — invokes `vshard.router.bootstrap()` on a
--                             router instance. Mutation; admin only.
--

local fiber = require('fiber')

local rbac    = require('webui.auth.rbac')
local state   = require('webui.cluster.state')
local logger  = require('webui.log_util')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'viewer'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

-- Returns map of group_name -> { members={alias..}, alive={alias..} }
-- by walking `cfg:instances()` and intersecting with the live state
-- snapshot from peer_poller.
--
-- We can't distinguish router / storage roles without an RPC to each
-- peer (`config:get('sharding.roles')` is per-instance state). For the
-- initial cut, treat every reachable member as a candidate router and
-- storage. A follow-up will refine via the peer_poller adding a
-- `sharding.roles` field per server.
local function inspect_groups()
    local cfg = require('config')
    local snap = state.snapshot() or {}
    local servers = snap.servers or {}

    local instances_ok, instances = pcall(function() return cfg:instances() end)
    if not instances_ok or type(instances) ~= 'table' then
        return {}
    end

    local groups = {}
    for alias, info in pairs(instances) do
        local gname = info.group_name or 'default'
        local g = groups[gname]
        if g == nil then
            g = { members = {}, alive = {} }
            groups[gname] = g
        end
        table.insert(g.members, alias)
        local srv = servers[alias]
        if srv and srv.reachable then table.insert(g.alive, alias) end
    end

    -- For now router/storage classification mirrors `members` /
    -- `alive`. When the poller exposes sharding.roles, swap these
    -- two lists for the filtered ones.
    for _, g in pairs(groups) do
        g.routers        = g.members
        g.storages       = g.members
        g.routers_alive  = g.alive
        g.storages_alive = g.alive
    end

    return groups
end

function M.query_vshard(root)
    require_role(root, 'cluster')
    local snap = state.snapshot() or {}
    local groups = {}
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

function M.query_known_groups(root)
    require_role(root, 'cluster')
    local out = {}
    for name in pairs(inspect_groups()) do
        table.insert(out, name)
    end
    table.sort(out)
    return { groups = out }
end

function M.query_can_bootstrap(root, args)
    require_role(root, 'cluster')
    local target = args and args.group or 'default'
    local groups = inspect_groups()
    local g = groups[target]
    local reasons = {}
    if g == nil then
        table.insert(reasons, 'group not found in cluster config')
        return { ok = false, group = target, reasons = reasons }
    end
    if #g.routers == 0 then
        table.insert(reasons, 'no router instances declared in group')
    elseif #g.routers_alive == 0 then
        table.insert(reasons, 'no router instances reachable')
    end
    if #g.storages == 0 then
        table.insert(reasons, 'no storage instances declared in group')
    elseif #g.storages_alive == 0 then
        table.insert(reasons, 'no storage instances reachable')
    end
    return {
        ok      = (#reasons == 0),
        group   = target,
        reasons = reasons,
    }
end

-- Mutation: invoke vshard.router.bootstrap() on a router instance
-- within the requested group. Returns the chosen router alias plus
-- the call result so the UI can render a friendly outcome.
function M.mutation_bootstrap(root, args)
    require_role(root, 'setVshardGroup')
    local target = args and args.group or 'default'
    local groups = inspect_groups()
    local g = groups[target]
    if g == nil then
        error('VSHARD_GROUP_NOT_FOUND: ' .. target)
    end
    if #g.routers_alive == 0 then
        error('NO_ROUTER_REACHABLE: cannot bootstrap group ' .. target)
    end

    local router_alias = g.routers_alive[1]
    logger.info('vshard bootstrap requested', {
        group = target, router = router_alias,
    })

    -- Local router? Use direct module call. Remote? RPC via peer pool.
    local peers_ok, peers = pcall(require, 'webui.cluster.peers')
    local self_alias = peers_ok and peers.self_alias() or nil
    local started = fiber.time()
    local ok, result

    if peers_ok and router_alias ~= self_alias then
        local peer = peers.get(router_alias)
        local conn = peer and peer.conn
        if conn == nil then
            ok = false
            result = 'PEER_UNAVAILABLE: no net.box connection to ' .. router_alias
        else
            ok, result = pcall(conn.call, conn,
                'webui_vshard_bootstrap_local', { target }, { timeout = 30 })
        end
    else
        local vshard_ok, vshard = pcall(require, 'vshard')
        if not vshard_ok or vshard.router == nil then
            ok = false
            result = 'VSHARD_NOT_AVAILABLE: vshard module missing on ' .. router_alias
        else
            ok, result = pcall(vshard.router.bootstrap, { timeout = 30 })
        end
    end
    local latency_ms = (fiber.time() - started) * 1000

    if not ok then
        logger.warn('vshard bootstrap failed', {
            group = target, router = router_alias, err = tostring(result),
        })
        return {
            ok         = false,
            group      = target,
            router     = router_alias,
            latency_ms = latency_ms,
            message    = tostring(result),
        }
    end

    logger.info('vshard bootstrap ok', { group = target, router = router_alias })
    return {
        ok         = true,
        group      = target,
        router     = router_alias,
        latency_ms = latency_ms,
        message    = box.NULL,
    }
end

-- Stub remote function callable from peer connections. The
-- mutation above tries to call this on the chosen router instance
-- via net.box. It throws on failure so the calling pcall can
-- collect the message; otherwise the resolver would only see the
-- first return (nil) and report a false-positive success.
--
-- RBAC at the HTTP edge already filtered the caller to `admin`
-- before we reached this code path, and net.box auth happens with
-- the `webui_peer` system account, so direct calls from outside
-- the cluster cannot reach this function.
function M.install_remote()
    rawset(_G, 'webui_vshard_bootstrap_local', function(_group)
        local vshard_ok, vshard = pcall(require, 'vshard')
        if not vshard_ok or vshard.router == nil then
            error('VSHARD_NOT_AVAILABLE', 0)
        end
        local ok, result = pcall(vshard.router.bootstrap, { timeout = 30 })
        if not ok then error(tostring(result), 0) end
        return result == nil and true or result
    end)
end

return M
