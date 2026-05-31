-- Unit test for the graceful-shutdown registry (Task 3a).
--
-- The registry is pure Lua + fiber primitives — no http stack
-- required. We exercise the public surface directly: acquire /
-- release for inflight counting, mark_draining + bypasses_drain
-- for the gate, and wait_drain for the cond/timeout path.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' ..
               repo_root .. '/backend/?/init.lua;' ..
               package.path

local g = t.group('http_shutdown')

local fiber = require('fiber')
local shutdown = require('webui.http.shutdown')

g.before_each(function() shutdown.reset() end)

g.test_idle_registry = function()
    t.assert_equals(shutdown.is_draining(), false)
    t.assert_equals(shutdown.inflight_count(), 0)
end

g.test_acquire_increments_and_release_decrements = function()
    local r1 = shutdown.acquire()
    t.assert_equals(shutdown.inflight_count(), 1)
    local r2 = shutdown.acquire()
    t.assert_equals(shutdown.inflight_count(), 2)
    r1()
    t.assert_equals(shutdown.inflight_count(), 1)
    r2()
    t.assert_equals(shutdown.inflight_count(), 0)
end

g.test_release_is_idempotent = function()
    local r = shutdown.acquire()
    r()
    r()  -- second call must not push the counter negative
    r()
    t.assert_equals(shutdown.inflight_count(), 0)
end

g.test_mark_draining_flips_the_flag = function()
    t.assert_equals(shutdown.is_draining(), false)
    shutdown.mark_draining()
    t.assert_equals(shutdown.is_draining(), true)
    -- Double-call must remain idempotent.
    shutdown.mark_draining()
    t.assert_equals(shutdown.is_draining(), true)
end

g.test_health_endpoint_bypasses_drain = function()
    t.assert_equals(shutdown.bypasses_drain('/api/health'), true)
    t.assert_equals(shutdown.bypasses_drain('/admin/api'), false)
    t.assert_equals(shutdown.bypasses_drain('/api/eval'), false)
end

g.test_wait_drain_returns_immediately_when_idle = function()
    local started = fiber.time()
    local ok = shutdown.wait_drain(5)
    local elapsed = fiber.time() - started
    t.assert_equals(ok, true)
    t.assert(elapsed < 0.1, 'wait_drain on idle registry should be instant')
end

g.test_wait_drain_blocks_until_release = function()
    local release = shutdown.acquire()
    local done = false
    local resolved
    fiber.create(function()
        resolved = shutdown.wait_drain(2)
        done = true
    end)
    fiber.sleep(0.05)
    t.assert_equals(done, false, 'wait_drain must block while inflight>0')
    release()
    -- Yield once so the waiter wakes up from the cond:broadcast.
    fiber.sleep(0.05)
    t.assert_equals(done, true)
    t.assert_equals(resolved, true)
end

g.test_wait_drain_times_out = function()
    local _ = shutdown.acquire()  -- never released
    local started = fiber.time()
    local ok = shutdown.wait_drain(0.2)
    local elapsed = fiber.time() - started
    t.assert_equals(ok, false)
    t.assert(elapsed >= 0.15, 'wait_drain returned before the timeout window')
    t.assert(elapsed < 0.6, 'wait_drain exceeded the timeout window by more than 2x')
end
