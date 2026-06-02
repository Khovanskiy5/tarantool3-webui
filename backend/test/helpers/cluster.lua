--
-- WebUI test cluster — thin wrapper around luatest.cluster.
--
-- luatest.cluster handles instance enumeration from a cluster YAML and
-- the per-instance start/stop/exec plumbing. This helper adds:
--
--   * Package-path wiring so each spawned process finds backend modules
--     without `tt rocks install`.
--   * wait_all_webui_ready() that walks the cluster and polls every
--     instance's /api/health until the slowest one transitions to
--     ready (or the timeout fires).
--   * Port allocation: webui_port_of(name) lets tests reach individual
--     instances over plain HTTP without going through HAProxy.
--
-- Usage:
--   local Cluster = require('test.helpers.cluster')
--   local cl = Cluster:new({
--       config_file = paths.cluster_seed_dir .. '/40-topology.yaml',
--       webui_ports = { ['tt-1'] = 18081, ['tt-2'] = 18082, ['tt-3'] = 18083 },
--   })
--   cl:start()
--   cl:wait_all_webui_ready()
--   ...
--   cl:drop()
--

local checks = require('checks')
local fiber  = require('fiber')

local paths = require('test.helpers.paths')
paths.setup_package_path()

local luatest_cluster = require('luatest.cluster')
local WebuiServer    = require('test.helpers.server')

local Cluster = {}

function Cluster:new(object)
    checks('table', {
        config_file = '?string',
        config      = '?table',
        webui_ports = '?table',
        env         = '?table',
    })
    object = object or {}
    assert(object.config_file ~= nil or object.config ~= nil,
        'Cluster:new requires config_file or config')

    -- Pre-build the underlying luatest cluster. We let luatest discover
    -- instances from the YAML; webui_ports map is applied later when
    -- we project the cluster into our health-aware Server wrappers.
    local config_arg
    if object.config_file then
        local f = io.open(object.config_file, 'r')
        assert(f, 'cannot open ' .. object.config_file)
        local yaml = require('yaml')
        config_arg = yaml.decode(f:read('*a'))
        f:close()
    else
        config_arg = object.config
    end

    local instance = {
        _luatest_cluster = luatest_cluster:new(config_arg),
        _webui_ports = object.webui_ports or {},
        _env = object.env or {},
    }
    setmetatable(instance, { __index = self })
    return instance
end

function Cluster:start()
    self._luatest_cluster:start()
    return self
end

function Cluster:drop()
    self._luatest_cluster:drop()
end

function Cluster:stop()
    self._luatest_cluster:stop()
end

function Cluster:size()
    return self._luatest_cluster:size()
end

function Cluster:each(fn)
    self._luatest_cluster:each(fn)
end

-- Return the WebUI HTTP port associated with an instance alias.
function Cluster:webui_port_of(alias)
    return self._webui_ports[alias]
end

-- Walk the cluster, probe every instance, return as soon as all are
-- ready or fail loudly on timeout. The probe re-uses the standalone
-- server helper's wait function so the wait semantics are identical
-- whether a test runs against a single server or a cluster.
function Cluster:wait_all_webui_ready(timeout)
    timeout = timeout or 60
    local deadline = fiber.clock() + timeout
    self._luatest_cluster:each(function(server)
        local port = self:webui_port_of(server.alias)
        if port == nil then return end
        local probe_server = WebuiServer:new({
            alias = server.alias,
            webui_port = port,
            config_file = '',
        })
        local remaining = math.max(0.1, deadline - fiber.clock())
        probe_server:wait_webui_ready(remaining)
    end)
end

return Cluster
