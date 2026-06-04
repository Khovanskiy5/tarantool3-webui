local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local diag = require('webui.api.diagnostics')

local g = t.group('diagnostics.resolve_one')

g.test_absolute_path_returned_as_is = function()
    t.assert_equals(diag._resolve_one('/opt/webui/var/lib/tt-1',
        '/opt/webui/var/lib'), '/opt/webui/var/lib/tt-1')
end

g.test_relative_path_anchored_to_work_dir = function()
    t.assert_equals(diag._resolve_one('var/lib/tt-1',
        '/opt/webui/var/lib'),
        '/opt/webui/var/lib/var/lib/tt-1')
end

g.test_trailing_slash_in_work_dir_no_doubled_separator = function()
    t.assert_equals(diag._resolve_one('tt-1', '/data/'), '/data/tt-1')
end

g.test_nil_path_returns_nil = function()
    t.assert_equals(diag._resolve_one(nil, '/data'), nil)
end

g.test_nil_work_dir_returns_path_as_is = function()
    t.assert_equals(diag._resolve_one('rel/path', nil), 'rel/path')
end

g.test_empty_work_dir_returns_path_as_is = function()
    t.assert_equals(diag._resolve_one('rel/path', ''), 'rel/path')
end

-- ── _set_instance_uuid (rebootstrap identity pin) ───────────────────

local g2 = t.group('diagnostics.set_instance_uuid')

local function cfg(uri_db)
    return {
        groups = { default = { replicasets = { ['rs-1'] = { instances = {
            ['tt-1'] = { iproto = {} },
            ['tt-3'] = uri_db or { iproto = {} },
        } } } } },
    }
end

g2.test_sets_uuid_on_instance_without_database = function()
    local c = cfg()
    local r = diag._set_instance_uuid(c, 'tt-3', 'uuid-xyz')
    t.assert_equals(r, 'set')
    t.assert_equals(
        c.groups.default.replicasets['rs-1'].instances['tt-3']
            .database.instance_uuid,
        'uuid-xyz')
end

g2.test_idempotent_when_already_pinned = function()
    local c = cfg({ iproto = {}, database = { instance_uuid = 'uuid-xyz' } })
    local r = diag._set_instance_uuid(c, 'tt-3', 'uuid-xyz')
    t.assert_equals(r, 'already')
end

g2.test_overwrites_a_different_pinned_uuid = function()
    local c = cfg({ iproto = {}, database = { instance_uuid = 'old' } })
    local r = diag._set_instance_uuid(c, 'tt-3', 'new')
    t.assert_equals(r, 'set')
    t.assert_equals(
        c.groups.default.replicasets['rs-1'].instances['tt-3']
            .database.instance_uuid,
        'new')
end

g2.test_missing_when_instance_absent = function()
    local r = diag._set_instance_uuid(cfg(), 'tt-9', 'uuid-xyz')
    t.assert_equals(r, 'missing')
end

g2.test_preserves_other_database_keys = function()
    local c = cfg({ iproto = {}, database = { mode = 'rw' } })
    diag._set_instance_uuid(c, 'tt-3', 'uuid-xyz')
    local db = c.groups.default.replicasets['rs-1'].instances['tt-3'].database
    t.assert_equals(db.mode, 'rw')
    t.assert_equals(db.instance_uuid, 'uuid-xyz')
end
