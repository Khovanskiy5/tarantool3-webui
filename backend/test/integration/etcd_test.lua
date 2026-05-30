--
-- Integration test for the etcd v3 HTTP client.
--
-- Requires `etcd` reachable on 127.0.0.1:2379 (the dev compose
-- exposes it on that port). Skipped if etcd is not up.
--

local t = require('luatest')
local fio = require('fio')
local socket = require('socket')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local etcd = require('webui.config_store.etcd')

local g = t.group('etcd_v3')

local CLIENT = nil

g.before_all(function()
    local s = socket.tcp_connect('127.0.0.1', 2379)
    if s == nil then t.skip('etcd not reachable') end
    s:close()
    local c, err = etcd.new({
        endpoints = { 'http://127.0.0.1:2379' },
        prefix    = '/webui-test-' .. tostring(os.time()),
    })
    if c == nil then t.skip('etcd new failed: ' .. (err and err.message or '?')) end
    CLIENT = c
end)

g.test_put_get_delete_roundtrip = function()
    local r, _ = CLIENT:put('k1', 'v1')
    t.assert(r and r.revision)
    local v, _ = CLIENT:get('k1')
    t.assert_equals(v.value, 'v1')
    CLIENT:delete('k1')
    local v2, _ = CLIENT:get('k1')
    t.assert_equals(v2, nil)
end

g.test_txn_cas_success_then_conflict = function()
    CLIENT:delete('cas-key')
    local r1, _ = CLIENT:put('cas-key', 'a')
    t.assert(r1.revision)
    local v, _ = CLIENT:get('cas-key')
    -- Correct revision succeeds
    local cas_ok, _ = CLIENT:txn_cas('cas-key', 'b', v.revision)
    t.assert(cas_ok and cas_ok.committed)
    -- Stale revision fails
    local cas_bad, err = CLIENT:txn_cas('cas-key', 'c', v.revision)
    t.assert_equals(cas_bad, nil)
    t.assert_equals(err.category, 'CAS_CONFLICT')
    CLIENT:delete('cas-key')
end

g.test_lease_grant_and_revoke = function()
    local g_res, err = CLIENT:lease_grant(30)
    t.assert(g_res, err and err.message)
    t.assert(g_res.id ~= nil)
    local _, e = CLIENT:lease_revoke(g_res.id)
    t.assert_equals(e, nil)
end
