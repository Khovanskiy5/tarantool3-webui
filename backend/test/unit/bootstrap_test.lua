-- Unit tests for backend/webui/config_store/bootstrap.lua (Task 36).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('bootstrap_wizard')

local bootstrap = require('webui.config_store.bootstrap')

-- ── templates catalog ──────────────────────────────────────────────

g.test_three_templates_shipped = function()
    local names = {}
    for _, tpl in ipairs(bootstrap.list_templates()) do
        table.insert(names, tpl.name)
    end
    t.assert_equals(#names, 3, 'expected 3 templates shipped')
    t.assert(table.concat(names, ','):find('single%-instance'),
        'single-instance template missing')
    t.assert(table.concat(names, ','):find('replicaset%-3'),
        'replicaset-3 template missing')
    t.assert(table.concat(names, ','):find('vshard%-3x3'),
        'vshard-3x3 template missing')
end

g.test_each_template_has_title_and_description = function()
    for _, tpl in ipairs(bootstrap.list_templates()) do
        t.assert_type(tpl.title, 'string')
        t.assert(#tpl.title > 0, 'title empty for ' .. tpl.name)
        t.assert_type(tpl.description, 'string')
        t.assert(#tpl.description > 0, 'description empty for ' .. tpl.name)
    end
end

-- ── render ─────────────────────────────────────────────────────────

g.test_render_unknown_template = function()
    local yaml, err = bootstrap.render('does-not-exist', 'cluster')
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'TEMPLATE_NOT_FOUND')
end

g.test_render_invalid_cluster_name_rejected = function()
    -- Spaces, slashes, leading dashes, etc. all fail the whitelist.
    for _, bad in ipairs({
        ' my-cluster ', 'my/cluster', '-leading-dash',
        'has space', '$danger',
    }) do
        local yaml, err = bootstrap.render('single-instance', bad)
        t.assert_equals(yaml, nil, 'name "' .. bad .. '" should be rejected')
        t.assert_equals(err, 'INVALID_CLUSTER_NAME')
    end
end

g.test_render_accepts_safe_cluster_name = function()
    for _, good in ipairs({ 'demo', 'demo-1', 'prod_west.us', 'demo1' }) do
        local yaml, err = bootstrap.render('single-instance', good)
        t.assert_equals(err, nil)
        t.assert_type(yaml, 'string')
        t.assert(#yaml > 0)
    end
end

g.test_single_instance_yaml_shape = function()
    local yaml = bootstrap.render('single-instance', 'demo')
    t.assert_str_contains(yaml, 'credentials:')
    t.assert_str_contains(yaml, 'webui_peer:')
    t.assert_str_contains(yaml, 'replication:')
    t.assert_str_contains(yaml, 'failover: off')
    t.assert_str_contains(yaml, 'groups:')
    t.assert_str_contains(yaml, 'roles: [webui]')
end

g.test_replicaset_3_yaml_has_three_instances = function()
    local yaml = bootstrap.render('replicaset-3', 'demo')
    t.assert_str_contains(yaml, 'inst-1:')
    t.assert_str_contains(yaml, 'inst-2:')
    t.assert_str_contains(yaml, 'inst-3:')
    t.assert_str_contains(yaml, 'failover: election')
end

g.test_vshard_yaml_has_sharding_block = function()
    local yaml = bootstrap.render('vshard-3x3', 'demo')
    t.assert_str_contains(yaml, 'sharding:')
    t.assert_str_contains(yaml, 'bucket_count:')
    t.assert_str_contains(yaml, 'routers:')
    t.assert_str_contains(yaml, 'storages:')
end

-- ── status ────────────────────────────────────────────────────────

g.test_status_needed_when_no_local_no_etcd = function()
    local s = bootstrap.status({ local_yaml = '' })
    t.assert_equals(s.needed, true)
    t.assert_str_contains(s.reason, 'no cluster config')
end

g.test_status_not_needed_when_local_yaml_present = function()
    local s = bootstrap.status({ local_yaml = 'groups: {}\n' })
    t.assert_equals(s.needed, false)
    t.assert_equals(s.source, 'file')
end

g.test_status_not_needed_when_etcd_has_config = function()
    local fake_etcd = {
        get = function(_self, _key)
            return { value = 'groups: {}\n', mod_revision = 1 }
        end,
    }
    local s = bootstrap.status({
        local_yaml  = '',
        etcd_client = fake_etcd,
    })
    t.assert_equals(s.needed, false)
    t.assert_equals(s.source, 'etcd')
    t.assert_str_contains(s.reason, 'etcd already holds')
end

g.test_status_needed_when_etcd_empty_and_no_local = function()
    local fake_etcd = {
        get = function(_self, _key) return nil, 'KEY_NOT_FOUND' end,
    }
    local s = bootstrap.status({
        local_yaml  = '',
        etcd_client = fake_etcd,
    })
    t.assert_equals(s.needed, true)
    t.assert_equals(s.source, 'etcd')
end
