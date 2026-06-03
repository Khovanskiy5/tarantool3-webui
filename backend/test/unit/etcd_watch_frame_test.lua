-- Unit tests for the etcd v3 streaming-watch frame parser (Task FO-7).

local t = require('luatest')
local fio = require('fio')
local digest = require('digest')
local json = require('json')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('etcd_watch_frame')

local etcd = require('webui.config_store.etcd')

local function b64(s)
    return digest.base64_encode(s, { nowrap = true })
end

-- Collect callback invocations into a list.
local function collector()
    local events = {}
    return events, function(kv, kind)
        events[#events + 1] = { kv = kv, kind = kind }
    end
end

g.test_created_ack_yields_no_event = function()
    local events, cb = collector()
    etcd._handle_watch_frame({ result = { created = true } }, cb)
    t.assert_equals(#events, 0, 'the creation ack is not a change')
end

g.test_progress_notify_yields_no_event = function()
    local events, cb = collector()
    -- progress_notify keepalive: a result with header but no events.
    etcd._handle_watch_frame({ result = { header = { revision = 42 } } }, cb)
    t.assert_equals(#events, 0)
end

g.test_put_event_decodes_kv = function()
    local events, cb = collector()
    local frame = {
        result = {
            events = {
                {
                    type = 'PUT',
                    kv = {
                        key = b64('/tarantool/webui/failover/replicasets/r1/leader'),
                        value = b64('{"leader":"tt-2"}'),
                        mod_revision = '128',
                    },
                },
            },
        },
    }
    etcd._handle_watch_frame(frame, cb)
    t.assert_equals(#events, 1)
    t.assert_equals(events[1].kind, 'PUT')
    t.assert_str_contains(events[1].kv.key, 'r1/leader')
    t.assert_equals(events[1].kv.value, '{"leader":"tt-2"}')
    t.assert_equals(events[1].kv.revision, 128)
end

g.test_delete_event_default_type = function()
    local events, cb = collector()
    -- A DELETE event (lease expiry on the coordinator key) — no value.
    local frame = {
        result = {
            events = {
                { type = 'DELETE', kv = { key = b64('/c'), mod_revision = '9' } },
            },
        },
    }
    etcd._handle_watch_frame(frame, cb)
    t.assert_equals(#events, 1)
    t.assert_equals(events[1].kind, 'DELETE')
    t.assert_equals(events[1].kv.revision, 9)
end

g.test_multiple_events_in_one_frame = function()
    local events, cb = collector()
    local frame = {
        result = {
            events = {
                { type = 'PUT', kv = { key = b64('/a'), mod_revision = '1' } },
                { type = 'PUT', kv = { key = b64('/b'), mod_revision = '2' } },
            },
        },
    }
    etcd._handle_watch_frame(frame, cb)
    t.assert_equals(#events, 2)
end

g.test_canceled_frame_raises_for_reconnect = function()
    local _, cb = collector()
    t.assert_error_msg_contains('watch canceled', function()
        etcd._handle_watch_frame(
            { result = { canceled = true, cancel_reason = 'compacted' } }, cb)
    end)
end

g.test_error_frame_raises = function()
    local _, cb = collector()
    -- `{"error": {...}}` from the gateway has no `result` table.
    t.assert_error_msg_contains('watch stream error', function()
        etcd._handle_watch_frame({ error = { code = 13 } }, cb)
    end)
end

g.test_real_json_line_roundtrip = function()
    -- A frame as it actually arrives on the wire (JSON string), decoded
    -- then parsed — mirrors run_watch_stream's read→decode→handle path.
    local events, cb = collector()
    local line = json.encode({
        result = {
            header = { revision = 200 },
            events = {
                { type = 'PUT', kv = {
                    key = b64('/k'), value = b64('v'), mod_revision = '200' } },
            },
        },
    })
    local parsed = json.decode(line)
    etcd._handle_watch_frame(parsed, cb)
    t.assert_equals(#events, 1)
    t.assert_equals(events[1].kv.value, 'v')
    t.assert_equals(events[1].kv.revision, 200)
end
