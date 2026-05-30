-- Error class catalog for the webui role.
--
-- The catalog is the stable part of the API contract. Each entry maps
-- to one of the `extensions.code` values surfaced to GraphQL clients
-- and to the `error.code` field of REST envelopes. Adding new codes
-- is non-breaking; renaming or removing a code is breaking.
--
-- All non-INTERNAL classes are created with capture_stack=false because
-- they represent expected, surface-level failures and the stack adds
-- noise to logs. INTERNAL keeps the stack for post-mortem analysis.
--
-- Usage:
--
--   local Err = require('webui.errors')
--   if not allowed then
--     return nil, Err.FORBIDDEN:new('role %s required', required_role)
--   end

local errors = require('errors')

local function shallow(name)
    return errors.new_class(name, { capture_stack = false })
end

local M = {}

-- ── Authentication & Authorization ──────────────────────────────────────
M.UNAUTHORIZED        = shallow('UNAUTHORIZED')
M.FORBIDDEN           = shallow('FORBIDDEN')
M.CSRF_INVALID        = shallow('CSRF_INVALID')
M.SESSION_EXPIRED     = shallow('SESSION_EXPIRED')
M.RATE_LIMITED        = shallow('RATE_LIMITED')
M.LOGIN_FAILED        = shallow('LOGIN_FAILED')
M.PASSWORD_TOO_WEAK   = shallow('PASSWORD_TOO_WEAK')

-- ── Validation ──────────────────────────────────────────────────────────
M.VALIDATION_ERROR    = shallow('VALIDATION_ERROR')
M.CONFIG_SCHEMA_INVALID            = shallow('CONFIG_SCHEMA_INVALID')
M.CONFIG_CROSS_VALIDATION_FAILED   = shallow('CONFIG_CROSS_VALIDATION_FAILED')
M.LARGE_CONFIG        = shallow('LARGE_CONFIG')
M.INVALID_URI         = shallow('INVALID_URI')
M.INVALID_INSTANCE_NAME = shallow('INVALID_INSTANCE_NAME')

-- ── Resource state ──────────────────────────────────────────────────────
M.NOT_FOUND           = shallow('NOT_FOUND')
M.CONFLICT            = shallow('CONFLICT')
M.CAS_CONFLICT        = shallow('CAS_CONFLICT')
M.EDIT_LOCK_HELD      = shallow('EDIT_LOCK_HELD')
M.PREPARED_LOCK_HELD  = shallow('PREPARED_LOCK_HELD')
M.BUSY                = shallow('BUSY')
M.ALREADY_EXISTS      = shallow('ALREADY_EXISTS')
M.STILL_IN_USE        = shallow('STILL_IN_USE')

-- ── Cluster operations ─────────────────────────────────────────────────
M.INSTANCE_UNREACHABLE         = shallow('INSTANCE_UNREACHABLE')
M.INSTANCE_INCOMPATIBLE_VERSION = shallow('INSTANCE_INCOMPATIBLE_VERSION')
M.INSTANCE_DIFFERENT_CLUSTER   = shallow('INSTANCE_DIFFERENT_CLUSTER')
M.TLS_HANDSHAKE_FAILED         = shallow('TLS_HANDSHAKE_FAILED')
M.CONFIG_NOT_APPLIED           = shallow('CONFIG_NOT_APPLIED')
M.NO_LEADER                    = shallow('NO_LEADER')
M.NO_ROUTERS                   = shallow('NO_ROUTERS')
M.FAILOVER_COORDINATOR_DOWN    = shallow('FAILOVER_COORDINATOR_DOWN')
M.READ_ONLY_SOURCE             = shallow('READ_ONLY_SOURCE')

-- ── Internal / system ───────────────────────────────────────────────────
M.UNAVAILABLE         = shallow('UNAVAILABLE')
M.TIMEOUT             = shallow('TIMEOUT')
M.SHUTDOWN_IN_PROGRESS = shallow('SHUTDOWN_IN_PROGRESS')
M.ETCD_UNAVAILABLE        = shallow('ETCD_UNAVAILABLE')
M.ETCD_AUTH_FAILED        = shallow('ETCD_AUTH_FAILED')
M.ETCD_COMPACTED_REVISION = shallow('ETCD_COMPACTED_REVISION')
M.TX_THREAD_BLOCKED   = shallow('TX_THREAD_BLOCKED')

-- INTERNAL is the only class that keeps a stack trace because it
-- represents unexpected programming errors that need debugging.
M.INTERNAL            = errors.new_class('INTERNAL', { capture_stack = true })

-- ── Console / eval ──────────────────────────────────────────────────────
M.CONSOLE_DISABLED    = shallow('CONSOLE_DISABLED')
M.EVAL_TIMEOUT        = shallow('EVAL_TIMEOUT')
M.EVAL_FORBIDDEN      = shallow('EVAL_FORBIDDEN')

-- ── Protocol ────────────────────────────────────────────────────────────
M.UNSUPPORTED_PROTOCOL_VERSION = shallow('UNSUPPORTED_PROTOCOL_VERSION')
M.WS_SLOW_CONSUMER             = shallow('WS_SLOW_CONSUMER')
M.WS_AUTH_FAILED               = shallow('WS_AUTH_FAILED')

-- Mapping of error code → recommended HTTP status code. Used by
-- http/error_envelope to derive the status when only an error object
-- is in hand. Codes absent from this table default to 500.
M.HTTP_STATUS = {
    UNAUTHORIZED         = 401,
    SESSION_EXPIRED      = 401,
    LOGIN_FAILED         = 401,
    FORBIDDEN            = 403,
    CSRF_INVALID         = 403,
    CONSOLE_DISABLED     = 403,
    EVAL_FORBIDDEN       = 403,
    READ_ONLY_SOURCE     = 403,
    NOT_FOUND            = 404,
    ALREADY_EXISTS       = 409,
    CONFLICT             = 409,
    CAS_CONFLICT         = 409,
    STILL_IN_USE         = 409,
    VALIDATION_ERROR     = 400,
    CONFIG_SCHEMA_INVALID            = 400,
    CONFIG_CROSS_VALIDATION_FAILED   = 400,
    INVALID_URI                      = 400,
    INVALID_INSTANCE_NAME            = 400,
    PASSWORD_TOO_WEAK    = 400,
    LARGE_CONFIG         = 413,
    EDIT_LOCK_HELD       = 423,
    PREPARED_LOCK_HELD   = 423,
    BUSY                 = 423,
    RATE_LIMITED         = 429,
    UNSUPPORTED_PROTOCOL_VERSION = 426,
    UNAVAILABLE          = 503,
    INSTANCE_UNREACHABLE = 503,
    CONFIG_NOT_APPLIED   = 503,
    NO_LEADER            = 503,
    NO_ROUTERS           = 503,
    FAILOVER_COORDINATOR_DOWN = 503,
    ETCD_UNAVAILABLE          = 503,
    ETCD_AUTH_FAILED          = 503,
    ETCD_COMPACTED_REVISION   = 503,
    TX_THREAD_BLOCKED         = 503,
    SHUTDOWN_IN_PROGRESS      = 503,
    TIMEOUT              = 504,
    EVAL_TIMEOUT         = 504,
    INTERNAL             = 500,
}

function M.http_status(code)
    return M.HTTP_STATUS[code] or 500
end

return M
