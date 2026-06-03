-- HTTP server lifecycle for the webui role.
--
-- Wraps the http rock 1.6+ (`http.server`) which integrates routing.
-- Exposes start(opts) / stop() / register_route() / heartbeat_tick().
--
-- The heartbeat fiber pulses every second and updates the role state's
-- last_heartbeat_at. /api/health uses the staleness of this value to
-- detect TX-thread block: if the TX thread stalls > 5s, the fiber cannot
-- run and the heartbeat goes stale.

local fiber = require('fiber')
local http_server = require('http.server')

local log_util = require('webui.log_util')
local middleware = require('webui.http.middleware')
local error_envelope = require('webui.http.error_envelope')
local health_api = require('webui.api.health')

local logger = log_util.with_tag('http')

local M = {}

-- Module-local lifecycle state. One server per process.
local STATE = {
    httpd = nil,            -- http.server instance
    listen = nil,           -- host:port string
    started_at = nil,
    heartbeat_fiber = nil,
    heartbeat_stop_flag = false,
    last_heartbeat_at = 0,
    role_status_provider = nil,
    -- Default not-found and method-not-allowed handlers attached after start.
}

local DEFAULT_LISTEN = '0.0.0.0:8081'
local HEARTBEAT_INTERVAL_SEC = 1

local function parse_listen(listen)
    listen = listen or DEFAULT_LISTEN
    local host, port = string.match(listen, '^([^:]+):(%d+)$')
    if host == nil then
        return nil, 'invalid listen string: ' .. tostring(listen)
            .. ' (expected host:port)'
    end
    return host, tonumber(port)
end

local function spawn_heartbeat()
    STATE.heartbeat_stop_flag = false
    local f = fiber.create(function()
        fiber.self():name('webui_heartbeat')
        logger.debug('heartbeat fiber started', {
            interval_sec = HEARTBEAT_INTERVAL_SEC,
        })
        while not STATE.heartbeat_stop_flag do
            STATE.last_heartbeat_at = fiber.time()
            fiber.sleep(HEARTBEAT_INTERVAL_SEC)
        end
        logger.debug('heartbeat fiber exiting')
    end)
    STATE.heartbeat_fiber = f
end

local function stop_heartbeat()
    if STATE.heartbeat_fiber == nil then return end
    STATE.heartbeat_stop_flag = true
    local f = STATE.heartbeat_fiber
    STATE.heartbeat_fiber = nil
    -- Cooperative stop: wait briefly for the fiber to notice the flag.
    -- The heartbeat sleeps in 1-second chunks, so the worst case is
    -- ~1s + epsilon. We bound the wait at 2s and proceed.
    local deadline = fiber.time() + 2.0
    while fiber.status(f) ~= 'dead' and fiber.time() < deadline do
        fiber.sleep(0.05)
    end
    if fiber.status(f) ~= 'dead' then
        logger.warn('heartbeat fiber did not stop in time', {
            status = fiber.status(f),
        })
    end
end

-- Augment the role status snapshot with HTTP-side observations.
local function enriched_status_provider()
    local base = STATE.role_status_provider and STATE.role_status_provider() or {}
    base.last_heartbeat_at = STATE.last_heartbeat_at
    return base
end

-- Register the built-in health endpoint, the GraphQL endpoint and
-- the static SPA routes. Other modules call M.register_route() for
-- their own paths.
--
-- Route ordering matters: the http rock matches routes in iteration
-- order, so explicit /api/* and /admin/api/* paths must be registered
-- BEFORE the catch-all "/*splat" used for SPA history-mode fallback.
-- Otherwise the wildcard would shadow them and turn every API request
-- into a 404 inside the static handler.
local function register_builtin_routes(httpd, role_opts)
    httpd:route(
        { path = '/api/health', method = 'GET' },
        middleware.wrap('health', health_api.make_handler(enriched_status_provider))
    )

    -- Metrics (Task 42/42a) — public/no-auth, like /api/health.
    local mok, metrics = pcall(require, 'webui.api.metrics')
    if mok then
        httpd:route({ path = '/api/metrics',       method = 'GET' },
            middleware.wrap('metrics_app',  metrics.handler_app))
        httpd:route({ path = '/api/metrics/webui', method = 'GET' },
            middleware.wrap('metrics_self', metrics.handler_self))
    end

    -- Config IO (Task 37).
    local cio_ok, config_io = pcall(require, 'webui.api.config_io')
    if cio_ok then
        httpd:route({ path = '/api/config/download', method = 'GET' },
            middleware.wrap('config_download', config_io.handler_download,
                { auth = 'admin' }))
        httpd:route({ path = '/api/config/upload',   method = 'POST' },
            middleware.wrap('config_upload',   config_io.handler_upload,
                { auth = 'admin' }))
    end

    -- Tarantool log tail.
    local logs_ok, logs_mod = pcall(require, 'webui.api.logs')
    if logs_ok then
        httpd:route({ path = '/api/logs', method = 'GET' },
            middleware.wrap('logs_tail', logs_mod.handler_tail,
                { auth = 'admin' }))
    end

    -- Snapshots (Task 43).
    local snap_ok, snapshots = pcall(require, 'webui.api.snapshots')
    if snap_ok then
        httpd:route({ path = '/api/snapshots/take', method = 'POST' },
            middleware.wrap('snapshot_take', snapshots.handler_take,
                { auth = 'admin' }))
        httpd:route({ path = '/api/snapshots',      method = 'GET' },
            middleware.wrap('snapshot_list', snapshots.handler_list,
                { auth = 'admin' }))
        httpd:route({ path = '/api/snapshots/download', method = 'GET' },
            middleware.wrap('snapshot_download', snapshots.handler_download,
                { auth = 'admin' }))
    end

    -- Diagnostic bundle (Task 55).
    local diag_ok, diag = pcall(require, 'webui.api.diagnostics')
    if diag_ok then
        httpd:route({ path = '/api/diagnostics/bundle', method = 'GET' },
            middleware.wrap('diagnostics', diag.handler, { auth = 'admin' }))
        -- Destructive recovery: wipe WAL/snap on this instance and
        -- exit so Docker's restart policy spins up a fresh process
        -- that bootstraps clean from healthy peers. Refused on the
        -- synchro queue owner (would lose uncommitted txns).
        httpd:route({ path = '/api/diagnostics/rebootstrap', method = 'POST' },
            middleware.wrap('diagnostics_rebootstrap',
                diag.rebootstrap_handler, { auth = 'admin' }))
    end

    -- Lua/SQL eval (Task 44).
    local eval_ok, eval_api = pcall(require, 'webui.api.eval')
    if eval_ok then
        eval_api.configure({ console_enabled = role_opts.console_enabled == true })
        httpd:route({ path = '/api/eval', method = 'POST' },
            middleware.wrap('eval', eval_api.handler, { auth = 'superuser' }))
    end

    -- SQL workbench (Phase 3 Task 3.1 + 3.2). Operator role for
    -- read-only statements; the handler upgrades to admin if it
    -- sniffs a write keyword. EXPLAIN-only path is fixed at
    -- operator since it never mutates state.
    local sql_ok, sql_api = pcall(require, 'webui.api.sql')
    if sql_ok then
        httpd:route({ path = '/api/sql',         method = 'POST' },
            middleware.wrap('sql',         sql_api.handler,
                { auth = 'operator' }))
        httpd:route({ path = '/api/sql/explain', method = 'POST' },
            middleware.wrap('sql_explain', sql_api.handler_explain,
                { auth = 'operator' }))
    end

    -- Auth surface (Task 25). Lazy require so a misconfigured
    -- session storage does not block the rest of the role.
    local auth_ok, auth_api = pcall(require, 'webui.api.auth')
    if auth_ok then
        httpd:route({ path = '/api/auth/login',  method = 'POST' },
            middleware.wrap('auth_login',  auth_api.handler_login,
                { auth = 'public' }))
        httpd:route({ path = '/api/auth/logout', method = 'POST' },
            middleware.wrap('auth_logout', auth_api.handler_logout,
                { auth = 'public' }))
        httpd:route({ path = '/api/auth/me',     method = 'GET' },
            middleware.wrap('auth_me',     auth_api.handler_me,
                { auth = 'session' }))
        logger.info('auth routes registered')
    else
        logger.warn('auth module load failed; /api/auth disabled', {
            err = tostring(auth_api),
        })
    end

    -- GraphQL surface. Loaded inside pcall so a broken schema does not
    -- prevent the rest of the role from starting; the failure surfaces
    -- as 503 UNAVAILABLE on /admin/api requests and a warn log line.
    local ok_gql, graphql_srv = pcall(require, 'webui.graphql.server')
    if ok_gql then
        local init_ok, init_err = pcall(graphql_srv.init, {
            graphiql_enabled = role_opts.graphiql_enabled == true,
        })
        if init_ok then
            httpd:route(
                { path = '/admin/api', method = 'POST' },
                middleware.wrap('graphql', graphql_srv.handler,
                    { auth = 'session' })
            )
            httpd:route(
                { path = '/admin/api/explore', method = 'GET' },
                middleware.wrap('graphql_explorer', graphql_srv.graphiql_handler,
                    { auth = 'admin' })
            )
            local s = graphql_srv.status()
            logger.info('graphql routes registered', {
                graphiql_enabled = s.graphiql_enabled,
            })
        else
            logger.error('graphql init failed; /admin/api disabled', {
                err = tostring(init_err),
            })
        end
    else
        logger.warn('graphql module load failed; /admin/api disabled', {
            err = tostring(graphql_srv),
        })
    end

    -- WebSocket endpoint /ws. The module is loaded lazily so a
    -- broken WS framing layer cannot prevent the REST surface from
    -- coming up; the failure surfaces as a 404 on /ws and a warn
    -- log line.
    local ws_ok, ws = pcall(require, 'webui.http.ws')
    if ws_ok then
        -- The middleware runs in `auth = 'public'` mode because the
        -- WS handler does its own handshake-level cookie validation
        -- (the SPA cannot set custom headers from
        -- `new WebSocket(...)`, so middleware enforcement would
        -- always 401 with `no session` before the cookie is read).
        if ws.configure ~= nil then
            ws.configure({ allowed_origins = role_opts.ws_allowed_origins })
        end
        httpd:route(
            { path = '/ws', method = 'GET' },
            middleware.wrap('ws', ws.handler, { auth = 'public' })
        )
        logger.info('ws route registered', {
            path = '/ws',
            allowed_origins = role_opts.ws_allowed_origins,
        })
    else
        logger.warn('ws module load failed; /ws disabled', {
            err = tostring(ws),
        })
    end

    -- Static SPA. The module is always loadable: when the bundle has
    -- not been produced (unit-test runs without `make embed-assets`),
    -- the handler returns 404 for every path while leaving the rest
    -- of the role healthy.
    local ok, static = pcall(require, 'webui.http.static')
    if not ok then
        logger.warn('static module load failed; UI disabled', {
            err = tostring(static),
        })
        return
    end

    local static_handler = middleware.wrap('static', static.handler)

    -- Explicit, frequently-hit paths first.
    httpd:route({ path = '/',                       method = 'GET' }, static_handler)
    httpd:route({ path = '/index.html',             method = 'GET' }, static_handler)
    httpd:route({ path = '/favicon.ico',            method = 'GET' }, static_handler)
    httpd:route({ path = '/robots.txt',             method = 'GET' }, static_handler)

    -- Asset folders. The http rock's `*splat` syntax captures the
    -- remainder of the path under the `splat` stash; we ignore the
    -- capture because the handler re-reads req.path itself.
    httpd:route({ path = '/assets/*splat',           method = 'GET' }, static_handler)
    httpd:route({ path = '/monacoeditorwork/*splat', method = 'GET' }, static_handler)

    -- SPA history-mode fallback. Registered LAST so explicit routes
    -- (api, assets, favicons) match first. The handler inspects the
    -- request path and either serves the asset, falls back to
    -- index.html for nav paths, or emits a clean 404 for /api/* and
    -- friends if their owners never registered them.
    httpd:route({ path = '/*splat', method = 'GET' }, static_handler)

    local stats = static.stats()
    logger.info('static routes registered', {
        bundle_loaded = stats.loaded,
        entries = stats.entries,
        total_raw_bytes = stats.total_raw_bytes,
        index_present = stats.index_present,
    })
end

-- Public: register a route with the standard middleware wrapper applied.
function M.register_route(method, path, name, handler, opts)
    if STATE.httpd == nil then
        return nil, 'http server not started'
    end
    STATE.httpd:route(
        { path = path, method = method },
        middleware.wrap(name, handler, opts)
    )
    logger.debug('route registered', { method = method, path = path, name = name })
    return true
end

-- Public: start the server. opts:
--   listen                "host:port" (default 0.0.0.0:8081)
--   allowed_origins       table of allowed CORS origins (default nil)
--   role_status_provider  function returning { state, instance, started_at }
function M.start(opts)
    if STATE.httpd ~= nil then
        return nil, 'http server already started'
    end
    opts = opts or {}

    local host, port = parse_listen(opts.listen)
    if host == nil then
        return nil, port  -- second return is the error string from parse_listen
    end

    STATE.role_status_provider = opts.role_status_provider
        or function() return {} end
    STATE.listen = host .. ':' .. tostring(port)

    local httpd = http_server.new(host, port, {
        log_requests = false,  -- we log via our middleware
        -- Route handler exceptions are caught and rendered by our
        -- middleware, so the rock's own error logging is just noise.
        -- (Note: the rock's "failed to read request: Connection reset
        -- by peer" line on keep-alive teardown is logged unconditionally
        -- and is not affected by this flag — that churn is addressed by
        -- the WebSocket liveness fix in http/ws.lua.)
        log_errors = false,
    })

    httpd:hook('before_dispatch', function(_self, req)
        -- Place to enrich req before routing. Today we only seed a debug
        -- marker; request-id is owned by the per-route wrapper since not
        -- every route uses our wrapper (e.g. static fallback in Task 6).
        req._webui_seen_at = fiber.time()
    end)

    STATE.httpd = httpd
    register_builtin_routes(httpd, opts)

    local ok, err = pcall(function() httpd:start() end)
    if not ok then
        STATE.httpd = nil
        STATE.listen = nil
        logger.error('http server failed to start', { err = tostring(err) })
        return nil, tostring(err)
    end

    spawn_heartbeat()
    STATE.started_at = fiber.time()
    logger.info('http server started', { listen = STATE.listen })
    return true
end

function M.stop()
    if STATE.httpd == nil then
        logger.debug('stop called while http server not running')
        return true
    end

    stop_heartbeat()

    local ok, err = pcall(function() STATE.httpd:stop() end)
    if not ok then
        logger.error('http server stop raised', { err = tostring(err) })
    end

    STATE.httpd = nil
    STATE.listen = nil
    STATE.started_at = nil
    STATE.role_status_provider = nil
    STATE.last_heartbeat_at = 0
    logger.info('http server stopped')
    return true
end

function M.status()
    return {
        running = STATE.httpd ~= nil,
        listen = STATE.listen,
        started_at = STATE.started_at,
        last_heartbeat_at = STATE.last_heartbeat_at,
    }
end

-- Internal: expose error_envelope so route handlers can fail cleanly.
M.envelope = error_envelope

-- Re-export the http rock's DETACHED sentinel so the WebSocket
-- handler can return it without importing the rock directly. The
-- middleware passes numbers through verbatim — see
-- backend/webui/http/middleware.lua.
M.DETACHED = http_server.DETACHED

return M
