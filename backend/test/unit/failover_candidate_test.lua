-- Unit tests for failover candidate scoring/selection, incl. the
-- anonymous-replica exclusion (Task FO-20).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_candidate')

local agent = require('webui.failover.agent')

local function probe(over)
    local p = { reachable = true, status = 'running', ro = true, lag = 0 }
    for k, v in pairs(over or {}) do p[k] = v end
    return p
end

g.test_anon_never_scored = function()
    t.assert_equals(agent.score_candidate(probe({ anon = true }), 5), -math.huge,
        'anonymous replica is never a candidate')
end

g.test_healthy_candidate_scored = function()
    t.assert(agent.score_candidate(probe({ ro = false }), 5) > 0,
        'healthy RW candidate scores positive')
end

g.test_unreachable_and_orphan_and_lag_excluded = function()
    t.assert_equals(agent.score_candidate(probe({ reachable = false }), 5), -math.huge)
    t.assert_equals(agent.score_candidate(probe({ ro_reason = 'orphan' }), 5), -math.huge)
    t.assert_equals(agent.score_candidate(probe({ lag = 99 }), 5), -math.huge)
    t.assert_equals(agent.score_candidate(probe({ status = 'loading' }), 5), -math.huge)
end

g.test_pick_leader_skips_anon = function()
    local rs = {
        ['tt-1'] = probe({ anon = true, ro = false }),  -- anon, even if RW
        ['tt-2'] = probe({ ro = true, lag = 1 }),        -- healthy follower
    }
    t.assert_equals(agent.pick_leader(rs, 5), 'tt-2',
        'never pick the anon replica even though it looks RW')
end

g.test_pick_leader_all_anon_returns_nil = function()
    local rs = {
        ['tt-1'] = probe({ anon = true }),
        ['tt-2'] = probe({ anon = true }),
    }
    t.assert_equals(agent.pick_leader(rs, 5), nil,
        'no eligible (non-anon) candidate → nil')
end
