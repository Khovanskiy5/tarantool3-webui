--
-- Maintenance-window pause for the supervised failover agent.
--
-- The operator may want to stop an instance for an hour without
-- triggering an automatic re-election. We model this as a single
-- etcd key `<prefix>/failover/pause = {until_ts, by_user}`. The
-- coordinator's appointment_cycle reads it on every tick and
-- short-circuits new promotions when the pause is active.
--
-- Hard cap: MAX_PAUSE_TTL_SEC = 24h. Anything longer should be a
-- cluster-wide `replication.failover: off` edit (no agent), not a
-- runtime pause — otherwise an operator forgets and the cluster
-- silently runs unsupervised for weeks.
--

local json = require('json')
local fiber = require('fiber')

local M = {}

M.MAX_PAUSE_TTL_SEC = 24 * 60 * 60      -- 24 hours
M.DEFAULT_TTL_SEC   = 60 * 60           -- 1 hour
M.KEY               = 'failover/pause'

local function client_or_err(client)
    if client == nil then return nil, 'etcd client unavailable' end
    return client, nil
end

-- read(client) → ({until_ts, by_user, ts}, nil) when active;
-- (nil, nil) when key absent or expired; (nil, err) on transport
-- failure.
function M.read(client)
    local c, err = client_or_err(client)
    if c == nil then return nil, err end
    local kv, get_err = c:get(M.KEY)
    if get_err ~= nil then return nil, get_err end
    if kv == nil or kv.value == nil then return nil, nil end
    local ok, decoded = pcall(json.decode, kv.value)
    if not ok or type(decoded) ~= 'table' then return nil, nil end
    if type(decoded.until_ts) ~= 'number'
        or decoded.until_ts <= fiber.time() then
        return nil, nil
    end
    return decoded, nil
end

-- is_active(client) → bool. Convenience wrapper for the agent.
function M.is_active(client)
    local entry = M.read(client)
    return entry ~= nil
end

-- set(client, ttl_sec, by_user) → ({until_ts}, nil) | (nil, err)
function M.set(client, ttl_sec, by_user)
    local c, err = client_or_err(client)
    if c == nil then return nil, err end
    ttl_sec = tonumber(ttl_sec) or M.DEFAULT_TTL_SEC
    if ttl_sec <= 0 then ttl_sec = M.DEFAULT_TTL_SEC end
    if ttl_sec > M.MAX_PAUSE_TTL_SEC then
        return nil, 'PAUSE_TTL_TOO_LONG'
    end
    local until_ts = fiber.time() + ttl_sec
    local payload = json.encode({
        until_ts = until_ts,
        by_user  = by_user or '?',
        ts       = fiber.time(),
    })
    local _, put_err = c:put(M.KEY, payload)
    if put_err ~= nil then return nil, put_err end
    return { until_ts = until_ts }, nil
end

-- clear(client) → (true, nil) | (nil, err)
function M.clear(client)
    local c, err = client_or_err(client)
    if c == nil then return nil, err end
    local _, derr = c:delete(M.KEY)
    if derr ~= nil then return nil, derr end
    return true, nil
end

return M
