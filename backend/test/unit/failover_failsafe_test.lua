-- Unit tests for the failsafe acceptance verdict (Task FO-16).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_failsafe')

local failsafe = require('webui.failover.failsafe')

local function res(tbl) return tbl end

g.test_single_node_stays_rw = function()
    t.assert_equals(failsafe.all_accepted({}, 0), true,
        'no peers → single node → safe to stay RW')
end

g.test_all_peers_accept = function()
    t.assert_equals(failsafe.all_accepted(res({
        ['tt-2'] = { ok = true, value = { accepted = true } },
        ['tt-3'] = { ok = true, value = { accepted = true } },
    }), 2), true)
end

g.test_one_peer_rejects = function()
    t.assert_equals(failsafe.all_accepted(res({
        ['tt-2'] = { ok = true, value = { accepted = true } },
        ['tt-3'] = { ok = true, value = { accepted = false } },
    }), 2), false, 'a peer that is itself RW rejects → demote')
end

g.test_one_peer_unreachable = function()
    t.assert_equals(failsafe.all_accepted(res({
        ['tt-2'] = { ok = true, value = { accepted = true } },
        ['tt-3'] = { ok = false, err = 'timeout' },
    }), 2), false, 'unreachable peer → cannot confirm unanimity → demote')
end

g.test_missing_peer_response = function()
    t.assert_equals(failsafe.all_accepted(res({
        ['tt-2'] = { ok = true, value = { accepted = true } },
    }), 2), false, 'fewer responses than expected → demote')
end

g.test_garbage_results = function()
    t.assert_equals(failsafe.all_accepted(nil, 2), false)
    t.assert_equals(failsafe.all_accepted({ ['tt-2'] = { ok = true } }, 2), false,
        'missing value table → reject')
end
