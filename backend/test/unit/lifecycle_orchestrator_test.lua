-- Unit tests for the safe restart orchestration planners (Task FO-12).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('lifecycle_orchestrator')

local orch = require('webui.lifecycle.orchestrator')
local validate = require('webui.lifecycle.validate')

-- Build a 3-instance servers map. `leader` is the rw / queue owner.
local function cluster(opts)
    opts = opts or {}
    local leader = opts.leader or 'tt-1'
    local down = {}
    for _, a in ipairs(opts.down or {}) do down[a] = true end
    local servers = {}
    for i = 1, (opts.n or 3) do
        local alias = 'tt-' .. i
        local is_leader = (alias == leader)
        servers[alias] = {
            alias = alias,
            id = i,
            replicaset_name = 'rs-1',
            reachable = not down[alias],
            status = down[alias] and 'unknown' or (opts.orphan == alias
                and 'orphan' or 'running'),
            is_ro = not is_leader,
            synchro = { queue = { owner = is_leader and i or 0 } },
            replication = opts.replication,
        }
    end
    return servers
end

-- ── majority ────────────────────────────────────────────────────────

g.test_majority_needed = function()
    t.assert_equals(orch.majority_needed(3), 2)
    t.assert_equals(orch.majority_needed(5), 3)
    t.assert_equals(orch.majority_needed(2), 2)
    t.assert_equals(orch.majority_needed(1), 1)
end

g.test_count_alive_excludes_unreachable_and_orphan = function()
    t.assert_equals(orch.count_alive(cluster()), 3)
    t.assert_equals(orch.count_alive(cluster({ down = { 'tt-3' } })), 2)
    t.assert_equals(orch.count_alive(cluster({ orphan = 'tt-2' })), 2)
end

g.test_majority_after_stop_one_of_three_ok = function()
    local v = orch.majority_after_stop(cluster(), { 'tt-2' })
    t.assert_equals(v.total, 3)
    t.assert_equals(v.alive_after, 2)
    t.assert_equals(v.needed, 2)
    t.assert_equals(v.ok, true)
end

g.test_majority_after_stop_two_of_three_blocked = function()
    local v = orch.majority_after_stop(cluster(), { 'tt-2', 'tt-3' })
    t.assert_equals(v.alive_after, 1)
    t.assert_equals(v.ok, false)
    t.assert_str_contains(v.reason, 'majority')
    t.assert_str_contains(v.reason, 'tt-2, tt-3')
end

g.test_majority_after_stop_accepts_set = function()
    local v = orch.majority_after_stop(cluster(), { ['tt-2'] = true })
    t.assert_equals(v.ok, true)
end

g.test_majority_guard_wrapper = function()
    local ok1 = validate.majority_guard(cluster(), { 'tt-2' })
    t.assert_equals(ok1, true)
    local ok2, reason = validate.majority_guard(cluster(), { 'tt-1', 'tt-2' })
    t.assert_equals(ok2, false)
    t.assert_str_contains(reason, 'majority')
end

-- ── leader detection ────────────────────────────────────────────────

g.test_leader_alias_by_queue_owner = function()
    t.assert_equals(orch.leader_alias(cluster({ leader = 'tt-3' })), 'tt-3')
end

g.test_leader_alias_fallback_to_rw = function()
    -- no synchro owner info → fall back to is_ro==false.
    local servers = cluster()
    for _, s in pairs(servers) do s.synchro = nil end
    t.assert_equals(orch.leader_alias(servers), 'tt-1')
end

g.test_leaderless_returns_nil = function()
    local servers = cluster()
    for _, s in pairs(servers) do
        s.is_ro = true
        s.synchro = { queue = { owner = 0 } }
    end
    t.assert_equals(orch.leader_alias(servers), nil)
end

-- ── restart order (followers first, leader last) ────────────────────

g.test_restart_order_leader_last = function()
    local order, leader = orch.restart_order(cluster({ leader = 'tt-2' }))
    t.assert_equals(leader, 'tt-2')
    t.assert_equals(order, { 'tt-1', 'tt-3', 'tt-2' })
end

g.test_restart_order_skips_dead = function()
    local order = orch.restart_order(cluster({ leader = 'tt-1', down = { 'tt-3' } }))
    -- tt-3 is down → not in the order; leader tt-1 last.
    t.assert_equals(order, { 'tt-2', 'tt-1' })
end

-- ── best follower (lag-aware demote-first pick) ─────────────────────

g.test_best_follower_picks_least_lagged = function()
    local servers = cluster({ leader = 'tt-1' })
    servers['tt-2'].lag = 5.0
    servers['tt-3'].lag = 0.2
    t.assert_equals(orch.best_follower(servers, 'tt-1'), 'tt-3')
end

g.test_best_follower_tie_breaks_alphabetically = function()
    local servers = cluster({ leader = 'tt-2' })
    servers['tt-1'].lag = 1.0
    servers['tt-3'].lag = 1.0
    t.assert_equals(orch.best_follower(servers, 'tt-2'), 'tt-1')
end

g.test_best_follower_skips_dead_and_non_electable = function()
    local servers = cluster({ leader = 'tt-1', down = { 'tt-2' } })
    -- tt-2 down → only tt-3 left.
    t.assert_equals(orch.best_follower(servers, 'tt-1'), 'tt-3')
    servers['tt-3'].electable = false
    -- now no eligible follower.
    t.assert_equals(orch.best_follower(servers, 'tt-1'), nil)
end

-- ── convergence ─────────────────────────────────────────────────────

g.test_is_converged_running_no_upstreams = function()
    local servers = cluster()
    t.assert_equals(orch.is_converged(servers['tt-1']), true)
end

g.test_is_converged_false_when_upstream_not_following = function()
    local srv = {
        reachable = true, status = 'running',
        replication = { { upstream = { status = 'disconnected' } } },
    }
    t.assert_equals(orch.is_converged(srv), false)
end

g.test_is_converged_true_when_all_follow = function()
    local srv = {
        reachable = true, status = 'running',
        replication = {
            { upstream = { status = 'follow' } },
            { upstream = { status = 'sync' } },
            { id = 1 },  -- self entry, no upstream
        },
    }
    t.assert_equals(orch.is_converged(srv), true)
end

g.test_is_converged_false_when_orphan = function()
    local srv = { reachable = true, status = 'orphan' }
    t.assert_equals(orch.is_converged(srv), false)
end

-- ── plan ────────────────────────────────────────────────────────────

g.test_plan_rolling_restart_three_node = function()
    local plan = orch.plan_rolling_restart(cluster({ leader = 'tt-1' }))
    t.assert_equals(plan.blocked, false)
    t.assert_equals(plan.leader, 'tt-1')
    t.assert_equals(#plan.steps, 3)
    -- last step is the leader, flagged demote_first.
    local last = plan.steps[#plan.steps]
    t.assert_equals(last.instance or last.alias, 'tt-1')
    t.assert_equals(last.is_leader, true)
    t.assert_equals(last.demote_first, true)
end

g.test_plan_rolling_restart_two_node_blocked = function()
    -- 2-node cluster: stopping one leaves 1 < majority(2) → blocked.
    local plan = orch.plan_rolling_restart(cluster({ n = 2, leader = 'tt-1' }))
    t.assert_equals(plan.blocked, true)
    t.assert_str_contains(plan.reason, 'majority')
end
