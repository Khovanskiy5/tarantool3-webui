-- Unit tests for backend/webui/cluster/peers.lua
--
-- Only the pure-data helpers (filter_self, diff_peers, normalise_uri)
-- are covered here. Connection lifecycle, refresh against a live
-- `config:instances()` and `box.info.name` resolution all need an
-- actual Tarantool 3.x instance and land in the integration suite.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local peers = require('webui.cluster.peers')

local g = t.group('peers')

-- Convenience: stable list of names from a map so set comparisons
-- can use assert_equals (luatest does not have set assertions).
local function sorted_keys(tbl)
    local out = {}
    for k in pairs(tbl) do table.insert(out, k) end
    table.sort(out)
    return out
end

-- ── filter_self ──────────────────────────────────────────────────────

g.test_filter_self_drops_self_entry = function()
    local instances = {
        ['tt-1'] = { instance_name = 'tt-1', replicaset_name = 'rs', group_name = 'g' },
        ['tt-2'] = { instance_name = 'tt-2', replicaset_name = 'rs', group_name = 'g' },
        ['tt-3'] = { instance_name = 'tt-3', replicaset_name = 'rs', group_name = 'g' },
    }
    local out = peers.filter_self(instances, 'tt-2')
    t.assert_equals(sorted_keys(out), { 'tt-1', 'tt-3' })
end

g.test_filter_self_keeps_everything_when_alias_is_nil = function()
    local instances = { ['a'] = {}, ['b'] = {} }
    local out = peers.filter_self(instances, nil)
    t.assert_equals(sorted_keys(out), { 'a', 'b' })
end

g.test_filter_self_returns_empty_for_nil_input = function()
    local out = peers.filter_self(nil, 'tt-1')
    t.assert_equals(next(out), nil)
end

g.test_filter_self_does_not_mutate_input = function()
    local instances = { ['x'] = { instance_name = 'x' } }
    local snapshot = { ['x'] = instances.x }
    peers.filter_self(instances, 'x')
    t.assert_equals(instances, snapshot)
end

-- ── diff_peers ───────────────────────────────────────────────────────

g.test_diff_peers_classifies_open_and_close = function()
    local diff = peers.diff_peers({ 'a', 'b', 'c' }, { 'b', 'c', 'd' })
    t.assert_equals(diff.to_open, { 'd' })
    t.assert_equals(diff.to_close, { 'a' })
end

g.test_diff_peers_no_change_returns_empty_lists = function()
    local diff = peers.diff_peers({ 'a', 'b' }, { 'a', 'b' })
    t.assert_equals(diff.to_open, {})
    t.assert_equals(diff.to_close, {})
end

g.test_diff_peers_full_swap = function()
    local diff = peers.diff_peers({ 'a', 'b' }, { 'c', 'd' })
    t.assert_equals(diff.to_open, { 'c', 'd' })
    t.assert_equals(diff.to_close, { 'a', 'b' })
end

g.test_diff_peers_handles_nil_inputs = function()
    local diff = peers.diff_peers(nil, { 'a' })
    t.assert_equals(diff.to_open, { 'a' })
    t.assert_equals(diff.to_close, {})

    diff = peers.diff_peers({ 'a' }, nil)
    t.assert_equals(diff.to_open, {})
    t.assert_equals(diff.to_close, { 'a' })
end

g.test_diff_peers_output_is_sorted = function()
    -- Sort order matters: the pool iterates `to_open`/`to_close` in
    -- order, so a deterministic order gives a deterministic log.
    local diff = peers.diff_peers({}, { 'zeta', 'alpha', 'mu' })
    t.assert_equals(diff.to_open, { 'alpha', 'mu', 'zeta' })
end

-- ── normalise_uri ────────────────────────────────────────────────────

g.test_normalise_uri_returns_nil_for_empty_input = function()
    t.assert_equals(peers.normalise_uri(nil), nil)
    t.assert_equals(peers.normalise_uri({}), nil)
    t.assert_equals(peers.normalise_uri({ params = {} }), nil)
end

g.test_normalise_uri_passes_through_fields = function()
    local raw = {
        uri = '10.0.0.5:3301',
        login = 'webui_peer',
        password = 'abc',
        params = { transport = 'ssl', ssl_ca_file = '/etc/tarantool/ca.pem' },
    }
    local out = peers.normalise_uri(raw)
    t.assert_equals(out.uri, '10.0.0.5:3301')
    t.assert_equals(out.login, 'webui_peer')
    t.assert_equals(out.password, 'abc')
    t.assert_equals(out.params.transport, 'ssl')
    t.assert_equals(out.params.ssl_ca_file, '/etc/tarantool/ca.pem')
end

g.test_normalise_uri_handles_uri_only = function()
    local out = peers.normalise_uri({ uri = '127.0.0.1:3301' })
    t.assert_equals(out.uri, '127.0.0.1:3301')
    t.assert_equals(out.login, nil)
    t.assert_equals(out.password, nil)
    t.assert_equals(out.params, nil)
end

-- ── set_credential / self_alias defaults ─────────────────────────────

g.test_set_credential_signature = function()
    -- Should not throw on plain user (no password — peer_cookie's
    -- typical fallback when ad-hoc credential management).
    peers._reset()
    peers.set_credential('webui_peer')
    peers.set_credential('webui_peer', 'pw')
    -- Empty string is a programmer error and `checks` enforces type
    -- only; the resolver in init.lua guards against empty strings.
    t.assert_error(function() peers.set_credential(123) end)
end

g.test_self_alias_returns_nil_outside_box = function()
    -- Without a live box, the helper falls back to nil. The full
    -- behaviour is covered by the integration suite.
    peers._reset()
    -- box exists in this test process (luatest loads it) but
    -- box.info.name is nil-cdata when box.cfg hasn't run yet.
    local alias = peers.self_alias()
    t.assert(alias == nil or type(alias) == 'string',
        'self_alias must return nil or string, got ' .. type(alias))
end
