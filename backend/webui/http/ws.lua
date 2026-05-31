--
-- WebSocket endpoint and per-connection lifecycle.
--
-- /ws upgrades a plain HTTP request to a WebSocket session under
-- the rules from the plan:
--
--   * M1 ships in "dev-anonymous" mode, gated by
--     WEBUI_DEV_ANONYMOUS_WS=1. Without the flag the endpoint
--     responds 503 to make the prod deployment safe before auth
--     lands.
--   * On a successful upgrade the server immediately pushes the
--     current cluster snapshot (`initial`) and then publishes
--     deltas as subsystems (poller, issues, suggestions,
--     config.info watcher) signal them.
--   * Per-connection fibers handle reader (parse client frames,
--     answer pings, track pongs, react to close) and writer
--     (drain the queue from ws_registry).
--   * A heartbeat fiber pings every PING_INTERVAL_SEC and tears
--     the session down if the client misses
--     PONG_DEADLINE_SEC seconds of pongs.
--
-- Everything network-facing is wrapped in pcall so a misbehaving
-- client cannot bring down the role.
--

local fiber  = require('fiber')
local json   = require('json')

local frame    = require('webui.http.ws_frame')
local registry = require('webui.http.ws_registry')
local state    = require('webui.cluster.state')
local issues   = require('webui.cluster.issues')
local suggestions = require('webui.cluster.suggestions')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('ws')

-- Configurable Origin allow-list; set via M.configure({...}).
local ALLOWED_ORIGINS = nil

-- Cookie parsing shared with the REST middleware.
local SESSION_COOKIE = 'webui_session'

local function lazy_session()
    local ok, mod = pcall(require, 'webui.auth.session')
    if ok then return mod end
    return nil
end

local function parse_session_cookie(headers)
    if headers == nil then return nil end
    local raw = headers['cookie']
    if type(raw) ~= 'string' then return nil end
    for piece in raw:gmatch('([^; ]+)') do
        local name, value = piece:match('^([^=]+)=(.+)$')
        if name == SESSION_COOKIE then return value end
    end
    return nil
end

local function origin_allowed(headers)
    if ALLOWED_ORIGINS == nil or next(ALLOWED_ORIGINS) == nil then
        return true
    end
    local origin = headers and headers['origin']
    if origin == nil or origin == '' then return true end
    for _, allowed in ipairs(ALLOWED_ORIGINS) do
        if allowed == origin or allowed == '*' then return true end
    end
    return false
end

local M = {}

function M.configure(opts)
    opts = opts or {}
    if type(opts.allowed_origins) == 'table' then
        ALLOWED_ORIGINS = {}
        for _, o in ipairs(opts.allowed_origins) do
            if type(o) == 'string' and o ~= '' then
                table.insert(ALLOWED_ORIGINS, o)
            end
        end
    end
end

M.PING_INTERVAL_SEC  = 30
M.PONG_DEADLINE_SEC  = 60
M.WRITER_IDLE_SEC    = 0.5
M.HEARTBEAT_TICK_SEC = 5

-- Shared condition variable used by every subsystem that wants to
-- notify connected clients. Producers call `M.broadcast(msg)`
-- below; that wraps the registry's enqueue + the cond signal so
-- writer fibers wake up promptly.
local notify_cond = fiber.cond()

-- ─────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────

local function dev_anonymous_enabled()
    local flag = os.getenv('WEBUI_DEV_ANONYMOUS_WS')
    return flag == '1' or flag == 'true' or flag == 'TRUE'
end

local function jsonl(payload)
    local ok, encoded = pcall(json.encode, payload)
    if not ok then
        return json.encode({
            type = 'error',
            error = 'cannot encode payload',
        })
    end
    return encoded
end

-- Compose the broadcast message for the various subsystems. Keeping
-- the projection here means producers do not have to know the wire
-- format.
local function project_snapshot()
    return {
        type        = 'snapshot',
        generation  = state.generation(),
        last_tick   = state.last_tick_at(),
        cluster     = state.snapshot(),
        issues      = issues.current(),
        suggestions = suggestions.current(),
        ts          = fiber.time(),
    }
end

-- Public: the producer-side broadcast hook. Subsystems call this
-- whenever they want to nudge connected clients (e.g., after a
-- poller tick lands a new generation).
function M.broadcast()
    if registry.count() == 0 then return end
    local message = jsonl(project_snapshot())
    registry.broadcast(message)
    notify_cond:broadcast()
end

-- Public: subsystems that already build their own delta payload
-- (e.g., a future suggestions-only feed) can send custom messages.
-- The cond signal is still raised so writers wake up.
function M.broadcast_raw(payload)
    if registry.count() == 0 then return end
    local message = jsonl(payload)
    registry.broadcast(message)
    notify_cond:broadcast()
end

-- ─────────────────────────────────────────────────────────────────────
-- Per-connection lifecycle
-- ─────────────────────────────────────────────────────────────────────

local function safe_write(sock, bytes)
    local ok, err = pcall(function() return sock:write(bytes) end)
    if not ok then return nil, tostring(err) end
    return err  -- sock:write returns size; nil on EOF/error
end

local function send_close(sock, code, reason)
    safe_write(sock, frame.encode_close(code, reason))
end

-- Reader fiber: consume client bytes, parse frames, react to
-- control frames (ping/pong/close). Anything else (text/binary
-- data) is logged and ignored — the public protocol is
-- server-to-client today.
local function spawn_reader(entry, sock)
    fiber.create(function()
        fiber.name('webui_ws_reader_' .. entry.id, { truncate = true })
        local buf = ''
        while not entry.closed do
            local chunk
            local ok, err = pcall(function()
                chunk = sock:read({ chunk = 4096 }, 1)
            end)
            if not ok then
                logger.debug('ws read raised', { id = entry.id, err = tostring(err) })
                break
            end
            -- Distinguish three sock:read outcomes:
            --   chunk == ''   → clean EOF, peer closed the connection.
            --                   sock:read returns instantly in this state,
            --                   so we MUST break out — otherwise the
            --                   outer loop spins at 100% CPU until the
            --                   heartbeat fiber eventually flips
            --                   `entry.closed`. That bug burned a TX
            --                   thread on tt-2 for hours before discovery.
            --   chunk == nil  → 1s read timeout with no bytes. Normal.
            --                   We loop and try again; the timeout itself
            --                   yields the fiber so no CPU is wasted.
            --   non-empty str → bytes; append to buf and try to decode.
            if chunk == '' then
                logger.debug('ws peer EOF', { id = entry.id })
                entry.closed = true
                break
            end
            if chunk == nil then
                if entry.closed then break end
            else
                buf = buf .. chunk
            end

            while #buf >= 2 do
                local decoded, derr = frame.decode(buf)
                if decoded == nil and derr == 'incomplete' then break end
                if decoded == nil then
                    logger.warn('ws frame decode error', {
                        id = entry.id, err = derr,
                    })
                    send_close(sock, frame.CLOSE.PROTOCOL_ERR, derr or 'decode')
                    entry.closed = true
                    break
                end
                if not decoded.masked then
                    -- RFC 6455 §5.1: client frames MUST be masked.
                    send_close(sock, frame.CLOSE.PROTOCOL_ERR, 'unmasked')
                    entry.closed = true
                    break
                end
                buf = buf:sub(decoded.consumed + 1)

                if decoded.opcode == frame.OPCODE.PING then
                    safe_write(sock, frame.encode_pong(decoded.payload))
                elseif decoded.opcode == frame.OPCODE.PONG then
                    registry.update_pong(entry.id, os.time())
                elseif decoded.opcode == frame.OPCODE.CLOSE then
                    send_close(sock, frame.CLOSE.NORMAL, '')
                    entry.closed = true
                    break
                elseif decoded.opcode == frame.OPCODE.TEXT then
                    -- Today the protocol is server → client; log
                    -- and ignore client-side text so M2's command
                    -- channel slots in here cleanly.
                    logger.debug('ws ignoring inbound text', {
                        id = entry.id, len = #decoded.payload,
                    })
                end
            end
        end
        if not entry.closed then entry.closed = true end
        pcall(function() sock:close() end)
        registry.unregister(entry.id, 'reader_exit')
    end)
end

-- Writer loop. Runs in the http-rock's per-connection fiber so
-- that the rock's `process_client` does not return until the
-- WebSocket session is done — otherwise socket.tcp_server would
-- close the socket out from under us. Drains the connection's
-- queue and parks on notify_cond when idle.
local function run_writer_loop(entry, sock)
    fiber.name('webui_ws_writer_' .. entry.id, { truncate = true })
    while not entry.closed do
        local message = registry.pop(entry.id)
        if message == '__ping__' then
            local ok = safe_write(sock, frame.encode_ping(''))
            if ok == nil then entry.closed = true; break end
        elseif message ~= nil then
            local ok = safe_write(sock, frame.encode_text(message))
            if ok == nil then
                entry.closed = true
                break
            end
            logger.debug('ws message sent', {
                id = entry.id, bytes = #message,
            })
        else
            notify_cond:wait(M.WRITER_IDLE_SEC)
        end
    end
end

-- Heartbeat fiber: per-process, scans the registry, pings every
-- live connection, closes those that missed too many pongs.
local heartbeat_fiber = nil
local function ensure_heartbeat()
    if heartbeat_fiber ~= nil and heartbeat_fiber:status() ~= 'dead' then
        return
    end
    heartbeat_fiber = fiber.create(function()
        fiber.name('webui_ws_heartbeat', { truncate = true })
        while true do
            local now = os.time()
            for _, meta in ipairs(registry.list()) do
                local entry = registry.get(meta.id)
                if entry ~= nil and not entry.closed then
                    -- Send a ping every interval; close if we have
                    -- not heard a pong within the deadline.
                    if now - entry.last_pong > M.PONG_DEADLINE_SEC then
                        logger.warn('ws no pong, closing', {
                            id = entry.id,
                            silent_for_sec = now - entry.last_pong,
                        })
                        pcall(function()
                            if entry.close_fn then
                                entry.close_fn(frame.CLOSE.POLICY_VIOL, 'pong_timeout')
                            end
                        end)
                    elseif (now - entry.last_pong) >= M.PING_INTERVAL_SEC then
                        registry.enqueue(entry.id, '__ping__')
                        notify_cond:broadcast()
                    end
                end
            end
            fiber.sleep(M.HEARTBEAT_TICK_SEC)
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────
-- Endpoint
-- ─────────────────────────────────────────────────────────────────────

-- Returns the http-rock DETACHED sentinel after a successful
-- upgrade; the middleware passes it through unchanged. Failed
-- upgrades return a normal response table.
function M.handler(req)
    if req.method ~= 'GET' then
        return { status = 405, body = '', headers = {
            allow = 'GET', ['content-type'] = 'text/plain' } }
    end

    -- Origin allow-list. Reject early so a hostile page cannot
    -- even reach the upgrade phase.
    if not origin_allowed(req.headers) then
        logger.warn('ws origin rejected', {
            origin = req.headers and req.headers['origin'],
        })
        return {
            status = 403,
            body = 'origin not allowed',
            headers = { ['content-type'] = 'text/plain' },
        }
    end

    -- Authentication. Two paths:
    --   * production / default: read cookie `webui_session` and
    --     resolve it through the session storage.
    --   * `WEBUI_DEV_ANONYMOUS_WS=1`: skip auth entirely. The flag
    --     stays for the dev compose so contributors can browse the
    --     SPA without a real login.
    local auth_session
    local sid = parse_session_cookie(req.headers)
    if sid ~= nil then
        local sess = lazy_session()
        if sess ~= nil then
            auth_session = sess.get(sid)
        end
    end
    if auth_session == nil and not dev_anonymous_enabled() then
        logger.info('ws auth rejected', { reason = 'no_session' })
        return {
            status = 401,
            body = 'session required',
            headers = { ['content-type'] = 'text/plain' },
        }
    end

    local upgrade = req.headers and req.headers['upgrade'] or ''
    local connection = req.headers and req.headers['connection'] or ''
    local key = req.headers and req.headers['sec-websocket-key'] or ''
    if upgrade:lower() ~= 'websocket'
        or not connection:lower():find('upgrade', 1, true)
        or key == '' then
        return {
            status = 400,
            body = 'missing or invalid upgrade headers',
            headers = { ['content-type'] = 'text/plain' },
        }
    end

    local handshake = frame.handshake_response(key)
    local sock = req.s
    if sock == nil then
        logger.error('ws handler — no raw socket on request')
        return { status = 500, body = 'no socket' }
    end

    local entry, err = registry.register({
        ip = (req.peer and tostring(req.peer.host)) or nil,
        ua = req.headers and req.headers['user-agent'] or nil,
        session_id = sid,
        user       = auth_session and auth_session.user,
    })
    if entry == nil then
        local resp_body = 'too many connections'
        if err == 'limit_reached' then
            -- Return 503 so HAProxy and metrics flag it as overloaded.
            return {
                status = 503,
                body = resp_body,
                headers = { ['content-type'] = 'text/plain' },
            }
        end
        return { status = 500, body = resp_body }
    end

    -- Send the HTTP/1.1 101 first, then own the socket.
    local write_ok, write_err = pcall(function()
        sock:write(handshake)
    end)
    if not write_ok then
        registry.unregister(entry.id, 'handshake_write_failed')
        logger.warn('ws handshake write failed', { err = tostring(write_err) })
        return require('webui.http.server').DETACHED or 101
    end

    -- Close helper used by heartbeat / broadcast slow-consumer path.
    entry.close_fn = function(code, reason)
        if entry.closed then return end
        pcall(function()
            sock:write(frame.encode_close(code, reason))
        end)
        entry.closed = true
        pcall(function() sock:close() end)
        registry.unregister(entry.id, 'close_fn:' .. tostring(reason or code))
    end

    spawn_reader(entry, sock)
    ensure_heartbeat()

    -- Push the initial snapshot before the writer loop starts so
    -- the very first iteration drains a real message.
    local initial = jsonl({
        type = 'initial',
        connection_id = entry.id,
        cluster = state.snapshot(),
        issues = issues.current(),
        suggestions = suggestions.current(),
        ts = fiber.time(),
    })
    registry.enqueue(entry.id, initial)

    -- Block in the writer loop until the session is done. We are
    -- already inside the http rock's per-connection fiber, so
    -- keeping the loop here prevents socket.tcp_server from
    -- closing the socket — exactly what DETACHED requires.
    local writer_ok, writer_err = pcall(run_writer_loop, entry, sock)
    if not writer_ok then
        logger.warn('ws writer loop raised', {
            id = entry.id, err = tostring(writer_err),
        })
    end

    pcall(function() sock:close() end)
    registry.unregister(entry.id, 'writer_exit')

    return require('webui.http.server').DETACHED
end

-- Graceful shutdown — called by webui.stop().
function M.shutdown()
    registry.close_all(frame.CLOSE.GOING_AWAY, 'shutdown')
    notify_cond:broadcast()
end

function M.status()
    return {
        connections = registry.count(),
        limits      = registry.limits(),
        dev_anonymous = dev_anonymous_enabled(),
    }
end

return M
