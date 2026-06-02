--
-- Unit test for the `webui_config_reload_remote` net.box shim
-- installed by `lifecycle.remote_shims`. The shim delegates to
-- Tarantool's native `config:reload()` and is the cluster-wide
-- reload trigger used by `twophase.commit` when
-- `opts.fanout_reload == true`.
--
-- We can't reach a real `config` module in luatest's standalone
-- sandbox (no `box.cfg{}` has run with a cluster YAML), but we
-- can:
--   * verify the shim is installed in _G after install();
--   * verify it returns a structured `{ err = ... }` table when
--     the config module is unavailable;
--   * verify the contract — return shape is always a table, never
--     raises — by monkeypatching `package.loaded.config`.
--

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('config_reload_remote')

local remote_shims = require('webui.lifecycle.remote_shims')

g.before_each(function()
    -- Wipe any prior monkeypatch from a previous test.
    package.loaded.config = nil
    rawset(_G, 'webui_config_reload_remote', nil)
end)

g.test_install_exposes_global = function()
    remote_shims.install()
    t.assert_type(_G.webui_config_reload_remote, 'function',
        'install() must expose the global shim')
end

g.test_no_config_module_returns_err = function()
    -- Force `require('config')` to fail by stubbing the loader entry
    -- with a sentinel that raises on access.
    package.preload.config = function()
        error('config module unavailable in test sandbox')
    end
    remote_shims.install()
    local res = _G.webui_config_reload_remote()
    t.assert_type(res, 'table')
    t.assert(res.err ~= nil,
        'expected `err` field when config module is unavailable')
    package.preload.config = nil
end

g.test_successful_reload_returns_ok_and_status = function()
    local called = false
    package.loaded.config = {
        reload = function() called = true end,
        info = function() return { status = 'ready' } end,
    }
    remote_shims.install()
    local res = _G.webui_config_reload_remote()
    t.assert_type(res, 'table')
    t.assert_equals(res.ok, true)
    t.assert_equals(res.status, 'ready')
    t.assert_type(res.elapsed_ms, 'number')
    t.assert(called, 'config:reload was not invoked')
end

g.test_reload_raise_is_wrapped_in_err = function()
    package.loaded.config = {
        reload = function() error('boom') end,
        info = function() return {} end,
    }
    remote_shims.install()
    local res = _G.webui_config_reload_remote()
    t.assert_type(res, 'table')
    t.assert(res.err ~= nil)
    t.assert_str_contains(tostring(res.err), 'boom')
end

g.test_idempotent_install = function()
    remote_shims.install()
    local fn1 = _G.webui_config_reload_remote
    remote_shims.install()
    local fn2 = _G.webui_config_reload_remote
    t.assert_type(fn1, 'function')
    t.assert_type(fn2, 'function')
    -- The shim is reinstalled (rawset), not memoized — different
    -- callable references are fine. What matters is that calling
    -- after re-install still produces a result table.
    package.loaded.config = {
        reload = function() end,
        info = function() return { status = 'ok' } end,
    }
    t.assert_type(fn2(), 'table')
end
