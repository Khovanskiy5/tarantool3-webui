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

-- Register the built-in health endpoint. Other modules call
-- M.register_route() for their own paths.
local function register_builtin_routes(httpd)
    httpd:route(
        { path = '/api/health', method = 'GET' },
        middleware.wrap('health', health_api.make_handler(enriched_status_provider))
    )
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
        log_errors = true,
    })

    httpd:hook('before_dispatch', function(_self, req)
        -- Place to enrich req before routing. Today we only seed a debug
        -- marker; request-id is owned by the per-route wrapper since not
        -- every route uses our wrapper (e.g. static fallback in Task 6).
        req._webui_seen_at = fiber.time()
    end)

    STATE.httpd = httpd
    register_builtin_routes(httpd)

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

return M
