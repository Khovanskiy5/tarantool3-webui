--
-- Net.box RPC fan-out over the peer pool.
--
-- `map_call(fn_name, args, opts)` issues an async `conn:call` against
-- every peer currently in the pool and collects the answers under a
-- shared deadline. The function never raises — every per-peer error
-- is captured in the result table — because the callers (admin API
-- handlers, the peer poller) need to render partial cluster state
-- when some peers are unavailable.
--
-- Result shape:
--   {
--     [<peer_name>] = { ok = true,  value = <call result>  },
--     [<peer_name>] = { ok = false, err   = <string>      },
--     ...
--   }
--
-- The shape is intentionally homogeneous so consumers can iterate
-- without a `pcall` per entry. Connections that are not yet
-- established at call time are marked `ok=false, err='not connected'`
-- rather than waited on indefinitely.
--

local checks = require('checks')
local fiber  = require('fiber')

local peers    = require('webui.cluster.peers')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('rpc')

local M = {}

-- Default per-call deadline. The poller (Task 17) ticks at 1.5s, so
-- giving a single call 1s leaves headroom for result aggregation
-- without breaking the cadence.
M.DEFAULT_TIMEOUT_SEC = 1.0

-- ── pure helpers (unit-testable) ─────────────────────────────────────

-- Convert the raw `wait_result` outcome to the homogeneous result
-- shape used by map_call. Pulled out so unit tests can drive every
-- branch without touching net.box.
function M.interpret_result(ok, value, err)
    if not ok then
        return { ok = false, err = tostring(err or value or 'pcall failed') }
    end
    if value == nil and err ~= nil then
        return { ok = false, err = tostring(err) }
    end
    -- conn:call returns the call's return values as an array; the
    -- typical resolver call is `function() return <one value> end`,
    -- so we unwrap a single-element array. Multi-return calls keep
    -- their array form so the caller can still inspect `value[2]`.
    if type(value) == 'table' and value[1] ~= nil and value[2] == nil then
        return { ok = true, value = value[1] }
    end
    return { ok = true, value = value }
end

-- ── public surface ──────────────────────────────────────────────────

-- map_call returns one result entry per peer, never raises.
-- Options:
--   * timeout  — per-call deadline; default 1s.
--   * peers    — optional whitelist of peer names; default all.
--   * args     — call arguments; default `{}`.
function M.map_call(fn_name, args, opts)
    checks('string', '?table', '?table')
    args = args or {}
    opts = opts or {}
    local timeout = tonumber(opts.timeout) or M.DEFAULT_TIMEOUT_SEC
    local whitelist
    if type(opts.peers) == 'table' then
        whitelist = {}
        for _, name in ipairs(opts.peers) do whitelist[name] = true end
    end

    local conns = peers.connections()
    local futures = {}
    local results = {}
    for name, conn in pairs(conns) do
        if whitelist == nil or whitelist[name] then
            local connected = false
            local s_ok, s = pcall(function() return conn.state end)
            if s_ok then
                -- net.box states: 'initial', 'active', 'graceful_shutdown',
                -- 'error', 'error_reconnect', 'closed', 'fetch_schema'.
                connected = (s == 'active' or s == 'fetch_schema')
            end
            if not connected then
                results[name] = { ok = false, err = 'not connected' }
            else
                local fut_ok, fut = pcall(function()
                    return conn:call(fn_name, args, { is_async = true })
                end)
                if not fut_ok then
                    results[name] = { ok = false, err = tostring(fut) }
                else
                    futures[name] = fut
                end
            end
        end
    end

    local deadline = fiber.clock() + timeout
    for name, fut in pairs(futures) do
        local remaining = math.max(0, deadline - fiber.clock())
        local ok, value, err = pcall(function()
            return fut:wait_result(remaining)
        end)
        results[name] = M.interpret_result(ok, value, err)
        if not results[name].ok then
            logger.warn('map_call peer failed', {
                fn   = fn_name,
                peer = name,
                err  = results[name].err,
            })
        else
            logger.debug('map_call peer ok', {
                fn   = fn_name,
                peer = name,
            })
        end
    end

    return results
end

return M
