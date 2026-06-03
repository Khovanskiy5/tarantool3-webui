--
-- Declarative role interface (Tarantool 3.x): validate config.
--
-- Pure and side-effect-free. Returns true on success, (nil, err)
-- on rejection. Failure aborts apply() and is surfaced via
-- config:info().alerts.
--
-- Logic preserved verbatim from the pre-split init.lua so the role
-- continues to reject the exact same configs it did before.
--

local checks  = require('checks')
local version = require('webui.version')

local M = {}

-- Runtime majority-guard (FO-12). Given the live cluster snapshot's
-- `servers` map and the aliases an operation would stop, return
-- (true, nil) when a write majority (N/2+1) survives, or (false, reason)
-- otherwise. Thin wrapper over the orchestrator's pure check so the
-- GraphQL layer has one obvious place to gate destructive operations.
function M.majority_guard(servers, stop_aliases)
    local orch = require('webui.lifecycle.orchestrator')
    local verdict = orch.majority_after_stop(servers or {}, stop_aliases)
    if verdict.ok then return true end
    return false, verdict.reason
end

-- Split out of validate() to keep its cyclomatic complexity below
-- the project luacheck cap. Returns (true, nil) on success or
-- (false, message) on rejection. Accepts nil (unset → no-op).
function M._validate_state_reporter(sr)
    if sr == nil then return true end
    if type(sr) ~= 'table' then
        return false, 'roles_cfg.webui.state_reporter must be a table'
    end
    if sr.enabled ~= nil and type(sr.enabled) ~= 'boolean' then
        return false,
            'roles_cfg.webui.state_reporter.enabled must be a boolean'
    end
    for _, k in ipairs({ 'renew_interval', 'keepalive_interval' }) do
        if sr[k] ~= nil
            and (type(sr[k]) ~= 'number' or sr[k] <= 0) then
            return false, 'roles_cfg.webui.state_reporter.' .. k
                .. ' must be a positive number'
        end
    end
    return true
end

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
    if cfg.etcd_writer ~= nil then
        if type(cfg.etcd_writer) ~= 'table' then
            return nil, 'roles_cfg.webui.etcd_writer must be a table'
        end
        if type(cfg.etcd_writer.endpoints) ~= 'table'
            or #cfg.etcd_writer.endpoints == 0 then
            return nil, 'roles_cfg.webui.etcd_writer.endpoints '
                .. 'must be a non-empty list of URLs'
        end
        for _, ep in ipairs(cfg.etcd_writer.endpoints) do
            if type(ep) ~= 'string' or #ep == 0 then
                return nil,
                    'roles_cfg.webui.etcd_writer.endpoints entries '
                    .. 'must be non-empty strings'
            end
        end
    end
    local sr_ok, sr_err = M._validate_state_reporter(cfg.state_reporter)
    if not sr_ok then return nil, sr_err end
    if cfg.failover ~= nil then
        if type(cfg.failover) ~= 'table' then
            return nil, 'roles_cfg.webui.failover must be a table'
        end
        if cfg.failover.agent ~= nil and type(cfg.failover.agent) ~= 'boolean' then
            return nil, 'roles_cfg.webui.failover.agent must be a boolean'
        end
        for _, k in ipairs({ 'lease_ttl_sec', 'keepalive_interval',
                'election_interval', 'appointment_interval',
                'watcher_poll_interval_sec' }) do
            if cfg.failover[k] ~= nil
                and (type(cfg.failover[k]) ~= 'number'
                or cfg.failover[k] <= 0) then
                return nil, 'roles_cfg.webui.failover.' .. k
                    .. ' must be a positive number'
            end
        end
    end

    return true
end

return M
