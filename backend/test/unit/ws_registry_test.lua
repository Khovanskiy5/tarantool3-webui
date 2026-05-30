-- Unit tests for backend/webui/http/ws_registry.lua
--
-- All assertions hit the in-memory registry. Production wires the
-- registry to a live socket via send_fn / close_fn; the unit test
-- substitutes plain closures so the lifecycle can be exercised
-- without a TCP listener.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local registry = require('webui.http.ws_registry')

local g = t.group('ws_registry')

g.before_each(function() registry._reset() end)

-- ── registration / unregister ───────────────────────────────────────

g.test_register_assigns_unique_ids = function()
    local a = registry.register({ ip = '10.0.0.1' })
    local b = registry.register({ ip = '10.0.0.2' })
    t.assert(a.id ~= b.id)
    t.assert_equals(registry.count(), 2)
end

g.test_register_carries_metadata = function()
    local e = registry.register({ ip = '10.0.0.5', ua = 'curl/8' })
    t.assert_equals(e.ip, '10.0.0.5')
    t.assert_equals(e.ua, 'curl/8')
    t.assert_equals(e.backlog_size, 0)
end

g.test_register_respects_max_connections = function()
    registry.set_limits({ max_connections = 2 })
    registry.register({ ip = 'a' })
    registry.register({ ip = 'b' })
    local entry, err = registry.register({ ip = 'c' })
    t.assert_equals(entry, nil)
    t.assert_equals(err, 'limit_reached')
end

g.test_unregister_removes_entry_and_records_reason = function()
    local e = registry.register({ ip = 'x' })
    registry.unregister(e.id, 'bye')
    t.assert_equals(registry.count(), 0)
    t.assert(e.closed)
end

g.test_unregister_unknown_id_is_noop = function()
    -- Idempotency matters when both the reader and writer fiber
    -- race to teardown the same connection.
    registry.unregister(99, 'reaper')
    -- no error → success
end

-- ── queue / enqueue / pop ──────────────────────────────────────────

g.test_enqueue_increments_backlog_and_pop_drains = function()
    local e = registry.register({ ip = 'q' })
    local ok = registry.enqueue(e.id, 'm1')
    t.assert_equals(ok, true)
    t.assert_equals(e.backlog_size, 1)
    ok = registry.enqueue(e.id, 'm2')
    t.assert_equals(ok, true)
    t.assert_equals(e.backlog_size, 2)
    t.assert_equals(registry.pop(e.id), 'm1')
    t.assert_equals(e.backlog_size, 1)
    t.assert_equals(registry.pop(e.id), 'm2')
    t.assert_equals(e.backlog_size, 0)
    t.assert_equals(registry.pop(e.id), nil)
end

g.test_enqueue_overflow_returns_error = function()
    registry.set_limits({ backlog_limit = 3 })
    local e = registry.register({})
    for i = 1, 3 do registry.enqueue(e.id, 'm' .. i) end
    local ok, err = registry.enqueue(e.id, 'overflow')
    t.assert_equals(ok, false)
    t.assert_equals(err, 'backlog_overflow')
end

g.test_enqueue_on_closed_connection_fails = function()
    local e = registry.register({})
    registry.unregister(e.id, 'closed')
    local ok, err = registry.enqueue(e.id, 'm')
    t.assert_equals(ok, false)
    t.assert_equals(err, 'no_connection')
end

-- ── broadcast + slow consumer detection ─────────────────────────────

g.test_broadcast_fans_to_every_live_connection = function()
    local a = registry.register({})
    local b = registry.register({})
    local result = registry.broadcast('payload')
    t.assert_equals(result.sent, 2)
    t.assert_equals(result.dropped, 0)
    t.assert_equals(registry.pop(a.id), 'payload')
    t.assert_equals(registry.pop(b.id), 'payload')
end

g.test_broadcast_drops_and_closes_slow_consumer = function()
    registry.set_limits({ backlog_limit = 1 })
    local close_called_with
    local e = registry.register({
        close_fn = function(code, reason) close_called_with = { code, reason } end,
    })
    registry.enqueue(e.id, 'pre')      -- fill the backlog
    local res = registry.broadcast('again')
    t.assert_equals(res.sent, 0)
    t.assert_equals(res.dropped, 1)
    t.assert_equals(close_called_with[1], 1008)
    t.assert_equals(close_called_with[2], 'backlog_overflow')
end

-- ── pong tracking ───────────────────────────────────────────────────

g.test_update_pong_refreshes_timestamp = function()
    local e = registry.register({})
    local before = e.last_pong
    registry.update_pong(e.id, before + 100)
    t.assert_equals(e.last_pong, before + 100)
end

g.test_update_pong_for_unknown_id_is_noop = function()
    registry.update_pong(42)
end

-- ── close_all (shutdown) ────────────────────────────────────────────

g.test_close_all_calls_close_fn_and_clears_registry = function()
    local closed = {}
    registry.register({
        close_fn = function(code, reason)
            table.insert(closed, { code, reason }) end,
    })
    registry.register({
        close_fn = function(code, reason)
            table.insert(closed, { code, reason }) end,
    })
    registry.close_all(1001, 'shutdown')
    t.assert_equals(registry.count(), 0)
    t.assert_equals(#closed, 2)
    t.assert_equals(closed[1][1], 1001)
end

-- ── list / count ────────────────────────────────────────────────────

g.test_list_returns_sorted_metadata = function()
    registry.register({ ip = '10.0.0.1' })
    registry.register({ ip = '10.0.0.2' })
    registry.register({ ip = '10.0.0.3' })
    local list = registry.list()
    t.assert_equals(#list, 3)
    -- Sort order by id.
    t.assert(list[1].id < list[2].id and list[2].id < list[3].id)
    -- Production-relevant fields only, no socket refs.
    t.assert(list[1].queue == nil, 'queue must not leak into list()')
end

-- ── module constants ────────────────────────────────────────────────

g.test_default_limits_match_plan = function()
    t.assert_equals(registry.DEFAULT_MAX_CONNECTIONS, 100)
    t.assert_equals(registry.DEFAULT_BACKLOG_LIMIT, 1000)
end

g.test_would_exceed_limit_pure_helper = function()
    t.assert_equals(registry.would_exceed_limit(0, 1), false)
    t.assert_equals(registry.would_exceed_limit(1, 1), true)
    t.assert_equals(registry.would_exceed_limit(99, 100), false)
    t.assert_equals(registry.would_exceed_limit(100, 100), true)
end
