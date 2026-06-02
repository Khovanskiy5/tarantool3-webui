--
-- Facade contract for backend/webui/init.lua.
--
-- Two invariants this file pins:
--
--   1. `init.lua` stays under the hard 40-line cap. A growing
--      facade is the signal that something leaked out of the
--      lifecycle/ submodules into the wiring layer.
--   2. Every name documented in init.lua's header is actually
--      exported. The role registration in cluster.yaml ultimately
--      reaches `validate` / `apply` / `stop`, schema.lua reaches
--      `status`, and tests reach `start` — silently dropping one
--      of them breaks production cold, not at unit-test time.
--

local t   = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('webui_facade')

local FACADE_PATH = repo_root .. '/backend/webui/init.lua'

g.test_init_lua_is_under_size_cap = function()
    local f = io.open(FACADE_PATH, 'r')
    t.assert(f ~= nil, 'init.lua must exist at ' .. FACADE_PATH)
    local lines = 0
    for _ in f:lines() do lines = lines + 1 end
    f:close()
    t.assert(lines <= 40,
        'webui/init.lua grew to ' .. lines .. ' lines; the hard cap is 40. '
        .. 'Anything beyond require + re-export belongs in '
        .. 'webui.lifecycle.* (state / validate / apply / start / stop / '
        .. 'remote_shims), not here.')
end

g.test_facade_exports_full_public_surface = function()
    local webui = require('webui')
    for _, name in ipairs({ 'validate', 'apply', 'start', 'stop', 'status' }) do
        t.assert_type(webui[name], 'function',
            'facade is missing export: ' .. name)
    end
end

g.test_status_returns_state_snapshot = function()
    -- Sanity: `webui.status()` reaches state.lua and returns the
    -- canonical snapshot shape. The bootstrap_test (and the rest
    -- of the integration suite) only checks the keys it cares
    -- about; we pin the full key set here so a refactor that
    -- drops e.g. `uptime_sec` is caught before it lands.
    local webui = require('webui')
    local snap = webui.status()
    t.assert_type(snap, 'table')
    for _, key in ipairs({
        'state', 'version', 'tarantool', 'instance',
        'started_at', 'uptime_sec', 'log_level',
    }) do
        t.assert(snap[key] ~= nil or key == 'instance' or key == 'started_at',
            'status() missing key: ' .. key)
    end
end
