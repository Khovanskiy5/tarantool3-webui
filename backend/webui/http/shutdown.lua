--
-- HTTP graceful-shutdown registry (Task 3a).
--
-- Owns two pieces of process-local state:
--
--   1. A `draining` flag. While true, the middleware refuses every
--      new request with `503 SHUTTING_DOWN` + `Retry-After`. A small
--      whitelist (the health probe) bypasses the gate so monitoring
--      keeps seeing `degraded`.
--
--   2. An in-flight counter that wraps every handler invocation.
--      Stop() can then `wait_drain(timeout)` until the counter hits
--      zero before tearing down sub-systems. The counter uses a
--      `fiber.cond` so the wait wakes up exactly when the last
--      in-flight request finishes.
--
-- The module is loaded lazily by middleware.lua via pcall so a unit
-- test environment without the http stack does not see import
-- errors. State is module-local — there is exactly one shutdown
-- registry per Tarantool process, mirroring the singleton http
-- server.
--

local fiber = require('fiber')

local M = {}

local STATE = {
    draining   = false,
    inflight   = 0,
    cond       = fiber.cond(),
}

-- Routes that must keep answering even while the role drains. The
-- health probe is the canonical one — its only job is to report the
-- draining state back to load balancers.
local DRAIN_BYPASS = {
    ['/api/health'] = true,
}

function M.is_draining()
    return STATE.draining == true
end

function M.mark_draining()
    if STATE.draining then return end
    STATE.draining = true
end

-- Test hook + role start path. Reset to a clean slate.
function M.reset()
    STATE.draining = false
    STATE.inflight = 0
    STATE.cond     = fiber.cond()
end

function M.bypasses_drain(path)
    return DRAIN_BYPASS[path] == true
end

function M.inflight_count()
    return STATE.inflight
end

-- Bump the in-flight counter for the duration of a handler call.
-- Returns a release function so callers can pair acquire/release in
-- a single line: `local rel = shutdown.acquire(); ... rel()`. The
-- release closure is idempotent — calling it twice is a no-op so a
-- handler that yields and then errors does not double-decrement.
function M.acquire()
    STATE.inflight = STATE.inflight + 1
    local released = false
    return function()
        if released then return end
        released = true
        STATE.inflight = STATE.inflight - 1
        if STATE.inflight <= 0 then
            STATE.inflight = 0
            STATE.cond:broadcast()
        end
    end
end

-- Wait at most `timeout_sec` for the in-flight counter to reach
-- zero. Returns true on clean drain, false on timeout. The caller
-- is expected to log the verdict; this module stays silent so it
-- can be unit-tested without log capture.
function M.wait_drain(timeout_sec)
    timeout_sec = tonumber(timeout_sec) or 10
    local deadline = fiber.time() + timeout_sec
    while STATE.inflight > 0 do
        local remaining = deadline - fiber.time()
        if remaining <= 0 then
            return false
        end
        STATE.cond:wait(remaining)
    end
    return true
end

return M
