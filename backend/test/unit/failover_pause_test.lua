-- Unit tests for the maintenance-pause key helper (Task FO-19).

local t = require('luatest')
local fio = require('fio')
local fiber = require('fiber')
local json = require('json')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_pause')

local pause = require('webui.failover.pause')

-- Minimal in-memory etcd client (get/put/delete on the raw key — the
-- real client applies the prefix internally).
local function fake_client()
    local store = {}
    return {
        store = store,
        get = function(_, k)
            local v = store[k]
            return v and { value = v } or nil
        end,
        put = function(_, k, val) store[k] = val; return {}, nil end,
        delete = function(_, k) store[k] = nil; return {}, nil end,
    }
end

g.test_set_rejects_too_long_ttl = function()
    local res, err = pause.set(fake_client(), pause.MAX_PAUSE_TTL_SEC + 1, 'op')
    t.assert_is(res, nil)
    t.assert_equals(err, 'PAUSE_TTL_TOO_LONG')
end

g.test_set_read_clear_roundtrip = function()
    local c = fake_client()
    local res = pause.set(c, 60, 'alice')
    t.assert_not_equals(res, nil)
    t.assert_equals(pause.is_active(c), true)
    local entry = pause.read(c)
    t.assert_equals(entry.by_user, 'alice')
    t.assert(entry.until_ts > fiber.time())
    pause.clear(c)
    t.assert_equals(pause.is_active(c), false)
end

g.test_read_expired_returns_nil = function()
    local c = fake_client()
    c.store[pause.KEY] = json.encode({
        until_ts = fiber.time() - 10, by_user = 'x',
    })
    t.assert_equals(pause.read(c), nil)
    t.assert_equals(pause.is_active(c), false)
end

g.test_zero_ttl_falls_back_to_default = function()
    local c = fake_client()
    local res = pause.set(c, 0, 'op')
    t.assert_not_equals(res, nil)
    -- default TTL is 1h → still active and well in the future.
    t.assert(res.until_ts > fiber.time() + 60)
end

g.test_no_client_is_typed_error = function()
    local _, err = pause.set(nil, 60, 'op')
    t.assert_str_contains(err, 'etcd client unavailable')
end
