--
-- In-memory rate limiter keyed by `(ip, action)`.
--
-- The limiter holds a sliding window: every miss increments the
-- counter, every successful login wipes it. The window resets
-- after WINDOW_SEC seconds with no failures. Storage is purely
-- local to the instance — the small budget (5 attempts per
-- minute per IP) makes the cost of cross-instance synchronisation
-- not worth paying.
--

local fiber = require('fiber')

local M = {}

M.MAX_FAILURES = 5
M.WINDOW_SEC   = 60

local state = {}

-- ─────────────────────────────────────────────────────────────────────
-- Pure helpers
-- ─────────────────────────────────────────────────────────────────────

-- Returns the entry's surviving fail count given the latest time.
-- If the last failure aged beyond WINDOW_SEC, the entry is reset.
function M.prune_entry(entry, now, window)
    if entry == nil then return nil end
    window = window or M.WINDOW_SEC
    if now - entry.last >= window then return nil end
    return entry
end

-- ─────────────────────────────────────────────────────────────────────
-- Public surface
-- ─────────────────────────────────────────────────────────────────────

local function key(ip, action)
    return tostring(ip or '_') .. '|' .. tostring(action or '_')
end

function M.check(ip, action)
    local k = key(ip, action)
    local entry = M.prune_entry(state[k], fiber.time(), M.WINDOW_SEC)
    state[k] = entry
    if entry == nil then return true end
    if entry.count >= M.MAX_FAILURES then
        return false, entry.count, M.WINDOW_SEC - (fiber.time() - entry.last)
    end
    return true
end

function M.fail(ip, action)
    local k = key(ip, action)
    local now = fiber.time()
    local entry = M.prune_entry(state[k], now, M.WINDOW_SEC)
        or { count = 0, last = now }
    entry.count = entry.count + 1
    entry.last  = now
    state[k] = entry
    return entry.count
end

function M.success(ip, action)
    state[key(ip, action)] = nil
end

function M._reset()
    state = {}
end

return M
