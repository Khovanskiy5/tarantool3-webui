local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local rbac = require('webui.auth.rbac')

local g = t.group('rbac')

g.before_each(function() rbac.set_user_roles({}) end)

g.test_rank_ordering = function()
    t.assert_equals(rbac.role_rank('viewer'),    1)
    t.assert_equals(rbac.role_rank('operator'),  2)
    t.assert_equals(rbac.role_rank('admin'),     3)
    t.assert_equals(rbac.role_rank('superuser'), 4)
    t.assert_equals(rbac.role_rank('ghost'),     0)
end

g.test_allowed_uses_highest_role = function()
    t.assert_equals(rbac.allowed({'viewer','admin'}, 'operator'), true)
    t.assert_equals(rbac.allowed({'viewer'},        'operator'), false)
    t.assert_equals(rbac.allowed({'superuser'},     'admin'),    true)
    t.assert_equals(rbac.allowed({},                'viewer'),   false)
end

g.test_unknown_required_role_denies = function()
    t.assert_equals(rbac.allowed({'admin'}, 'bogus'), false)
end

g.test_default_dev_user_mapping = function()
    t.assert_equals(rbac.user_roles('admin_dev'),    {'admin'})
    t.assert_equals(rbac.user_roles('operator_dev'), {'operator'})
    t.assert_equals(rbac.user_roles('viewer_dev'),   {'viewer'})
end

g.test_runtime_overrides_defaults = function()
    rbac.set_user_roles({ admin_dev = {'viewer'}, alice = {'operator'} })
    t.assert_equals(rbac.user_roles('admin_dev'), {'viewer'})
    t.assert_equals(rbac.user_roles('alice'),     {'operator'})
    -- non-overridden default still resolves
    rbac.set_user_roles({})
    t.assert_equals(rbac.user_roles('admin_dev'), {'admin'})
end

g.test_graphql_map_has_known_roles = function()
    for field, role in pairs(rbac.GRAPHQL_FIELD) do
        t.assert(rbac.role_rank(role) > 0,
            'field ' .. field .. ' maps to unknown role: ' .. role)
    end
end
