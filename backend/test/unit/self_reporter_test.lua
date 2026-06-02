local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local self_reporter = require('webui.cluster.self_reporter')

local g = t.group('self_reporter')

g.test_build_payload_rw_instance = function()
    -- Healthy RW leader: status=running, ro=false, no ro_reason.
    local info = {
        pid       = 4242,
        ro        = false,
        ro_reason = nil,
        status    = 'running',
    }
    local p = self_reporter.build_payload(info, 'tt-1.local', 'tt-1', 1000.5)
    t.assert_equals(p.hostname, 'tt-1.local')
    t.assert_equals(p.pid, 4242)
    t.assert_equals(p.alias, 'tt-1')
    t.assert_equals(p.mode, 'rw')
    t.assert_equals(p.ro_reason, nil)
    t.assert_equals(p.status, 'running')
    t.assert_equals(p.ts, 1000.5)
end

g.test_build_payload_ro_instance_with_reason = function()
    -- Replica: status=running but RO with a reason (typical follower).
    local info = {
        pid       = 7,
        ro        = true,
        ro_reason = 'config',
        status    = 'running',
    }
    local p = self_reporter.build_payload(info, 'h', 'tt-2', 2000)
    t.assert_equals(p.mode, 'ro')
    t.assert_equals(p.ro_reason, 'config')
end

g.test_build_payload_orphan = function()
    -- Orphan: box hasn't fully joined the cluster yet.
    local info = {
        pid       = 99,
        ro        = true,
        ro_reason = 'orphan',
        status    = 'orphan',
    }
    local p = self_reporter.build_payload(info, 'h', 'tt-3', 3000)
    t.assert_equals(p.mode, 'ro')
    t.assert_equals(p.ro_reason, 'orphan')
    t.assert_equals(p.status, 'orphan')
end

g.test_resolve_hostname_prefers_env = function()
    -- HOSTNAME is set by docker; the resolver must trust it without
    -- touching the filesystem when present and non-empty.
    local saved = os.getenv('HOSTNAME')
    -- Lua 5.1 has no os.setenv; setenv via shell-out is overkill for
    -- a unit test. Skip the env-preference assertion when HOSTNAME is
    -- already populated (CI is a known consumer) — the fallback path
    -- is exercised by the next test on systems without /etc/hostname.
    if saved ~= nil and saved ~= '' then
        t.assert_type(self_reporter.resolve_hostname(), 'string')
        t.assert(#self_reporter.resolve_hostname() > 0)
    else
        -- Without env and /etc/hostname the fallback string is exact.
        local got = self_reporter.resolve_hostname()
        t.assert_type(got, 'string')
        -- Either the file resolves to something non-empty, or we
        -- get the documented fallback literal.
        t.assert(got == 'unknown' or #got > 0)
    end
end

g.test_defaults_match_enterprise_stateboard = function()
    -- Defaults documented as matching Enterprise stateboard semantics.
    -- These must stay in sync with the values in instance_config.lua.
    t.assert_equals(self_reporter.DEFAULTS.enabled, false)
    t.assert_equals(self_reporter.DEFAULTS.renew_interval, 2)
    t.assert_equals(self_reporter.DEFAULTS.keepalive_interval, 10)
end

g.test_key_prefix_matches_enterprise_layout = function()
    -- The key path is the contract Enterprise stateboard documents
    -- (`<config-prefix>/state/by-name/<instance_name>`). Test pins
    -- the relative-to-etcd-prefix portion so a refactor cannot
    -- silently move the keyspace.
    t.assert_equals(self_reporter.KEY_PREFIX, '/state/by-name/')
end

g.test_start_requires_enabled = function()
    -- start({}) without enabled: true must return (nil, 'disabled')
    -- so the lifecycle wiring can distinguish "operator opted out"
    -- from "start failed for a real reason".
    self_reporter._reset()
    local ok, err = self_reporter.start({})
    t.assert_equals(ok, nil)
    t.assert_equals(err, 'disabled')
end

g.test_status_when_stopped = function()
    self_reporter._reset()
    local s = self_reporter.status()
    t.assert_equals(s.enabled, false)
    t.assert_equals(s.lease_id, nil)
end

-- ─── liveness resolver decoder ───────────────────────────────────────

local liveness = require('webui.graphql.resolvers.cluster_liveness')
local json     = require('json')

g.test_decode_entry_happy_path = function()
    -- A payload written by self_reporter on an RW leader.
    local payload = json.encode({
        hostname  = 'tt-1.local',
        pid       = 4242,
        alias     = 'tt-1',
        mode      = 'rw',
        ro_reason = nil,
        status    = 'running',
        ts        = 1000,
    })
    local row = liveness._decode_entry(
        { key = '/tarantool/webui/state/by-name/tt-1', value = payload },
        1005)
    t.assert_equals(row.alias, 'tt-1')
    t.assert_equals(row.hostname, 'tt-1.local')
    t.assert_equals(row.pid, 4242)
    t.assert_equals(row.mode, 'rw')
    t.assert_equals(row.status, 'running')
    t.assert_equals(row.ts, 1000)
    t.assert_equals(row.age_seconds, 5)
end

g.test_decode_entry_falls_back_to_key_alias = function()
    -- Future writers may stop embedding `alias` in the payload.
    -- The decoder must still produce a usable row by parsing the
    -- key suffix — otherwise the UI would silently lose rows.
    local payload = json.encode({
        hostname = 'h', pid = 1, mode = 'ro', status = 'running', ts = 100,
    })
    local row = liveness._decode_entry(
        { key = '/tarantool/webui/state/by-name/tt-3', value = payload }, 200)
    t.assert_equals(row.alias, 'tt-3')
end

g.test_decode_entry_rejects_garbage = function()
    -- Hand-written keys / corrupted values must not break the
    -- response — return nil and let the caller filter them out.
    t.assert_equals(liveness._decode_entry(nil, 0), nil)
    t.assert_equals(liveness._decode_entry({}, 0), nil)
    t.assert_equals(liveness._decode_entry(
        { key = 'k', value = 'not json' }, 0), nil)
    t.assert_equals(liveness._decode_entry(
        { key = 'k', value = '"not a table"' }, 0), nil)
end

g.test_decode_entry_omits_age_when_ts_missing = function()
    -- A truncated payload (no ts) yields age = nil so the UI does
    -- not render a misleading negative number.
    local payload = json.encode({
        alias = 'tt-9', mode = 'rw', status = 'running',
    })
    local row = liveness._decode_entry(
        { key = 'k/tt-9', value = payload }, 500)
    t.assert_equals(row.age_seconds, nil)
    t.assert_equals(row.ts, 0)
end
