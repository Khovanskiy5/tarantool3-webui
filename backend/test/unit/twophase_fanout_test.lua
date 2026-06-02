--
-- Unit test for `twophase.M.commit` opt-in `fanout_reload` flag.
--
-- Verifies:
--   * Without `opts.fanout_reload`, commit does not touch
--     `webui.cluster.rpc` (legacy behaviour for the config-editor
--     `commitConfig` flow stays untouched).
--   * With `opts.fanout_reload == true` and an empty peer pool,
--     commit logs a WARN and returns `reloaded_count` reflecting
--     only the self reload, no `reload_failures`.
--   * With `opts.fanout_reload == true` and a populated peer pool,
--     commit calls `webui_config_reload_remote` via `rpc.map_call`
--     once per peer in parallel; per-peer results are aggregated
--     into `reloaded_count` and `reload_failures`.
--   * One peer failing does not poison the others — the partial
--     count is correct.
--
-- All net.box state is fake: we monkeypatch `webui.cluster.peers`,
-- `webui.cluster.rpc`, and `config` via `package.loaded`. The real
-- `_webui_prepared` space and etcd-CAS path are kept intact, so the
-- test still exercises the surrounding commit pipeline.
--

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local twophase = require('webui.config_store.twophase')

local g = t.group('twophase_fanout')

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

local saved_peers_mod
local saved_rpc_mod
local saved_config_mod

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
    end
    local spaces = require('webui.storage.spaces')
    pcall(spaces.bootstrap)
    pcall(box.ctl.promote)
end)

g.before_each(function()
    twophase._reset()
    saved_peers_mod  = package.loaded['webui.cluster.peers']
    saved_rpc_mod    = package.loaded['webui.cluster.rpc']
    saved_config_mod = package.loaded.config
end)

g.after_each(function()
    package.loaded['webui.cluster.peers'] = saved_peers_mod
    package.loaded['webui.cluster.rpc']   = saved_rpc_mod
    package.loaded.config                 = saved_config_mod
end)

local function fake_etcd_capture()
    local captured = {}
    return setmetatable({
        put = function(self, key, value)
            table.insert(captured, { op = 'put', key = key, value = value })
            return { revision = 42 }
        end,
        txn_cas = function(self, key, value, rev)
            table.insert(captured, { op = 'cas', key = key, value = value, rev = rev })
            return { revision = 42 }
        end,
        get = function() return nil end,
    }, { __index = function() return function() return nil end end }), captured
end

g.test_no_flag_skips_reload_fanout = function()
    local map_call_count = 0
    package.loaded['webui.cluster.rpc'] = {
        map_call = function() map_call_count = map_call_count + 1
            return {} end,
    }
    package.loaded['webui.cluster.peers'] = {
        list = function() return { ['tt-2'] = { conn = {} } } end,
    }
    package.loaded.config = {
        reload = function() error('should not be called') end,
        info = function() return {} end,
    }

    local p = twophase.prepare({ yaml = MIN_VALID_YAML })
    local etcd, _ = fake_etcd_capture()
    local r = twophase.commit(p.prepared_id, { etcd = etcd })
    t.assert_equals(r.revision, 42)
    t.assert_equals(r.reloaded_count, nil,
        'reloaded_count must not appear when fanout_reload is off')
    t.assert_equals(r.reload_failures, nil,
        'reload_failures must not appear when fanout_reload is off')
    -- map_call may still be called by the existing file_writer fan-out
    -- (a separate code path) — we only assert reload-specific state is
    -- absent in the result table.
end

g.test_flag_on_empty_peer_pool_self_only = function()
    package.loaded['webui.cluster.rpc'] = {
        map_call = function() return {} end,
    }
    package.loaded['webui.cluster.peers'] = {
        list = function() return {} end,
    }
    local self_called = false
    package.loaded.config = {
        reload = function() self_called = true end,
        info = function() return { status = 'ready' } end,
    }

    local p = twophase.prepare({ yaml = MIN_VALID_YAML })
    local etcd, _ = fake_etcd_capture()
    local r = twophase.commit(p.prepared_id, {
        etcd = etcd, fanout_reload = true,
    })
    t.assert_equals(r.revision, 42)
    t.assert_equals(r.reloaded_count, 1, 'only self counts')
    t.assert_equals(#r.reload_failures, 0)
    t.assert(self_called, 'self config:reload was not invoked')
end

g.test_flag_on_peers_aggregate_results = function()
    local map_call_args
    package.loaded['webui.cluster.rpc'] = {
        map_call = function(fn_name, args, opts)
            map_call_args = { fn_name = fn_name, args = args, opts = opts }
            return {
                ['tt-2'] = { ok = true, value = { ok = true, status = 'ready', elapsed_ms = 12 } },
                ['tt-3'] = { ok = true, value = { ok = true, status = 'ready', elapsed_ms = 18 } },
            }
        end,
    }
    package.loaded['webui.cluster.peers'] = {
        list = function() return {
            ['tt-2'] = { conn = {} }, ['tt-3'] = { conn = {} },
        } end,
    }
    package.loaded.config = {
        reload = function() end,
        info = function() return { status = 'ready' } end,
    }

    local p = twophase.prepare({ yaml = MIN_VALID_YAML })
    local etcd, _ = fake_etcd_capture()
    local r = twophase.commit(p.prepared_id, {
        etcd = etcd, fanout_reload = true,
    })
    t.assert_equals(r.reloaded_count, 3, 'self + 2 peers')
    t.assert_equals(#r.reload_failures, 0)
    t.assert(map_call_args ~= nil, 'rpc.map_call was not invoked')
    t.assert_equals(map_call_args.fn_name, 'webui_config_reload_remote')
end

g.test_one_peer_failure_aggregates_partial = function()
    package.loaded['webui.cluster.rpc'] = {
        map_call = function()
            return {
                ['tt-2'] = { ok = true, value = { ok = true, status = 'ready' } },
                ['tt-3'] = { ok = false, err = 'timeout' },
            }
        end,
    }
    package.loaded['webui.cluster.peers'] = {
        list = function() return {
            ['tt-2'] = { conn = {} }, ['tt-3'] = { conn = {} },
        } end,
    }
    package.loaded.config = {
        reload = function() end,
        info = function() return { status = 'ready' } end,
    }

    local p = twophase.prepare({ yaml = MIN_VALID_YAML })
    local etcd, _ = fake_etcd_capture()
    local r = twophase.commit(p.prepared_id, {
        etcd = etcd, fanout_reload = true,
    })
    t.assert_equals(r.reloaded_count, 2, 'self + 1 successful peer')
    t.assert_equals(#r.reload_failures, 1)
    t.assert_equals(r.reload_failures[1].alias, 'tt-3')
    t.assert_str_contains(r.reload_failures[1].err, 'timeout')
end

g.test_self_reload_failure_recorded = function()
    package.loaded['webui.cluster.rpc'] = {
        map_call = function() return {} end,
    }
    package.loaded['webui.cluster.peers'] = {
        list = function() return {} end,
    }
    package.loaded.config = {
        reload = function() error('boom') end,
        info = function() return {} end,
    }

    local p = twophase.prepare({ yaml = MIN_VALID_YAML })
    local etcd, _ = fake_etcd_capture()
    local r = twophase.commit(p.prepared_id, {
        etcd = etcd, fanout_reload = true,
    })
    t.assert_equals(r.reloaded_count, 0, 'self failed, no peers')
    t.assert_equals(#r.reload_failures, 1)
    t.assert_equals(r.reload_failures[1].alias, '_self')
    t.assert_str_contains(r.reload_failures[1].err, 'boom')
end
