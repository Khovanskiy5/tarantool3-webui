-- Golden vectors for diff.diff_revisions — five canonical change
-- shapes the history-panel UI needs to render: new user, password
-- change, role-list change, endpoint mutation, all-clear no-op.

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local diff = require('webui.config_store.diff')

local g = t.group('config_diff_revisions')

local function find_op(ops, path, op_name)
    for _, e in ipairs(ops or {}) do
        if e.path == path and e.op == op_name then return e end
    end
    return nil
end

local function header()
    return 'replication:\n  failover: off\n'
        .. 'groups:\n  default:\n    replicasets:\n      rs-1:\n'
        .. '        instances:\n          tt-1: {}\n'
end

g.test_added_user_surfaces_as_add_ops = function()
    local yaml_old = header()
    local yaml_new = header()
        .. 'credentials:\n  users:\n'
        .. '    deploy:\n      password: "s3cret"\n      roles: [public]\n'
    local res = diff.diff_revisions(yaml_old, yaml_new)
    -- structural diff bubbles "new subtree" up to the deepest existing
    -- ancestor; here `credentials` was absent in `from`, so the ADD
    -- lands at the top of the new subtree, not at the leaf level.
    local credentials = find_op(res.ops, '/credentials', 'add')
    t.assert(credentials, 'expected /credentials subtree ADDED')
    t.assert_equals(credentials.after.users.deploy.password, 's3cret')
end

g.test_changed_password_surfaces_as_change_op = function()
    local yaml_old = 'credentials:\n  users:\n    deploy:\n      password: "old"\n'
    local yaml_new = 'credentials:\n  users:\n    deploy:\n      password: "new"\n'
    local res = diff.diff_revisions(yaml_old, yaml_new)
    local pwd = find_op(res.ops, '/credentials/users/deploy/password', 'change')
    t.assert(pwd, 'expected /credentials/users/deploy/password CHANGE')
    t.assert_equals(pwd.before, 'old')
    t.assert_equals(pwd.after,  'new')
end

g.test_changed_etcd_endpoints_surfaces_change_op = function()
    local yaml_old = 'config:\n  etcd:\n    endpoints:\n      - http://etcd-old:2379\n'
    local yaml_new = 'config:\n  etcd:\n    endpoints:\n      - http://etcd-new:2379\n'
    local res = diff.diff_revisions(yaml_old, yaml_new)
    local ep = find_op(res.ops, '/config/etcd/endpoints/1', 'change')
    t.assert(ep, 'expected /config/etcd/endpoints/1 CHANGE')
end

g.test_no_diff_returns_empty_ops = function()
    local same = header()
    local res = diff.diff_revisions(same, same)
    t.assert_equals(res.ops, {})
end

g.test_invalid_yaml_does_not_error = function()
    -- Both sides invalid → both coerced to {} → zero ops, no crash.
    local res = diff.diff_revisions(']]\nthis is not yaml', '[[\nalso not yaml')
    t.assert_equals(res.ops, {})
end

g.test_categories_returned_alongside_ops = function()
    local yaml_old = 'credentials:\n  users:\n    deploy:\n      password: "old"\n'
    local yaml_new = 'credentials:\n  users:\n    deploy:\n      password: "new"\n'
    local res = diff.diff_revisions(yaml_old, yaml_new)
    t.assert(type(res.categories) == 'table',
        'diff_revisions must surface category buckets')
    t.assert(#res.categories.credentials >= 1,
        'credentials category must capture the password change')
end
