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
    local res, err = twophase.prepare({ yaml = 'a: 1\n' })
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
    local p = twophase.prepare({ yaml = 'a: 1\n' })
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
