local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local snap = require('webui.recovery.snapshot')

local g = t.group('recovery.snapshot')

local function srv(overrides)
    local base = {
        uuid = 'uuid', reachable = true, ro = false,
        replication = {}, box_info = {
            id = 1, status = 'running',
            synchro = { queue = { owner = 1 } },
            vclock = { [1] = 10 },
            election = { term = 5 },
            replication = {},
        },
    }
    for k, v in pairs(overrides or {}) do base[k] = v end
    return base
end

g.test_classify_marks_queue_owner = function()
    local out = snap.classify({
        ['tt-1'] = srv({}),
    })
    t.assert_equals(out['tt-1'].role, 'queue-owner')
    t.assert_equals(out['tt-1'].current_term, 5)
    t.assert_equals(out['tt-1'].last_lsn, 10)
end

g.test_classify_marks_orphan_from_status = function()
    local out = snap.classify({
        ['tt-1'] = srv({
            box_info = { status = 'orphan',
                synchro = { queue = { owner = 0 } } },
        }),
    })
    t.assert_equals(out['tt-1'].role, 'orphan')
end

g.test_classify_detects_split_brain_from_message = function()
    local out = snap.classify({
        ['tt-1'] = srv({
            replication = {
                [1] = {
                    uuid = 'wins-uuid',
                    upstream = {
                        status = 'stopped',
                        message = 'Split-Brain discovered: got an async transaction from an old term',
                    },
                },
            },
        }),
    })
    t.assert_equals(out['tt-1'].role, 'split-brain')
    t.assert_equals(#out['tt-1'].broken_upstreams, 1)
end

g.test_classify_marks_unreachable = function()
    local out = snap.classify({
        ['tt-1'] = srv({ reachable = false }),
    })
    t.assert_equals(out['tt-1'].role, 'unreachable')
end

g.test_recommendation_split_brain_wins = function()
    local classified = {
        ['tt-1'] = { role = 'split-brain' },
        ['tt-2'] = { role = 'orphan' },
        ['tt-3'] = { role = 'queue-owner' },
    }
    t.assert_equals(snap.recommend(classified), 'split_brain_resolve')
end

g.test_recommendation_orphan_when_no_split_brain = function()
    local classified = {
        ['tt-1'] = { role = 'orphan' },
        ['tt-3'] = { role = 'queue-owner' },
    }
    t.assert_equals(snap.recommend(classified), 'orphan_resolve')
end

g.test_recommendation_takeover_when_no_owner = function()
    local classified = {
        ['tt-1'] = { role = 'follower' },
        ['tt-2'] = { role = 'follower' },
    }
    t.assert_equals(snap.recommend(classified), 'leader_takeover')
end

g.test_recommendation_no_action_when_healthy = function()
    local classified = {
        ['tt-1'] = { role = 'queue-owner' },
        ['tt-2'] = { role = 'follower' },
    }
    t.assert_equals(snap.recommend(classified), 'no_action_needed')
end

g.test_recommendation_degraded_when_peer_unreachable = function()
    -- Quorum is intact (queue owner present) but at least one peer
    -- is gone. The cluster is operational but cannot tolerate
    -- another failure — UI should show a degraded banner, not the
    -- green "healthy" one.
    local classified = {
        ['tt-1'] = { role = 'queue-owner' },
        ['tt-2'] = { role = 'follower' },
        ['tt-3'] = { role = 'unreachable' },
    }
    t.assert_equals(snap.recommend(classified), 'degraded')
end

g.test_split_brain_groups_groups_by_divergent_from = function()
    local classified = {
        ['tt-1'] = {
            role = 'split-brain',
            broken_upstreams = {
                { peer_uuid = 'wins-uuid',
                  message = 'Split-Brain discovered: ...' },
            },
        },
        ['tt-2'] = {
            role = 'split-brain',
            broken_upstreams = {
                { peer_uuid = 'wins-uuid',
                  message = 'Split-Brain discovered: ...' },
            },
        },
    }
    local groups = snap.split_brain_groups(classified)
    t.assert_equals(#groups, 1)
    t.assert_equals(groups[1].divergent_from, 'wins-uuid')
    t.assert_equals(groups[1].members, { 'tt-1', 'tt-2' })
end

local json = require('json')

g.test_recommend_action_orphan_force_reconnect = function()
    local classified = {
        ['tt-2'] = { alias = 'tt-2', role = 'orphan', reachable = true,
            vclock = { [1] = 5 } },
    }
    local ra = snap.recommend_action(classified, 'orphan_resolve')
    t.assert_equals(ra.action, 'orphan_resolve')
    local p = json.decode(ra.payload)
    t.assert_equals(p.action, 'force_reconnect')
    t.assert_equals(p.target_alias, 'tt-2')
end

g.test_recommend_action_takeover_dominating_candidate = function()
    local classified = {
        ['tt-2'] = { alias = 'tt-2', role = 'follower', reachable = true,
            vclock = { [1] = 12 } },
        ['tt-3'] = { alias = 'tt-3', role = 'follower', reachable = true,
            vclock = { [1] = 10 } },
    }
    local ra = snap.recommend_action(classified, 'leader_takeover')
    t.assert_equals(ra.action, 'leader_takeover')
    t.assert_equals(json.decode(ra.payload).target_alias, 'tt-2')
end

g.test_recommend_action_takeover_no_dominator_is_nil = function()
    -- Divergence: neither dominates the other.
    local classified = {
        ['tt-2'] = { alias = 'tt-2', role = 'follower', reachable = true,
            vclock = { [1] = 12, [2] = 0 } },
        ['tt-3'] = { alias = 'tt-3', role = 'follower', reachable = true,
            vclock = { [1] = 10, [2] = 5 } },
    }
    t.assert_equals(snap.recommend_action(classified, 'leader_takeover'), nil)
end

g.test_recommend_action_split_brain_is_nil = function()
    t.assert_equals(snap.recommend_action({}, 'split_brain_resolve'), nil)
end

g.test_recommend_action_degraded_and_healthy_are_nil = function()
    t.assert_equals(snap.recommend_action({}, 'degraded'), nil)
    t.assert_equals(snap.recommend_action({}, 'no_action_needed'), nil)
end
