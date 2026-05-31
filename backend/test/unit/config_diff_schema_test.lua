local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local schema = require('webui.config_store.schema')
local diff   = require('webui.config_store.diff')
local twophase = require('webui.config_store.twophase')
local history = require('webui.config_store.history')

local g = t.group('config_store')

-- twophase._reset() touches `box.space[...]`, which requires
-- `box.cfg{}` to have run. Spin up a throwaway instance under a
-- temp dir so the whole file (cross-validate, diff, twophase,
-- history) can run without a docker-backed integration harness.
g.before_all(function()
    if box.info.status == 'unconfigured' then
        local tmp = fio.tempdir()
        box.cfg({
            memtx_dir   = tmp,
            wal_dir     = tmp,
            wal_mode    = 'none',
            listen      = box.NULL,
            log_level   = 0,
            background  = false,
        })
        rawset(_G, '__schema_test_tmpdir', tmp)
    end
    -- twophase.prepare() persists into the `_webui_prepared` space.
    -- Without bootstrapping the space layout, the lifecycle tests
    -- fail with "prepared storage is not bootstrapped".
    local spaces = require('webui.storage.spaces')
    pcall(spaces.bootstrap)
    -- `_webui_prepared` is a synchronous space. A solo instance
    -- without an explicit promote has no synchro queue owner, so
    -- inserts fail with "queue doesn't belong to any instance".
    pcall(box.ctl.promote)
end)

g.before_each(function() twophase._reset() end)

-- ── schema.lua ──────────────────────────────────────────────────────

g.test_cross_validate_detects_election_with_leader = function()
    local cfg = {
        replication = { failover = 'election' },
        groups = {
            default = {
                replicasets = {
                    ['rs-1'] = {
                        leader = 'tt-1',
                        instances = { ['tt-1'] = {} },
                    },
                },
            },
        },
    }
    local issues = schema.cross_validate(cfg)
    t.assert(#issues > 0)
end

g.test_cross_validate_detects_unknown_leader = function()
    local cfg = {
        groups = {
            default = {
                replicasets = {
                    ['rs-1'] = {
                        leader = 'tt-ghost',
                        instances = { ['tt-1'] = {} },
                    },
                },
            },
        },
    }
    local issues = schema.cross_validate(cfg)
    t.assert(#issues > 0)
end

g.test_cross_validate_detects_duplicate_uri = function()
    local cfg = {
        groups = {
            default = {
                replicasets = {
                    ['rs-1'] = {
                        instances = {
                            ['tt-1'] = { iproto = { advertise = { peer = { uri = 'host:3301' } } } },
                            ['tt-2'] = { iproto = { advertise = { peer = { uri = 'host:3301' } } } },
                        },
                    },
                },
            },
        },
    }
    local issues = schema.cross_validate(cfg)
    t.assert(#issues > 0)
end

-- Regression: rev 175 / rev 179 incidents — values that Tarantool's
-- config validator rejects on reload (so they leave the cluster with
-- an unloadable YAML and a stuck synchro queue) must be rejected at
-- precommit, not after. Both `schema.validate()` calls below
-- previously returned the parsed table; they MUST now return errors.

local MIN_VALID_YAML = table.concat({
    'replication:',
    '  failover: off',
    'groups:',
    '  default:',
    '    replicasets:',
    '      rs-1:',
    '        instances:',
    '          tt-1:',
    '            iproto:',
    '              listen:',
    '              - uri: 0.0.0.0:3301',
    '              advertise:',
    '                peer:',
    '                  uri: tt-1:3301',
    '',
}, '\n')

g.test_validate_accepts_minimal_valid_yaml = function()
    local parsed, errs = schema.validate(MIN_VALID_YAML)
    t.assert_equals(errs, nil)
    t.assert_not_equals(parsed, nil)
    t.assert_equals(parsed.replication.failover, 'off')
end

g.test_validate_rejects_etcd_endpoints_as_table = function()
    -- Reproduces rev 175: editTopology serialised endpoints[1] as a
    -- nested table ({{...}}) instead of a string URL.
    local yaml_text = MIN_VALID_YAML ..
        'config:\n' ..
        '  etcd:\n' ..
        '    endpoints:\n' ..
        '    - not_a_string: oops\n' ..
        '    prefix: /tarantool/webui\n'
    local parsed, errs = schema.validate(yaml_text)
    t.assert_equals(parsed, nil)
    t.assert(errs ~= nil and #errs > 0,
        'expected schema validation to reject endpoints[1] as table')
    t.assert_str_contains(errs[1].message, 'endpoints')
end

g.test_validate_rejects_empty_etcd_prefix = function()
    -- Reproduces rev 179: config.etcd.prefix saved as "" — passes
    -- YAML parsing, passes our old "best-effort touch", but the
    -- runtime cluster_config schema rejects it as not path-alike.
    local yaml_text = MIN_VALID_YAML ..
        'config:\n' ..
        '  etcd:\n' ..
        '    endpoints:\n' ..
        '    - http://etcd:2379\n' ..
        '    prefix: ""\n'
    local parsed, errs = schema.validate(yaml_text)
    t.assert_equals(parsed, nil)
    t.assert(errs ~= nil and #errs > 0,
        'expected schema validation to reject empty etcd.prefix')
    t.assert_str_contains(errs[1].message, 'prefix')
end

-- ── diff.lua ────────────────────────────────────────────────────────

g.test_diff_detects_change = function()
    local from = { a = 1, b = { c = 'x' } }
    local to   = { a = 2, b = { c = 'x' } }
    local ops = diff.structural(from, to)
    t.assert_equals(#ops, 1)
    t.assert_equals(ops[1].op, 'changed')
end

g.test_diff_detects_added_removed = function()
    local from = { a = 1 }
    local to   = { b = 2 }
    local ops = diff.structural(from, to)
    t.assert_equals(#ops, 2)
    local kinds = {}
    for _, o in ipairs(ops) do kinds[o.op] = true end
    t.assert(kinds.added)
    t.assert(kinds.removed)
end

g.test_diff_categorise_groups_by_path = function()
    local cats = diff.categorise({
        { op = 'changed', path = '/credentials/users/admin' },
        { op = 'changed', path = '/replication/failover' },
        { op = 'added',   path = '/groups/default/replicasets/rs-1/instances/tt-1' },
    })
    t.assert(#cats.credentials > 0)
    t.assert(#cats.failover > 0)
    t.assert(#cats.instance > 0)
end

-- ── twophase.lua ────────────────────────────────────────────────────

g.test_prepare_then_abort_lifecycle = function()
    local res, err = twophase.prepare({ yaml = MIN_VALID_YAML })
    t.assert_equals(err, nil)
    t.assert(res.prepared_id ~= nil)
    local ok = twophase.abort(res.prepared_id)
    t.assert_equals(ok, true)
    t.assert_equals(twophase.get_prepared(res.prepared_id), nil)
end

g.test_prepare_rejects_invalid_yaml = function()
    local res, errs = twophase.prepare({ yaml = ': : :' })
    t.assert_equals(res, nil)
    t.assert(#errs > 0)
end

g.test_commit_without_etcd_is_dry_run = function()
    local p = twophase.prepare({ yaml = MIN_VALID_YAML })
    local r, e = twophase.commit(p.prepared_id, {})
    t.assert_equals(e, nil)
    t.assert(r.dry_run)
end

-- ── history.lua ─────────────────────────────────────────────────────

g.test_history_key_pads_revision = function()
    t.assert_equals(history.history_key('/p', 5), '/p/history/0000000005')
end

g.test_prune_plan_drops_oldest = function()
    local keys = { 'a', 'b', 'c', 'd', 'e' }
    t.assert_equals(history.prune_plan(keys, 3), { 'a', 'b' })
    t.assert_equals(history.prune_plan(keys, 5), {})
end
