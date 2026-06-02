--
-- Role start sequence.
--
-- Called from M.apply on first boot and from M.apply after M.stop on
-- subsequent config rolls. The body follows the documented init
-- order:
--
--   1. validate-options-implicit (already done in M.validate)
--   2. configure logging
--   3. (metrics — landing in later task)
--   4. storage spaces + migrations
--   5. peer cookie
--   6. cluster.peers + rpc pool
--   7. cluster.state (implicit — module-local table)
--   8. background fibers (poller, issues, suggestions, retention,
--      notifications, failover)
--   9. HTTP server
--  10. on_shutdown hook
--
-- The 11 `webui_*_remote` net.box shims are installed between steps
-- 4 and 5 by lifecycle.remote_shims so the spaces they read exist
-- before any follower can call them.
--

local fiber              = require('fiber')

local log_util           = require('webui.log_util')
local version            = require('webui.version')
local http_srv           = require('webui.http.server')
local storage            = require('webui.storage.spaces')
local peer_cookie        = require('webui.cluster.peer_cookie')
local peers              = require('webui.cluster.peers')
local poller             = require('webui.cluster.poller')
local issues             = require('webui.cluster.issues')
local suggestions_engine = require('webui.cluster.suggestions')

local state              = require('webui.lifecycle.state')
local remote_shims       = require('webui.lifecycle.remote_shims')

local logger = log_util.with_tag('init')

local M = {}

function M.start(opts)
    require('checks')('?table')
    opts = opts or {}

    local STATE = state.STATE

    if STATE.status == 'starting' or STATE.status == 'ready' then
        logger.warn('start invoked while already running', {
            current_status = STATE.status,
        })
        return STATE.status == 'ready'
    end

    STATE.status = 'starting'
    STATE.config = opts
    STATE.instance = state.instance_alias()

    -- Reset the graceful-shutdown gate. A role reload (config change
    -- → stop() + start()) must not leave the registry in the
    -- `draining=true` state from the previous run; otherwise every
    -- request would 503 forever.
    local sh_ok, sh_mod = pcall(require, 'webui.http.shutdown')
    if sh_ok then sh_mod.reset() end

    state.configure_logging(opts)

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

    -- Install every `webui_*_remote` net.box receiver. See
    -- lifecycle/remote_shims.lua for the full inventory and the
    -- rationale for living in the global namespace.
    remote_shims.install()

    -- Step 5: peer cookie (system user `webui_peer` + per-instance
    -- secret persistence). Steps 3, 7, 8 land in subsequent tasks
    -- (metrics, cluster state, fibers).
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

    -- Step 9: HTTP server.
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

    -- Audit forwarders (Phase 4 Task 4.5). Opt-in side channels
    -- (syslog / file). Configured from
    -- `roles_cfg.webui.audit.forwarders`; absent → no-op.
    local fwd_ok, fwd_mod = pcall(require, 'webui.audit.forwarder')
    if fwd_ok then
        local audit_opts = (opts.audit and type(opts.audit) == 'table')
            and opts.audit or {}
        pcall(fwd_mod.configure, { forwarders = audit_opts.forwarders })
    end

    -- Failover-commands journal retention fiber (Task 5.13). Same
    -- shape as audit retention: leader-only, time-based prune,
    -- per-tick budget. Default 30 days. Roll forward gracefully
    -- when the module is missing during partial-image builds.
    do
        local cmds_ok, commands_mod = pcall(require, 'webui.failover.commands')
        if cmds_ok then
            local cfg = (opts.failover and opts.failover.commands_retention_days)
                or nil
            pcall(commands_mod.start_retention, {
                retention_days = cfg,
            })
        end
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

    -- Open-source supervised-failover agent + watcher. Opt-in via
    -- `roles_cfg.webui.failover.agent: true`. The wrapper refuses
    -- to start when `replication.failover` is not "off" — Tarantool
    -- raft would fight us over `box.cfg.read_only` otherwise.
    --
    -- Apply is re-entered on every `config:reload()`. When the
    -- operator flips agent: true → false (e.g. via setFailoverMode
    -- election / manual), STOP the running fibers before
    -- swallowing the new opts; otherwise the stale agent keeps
    -- coordinating against the new mode. Symmetric on the reverse
    -- transition: a previously-stopped agent must be re-started.
    local fo_ok, fo = pcall(require, 'webui.failover')
    if fo_ok then
        local fo_cfg = opts.failover or {}
        local want_agent = fo_cfg.agent == true
        if STATE.failover ~= nil and not want_agent then
            pcall(function() STATE.failover.stop() end)
            STATE.failover = nil
            logger.info('failover agent stopped via config reload',
                { reason = 'roles_cfg.webui.failover.agent != true' })
        end
        if want_agent and STATE.failover == nil then
            local fo_started, fo_err = fo.start(fo_cfg)
            if fo_started == true then
                STATE.failover = fo
            elseif fo_err ~= nil and fo_err ~= 'disabled' then
                logger.warn('failover agent not started',
                    { reason = fo_err })
            end
        end
    end

    local http_ok, http_err = http_srv.start({
        listen = opts.listen,
        allowed_origins = opts.allowed_origins,
        graphiql_enabled = opts.graphiql_enabled == true,
        console_enabled = opts.console_enabled == true,
        ws_allowed_origins = opts.ws_allowed_origins,
        role_status_provider = function() return state.status() end,
    })
    if not http_ok then
        STATE.status = 'uninitialized'
        STATE.started_at = nil
        STATE.config = nil
        logger.error('http server start failed', { err = http_err })
        return nil, http_err
    end

    STATE.status = 'ready'

    -- Tarantool 3.x calls the role's `stop` when the role is
    -- removed from the cluster config but does NOT guarantee it
    -- fires on process SIGTERM / SIGINT. Register an explicit
    -- `box.ctl.on_shutdown` so we get a chance to revoke the
    -- failover coordinator lease + drain HTTP in-flight before
    -- the process exits. Idempotent: STATE.shutdown_hook tracks
    -- whether we already registered (apply() runs once per role
    -- restart; without the guard a roll of the cluster config
    -- would queue multiple hooks).
    if box.ctl ~= nil and box.ctl.on_shutdown ~= nil
            and not STATE.shutdown_hook_installed then
        local stop_mod = require('webui.lifecycle.stop')
        local ok = pcall(box.ctl.on_shutdown, function()
            local sok, serr = pcall(stop_mod.stop)
            if not sok then
                logger.warn('on_shutdown stop raised', { err = tostring(serr) })
            end
        end)
        if ok then
            STATE.shutdown_hook_installed = true
            logger.debug('on_shutdown hook installed')
        end
    end

    logger.info('webui role ready', { started_at = STATE.started_at })
    return true
end

return M
