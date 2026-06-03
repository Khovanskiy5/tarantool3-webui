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

-- Bring the state-reporter fiber up or down based on the live
-- `roles_cfg.webui.state_reporter` block. Re-entrant: handles
-- enabled: true ↔ false transitions on every config:reload() the same
-- way the failover-agent block does.
local function reconcile_state_reporter(STATE, opts)
    local sr_ok, sr_mod = pcall(require, 'webui.cluster.self_reporter')
    if not sr_ok then return end
    local sr_cfg = opts.state_reporter or {}
    local want_sr = sr_cfg.enabled == true
    if STATE.state_reporter ~= nil and not want_sr then
        pcall(function() STATE.state_reporter.stop() end)
        STATE.state_reporter = nil
        logger.info('state reporter stopped via config reload',
            { reason = 'roles_cfg.webui.state_reporter.enabled != true' })
    end
    if want_sr and STATE.state_reporter == nil then
        local sr_started, sr_err = sr_mod.start(sr_cfg)
        if sr_started == true then
            STATE.state_reporter = sr_mod
        elseif sr_err ~= nil and sr_err ~= 'disabled' then
            logger.warn('state reporter not started',
                { reason = sr_err })
        end
    end
end

-- Stable fingerprint of the scalar failover opts, so a config reload
-- can tell whether the agent's tunables actually changed and only then
-- live-reconfigure it (avoiding needless churn when nothing changed).
local function failover_opts_fingerprint(cfg)
    cfg = cfg or {}
    local keys = {}
    for k, v in pairs(cfg) do
        local tv = type(v)
        if tv == 'string' or tv == 'number' or tv == 'boolean' then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. '=' .. tostring(cfg[k])
    end
    return table.concat(parts, ';')
end

-- Step 4: internal storage spaces (`_webui_meta`, `_webui_sessions`,
-- `_webui_audit`). Created on the leader and replicated to followers;
-- idempotent and tolerant of the read-only state. Returns the bootstrap
-- result, or (nil, err) on a fatal failure.
local function init_storage()
    local sto_ok, sto_result = pcall(storage.bootstrap)
    if not sto_ok then
        logger.error('storage bootstrap failed', { err = tostring(sto_result) })
        return nil, 'storage bootstrap failed: ' .. tostring(sto_result)
    end
    if sto_result == nil then
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
    return sto_result
end

-- Step 5: peer cookie (system user `webui_peer` + per-instance secret).
-- Production source of truth for the peer secret is the cluster config
-- (`credentials.users.webui_peer.password`); fall back to
-- `opts.peer_password` so standalone scripts work without a declarative
-- config. Returns (pc_result, nil, cluster_password) on success or
-- (nil, err) on a fatal failure.
local function init_peer_credentials(opts)
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
        logger.error('peer cookie bootstrap failed', { err = tostring(pc_result) })
        return nil, 'peer cookie bootstrap failed: ' .. tostring(pc_result)
    end
    logger.debug('peer cookie ready', {
        user    = pc_result.user,
        source  = pc_result.source,
        created = pc_result.created,
    })
    return pc_result, nil, cluster_password
end

-- Step 6: peer pool. Bind the credential resolved at step 5 (cluster
-- config wins, then env, then ad-hoc generated) and refresh the
-- connection map. Never aborts role start — if the config is not ready
-- yet we still want HTTP / GraphQL up.
local function init_peer_pool(pc_result, opts, cluster_password)
    local pool_password = opts.peer_password
        or cluster_password
        or os.getenv('TT_WEBUI_PEER_PASSWORD')
    peers.set_credential(pc_result.user, pool_password)
    local pp_ok, pp_err = pcall(peers.refresh)
    if not pp_ok then
        logger.warn('initial peer pool refresh failed', { err = tostring(pp_err) })
    end
end

-- Step 7 + 8: cluster state cache, peer poller, issues scanner,
-- suggestions engine, RBAC map, audit retention + forwarders, failover-
-- commands retention and the notifications dispatcher. All best-effort
-- (each pcall'd) so a single subsystem failing never aborts role start.
-- `STATE.started_at` is stamped here, before the HTTP server binds.
local function init_background_fibers(STATE, opts)
    local pl_ok, pl_err = pcall(poller.start)
    if not pl_ok then
        logger.warn('poller start failed', { err = tostring(pl_err) })
    end

    -- Issues scanner: separate fiber so its 5s human-facing cadence does
    -- not interfere with the poller's 1.5s data-collection loop.
    local is_ok, is_err = pcall(issues.start)
    if not is_ok then
        logger.warn('issues scanner start failed', { err = tostring(is_err) })
    end

    -- Suggestions engine: same 5s cadence, separate fiber so a slow
    -- detector cannot starve the other.
    local sg_ok, sg_err = pcall(suggestions_engine.start)
    if not sg_ok then
        logger.warn('suggestions scanner start failed', { err = tostring(sg_err) })
    end

    -- Stamp the start time before the HTTP server binds (Step 9).
    STATE.started_at = fiber.time()

    -- RBAC user→roles map from cluster config (Task 26).
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
    -- (syslog / file) from `roles_cfg.webui.audit.forwarders`.
    local fwd_ok, fwd_mod = pcall(require, 'webui.audit.forwarder')
    if fwd_ok then
        local audit_opts = (opts.audit and type(opts.audit) == 'table')
            and opts.audit or {}
        pcall(fwd_mod.configure, { forwarders = audit_opts.forwarders })
    end

    -- Failover-commands journal retention fiber (Task 5.13).
    local cmds_ok, commands_mod = pcall(require, 'webui.failover.commands')
    if cmds_ok then
        local cfg = (opts.failover and opts.failover.commands_retention_days)
            or nil
        pcall(commands_mod.start_retention, {
            retention_days = cfg,
        })
    end

    -- Outbound notifications dispatcher (Task 53a). The fiber runs only
    -- on the leader; configure() refreshes the webhook list on every
    -- role apply.
    local notif_ok, notif = pcall(require, 'webui.notifications')
    if notif_ok then
        local _, n_err = pcall(notif.configure, { webhooks = opts.webhooks or {} })
        if n_err ~= nil then
            logger.warn('notifications configure raised', { err = tostring(n_err) })
        end
        pcall(notif.start)
        STATE.notifications = notif
    end
end

-- Open-source supervised-failover agent + watcher. Opt-in via
-- `roles_cfg.webui.failover.agent: true`. Re-entered on every
-- `config:reload()`: flips the agent up/down on the agent-toggle
-- transition and live-reconfigures it when only the tunables changed.
local function init_failover_agent(STATE, opts)
    local fo_ok, fo = pcall(require, 'webui.failover')
    if not fo_ok then return end

    local fo_cfg = opts.failover or {}
    local want_agent = fo_cfg.agent == true
    local fp = failover_opts_fingerprint(fo_cfg)
    if STATE.failover ~= nil and not want_agent then
        pcall(function() STATE.failover.stop() end)
        STATE.failover = nil
        STATE.failover_fp = nil
        logger.info('failover agent stopped via config reload',
            { reason = 'roles_cfg.webui.failover.agent != true' })
    end
    if want_agent and STATE.failover == nil then
        local fo_started, fo_err = fo.start(fo_cfg)
        if fo_started == true then
            STATE.failover = fo
            STATE.failover_fp = fp
        elseif fo_err ~= nil and fo_err ~= 'disabled' then
            logger.warn('failover agent not started',
                { reason = fo_err })
        end
    elseif want_agent and STATE.failover ~= nil and STATE.failover_fp ~= fp then
        -- Tunables changed on reload — apply them live (no lease drop /
        -- re-election; only the dead-man watchdog restarts).
        local ok_rc = pcall(function() return fo.reconfigure(fo_cfg) end)
        STATE.failover_fp = fp
        logger.info('failover agent reconfigured via config reload',
            { applied = ok_rc })
    end
end

-- Step 10: register an explicit `box.ctl.on_shutdown` so the role gets a
-- chance to revoke the failover lease + drain HTTP before the process
-- exits (Tarantool does not guarantee `stop` fires on SIGTERM/SIGINT).
-- Idempotent: `STATE.shutdown_hook_installed` guards against queuing
-- multiple hooks across config rolls.
local function init_shutdown_hook(STATE)
    if box.ctl == nil or box.ctl.on_shutdown == nil
            or STATE.shutdown_hook_installed then
        return
    end
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

    local sto_result, sto_err = init_storage()
    if sto_result == nil then
        STATE.status = 'uninitialized'
        STATE.config = nil
        return nil, sto_err
    end

    -- Install every `webui_*_remote` net.box receiver between steps 4
    -- and 5 so the spaces they read exist before any follower calls them.
    remote_shims.install()

    local pc_result, pc_err, cluster_password = init_peer_credentials(opts)
    if pc_result == nil then
        STATE.status = 'uninitialized'
        STATE.config = nil
        return nil, pc_err
    end

    init_peer_pool(pc_result, opts, cluster_password)
    init_background_fibers(STATE, opts)

    -- Instance state reporter (open-source equivalent of the Enterprise
    -- top-level `stateboard.*` block). Opt-in via
    -- `roles_cfg.webui.state_reporter.enabled: true`.
    reconcile_state_reporter(STATE, opts)

    init_failover_agent(STATE, opts)

    -- Step 9: HTTP server.
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

    -- Step 10: on_shutdown hook (revoke failover lease + drain HTTP).
    init_shutdown_hook(STATE)

    logger.info('webui role ready', { started_at = STATE.started_at })
    return true
end

return M
