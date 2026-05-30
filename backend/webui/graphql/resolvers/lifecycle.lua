--
-- Lifecycle GraphQL surface.
--
--   * probeUri(uri)         — net.box probe a foreign Tarantool.
--   * forceReapplyConfig    — `config:reload()` on selected peers.
--   * reloadRoles           — re-applies role modules on peers.
--
-- These mutations dispatch through `cluster.rpc.map_call`, which
-- preserves the role's "no net.box on TX-thread" invariant by
-- routing through the peer pool's fiber-backed dispatcher.
--

local netbox = require('net.box')
local fiber  = require('fiber')

local rbac = require('webui.auth.rbac')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('graphql.lifecycle')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

-- ── probeUri ────────────────────────────────────────────────────────

-- Pure helper for tests: extracts the fields we want from
-- `box.info` while protecting against `nil` deep paths.
function M.shape_box_info(info)
    if type(info) ~= 'table' then return {} end
    return {
        tarantool_version = info.version,
        cluster_uuid      = info.cluster and info.cluster.uuid or info.cluster_uuid,
        instance_uuid     = info.uuid,
        ro                = info.ro,
        ro_reason         = info.ro_reason,
    }
end

function M.mutation_probe_uri(root, args)
    require_role(root, 'probeUri')
    if type(args.uri) ~= 'string' or args.uri == '' then
        error('INVALID_QUERY: uri is required')
    end
    local started = fiber.time()
    local out = { reachable = false, latency_ms = 0 }
    local conn
    local ok = pcall(function()
        conn = netbox.connect(args.uri, { connect_timeout = 3 })
        if conn:wait_connected(3) then
            out.reachable = true
            local info_ok, info = pcall(function()
                return conn:eval('return box.info', {}, { timeout = 2 })
            end)
            if info_ok then
                local shaped = M.shape_box_info(info)
                for k, v in pairs(shaped) do out[k] = v end
            end
        end
    end)
    pcall(function() if conn then conn:close() end end)
    out.latency_ms = math.floor((fiber.time() - started) * 1000)
    if not ok then out.reachable = false end
    logger.info('probe uri', {
        uri = args.uri, ok = out.reachable,
        latency_ms = out.latency_ms, user = root and root.user,
    })
    return out
end

-- ── force-reapply ───────────────────────────────────────────────────

local function rpc_call_each(peer_uuids, action_name, action_body)
    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    if not rpc_ok or type(rpc.map_call) ~= 'function' then
        -- No peer pool yet — fall back to local call.
        local ok, err = pcall(action_body)
        return { { instance = 'self', ok = ok, err = tostring(err) } }
    end
    local results = rpc.map_call(action_name, peer_uuids, {}, { timeout = 10 })
    if type(results) ~= 'table' then return {} end
    local out = {}
    for instance, res in pairs(results) do
        table.insert(out, {
            instance = instance,
            ok = res and res.ok or false,
            err = res and res.err or nil,
        })
    end
    return out
end

function M.mutation_force_reapply(root, args)
    require_role(root, 'forceReapplyConfig')
    local results = rpc_call_each(args.instances or {}, 'webui.config.reload', function()
        local config = require('config')
        config:reload()
        return true
    end)
    return { results = results }
end

function M.mutation_reload_roles(root, args)
    require_role(root, 'reloadRoles')
    -- Tarantool 3.x re-applies role modules on config:reload(); the
    -- explicit reload mirrors `tt cluster reload` for operator UX.
    return M.mutation_force_reapply(root, args)
end

return M
