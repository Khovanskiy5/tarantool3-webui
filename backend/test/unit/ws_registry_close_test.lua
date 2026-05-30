local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local registry = require('webui.http.ws_registry')

local g = t.group('ws_registry.close_by_session')

g.before_each(function() registry._reset() end)

g.test_close_by_session_targets_matching_entries = function()
    local closed = {}
    local function close_fn(code, reason)
        table.insert(closed, { code = code, reason = reason })
    end
    local a = registry.register({ session_id = 'sid-A', close_fn = close_fn })
    local b = registry.register({ session_id = 'sid-A', close_fn = close_fn })
    local c = registry.register({ session_id = 'sid-B', close_fn = close_fn })
    t.assert(a and b and c)
    local n = registry.close_by_session('sid-A', 'logout')
    t.assert_equals(n, 2)
    t.assert_equals(#closed, 2)
    -- the survivor must still be registered
    t.assert_equals(registry.count(), 1)
    t.assert_equals(registry.get(c.id).session_id, 'sid-B')
end

g.test_close_by_session_ignores_unknown_or_empty_sid = function()
    registry.register({ session_id = 'sid-A' })
    t.assert_equals(registry.close_by_session('sid-MISSING', 'logout'), 0)
    t.assert_equals(registry.close_by_session('', 'logout'),            0)
    t.assert_equals(registry.close_by_session(nil, 'logout'),           0)
end
