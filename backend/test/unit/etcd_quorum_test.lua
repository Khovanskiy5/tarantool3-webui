-- Unit tests for the pure etcd quorum decision (Task FO-8).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('etcd_quorum')

local etcd = require('webui.config_store.etcd')

local function member(reachable, leader)
    return { reachable = reachable, leader = leader }
end

g.test_three_all_healthy_has_quorum = function()
    local q = etcd._quorum_from_statuses({
        member(true, '1001'), member(true, '1001'), member(true, '1001'),
    })
    t.assert_equals(q.total, 3)
    t.assert_equals(q.needed, 2)
    t.assert_equals(q.in_quorum, 3)
    t.assert_equals(q.has_quorum, true)
end

g.test_three_one_down_still_quorum = function()
    -- one member down — majority (2/3) still in quorum.
    local q = etcd._quorum_from_statuses({
        member(true, '1001'), member(true, '1001'), member(false, nil),
    })
    t.assert_equals(q.reachable, 2)
    t.assert_equals(q.in_quorum, 2)
    t.assert_equals(q.has_quorum, true)
end

g.test_three_two_down_loses_quorum = function()
    local q = etcd._quorum_from_statuses({
        member(true, '1001'), member(false, nil), member(false, nil),
    })
    t.assert_equals(q.in_quorum, 1)
    t.assert_equals(q.needed, 2)
    t.assert_equals(q.has_quorum, false)
end

g.test_partition_all_reachable_but_no_leader = function()
    -- All three respond, but each reports leader "0" (no raft leader) —
    -- a partition where nobody has quorum.
    local q = etcd._quorum_from_statuses({
        member(true, '0'), member(true, '0'), member(true, '0'),
    })
    t.assert_equals(q.reachable, 3)
    t.assert_equals(q.in_quorum, 0)
    t.assert_equals(q.has_quorum, false)
end

g.test_leader_zero_as_number_counts_as_no_leader = function()
    local q = etcd._quorum_from_statuses({
        member(true, 0), member(true, '1001'), member(true, '1001'),
    })
    -- the numeric-zero member does not count; 2/3 still quorum.
    t.assert_equals(q.in_quorum, 2)
    t.assert_equals(q.has_quorum, true)
end

g.test_single_node_quorum = function()
    -- A 1-node etcd (dev / witness degenerate case): needs 1.
    local q = etcd._quorum_from_statuses({ member(true, '1001') })
    t.assert_equals(q.needed, 1)
    t.assert_equals(q.has_quorum, true)
    local down = etcd._quorum_from_statuses({ member(false, nil) })
    t.assert_equals(down.has_quorum, false)
end

g.test_empty_is_no_quorum = function()
    local q = etcd._quorum_from_statuses({})
    t.assert_equals(q.total, 0)
    t.assert_equals(q.has_quorum, false)
end
