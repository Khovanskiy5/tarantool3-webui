--
-- WebUI test server — thin wrapper around luatest.server.
--
-- luatest.server already knows how to spawn Tarantool 3.x with a
-- declarative YAML config and to net.box-eval into the running
-- process. This helper adds two project-specific touches:
--
--   1. It propagates the in-tree package.path so the spawned process
--      finds the WebUI backend modules without a rocks install.
--   2. It exposes wait_webui_ready(), which polls /api/health until
--      the role lifecycle transitions to "ready".
--
-- Usage:
--   local Server = require('test.helpers.server')
--   local s = Server:new({
--       alias       = 'tt-test',
--       config_file = paths.cluster_seed_dir .. '/40-topology.yaml',
--       webui_port  = 8081,
--   })
--   s:start()
--   s:wait_webui_ready()
--   ...
--   s:stop()
--

local checks = require('checks')
local fiber  = require('fiber')
local http_client = require('http.client')
local json   = require('json')

local paths = require('test.helpers.paths')
paths.setup_package_path()

local luatest_server = require('luatest.server')

local Server = luatest_server:inherit({})

-- ── construction ──────────────────────────────────────────────────────

function Server:new(object)
    checks('table', {
        alias       = '?string',
        config_file = '?string',
        webui_port  = '?number',
        net_box_uri = '?string',
        env         = '?table',
        args        = '?table',
        workdir     = '?string',
    })
    object = object or {}

    -- Forward LUA_PATH / LUA_CPATH so the spawned process can require
    -- backend modules. luatest merges `env` with its own defaults.
    object.env = object.env or {}
    object.env.LUA_PATH = (object.env.LUA_PATH or package.path)
    object.env.LUA_CPATH = (object.env.LUA_CPATH or package.cpath)
    object.env.WEBUI_LOG_LEVEL = object.env.WEBUI_LOG_LEVEL or 'info'

    object.webui_port = object.webui_port or 8081

    return luatest_server.new(self, object)
end

-- ── health probe ──────────────────────────────────────────────────────

local function probe(self)
    local client = http_client.new()
    local url = ('http://127.0.0.1:%d/api/health'):format(self.webui_port)
    local ok, res = pcall(function()
        return client:request('GET', url, nil, { timeout = 1 })
    end)
    if not ok or res == nil then return nil, tostring(res) end
    if res.status ~= 200 then
        return nil, ('HTTP %d'):format(res.status)
    end
    local body_ok, body = pcall(json.decode, res.body or '')
    if not body_ok then return nil, 'invalid JSON body' end
    return body
end

-- Block until /api/health returns `status: "ok"` (or "degraded" — both
-- mean the role transitioned to ready and the listener is up).
-- Raises on timeout to keep test failures loud.
function Server:wait_webui_ready(timeout)
    timeout = timeout or 30
    local deadline = fiber.clock() + timeout
    local last_err
    while fiber.clock() < deadline do
        local body, err = probe(self)
        if body ~= nil and (body.status == 'ok' or body.status == 'degraded') then
            return body
        end
        last_err = err
        fiber.sleep(0.2)
    end
    error(('webui not ready within %ds: %s'):format(timeout, tostring(last_err)), 2)
end

-- Convenience: return the parsed last health response without polling.
function Server:webui_health()
    return probe(self)
end

-- Convenience: the base URL of the WebUI on this instance.
function Server:webui_base_url()
    return ('http://127.0.0.1:%d'):format(self.webui_port)
end

return Server
