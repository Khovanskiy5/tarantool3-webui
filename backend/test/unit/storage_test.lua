-- Unit tests for backend/webui/storage/spaces.lua
--
-- The DDL path needs a live box and is exercised by the
-- integration suite (Task 24 ties through the role start). The
-- pure helpers (can_run_ddl, NAMES, CURRENT_SCHEMA_VERSION) are
-- covered here without spinning up box.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local storage = require('webui.storage.spaces')

local g = t.group('storage')

-- ── exported names match the plan contract ────────────────────────

g.test_space_names = function()
    t.assert_equals(storage.NAMES.META, '_webui_meta')
    t.assert_equals(storage.NAMES.SESSIONS, '_webui_sessions')
    t.assert_equals(storage.NAMES.AUDIT, '_webui_audit')
end

g.test_current_schema_version_is_positive = function()
    -- The baseline is 1; every migration shipped in
    -- backend/webui/storage/migrations.lua bumps this constant.
    -- The test guards against accidentally setting it to 0 / nil.
    t.assert_type(storage.CURRENT_SCHEMA_VERSION, 'number')
    t.assert(storage.CURRENT_SCHEMA_VERSION >= 1,
        'CURRENT_SCHEMA_VERSION must be >= 1')
end

-- ── can_run_ddl decision matrix ───────────────────────────────────

g.test_can_run_ddl_refuses_when_box_missing = function()
    local saved = rawget(_G, 'box')
    rawset(_G, 'box', nil)
    local ok, reason = storage.can_run_ddl()
    rawset(_G, 'box', saved)
    t.assert_equals(ok, false)
    t.assert_str_contains(reason, 'box not initialised')
end

g.test_can_run_ddl_refuses_when_ro = function()
    local saved = rawget(_G, 'box')
    rawset(_G, 'box', {
        info = { ro = true, ro_reason = 'election' },
        schema = {},
    })
    local ok, reason = storage.can_run_ddl()
    rawset(_G, 'box', saved)
    t.assert_equals(ok, false)
    t.assert_equals(reason, 'election')
end

g.test_can_run_ddl_allows_when_writable = function()
    local saved = rawget(_G, 'box')
    rawset(_G, 'box', { info = { ro = false }, schema = {} })
    local ok, reason = storage.can_run_ddl()
    rawset(_G, 'box', saved)
    t.assert_equals(ok, true)
    t.assert_equals(reason, nil)
end

-- ── bootstrap pre-conditions ──────────────────────────────────────

g.test_bootstrap_errors_when_box_missing = function()
    local saved = rawget(_G, 'box')
    rawset(_G, 'box', nil)
    local ok, err = storage.bootstrap()
    rawset(_G, 'box', saved)
    t.assert_equals(ok, nil)
    t.assert_str_contains(err, 'box is not initialised')
end

g.test_bootstrap_returns_deferred_on_read_only = function()
    local saved = rawget(_G, 'box')
    rawset(_G, 'box', {
        info = { ro = true, ro_reason = 'config' },
        space = {},
    })
    local result = storage.bootstrap()
    rawset(_G, 'box', saved)
    t.assert_type(result, 'table')
    t.assert_equals(result.deferred, true)
    t.assert_equals(result.created_meta, false)
    t.assert_equals(result.created_sessions, false)
    t.assert_equals(result.created_audit, false)
end
