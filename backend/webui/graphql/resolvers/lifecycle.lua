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
    args = args or {}

    -- Optional revision: rollback to the named history snapshot
    -- BEFORE fanning out the reload. Composes through the existing
    -- rollbackConfig pipeline so the audit trail is identical
    -- (one `config.rollback` row plus the reload outcome below).
    --
    -- The two-step shape ("force apply revision N") is what the
    -- /config-history UI wants: pick a revision in the timeline,
    -- click "force apply", land the rollback + reload as a single
    -- operator action.
    local rollback_outcome = nil
    if args.revision ~= nil then
        local config_resolver = require('webui.graphql.resolvers.config')
        local ok, res = pcall(config_resolver.mutation_rollback, root, {
            revision = args.revision,
        })
        if not ok then
            -- Surface the typed error straight through — rollback already
            -- raised something like ROLLBACK_INCOMPATIBLE / REVISION_NOT_FOUND.
            error(tostring(res))
        end
        rollback_outcome = res
        -- After rollback the fan-out reload already ran on every peer
        -- — additional reload calls are redundant. Return the rollback
        -- outcome shaped to look like a force_reapply result.
        return {
            results = { {
                instance = 'cluster',
                ok = res and res.applied or false,
                err = nil,
            } },
            rollback_to       = args.revision,
            rollback_revision = res and res.revision or nil,
            rollback_message  = res and res.message or nil,
        }
    end

    local results = rpc_call_each(args.instances or {}, 'webui.config.reload', function()
        local config = require('config')
        config:reload()
        return true
    end)
    pcall(function()
        require('webui.notifications').emit({
            type     = 'config.reloaded',
            severity = 'info',
            scope    = table.concat(args.instances or { '*' }, ','),
            category = 'config',
            user     = root and root.user,
            message  = 'config:reload() invoked on '
                .. tostring(#(args.instances or {})) .. ' instance(s)',
        })
    end)
    return { results = results }
end

function M.mutation_reload_roles(root, args)
    require_role(root, 'reloadRoles')
    -- Tarantool 3.x re-applies role modules on config:reload(); the
    -- explicit reload mirrors `tt cluster reload` for operator UX.
    return M.mutation_force_reapply(root, args)
end

-- rebootstrapInstance(alias) — destructive recovery for a single
-- follower stuck in split-brain. Routes through the peer net.box
-- pool to the named alias, calls the `webui_rebootstrap_remote`
-- shim there. The target wipes its WAL/snap and exits; Docker
-- restart policy spins up a fresh process that bootstraps clean
-- from healthy peers. The endpoint refuses to act on the synchro
-- queue owner (would lose uncommitted txns) — operators promote
-- another peer first.
function M.mutation_rebootstrap_instance(root, args)
    require_role(root, 'rebootstrapInstance')
    if args == nil or type(args.alias) ~= 'string' or args.alias == '' then
        error('VALIDATION_ERROR: alias is required')
    end
    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    if not rpc_ok then
        error('UNAVAILABLE: peer pool not ready')
    end
    local results, call_err = pcall(rpc.map_call,
        'webui_rebootstrap_remote', {}, {
            timeout = 5,
            peers   = { args.alias },
        })
    if not results then
        error('UNAVAILABLE: rebootstrap call failed: ' .. tostring(call_err))
    end
    local per_peer = call_err
    if type(per_peer) ~= 'table' or per_peer[args.alias] == nil then
        error('NOT_FOUND: peer ' .. args.alias .. ' is not in the pool')
    end
    local r = per_peer[args.alias]
    if not (r and r.ok) then
        local peer_err = (r and r.err) or 'unknown'
        error('UNAVAILABLE: rebootstrap on ' .. args.alias ..
            ' failed: ' .. tostring(peer_err))
    end
    local v = r.value or {}
    -- Backend shim returns {err, message, status} when target refused
    -- (e.g. tried to wipe the queue owner). Surface the typed code
    -- straight through.
    if v.err then
        if v.err == 'FORBIDDEN' then
            error('FORBIDDEN: ' .. tostring(v.message
                or 'queue owner refused rebootstrap'))
        end
        error('UNAVAILABLE: ' .. tostring(v.message or v.err))
    end
    logger.warn('rebootstrap dispatched', {
        target_alias = args.alias,
        deleted_count = v.deleted_count,
        user = root and root.user,
    })
    return {
        ok = v.ok == true,
        alias = args.alias,
        deleted_count = tonumber(v.deleted_count) or 0,
        message = v.message or 'rebootstrap initiated',
    }
end

return M
