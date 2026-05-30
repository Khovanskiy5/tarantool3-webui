-- WebUI role entry point.
--
-- Implements both the explicit start()/stop()/status() trio (used by
-- tests and standalone scripts) and the declarative Tarantool 3.x role
-- interface validate()/apply()/stop(). On apply(), if the role is not
-- initialised yet, the lifecycle delegates to start(); otherwise the
-- current run is torn down and re-started with the new configuration.
--
-- The body of start() is deliberately minimal at this stage of M0.
-- Subsequent tasks register their sub-systems through the documented
-- initialisation order (see plan, contract "Lua module loading"):
--   1. validate options
--   2. configure logging
--   3. metrics registry
--   4. storage spaces + migrations
--   5. peer cookie
--   6. cluster.peers + rpc pool
--   7. cluster.state
--   8. background fibers
--   9. HTTP server
--  10. GraphQL server
--  11. WebSocket endpoint
--  12. broadcast webui.started

local checks = require('checks')
local fiber = require('fiber')

local log_util    = require('webui.log_util')
local version     = require('webui.version')
local http_srv    = require('webui.http.server')
local peer_cookie = require('webui.cluster.peer_cookie')
local peers       = require('webui.cluster.peers')
local poller      = require('webui.cluster.poller')
local issues      = require('webui.cluster.issues')
local suggestions_engine = require('webui.cluster.suggestions')

local logger = log_util.with_tag('init')

local M = {}

-- Module-local lifecycle state. Never global.
local STATE = {
    status = 'uninitialized',  -- uninitialized | starting | ready | stopping | stopped
    started_at = nil,
    config = nil,
    instance = nil,
}

local function instance_alias()
    if rawget(_G, 'box') == nil then
        return nil
    end
    -- box.info is a table even before box.cfg has run, but its fields
    -- (.name, .cluster.name) hold NULL cdata until bootstrap completes.
    -- Treat only proper strings as a valid alias.
    local ok, info = pcall(function() return box.info end)
    if not ok or type(info) ~= 'table' then
        return nil
    end
    if type(info.name) == 'string' and info.name ~= '' then
        return info.name
    end
    if type(info.cluster) == 'table'
        and type(info.cluster.name) == 'string'
        and info.cluster.name ~= '' then
        return info.cluster.name
    end
    return nil
end

local function configure_logging(opts)
    local explicit = opts.log_level
    local env_level = os.getenv('WEBUI_LOG_LEVEL')
    log_util.configure({
        level = explicit or env_level or 'debug',
        instance = instance_alias(),
    })
end

-- Declarative role interface (Tarantool 3.x): validate config.
-- Must be pure and side-effect-free. Returns true on success,
-- (nil, err) on rejection. Failure aborts apply() and is surfaced
-- via config:info().alerts.
function M.validate(cfg)
    checks('?table')
    cfg = cfg or {}

    local ok, err = version.check_tarantool()
    if not ok then
        return nil, err
    end

    if cfg.listen ~= nil and type(cfg.listen) ~= 'string' then
        return nil, 'roles_cfg.webui.listen must be a string'
    end
    if cfg.log_level ~= nil and type(cfg.log_level) ~= 'string' then
        return nil, 'roles_cfg.webui.log_level must be a string'
    end
    if cfg.console_enabled ~= nil and type(cfg.console_enabled) ~= 'boolean' then
        return nil, 'roles_cfg.webui.console_enabled must be a boolean'
    end
    if cfg.graphiql_enabled ~= nil and type(cfg.graphiql_enabled) ~= 'boolean' then
        return nil, 'roles_cfg.webui.graphiql_enabled must be a boolean'
    end

    return true
end

-- Declarative role interface (Tarantool 3.x): apply config.
-- Called once on initial bootstrap and again on every cluster config
-- change that touches roles_cfg.webui. Internally re-routes to start()
-- or to a stop()/start() cycle.
function M.apply(cfg)
    checks('?table')
    cfg = cfg or {}

    configure_logging(cfg)
    logger.debug('apply requested', {
        first_apply = (STATE.status == 'uninitialized'),
        current_status = STATE.status,
    })

    if STATE.status == 'uninitialized' or STATE.status == 'stopped' then
        return M.start(cfg)
    end

    local ok, err = M.stop()
    if not ok then
        return nil, err
    end
    return M.start(cfg)
end

function M.start(opts)
    checks('?table')
    opts = opts or {}

    if STATE.status == 'starting' or STATE.status == 'ready' then
        logger.warn('start invoked while already running', {
            current_status = STATE.status,
        })
        return STATE.status == 'ready'
    end

    STATE.status = 'starting'
    STATE.config = opts
    STATE.instance = instance_alias()

    configure_logging(opts)

    logger.info('webui role starting', {
        version = version.SEMVER,
        tarantool = _TARANTOOL,
        instance = STATE.instance,
        log_level = log_util.current_level(),
    })

    local compat, err = version.check_tarantool()
    if not compat then
        STATE.status = 'uninitialized'
        STATE.config = nil
        logger.error('Tarantool version check failed', { err = err })
        return nil, err
    end

    logger.debug('configuration accepted', {
        listen = opts.listen,
        console_enabled = opts.console_enabled,
        graphiql_enabled = opts.graphiql_enabled,
    })

    -- Step 5 in the role start sequence: peer cookie (system user
    -- `webui_peer` + per-instance secret persistence). Steps 3, 4,
    -- 7, 8 land in subsequent tasks (metrics, storage, cluster
    -- state, fibers).
    --
    -- Production source of truth for the peer secret is the cluster
    -- config (`credentials.users.webui_peer.password`); look it up
    -- now so peer_cookie sees the canonical value and the pool can
    -- authenticate against peers immediately. Falling back to
    -- `opts.peer_password` keeps standalone scripts working without
    -- a declarative config.
    local cluster_password
    do
        local cfg_ok, cfg = pcall(require, 'config')
        if cfg_ok then
            local got_ok, value = pcall(function()
                return cfg:get('credentials.users.webui_peer.password')
            end)
            if got_ok and type(value) == 'string' and value ~= '' then
                cluster_password = value
            end
        end
    end

    local pc_ok, pc_result = pcall(peer_cookie.bootstrap, {
        config_password = opts.peer_password or cluster_password,
    })
    if not pc_ok then
        STATE.status = 'uninitialized'
        STATE.config = nil
        logger.error('peer cookie bootstrap failed', { err = tostring(pc_result) })
        return nil, 'peer cookie bootstrap failed: ' .. tostring(pc_result)
    end
    logger.debug('peer cookie ready', {
        user    = pc_result.user,
        source  = pc_result.source,
        created = pc_result.created,
    })

    -- Step 6: peer pool. Bind the credential resolved at step 5
    -- (cluster config wins, then env, then ad-hoc generated) and
    -- refresh the connection map from the current cluster config.
    -- The pool fans out via cluster.rpc.map_call; the poller
    -- (Task 17) will re-call peers.refresh() on every
    -- `box.watch('config.info', ...)` event to track config rolls.
    -- We never let pool errors abort role start — if the config is
    -- not ready yet or the local instance is the only one defined,
    -- we still want HTTP / GraphQL up.
    local pool_password = opts.peer_password
        or cluster_password
        or os.getenv('TT_WEBUI_PEER_PASSWORD')
    peers.set_credential(pc_result.user, pool_password)
    local pp_ok, pp_err = pcall(peers.refresh)
    if not pp_ok then
        logger.warn('initial peer pool refresh failed', { err = tostring(pp_err) })
    end

    -- Step 7 + 8: cluster state cache + peer poller fiber. The
    -- poller is the single producer; HTTP / GraphQL resolvers will
    -- read snapshots from cluster.state. Starting the fiber here
    -- (before HTTP) means the first GraphQL query never sees an
    -- empty state — the poller has had at least one immediate
    -- iteration via `box.watch('config.info', ...)` by the time the
    -- server accepts connections.
    local pl_ok, pl_err = pcall(poller.start)
    if not pl_ok then
        logger.warn('poller start failed', { err = tostring(pl_err) })
    end

    -- Step 8b: issues scanner. Pulled out of poller so the 5s
    -- cadence of human-facing diagnostics does not interfere with
    -- the 1.5s data-collection loop. Reads state.snapshot() under
    -- pcall — never blocks role start.
    local is_ok, is_err = pcall(issues.start)
    if not is_ok then
        logger.warn('issues scanner start failed', { err = tostring(is_err) })
    end

    -- Step 8c: suggestions engine. Same 5s cadence as the issues
    -- scanner, separate fiber so a slow detector cannot starve
    -- the other.
    local sg_ok, sg_err = pcall(suggestions_engine.start)
    if not sg_ok then
        logger.warn('suggestions scanner start failed', { err = tostring(sg_err) })
    end

    -- Step 9 in the role start sequence: HTTP server.
    STATE.started_at = fiber.time()

    local http_ok, http_err = http_srv.start({
        listen = opts.listen,
        allowed_origins = opts.allowed_origins,
        graphiql_enabled = opts.graphiql_enabled == true,
        role_status_provider = function() return M.status() end,
    })
    if not http_ok then
        STATE.status = 'uninitialized'
        STATE.started_at = nil
        STATE.config = nil
        logger.error('http server start failed', { err = http_err })
        return nil, http_err
    end

    STATE.status = 'ready'
    logger.info('webui role ready', { started_at = STATE.started_at })
    return true
end

function M.stop()
    if STATE.status == 'uninitialized' or STATE.status == 'stopped' then
        logger.debug('stop invoked while not running', {
            current_status = STATE.status,
        })
        return true
    end

    STATE.status = 'stopping'
    local uptime = STATE.started_at and (fiber.time() - STATE.started_at) or 0
    logger.info('webui role stopping', { uptime_sec = uptime })

    -- Graceful shutdown sequence is extended in Task 3a with WS connection
    -- close, etcd lock release and HTTP drain. For now we stop the server
    -- and the heartbeat fiber.
    local ok, err = pcall(function() http_srv.stop() end)
    if not ok then
        logger.error('http server stop raised', { err = tostring(err) })
    end

    -- Close every WebSocket subscriber with 1001 "Going Away"
    -- before stopping the producers. The shutdown call walks the
    -- registry and tells each per-connection fiber to drop. We
    -- swallow errors because the SPA is already disconnected
    -- by the time this runs in practice.
    local ws_ok_mod, ws_mod = pcall(require, 'webui.http.ws')
    if ws_ok_mod then pcall(function() ws_mod.shutdown() end) end

    -- Stop the suggestions scanner first — it reads state.snapshot()
    -- which the poller produces.
    local sg_ok, sg_err = pcall(function() suggestions_engine.stop() end)
    if not sg_ok then
        logger.warn('suggestions stop raised', { err = tostring(sg_err) })
    end

    -- Stop the issues scanner — same dependency as above.
    local is_ok, is_err = pcall(function() issues.stop() end)
    if not is_ok then
        logger.warn('issues stop raised', { err = tostring(is_err) })
    end

    -- Stop the poller before closing the pool: in-flight ticks
    -- still want to read connection state. The cluster.state cache
    -- itself does not need teardown — module-local tables are GC'd
    -- when require() drops them.
    local pl_ok, pl_err = pcall(function() poller.stop() end)
    if not pl_ok then
        logger.warn('poller stop raised', { err = tostring(pl_err) })
    end

    -- Close every outbound net.box connection before declaring stop.
    -- pcall protects against partial init paths where peers was
    -- imported but never refresh()'ed.
    local pp_ok, pp_err = pcall(function() peers.close_all() end)
    if not pp_ok then
        logger.warn('peer pool close raised', { err = tostring(pp_err) })
    end

    STATE.status = 'stopped'
    STATE.started_at = nil
    STATE.config = nil

    logger.info('webui role stopped')
    return true
end

function M.status()
    local started = STATE.started_at
    return {
        state = STATE.status,
        version = version.SEMVER,
        tarantool = _TARANTOOL,
        instance = STATE.instance,
        started_at = started,
        uptime_sec = started and (fiber.time() - started) or 0,
        log_level = log_util.current_level(),
    }
end

return M
