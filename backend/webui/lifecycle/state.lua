--
-- Shared lifecycle state for the webui role.
--
-- The STATE table is mutable and shared by lifecycle/start.lua,
-- lifecycle/stop.lua, lifecycle/apply.lua and lifecycle/status() via
-- this single module instance (require() returns the same table on
-- every call thanks to package.loaded).
--
-- No global writes happen here — only locals through M.STATE.
--

local fiber    = require('fiber')

local log_util = require('webui.log_util')
local version  = require('webui.version')

local M = {}

-- Module-local lifecycle state. Never global.
M.STATE = {
    status = 'uninitialized',  -- uninitialized | starting | ready | stopping | stopped
    started_at = nil,
    config = nil,
    instance = nil,
}

function M.instance_alias()
    if rawget(_G, 'box') == nil then
        return nil
    end
    -- box.info is a table even before box.cfg has run, but its fields
    -- (.name, .cluster.name) hold NULL cdata until bootstrap completes.
    -- Treat only proper strings as a valid alias.
    local ok, info = pcall(function() return box.info end)
    if not ok or type(info) ~= 'table' then
        return nil
    end
    if type(info.name) == 'string' and info.name ~= '' then
        return info.name
    end
    if type(info.cluster) == 'table'
        and type(info.cluster.name) == 'string'
        and info.cluster.name ~= '' then
        return info.cluster.name
    end
    return nil
end

function M.configure_logging(opts)
    local explicit = opts.log_level
    local env_level = os.getenv('WEBUI_LOG_LEVEL')
    log_util.configure({
        level = explicit or env_level or 'debug',
        instance = M.instance_alias(),
    })
end

function M.status()
    local started = M.STATE.started_at
    return {
        state = M.STATE.status,
        version = version.SEMVER,
        tarantool = _TARANTOOL,
        instance = M.STATE.instance,
        started_at = started,
        uptime_sec = started and (fiber.time() - started) or 0,
        log_level = log_util.current_level(),
    }
end

return M
