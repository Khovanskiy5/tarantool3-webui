local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local validate = require('webui.lifecycle.validate')

local g = t.group('lifecycle.validate')

-- Baseline characterization of M.validate(cfg). The role's contract is
-- "reject the exact same configs it did before", so this locks the
-- accept/reject decision and the exact error text for every field
-- cluster (http / rbac / etcd_writer / failover / state_reporter)
-- BEFORE the function is split into per-cluster helpers.
--
-- Runs against the host Tarantool (3.7), so version.check_tarantool()
-- passes and we exercise pure field validation.

-- ── happy paths ──────────────────────────────────────────────────────

g.test_nil_config_ok = function()
    t.assert_equals(validate.validate(nil), true)
end

g.test_full_valid_config_ok = function()
    t.assert_equals(validate.validate({
        listen = '0.0.0.0:8080',
        log_level = 'info',
        console_enabled = false,
        graphiql_enabled = true,
        ws_allowed_origins = { 'https://ui.example.com' },
        audit_retention_days = 30,
        shutdown_timeout = 10,
        rbac = { users = { admin = { 'superuser' } } },
        etcd_writer = { endpoints = { 'http://etcd:2379' } },
        failover = { agent = true, lease_ttl_sec = 10 },
    }), true)
end

-- ── http / server fields ─────────────────────────────────────────────

g.test_listen_must_be_string = function()
    local ok, err = validate.validate({ listen = 123 })
    t.assert_equals(ok, nil)
    t.assert_equals(err, 'roles_cfg.webui.listen must be a string')
end

g.test_log_level_must_be_string = function()
    local _, err = validate.validate({ log_level = 5 })
    t.assert_equals(err, 'roles_cfg.webui.log_level must be a string')
end

g.test_console_enabled_must_be_boolean = function()
    local _, err = validate.validate({ console_enabled = 'yes' })
    t.assert_equals(err, 'roles_cfg.webui.console_enabled must be a boolean')
end

g.test_graphiql_enabled_must_be_boolean = function()
    local _, err = validate.validate({ graphiql_enabled = 1 })
    t.assert_equals(err, 'roles_cfg.webui.graphiql_enabled must be a boolean')
end

g.test_ws_allowed_origins_must_be_table = function()
    local _, err = validate.validate({ ws_allowed_origins = 'x' })
    t.assert_equals(err,
        'roles_cfg.webui.ws_allowed_origins must be a list of strings')
end

g.test_audit_retention_days_must_be_positive = function()
    local _, err = validate.validate({ audit_retention_days = 0 })
    t.assert_equals(err,
        'roles_cfg.webui.audit_retention_days must be a positive number')
end

g.test_shutdown_timeout_must_be_non_negative = function()
    local _, err = validate.validate({ shutdown_timeout = -1 })
    t.assert_equals(err,
        'roles_cfg.webui.shutdown_timeout must be a non-negative number')
end

-- ── rbac ─────────────────────────────────────────────────────────────

g.test_rbac_must_be_table = function()
    local _, err = validate.validate({ rbac = 'x' })
    t.assert_equals(err, 'roles_cfg.webui.rbac must be a table')
end

g.test_rbac_users_must_be_table = function()
    local _, err = validate.validate({ rbac = { users = 'x' } })
    t.assert_equals(err,
        'roles_cfg.webui.rbac.users must be a {user = [roles]} table')
end

-- ── etcd_writer ──────────────────────────────────────────────────────

g.test_etcd_writer_must_be_table = function()
    local _, err = validate.validate({ etcd_writer = 'x' })
    t.assert_equals(err, 'roles_cfg.webui.etcd_writer must be a table')
end

g.test_etcd_writer_endpoints_required = function()
    local _, err = validate.validate({ etcd_writer = { endpoints = {} } })
    t.assert_str_contains(err, 'must be a non-empty list of URLs')
end

g.test_etcd_writer_endpoint_entries_must_be_strings = function()
    local _, err = validate.validate(
        { etcd_writer = { endpoints = { '' } } })
    t.assert_str_contains(err, 'entries')
    t.assert_str_contains(err, 'must be non-empty strings')
end

-- ── state_reporter (delegated) ───────────────────────────────────────

g.test_state_reporter_must_be_table = function()
    local _, err = validate.validate({ state_reporter = 'x' })
    t.assert_equals(err, 'roles_cfg.webui.state_reporter must be a table')
end

-- ── failover ─────────────────────────────────────────────────────────

g.test_failover_must_be_table = function()
    local _, err = validate.validate({ failover = 'x' })
    t.assert_equals(err, 'roles_cfg.webui.failover must be a table')
end

g.test_failover_agent_must_be_boolean = function()
    local _, err = validate.validate({ failover = { agent = 'x' } })
    t.assert_equals(err, 'roles_cfg.webui.failover.agent must be a boolean')
end

g.test_failover_numeric_tunable_must_be_positive = function()
    local _, err = validate.validate({ failover = { lease_ttl_sec = 0 } })
    t.assert_equals(err,
        'roles_cfg.webui.failover.lease_ttl_sec must be a positive number')
end

g.test_failover_watcher_poll_interval_must_be_positive = function()
    local _, err = validate.validate(
        { failover = { watcher_poll_interval_sec = -2 } })
    t.assert_equals(err,
        'roles_cfg.webui.failover.watcher_poll_interval_sec '
        .. 'must be a positive number')
end
