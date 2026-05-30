-- GET /api/health — two-level liveness/readiness endpoint.
--
-- Response shape:
--
--   200 OK   { status: "ok",       instance, tarantool_version, version, uptime_sec, role_state }
--   200 OK   { status: "degraded", instance, ..., checks: { etcd, peers, config, shutdown } }
--   503      { status: "unhealthy", instance, ..., checks: { ... } }
--
-- We return 200 for "degraded" so load balancers do NOT pull the instance
-- out of rotation; monitoring picks up the degraded flag via metrics and
-- the `checks` body.
--
-- Unhealthy criteria implemented in M0:
--   * role status != 'ready'
--   * TX-thread heartbeat is stale (now - last_heartbeat_at > 5s)
--
-- Degraded criteria implemented in M0:
--   * role status == 'starting' or 'stopping'
--   * shutdown in progress
--
-- Additional checks land as the relevant sub-systems come online:
--   * etcd reachability  → Task 30
--   * peer-poll majority → Task 17
--   * config convergence → Task 27

local json = require('json')
local fiber = require('fiber')

local version = require('webui.version')

local M = {}

local HEARTBEAT_STALE_SEC = 5

local function pick_status(checks, role_state)
    if role_state ~= 'ready' then
        if checks.shutdown == true then
            return 'degraded'
        end
        if checks.tx_thread == 'blocked' then
            return 'unhealthy'
        end
        if role_state == 'starting' or role_state == 'stopping' then
            return 'degraded'
        end
        return 'unhealthy'
    end
    if checks.tx_thread == 'blocked' then
        return 'unhealthy'
    end
    -- Degraded if any check is non-OK.
    for _, v in pairs(checks) do
        if v ~= 'ok' and v ~= false then
            return 'degraded'
        end
    end
    return 'ok'
end

-- Factory: returns a route handler closed over the role status provider.
-- status_provider() should return a table with at least:
--   { state, instance, started_at, last_heartbeat_at }
function M.make_handler(status_provider)
    assert(type(status_provider) == 'function', 'status_provider must be a function')

    return function(_req)
        local now = fiber.time()
        local role = status_provider() or {}
        local role_state = role.state or 'uninitialized'

        local heartbeat_age = nil
        if type(role.last_heartbeat_at) == 'number' then
            heartbeat_age = now - role.last_heartbeat_at
        end

        local checks = {
            tx_thread = (heartbeat_age == nil or heartbeat_age <= HEARTBEAT_STALE_SEC)
                and 'ok' or 'blocked',
            -- Stubs for upcoming sub-systems; they remain absent until
            -- their owners register a checker via M.register_check().
        }

        for name, fn in pairs(M._extra_checks) do
            local ok_call, verdict = pcall(fn)
            if not ok_call then
                checks[name] = 'check_error'
            else
                checks[name] = verdict or 'ok'
            end
        end

        local status = pick_status(checks, role_state)

        local body = {
            status = status,
            instance = role.instance,
            tarantool_version = _TARANTOOL,
            webui_version = version.SEMVER,
            role_state = role_state,
            uptime_sec = role.started_at and (now - role.started_at) or 0,
            checks = checks,
        }

        local http_status = 200
        if status == 'unhealthy' then
            http_status = 503
        end

        local headers = { ['content-type'] = 'application/json; charset=utf-8' }
        if http_status == 503 then
            headers['retry-after'] = '5'
        end

        return {
            status = http_status,
            headers = headers,
            body = json.encode(body),
        }
    end
end

-- Extension point: other sub-systems append their own checks. Each
-- check is a function returning a string verdict ('ok', 'down', 'slow', …)
-- or boolean false meaning "this is not a problem".
M._extra_checks = {}

function M.register_check(name, fn)
    assert(type(name) == 'string' and #name > 0, 'check name required')
    assert(type(fn) == 'function', 'check fn required')
    M._extra_checks[name] = fn
end

function M.unregister_check(name)
    M._extra_checks[name] = nil
end

return M
