-- HTTP middleware: request-id, request logger, security headers,
-- CORS, JSON body parsing, error envelope wrapping.
--
-- Middlewares are not registered as before_dispatch / after_dispatch
-- hooks of the http rock because hooks cannot short-circuit a response.
-- Instead, route handlers are wrapped via wrap(name, sub) at registration
-- time; the wrapper composes the pipeline.
--
-- Each wrapped handler:
--   1. Assigns or accepts a request-id (X-Request-Id).
--   2. Parses JSON body lazily via req:json() helper.
--   3. Runs the sub in pcall.
--   4. Adds X-Request-Id and security headers to the response.
--   5. On pcall failure: logs the panic and emits an INTERNAL envelope.
--   6. Records a debug entry with method, path, status, latency.
--
-- Auth and CSRF middleware are reserved placeholders until M2.

local clock = require('clock')
local json = require('json')
local uuid = require('uuid')

local log_util = require('webui.log_util')
local error_envelope = require('webui.http.error_envelope')

local M = {}

local logger = log_util.with_tag('http')

-- Loaded lazily so unit tests that import middleware without the
-- shutdown module (rare but possible) do not blow up. In the real
-- role start path the module is always present.
local function lazy_shutdown()
    local ok, mod = pcall(require, 'webui.http.shutdown')
    if ok then return mod end
    return nil
end

-- Mandatory response headers for security. Applied unconditionally.
-- CSP allows blob: workers because Monaco needs them; if no Monaco page
-- is open this still costs nothing.
--
-- 'unsafe-eval' is allowed for the SPA bundle because vue-i18n's
-- runtime evaluates a small number of dynamic message functions via
-- `new Function(...)` even when JSON locales are AOT-precompiled by
-- @intlify/unplugin-vue-i18n. Stripping the runtime compiler via
-- `runtimeOnly: true` removes `new Function` from the static bundle
-- but leaves a single code path inside the message-compiler that
-- still tries to allocate one — which our strict CSP would block,
-- making the entire shell go blank.
-- See `frontend/vite.config.ts` for the AOT plugin and the smoke
-- test `frontend/tests/e2e/smoke.spec.ts` which guards this
-- regression. The follow-up to tighten CSP back to `'self'` lives
-- with the SPA refactor away from vue-i18n's runtime compiler.
local DEFAULT_SECURITY_HEADERS = {
    ['strict-transport-security'] = 'max-age=63072000; includeSubDomains',
    ['content-security-policy'] = table.concat({
        "default-src 'self'",
        "script-src 'self' 'unsafe-eval'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self' data:",
        "connect-src 'self' ws: wss:",
        "worker-src 'self' blob:",
        "frame-ancestors 'none'",
        "base-uri 'self'",
    }, '; '),
    ['x-content-type-options'] = 'nosniff',
    ['x-frame-options'] = 'DENY',
    ['referrer-policy'] = 'strict-origin-when-cross-origin',
    ['permissions-policy'] = 'geolocation=(), microphone=(), camera=()',
    ['cross-origin-opener-policy'] = 'same-origin',
    ['cross-origin-resource-policy'] = 'same-origin',
}

local function copy(t)
    local out = {}
    if t == nil then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function apply_security_headers(headers)
    headers = headers or {}
    for h, v in pairs(DEFAULT_SECURITY_HEADERS) do
        if headers[h] == nil then
            headers[h] = v
        end
    end
    return headers
end

-- CORS: only applied when configured. Default is same-origin.
-- allowed_origins is a list of exact origins; '*' is rejected on
-- credentialed endpoints because it conflicts with cookie auth.
local function build_cors_headers(req, allowed_origins)
    if allowed_origins == nil or #allowed_origins == 0 then
        return nil
    end
    local origin = req.headers['origin']
    if origin == nil then
        return nil
    end
    for _, allowed in ipairs(allowed_origins) do
        if origin == allowed then
            return {
                ['access-control-allow-origin']      = origin,
                ['access-control-allow-credentials'] = 'true',
                ['access-control-allow-headers']     = 'content-type, x-csrf-token, x-request-id',
                ['access-control-allow-methods']     = 'GET, POST, PUT, DELETE, OPTIONS',
                ['access-control-max-age']           = '3600',
                ['vary']                             = 'origin',
            }
        end
    end
    return nil
end

local function header_lookup(req, name)
    -- http rock 1.6+ lower-cases header names; be defensive.
    if req.headers == nil then return nil end
    return req.headers[name] or req.headers[string.lower(name)]
end

local function assign_request_id(req)
    local existing = header_lookup(req, 'x-request-id')
    if type(existing) == 'string'
        and #existing > 0 and #existing <= 128
        and string.match(existing, '^[%w%-_:]+$') then
        req.request_id = existing
    else
        req.request_id = uuid.str()
    end
end

-- Auth helpers. Pulled in via a deferred require so the
-- middleware module stays loadable in unit tests that don't
-- bootstrap the auth submodules.
local _session_mod, _rbac_mod, _audit_mod
local function lazy_session()
    if _session_mod == nil then
        local ok, mod = pcall(require, 'webui.auth.session')
        if ok then _session_mod = mod end
    end
    return _session_mod
end
local function lazy_rbac()
    if _rbac_mod == nil then
        local ok, mod = pcall(require, 'webui.auth.rbac')
        if ok then _rbac_mod = mod end
    end
    return _rbac_mod
end
local function lazy_audit()
    if _audit_mod == nil then
        local ok, mod = pcall(require, 'webui.audit.log')
        if ok then _audit_mod = mod end
    end
    return _audit_mod
end

local MUTATION_METHODS = {
    POST = true, PUT = true, PATCH = true, DELETE = true,
}

local COOKIE_NAME = 'webui_session'

local function parse_session_cookie(req)
    local raw = header_lookup(req, 'cookie')
    if type(raw) ~= 'string' then return nil end
    for piece in raw:gmatch('([^; ]+)') do
        local name, value = piece:match('^([^=]+)=(.+)$')
        if name == COOKIE_NAME then return value end
    end
    return nil
end

local function envelope_response(status, code, message, request_id)
    return {
        status = status,
        headers = { ['content-type'] = 'application/json; charset=utf-8' },
        body = json.encode({
            error = {
                code = code, message = message,
                request_id = request_id,
            },
        }),
    }
end

-- Enforce session + RBAC + CSRF as configured. Returns nil on pass,
-- or a fully-formed response table on rejection.
local function enforce_auth(req, opts, request_id, handler_logger, name)
    local required = opts.auth or 'session'
    if required == 'public' then return nil end

    local session_mod = lazy_session()
    if session_mod == nil then
        handler_logger.error('auth module unavailable', {
            request_id = request_id, handler = name,
        })
        return envelope_response(503, 'UNAVAILABLE',
            'auth subsystem unavailable', request_id)
    end

    local sid = parse_session_cookie(req)
    if sid == nil then
        return envelope_response(401, 'UNAUTHORIZED',
            'no session', request_id)
    end
    local tuple = session_mod.get(sid)
    if tuple == nil then
        return envelope_response(401, 'UNAUTHORIZED',
            'session expired', request_id)
    end

    -- CSRF check for state-changing methods.
    if MUTATION_METHODS[req.method] then
        local csrf = header_lookup(req, 'x-csrf-token')
        if type(csrf) ~= 'string' or csrf ~= tuple.csrf then
            handler_logger.info('csrf mismatch', {
                request_id = request_id, handler = name,
                user = tuple.user,
            })
            return envelope_response(403, 'CSRF_MISMATCH',
                'csrf token missing or invalid', request_id)
        end
    end

    -- RBAC check when a role is required.
    if required ~= 'session' then
        local rbac = lazy_rbac()
        if rbac == nil then
            return envelope_response(503, 'UNAVAILABLE',
                'rbac unavailable', request_id)
        end
        local user_roles = rbac.user_roles(tuple.user)
        if not rbac.allowed(user_roles, required) then
            handler_logger.info('rbac denied', {
                request_id = request_id, handler = name,
                user = tuple.user, required = required,
                actual = user_roles,
            })
            local audit = lazy_audit()
            if audit ~= nil then
                pcall(audit.record, {
                    user = tuple.user, action = 'rbac.denied',
                    scope = required, request_id = request_id,
                    payload = { handler = name },
                })
            end
            pcall(function()
                require('webui.notifications').emit({
                    type     = 'audit.security',
                    severity = 'warning',
                    user     = tuple.user,
                    scope    = required,
                    category = 'rbac',
                    message  = 'RBAC denied for ' .. tostring(name)
                        .. ' (need ' .. tostring(required) .. ')',
                })
            end)
            return envelope_response(403, 'FORBIDDEN',
                'insufficient role', request_id)
        end
    end

    -- Surface session context to the handler.
    req.session = tuple
    req.user = tuple.user
    -- Resolve user roles once and expose them so handlers that
    -- need per-statement RBAC (e.g. /api/sql sniffs the first
    -- keyword to decide between operator vs admin) do not have
    -- to call rbac.user_roles() again. `rbac` is scoped to the
    -- RBAC branch above; re-resolve via lazy_rbac() here so this
    -- runs even for `auth: session` handlers.
    do
        local rbac_mod = lazy_rbac()
        if rbac_mod and type(rbac_mod.user_roles) == 'function' then
            local ok_roles, roles_or_err = pcall(rbac_mod.user_roles, tuple.user)
            if ok_roles and type(roles_or_err) == 'table' then
                req.roles = roles_or_err
            end
        end
    end
    return nil
end

-- wrap(name, sub, opts) returns a handler suitable for server:route().
--
-- opts:
--   allowed_origins  list of origin strings (default: nil → no CORS headers)
--   handler_logger   optional log_util tagged logger (default: 'http')
--   auth             'public' | 'session' | <role-name> (default: 'session')
--                    'public' skips session and RBAC; routes without an
--                    explicit override default to 'public' until M2 fully
--                    flips the table (the http.server registers explicit
--                    overrides per route).
--   audit_action     when present, logs a successful response (<400) into
--                    `_webui_audit` with this action name.
function M.wrap(name, sub, opts)
    opts = opts or {}
    local handler_logger = opts.handler_logger or logger
    -- Honest default: most routes registered today predate this
    -- middleware. To avoid breaking them at once we keep the default
    -- as `public`; explicit routes that flip on auth pass `auth='session'`
    -- (or a role name) at registration time.
    opts.auth = opts.auth or 'public'

    return function(req)
        assign_request_id(req)
        local request_id = req.request_id
        local started = clock.monotonic()

        -- Short-circuit OPTIONS preflights when CORS is enabled.
        local cors = build_cors_headers(req, opts.allowed_origins)
        if req.method == 'OPTIONS' and cors ~= nil then
            local headers = apply_security_headers(copy(cors))
            headers['x-request-id'] = request_id
            return { status = 204, headers = headers, body = '' }
        end

        -- Drain gate (Task 3a). New requests get 503 + Retry-After
        -- while the role is shutting down so a load balancer pulls
        -- this instance out of rotation cleanly. /api/health stays
        -- exempt so monitoring can still observe `degraded`.
        local shutdown = lazy_shutdown()
        if shutdown ~= nil and shutdown.is_draining()
            and not shutdown.bypasses_drain(req.path) then
            local body = error_envelope.respond_with_code(
                'SHUTDOWN_IN_PROGRESS', 'instance is shutting down',
                request_id, 503)
            body.headers = body.headers or {}
            body.headers['retry-after'] = '5'
            body.headers['x-request-id'] = request_id
            apply_security_headers(body.headers)
            handler_logger.info('request rejected: draining', {
                request_id = request_id, handler = name,
                method = req.method, path = req.path,
            })
            return body
        end

        -- Auth pipeline. Runs before the handler and can short-circuit.
        local rejected = enforce_auth(req, opts, request_id, handler_logger, name)
        if rejected ~= nil then
            rejected.headers = rejected.headers or {}
            rejected.headers['x-request-id'] = request_id
            apply_security_headers(rejected.headers)
            handler_logger.info('request handled', {
                request_id = request_id, handler = name,
                method = req.method, path = req.path,
                status = rejected.status,
                latency_ms = (clock.monotonic() - started) * 1000,
            })
            return rejected
        end

        -- Track this request as in-flight for the duration of the
        -- handler call. The release closure pairs with mark_draining
        -- → wait_drain in M.stop(). Detached (WS upgrade) handlers
        -- return a numeric DETACHED below; release runs anyway so
        -- the WS lifecycle does not pin the shutdown waiter.
        local release_inflight = shutdown and shutdown.acquire() or nil
        local ok, response = pcall(sub, req)
        if release_inflight then release_inflight() end

        local latency_ms = (clock.monotonic() - started) * 1000

        if not ok then
            -- The handler raised. Log the panic with full message and
            -- return a generic envelope. response holds the raw error.
            handler_logger.error('handler panic', {
                request_id = request_id,
                handler = name,
                method = req.method,
                path = req.path,
                err = tostring(response),
                latency_ms = latency_ms,
            })
            response = error_envelope.respond_internal(request_id)
        end

        -- The http rock interprets a numeric return as a special
        -- signal. The only one we use is DETACHED (101) — the
        -- WebSocket handler returns it after successfully owning
        -- the raw socket. Pass it through without wrapping so the
        -- rock leaves the connection alone.
        if type(response) == 'number' then
            handler_logger.info('handler detached', {
                request_id = request_id,
                handler = name,
                method = req.method,
                path = req.path,
                latency_ms = latency_ms,
            })
            return response
        end

        if type(response) ~= 'table' then
            handler_logger.error('handler returned non-table', {
                request_id = request_id,
                handler = name,
                returned_type = type(response),
            })
            response = error_envelope.respond_internal(request_id)
        end

        response.status = response.status or 200
        response.headers = response.headers or {}
        response.headers['x-request-id'] = request_id
        if cors ~= nil then
            for h, v in pairs(cors) do
                response.headers[h] = response.headers[h] or v
            end
        end
        apply_security_headers(response.headers)

        local level = 'debug'
        if response.status >= 500 then
            level = 'error'
        elseif response.status >= 400 then
            level = 'info'
        end
        handler_logger[level]('request handled', {
            request_id = request_id,
            handler = name,
            method = req.method,
            path = req.path,
            status = response.status,
            latency_ms = latency_ms,
        })

        -- Audit-log successful mutations when configured.
        if opts.audit_action ~= nil and response.status < 400 then
            local audit = lazy_audit()
            if audit ~= nil then
                pcall(audit.record, {
                    user = req.user, action = opts.audit_action,
                    scope = opts.audit_scope, request_id = request_id,
                    payload = { handler = name, path = req.path },
                })
            end
        end

        return response
    end
end

-- Expose for tests and explicit security-only paths (e.g. static).
M.apply_security_headers = apply_security_headers
M.DEFAULT_SECURITY_HEADERS = DEFAULT_SECURITY_HEADERS

return M
