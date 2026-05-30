--
-- WebSocket connection registry.
--
-- Holds metadata for every live WS session: a synthetic ID, the
-- placeholder session id (auth fills it in M2), origin IP / UA,
-- creation timestamp, last received pong, and the size of the
-- pending outbound queue. The registry is also the broadcast fan-
-- out point — `broadcast(message)` walks every connection and
-- enqueues the message on its queue.
--
-- The registry exposes the limits documented in the plan as
-- module-level constants so they can be unit-tested. Production
-- code reads them via the public API.
--

local checks = require('checks')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('ws_registry')

local M = {}

M.DEFAULT_MAX_CONNECTIONS = 100
M.DEFAULT_BACKLOG_LIMIT   = 1000

local STATE = {
    by_id  = {},
    seq    = 0,
    limits = {
        max_connections = M.DEFAULT_MAX_CONNECTIONS,
        backlog_limit   = M.DEFAULT_BACKLOG_LIMIT,
    },
}

local function next_id()
    STATE.seq = STATE.seq + 1
    return STATE.seq
end

-- Pure helper: is the supplied count at or above the configured
-- limit? Used by the endpoint before accepting a new connection.
function M.would_exceed_limit(current_count, limit)
    return current_count >= (limit or M.DEFAULT_MAX_CONNECTIONS)
end

function M.set_limits(opts)
    checks({ max_connections = '?number', backlog_limit = '?number' })
    opts = opts or {}
    if opts.max_connections then STATE.limits.max_connections = opts.max_connections end
    if opts.backlog_limit   then STATE.limits.backlog_limit   = opts.backlog_limit   end
end

function M.limits() return STATE.limits end

-- Register a new connection. Returns the registry entry on
-- success, or `nil, 'limit_reached'` when the max-connections
-- limit would be exceeded.
function M.register(meta)
    checks({
        ip = '?string',
        ua = '?string',
        session_id = '?string',
        user       = '?string',
        send_fn = '?function',
        close_fn = '?function',
    })
    meta = meta or {}
    local count = 0
    for _ in pairs(STATE.by_id) do count = count + 1 end
    if M.would_exceed_limit(count, STATE.limits.max_connections) then
        logger.warn('ws connection rejected — max-connections limit reached', {
            current = count, limit = STATE.limits.max_connections,
        })
        return nil, 'limit_reached'
    end
    local id = next_id()
    local now = os.time()
    local entry = {
        id           = id,
        session_id   = meta.session_id,
        user         = meta.user,
        ip           = meta.ip,
        ua           = meta.ua,
        created_at   = now,
        last_pong    = now,
        backlog_size = 0,
        queue        = {},
        closed       = false,
        send_fn      = meta.send_fn,
        close_fn     = meta.close_fn,
    }
    STATE.by_id[id] = entry
    logger.info('ws connection registered', {
        id = id, ip = meta.ip, ua = meta.ua,
    })
    return entry
end

function M.unregister(id, reason)
    checks('number', '?string')
    local entry = STATE.by_id[id]
    if entry == nil then return end
    entry.closed = true
    STATE.by_id[id] = nil
    logger.info('ws connection unregistered', { id = id, reason = reason })
end

function M.update_pong(id, ts)
    local entry = STATE.by_id[id]
    if entry == nil then return end
    entry.last_pong = ts or os.time()
end

-- Push a message onto a single connection's outbound queue. The
-- caller is responsible for handling the limit overshoot (close
-- with 1008). The function returns true on success and
-- `false, 'backlog_overflow'` when the limit is reached.
function M.enqueue(id, message)
    local entry = STATE.by_id[id]
    if entry == nil or entry.closed then return false, 'no_connection' end
    if entry.backlog_size >= STATE.limits.backlog_limit then
        return false, 'backlog_overflow'
    end
    table.insert(entry.queue, message)
    entry.backlog_size = entry.backlog_size + 1
    return true
end

function M.pop(id)
    local entry = STATE.by_id[id]
    if entry == nil then return nil end
    local message = table.remove(entry.queue, 1)
    if message ~= nil then
        entry.backlog_size = entry.backlog_size - 1
    end
    return message
end

function M.is_closed(id)
    local entry = STATE.by_id[id]
    if entry == nil then return true end
    return entry.closed == true
end

-- Broadcast the same message to every live connection. The fan-out
-- returns counts so the caller can log appearance / drop signals.
function M.broadcast(message)
    local sent, dropped = 0, 0
    for id, entry in pairs(STATE.by_id) do
        if not entry.closed then
            local ok, err = M.enqueue(id, message)
            if ok then
                sent = sent + 1
            else
                dropped = dropped + 1
                logger.warn('ws broadcast drop — slow consumer', {
                    id = id, err = err, backlog = entry.backlog_size,
                })
                if entry.close_fn ~= nil then
                    pcall(entry.close_fn, 1008, 'backlog_overflow')
                end
            end
        end
    end
    return { sent = sent, dropped = dropped }
end

-- For shutdown: walk every connection and call its close_fn
-- (typically encode + send 1001 Going Away). The caller still has
-- to wait for the per-connection fibers to drain.
function M.close_all(code, reason)
    for id, entry in pairs(STATE.by_id) do
        if entry.close_fn ~= nil then
            pcall(entry.close_fn, code, reason)
        end
        entry.closed = true
        STATE.by_id[id] = nil
        logger.info('ws connection closed at shutdown', { id = id })
    end
end

-- Snapshot of registry metadata for diagnostic endpoints.
function M.list()
    local out = {}
    for id, entry in pairs(STATE.by_id) do
        table.insert(out, {
            id           = id,
            session_id   = entry.session_id,
            user         = entry.user,
            ip           = entry.ip,
            ua           = entry.ua,
            created_at   = entry.created_at,
            last_pong    = entry.last_pong,
            backlog_size = entry.backlog_size,
        })
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function M.count()
    local n = 0
    for _ in pairs(STATE.by_id) do n = n + 1 end
    return n
end

function M.get(id) return STATE.by_id[id] end

-- Walk every connection owned by `session_id`, run its close_fn
-- (typically 1001 Going Away) and drop it from the registry.
-- Used by auth.logout to enforce session revocation in real time.
function M.close_by_session(session_id, reason)
    if type(session_id) ~= 'string' or session_id == '' then return 0 end
    local closed = 0
    for id, entry in pairs(STATE.by_id) do
        if entry.session_id == session_id then
            if entry.close_fn ~= nil then
                pcall(entry.close_fn, 1001, reason or 'logout')
            end
            entry.closed = true
            STATE.by_id[id] = nil
            closed = closed + 1
        end
    end
    if closed > 0 then
        logger.info('ws sessions force-closed', {
            session_id = session_id, reason = reason, count = closed,
        })
    end
    return closed
end

-- Test hook.
function M._reset()
    STATE.by_id = {}
    STATE.seq = 0
    STATE.limits.max_connections = M.DEFAULT_MAX_CONNECTIONS
    STATE.limits.backlog_limit   = M.DEFAULT_BACKLOG_LIMIT
end

return M
