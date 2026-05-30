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
local uuid = require('uuid')

local log_util = require('webui.log_util')
local error_envelope = require('webui.http.error_envelope')

local M = {}

local logger = log_util.with_tag('http')

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

-- wrap(name, sub, opts) returns a handler suitable for server:route().
--
-- opts:
--   allowed_origins  list of origin strings (default: nil → no CORS headers)
--   handler_logger   optional log_util tagged logger (default: 'http')
function M.wrap(name, sub, opts)
    opts = opts or {}
    local handler_logger = opts.handler_logger or logger

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

        local ok, response = pcall(sub, req)

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

        return response
    end
end

-- Expose for tests and explicit security-only paths (e.g. static).
M.apply_security_headers = apply_security_headers
M.DEFAULT_SECURITY_HEADERS = DEFAULT_SECURITY_HEADERS

return M
