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

-- The rebootstrap identity pin (instances.<name>.database.instance_uuid)
-- now goes through the formatting-preserving webui.config_store.yaml_patch
-- helper; its behaviour is covered in config_store_yaml_patch_test.lua.
