--
-- Offline unit tests for the test helper modules themselves.
--
-- We do not start Tarantool or etcd here — those flows are covered by
-- integration tests. The point of this file is to keep the helpers'
-- public surface stable: if someone breaks
-- `require('test.helpers.<name>')` or removes a method, this test
-- fails fast in CI without needing Docker.
--
-- The test layout matches backend/test/unit/version_test.lua: a
-- standalone runner that exits with non-zero on failure so it slots
-- into the existing luatest target without configuration.

local fio = require('fio')

-- Bring the in-tree backend modules and rocks onto the package path
-- before any helper require runs. The dirname chain matches
-- `<repo>/backend/test/unit/helpers_test.lua` -> `<repo>`.
local source_path = debug.getinfo(1, 'S').source:sub(2)
local repo_root = fio.abspath(
    fio.dirname(fio.dirname(fio.dirname(fio.dirname(source_path))))
)
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. repo_root .. '/.rocks/share/tarantool/?.lua;'
            .. repo_root .. '/.rocks/share/tarantool/?/init.lua;'
            .. package.path
package.cpath = repo_root .. '/.rocks/lib/tarantool/?.so;'
             .. repo_root .. '/.rocks/lib/tarantool/?.dylib;'
             .. package.cpath

local t = require('luatest')
local g = t.group('helpers')

-- ── paths ────────────────────────────────────────────────────────────

g.test_paths_module = function()
    local paths = require('test.helpers.paths')
    t.assert_type(paths.repo_root, 'string')
    t.assert_type(paths.backend_dir, 'string')
    t.assert_type(paths.docker_compose, 'string')
    t.assert_equals(fio.path.exists(paths.backend_dir), true,
        'paths.backend_dir must point at an existing directory')
    -- setup_package_path is idempotent: once the backend prefixes are
    -- on the path, calling it again must not change package.path.
    paths.setup_package_path()
    t.assert(package.path:find(paths.backend_dir, 1, true) ~= nil,
        'package.path must contain the backend dir after setup')
    local snapshot = package.path
    paths.setup_package_path()
    t.assert_equals(package.path, snapshot,
        'setup_package_path must be idempotent after the first call')
end

-- ── server ───────────────────────────────────────────────────────────

g.test_server_module_loads = function()
    local Server = require('test.helpers.server')
    t.assert_type(Server, 'table')
    -- Methods we add on top of luatest.server's public surface:
    t.assert_type(Server.wait_webui_ready, 'function')
    t.assert_type(Server.webui_health, 'function')
    t.assert_type(Server.webui_base_url, 'function')
end

g.test_server_base_url_format = function()
    local Server = require('test.helpers.server')
    -- Build an instance just enough to test webui_base_url without
    -- spawning Tarantool — set the port on a bare metatable copy.
    local fake = setmetatable({ webui_port = 12345 }, { __index = Server })
    t.assert_equals(fake:webui_base_url(), 'http://127.0.0.1:12345')
end

-- ── cluster ──────────────────────────────────────────────────────────

g.test_cluster_module_loads = function()
    local Cluster = require('test.helpers.cluster')
    t.assert_type(Cluster, 'table')
    t.assert_type(Cluster.new, 'function')
    t.assert_type(Cluster.wait_all_webui_ready, 'function')
    t.assert_type(Cluster.webui_port_of, 'function')
end

g.test_cluster_port_lookup = function()
    local Cluster = require('test.helpers.cluster')
    local fake = setmetatable({
        _webui_ports = { ['tt-1'] = 18081, ['tt-2'] = 18082 },
    }, { __index = Cluster })
    t.assert_equals(fake:webui_port_of('tt-1'), 18081)
    t.assert_equals(fake:webui_port_of('tt-2'), 18082)
    t.assert_equals(fake:webui_port_of('tt-3'), nil)
end

-- ── etcd ─────────────────────────────────────────────────────────────

g.test_etcd_module_surface = function()
    local etcd = require('test.helpers.etcd')
    t.assert_type(etcd.attach, 'function')
    t.assert_type(etcd.spawn, 'function')
    local client = etcd.attach({ endpoint = 'http://127.0.0.1:65535' })
    t.assert_equals(client:endpoint(), 'http://127.0.0.1:65535')
    -- Helpers should refuse non-string keys/values via :checks
    t.assert_error(function() client:put(nil, 'x') end)
    t.assert_error(function() client:get(123) end)
end

-- ── http_client ──────────────────────────────────────────────────────

g.test_http_client_constructor = function()
    local Client = require('test.helpers.http_client')
    local c = Client:new({ base_url = 'http://localhost:8080/' })
    t.assert_type(c, 'table')
    -- Trailing slash gets normalized away to avoid double slashes when
    -- the caller passes paths like '/admin/api'.
    t.assert_equals(c._base_url, 'http://localhost:8080')
    t.assert_equals(c._graphql_path, '/admin/api')

    -- Custom timeout + custom GraphQL path are preserved.
    local c2 = Client:new({
        base_url = 'http://localhost:8080',
        timeout = 17,
        graphql_path = '/custom/gql',
    })
    t.assert_equals(c2._timeout, 17)
    t.assert_equals(c2._graphql_path, '/custom/gql')

    -- Missing base_url is a programmer error and should be loud.
    t.assert_error(function() Client:new({}) end)
end

g.test_http_client_cookie_jar = function()
    local Client = require('test.helpers.http_client')
    local c = Client:new({ base_url = 'http://localhost:8080' })
    -- Round-trip a typical Set-Cookie from the WebUI session middleware.
    c._cookies:merge_set_cookie('tarantool_sid=abc123; Path=/; HttpOnly; SameSite=Strict')
    t.assert_equals(c._cookies:get('tarantool_sid'), 'abc123')
    t.assert_equals(c._cookies:to_header(), 'tarantool_sid=abc123')
    -- Empty / nil headers should be a no-op, not a crash.
    c._cookies:merge_set_cookie(nil)
    c._cookies:merge_set_cookie('')
    t.assert_equals(c._cookies:get('tarantool_sid'), 'abc123')
end

g.test_http_client_login_is_unimplemented = function()
    local Client = require('test.helpers.http_client')
    local c = Client:new({ base_url = 'http://localhost:8080' })
    -- Auth lands in Task 25. The stub error documents that and stops
    -- test code from silently passing against an unauthenticated
    -- backend.
    t.assert_error_msg_contains('not implemented', function()
        c:login('admin', 'password')
    end)
end

g.test_http_client_assert_status_diagnostics = function()
    local Client = require('test.helpers.http_client')
    local c = Client:new({ base_url = 'http://localhost:8080' })
    local res = { status = 503, request_id = 'rq-1', body = 'down' }
    t.assert_error_msg_contains('expected HTTP 200', function()
        c:assert_status(res, 200)
    end)
    -- Happy path returns the response so callers can chain.
    local ok = { status = 200, body = '{}', request_id = 'rq-2' }
    t.assert_equals(c:assert_status(ok, 200), ok)
end

g.test_http_client_graphql_envelope_assertions = function()
    local Client = require('test.helpers.http_client')
    local c = Client:new({ base_url = 'http://localhost:8080' })
    -- Non-200 surfaces the underlying status mismatch.
    t.assert_error_msg_contains('expected HTTP 200', function()
        c:assert_graphql_ok({ status = 500, json = { errors = {} } })
    end)
    -- 200 with GraphQL errors[] is still a failure for callers using
    -- the strict assertion.
    t.assert_error_msg_contains('GraphQL errors', function()
        c:assert_graphql_ok({
            status = 200,
            json = { errors = { { message = 'boom', extensions = { code = 'INTERNAL' } } } },
            errors = { { message = 'boom', extensions = { code = 'INTERNAL' } } },
            data = nil,
        })
    end)
    -- 200 with neither data nor errors is suspicious — fail loudly.
    t.assert_error_msg_contains('no data', function()
        c:assert_graphql_ok({ status = 200, json = {}, data = nil, errors = nil })
    end)
    -- Happy path returns the response unchanged.
    local ok = {
        status = 200,
        json = { data = { ping = 'pong' } },
        data = { ping = 'pong' },
    }
    t.assert_equals(c:assert_graphql_ok(ok), ok)
end

