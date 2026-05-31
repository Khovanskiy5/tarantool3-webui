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
local storage     = require('webui.storage.spaces')
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
    if cfg.ws_allowed_origins ~= nil and type(cfg.ws_allowed_origins) ~= 'table' then
        return nil, 'roles_cfg.webui.ws_allowed_origins must be a list of strings'
    end
    if cfg.audit_retention_days ~= nil
        and (type(cfg.audit_retention_days) ~= 'number'
        or cfg.audit_retention_days < 1) then
        return nil, 'roles_cfg.webui.audit_retention_days must be a positive number'
    end
    if cfg.shutdown_timeout ~= nil
        and (type(cfg.shutdown_timeout) ~= 'number'
        or cfg.shutdown_timeout < 0) then
        return nil, 'roles_cfg.webui.shutdown_timeout must be a non-negative number'
    end
    local notif_ok, notif = pcall(require, 'webui.notifications')
    if notif_ok then
        local _, n_err = notif.validate(cfg)
        if n_err ~= nil then return nil, n_err end
    end
    if cfg.rbac ~= nil then
        if type(cfg.rbac) ~= 'table' then
            return nil, 'roles_cfg.webui.rbac must be a table'
        end
        if cfg.rbac.users ~= nil and type(cfg.rbac.users) ~= 'table' then
            return nil, 'roles_cfg.webui.rbac.users must be a {user = [roles]} table'
        end
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

    -- Reset the graceful-shutdown gate. A role reload (config change
    -- → stop() + start()) must not leave the registry in the
    -- `draining=true` state from the previous run; otherwise every
    -- request would 503 forever.
    local sh_ok, sh_mod = pcall(require, 'webui.http.shutdown')
    if sh_ok then sh_mod.reset() end

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

    -- Step 4 in the role start sequence: internal storage spaces.
    -- `_webui_meta`, `_webui_sessions`, `_webui_audit` are created
    -- on the leader and replicate to followers. The call is
    -- idempotent and tolerant of the read-only state — peer_cookie
    -- below uses the same can_run_ddl gate.
    local sto_ok, sto_result = pcall(storage.bootstrap)
    if not sto_ok then
        STATE.status = 'uninitialized'
        STATE.config = nil
        logger.error('storage bootstrap failed', { err = tostring(sto_result) })
        return nil, 'storage bootstrap failed: ' .. tostring(sto_result)
    end
    if sto_result == nil then
        STATE.status = 'uninitialized'
        STATE.config = nil
        logger.error('storage bootstrap returned nil; treating as fatal')
        return nil, 'storage bootstrap returned nil'
    end
    logger.debug('storage ready', {
        schema_version    = sto_result.schema_version,
        created_meta      = sto_result.created_meta,
        created_sessions  = sto_result.created_sessions,
        created_audit     = sto_result.created_audit,
        deferred          = sto_result.deferred,
    })

    -- Expose the leader-only session creator over net.box so
    -- followers can forward `/api/auth/login` writes. Safe to call
    -- on every instance — only the leader's INSERT actually
    -- succeeds; followers raise READONLY locally.
    local sess_remote_ok, sess_mod = pcall(require, 'webui.auth.session')
    if sess_remote_ok and type(sess_mod.install_remote) == 'function' then
        sess_mod.install_remote()
    end

    -- Expose the vshard bootstrap helper over net.box for the same
    -- reason: when the SPA calls `bootstrapVshard(group)` from a
    -- follower, the resolver routes the call to a router-flagged
    -- peer via this function.
    local vsh_ok, vsh_mod = pcall(require, 'webui.graphql.resolvers.vshard')
    if vsh_ok and type(vsh_mod.install_remote) == 'function' then
        vsh_mod.install_remote()
    end

    -- Expose the audit-log writer over net.box so a follower can
    -- forward `_webui_audit` inserts to the leader (the space is
    -- replicated; direct insert on a follower raises READONLY).
    -- The local M.record falls back to this when box.info.ro is
    -- true; here we wire the receiver side.
    rawset(_G, 'webui_audit_record_remote', function(entry)
        local ok_aud, aud_mod = pcall(require, 'webui.audit.log')
        if not ok_aud then return nil, 'audit module unavailable' end
        local ok, res = pcall(aud_mod.record_local, entry)
        if not ok then return nil, tostring(res) end
        if res == nil then return nil, 'insert returned nil' end
        return { id = res.id, ts = res.ts, action = res.action }
    end)

    -- Expose the dead-letter truncate over net.box. clearDeadLetter
    -- from the SPA lands on a random instance through round-robin;
    -- the leader is the only one that can actually truncate the
    -- replicated `_webui_webhook_dead_letter` space.
    rawset(_G, 'webui_webhook_dead_letter_clear_remote', function()
        local ok_sto, sto_mod = pcall(require, 'webui.storage.spaces')
        if not ok_sto then return nil, 'storage module unavailable' end
        local space = sto_mod.webhook_dead_letter()
        if space == nil then return nil, 'dead-letter space missing' end
        local count = space:count() or 0
        local ok, err = pcall(function() space:truncate() end)
        if not ok then return nil, tostring(err) end
        return { cleared = count }
    end)

    -- Step 5 in the role start sequence: peer cookie (system user
    -- `webui_peer` + per-instance secret persistence). Steps 3,
    -- 7, 8 land in subsequent tasks (metrics, cluster state,
    -- fibers).
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

    -- RBAC user→roles map from cluster config (Task 26). The map
    -- lives next to the rest of the role config so operators can
    -- promote/demote without touching code.
    if type(opts.rbac) == 'table' and type(opts.rbac.users) == 'table' then
        local rbac_ok, rbac = pcall(require, 'webui.auth.rbac')
        if rbac_ok then rbac.set_user_roles(opts.rbac.users) end
    end

    -- Audit-log retention fiber (Task 27).
    local retention_ok, retention = pcall(require, 'webui.audit.retention')
    if retention_ok then
        local r_ok, r_err = pcall(retention.start, {
            retention_days = opts.audit_retention_days,
        })
        if not r_ok then
            logger.warn('audit retention failed to start', {
                err = tostring(r_err),
            })
        end
        STATE.audit_retention = retention
    end

    -- Outbound notifications dispatcher (Task 53a). The fiber runs
    -- only on the leader; configure() refreshes the in-memory
    -- webhook list on every role apply (configuration change).
    local notif_ok, notif = pcall(require, 'webui.notifications')
    if notif_ok then
        local _, n_err = pcall(notif.configure, { webhooks = opts.webhooks or {} })
        if n_err ~= nil then
            logger.warn('notifications configure raised', { err = tostring(n_err) })
        end
        pcall(notif.start)
        STATE.notifications = notif
    end

    local http_ok, http_err = http_srv.start({
        listen = opts.listen,
        allowed_origins = opts.allowed_origins,
        graphiql_enabled = opts.graphiql_enabled == true,
        console_enabled = opts.console_enabled == true,
        ws_allowed_origins = opts.ws_allowed_origins,
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

    -- Phase 1: flip the drain gate. New HTTP requests get 503 +
    -- Retry-After (Task 3a). /api/health stays open so load
    -- balancers can confirm the `degraded`/`stopping` state.
    local sh_ok, shutdown_mod = pcall(require, 'webui.http.shutdown')
    if sh_ok then
        shutdown_mod.mark_draining()
        logger.info('shutdown: draining',
            { inflight = shutdown_mod.inflight_count() })
    end

    -- Phase 2: wait for in-flight HTTP requests to finish, bounded
    -- by `roles_cfg.webui.shutdown_timeout` (default 5s). The wait
    -- wakes up exactly when the last request releases its slot.
    --
    -- The default is intentionally well under Tarantool's own
    -- `on_shutdown` grace and docker's default 10s SIGTERM window:
    -- 5s drain + the remaining teardown (audit / poller / peer
    -- pool / WS close) fits comfortably under both. Operators can
    -- raise this for long-running internal handlers — but pair the
    -- bump with `docker stop -t <N>` / Tarantool's own
    -- `shutdown_timeout` so the role is not cut off mid-drain.
    local drain_timeout = 5
    if STATE.config ~= nil and type(STATE.config.shutdown_timeout) == 'number' then
        drain_timeout = STATE.config.shutdown_timeout
    end
    if sh_ok then
        local drained = shutdown_mod.wait_drain(drain_timeout)
        if drained then
            logger.info('shutdown: in-flight drained')
        else
            logger.warn('shutdown: drain timeout, forcing close', {
                inflight = shutdown_mod.inflight_count(),
                timeout_sec = drain_timeout,
            })
        end
    end

    -- Phase 3: stop accepting new connections.
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

    -- Stop the audit retention fiber.
    if STATE.audit_retention ~= nil then
        pcall(function() STATE.audit_retention.stop() end)
        STATE.audit_retention = nil
    end

    -- Stop the notifications dispatcher fiber.
    if STATE.notifications ~= nil then
        pcall(function() STATE.notifications.stop() end)
        STATE.notifications = nil
    end

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
