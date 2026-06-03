local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local split_brain = require('webui.recovery.split_brain')

local g = t.group('recovery.split_brain.resolve')

-- Baseline characterization of M.resolve(payload, root). Locks the
-- dispatch, the input-validation error shapes and the result-aggregation
-- contract BEFORE the function is split into per-action helpers, so the
-- refactor can be verified to preserve behaviour byte-for-byte.
--
-- The RPC/audit side-effects are stubbed: M.rebootstrap_one /
-- M.force_promote (public, reassignable) and the lazily-required
-- cluster.state snapshot. Live RPC behaviour stays covered by the
-- mandatory dev-cluster check in the refactor task.

local saved

g.before_each(function()
    saved = {
        rebootstrap_one = split_brain.rebootstrap_one,
        force_promote   = split_brain.force_promote,
        state_loaded    = package.loaded['webui.cluster.state'],
        fiber_sleep     = require('fiber').sleep,
    }
    -- Default stubs: no queue owner, every rebootstrap succeeds.
    package.loaded['webui.cluster.state'] = {
        snapshot = function() return { servers = {} } end,
    }
    require('fiber').sleep = function() end
end)

g.after_each(function()
    split_brain.rebootstrap_one = saved.rebootstrap_one
    split_brain.force_promote   = saved.force_promote
    package.loaded['webui.cluster.state'] = saved.state_loaded
    require('fiber').sleep = saved.fiber_sleep
end)

-- ── manual ───────────────────────────────────────────────────────────

g.test_manual_records_and_closes = function()
    local res = split_brain.resolve(
        { action = 'manual', winner_alias = 'tt-1',
          losing_aliases = { 'tt-2' } },
        { user = 'admin', request_id = 'r1' })
    t.assert_equals(res, {
        ok = true, action = 'manual',
        results = { { peer = '*', ok = true,
                      msg = 'operator handles manually' } },
    })
end

-- ── input validation ─────────────────────────────────────────────────

g.test_rebootstrap_requires_losers = function()
    local res = split_brain.resolve({ action = 'rebootstrap_losing' }, {})
    t.assert_equals(res, {
        ok = false, action = 'rebootstrap_losing',
        results = {}, error = 'losing_aliases is required',
    })
end

g.test_rebootstrap_empty_losers_rejected = function()
    local res = split_brain.resolve(
        { action = 'rebootstrap_losing', losing_aliases = {} }, {})
    t.assert_equals(res.ok, false)
    t.assert_equals(res.error, 'losing_aliases is required')
end

g.test_force_promote_requires_winner = function()
    local res = split_brain.resolve({ action = 'force_promote_winner' }, {})
    t.assert_equals(res, {
        ok = false, action = 'force_promote_winner',
        results = {}, error = 'winner_alias is required',
    })
end

g.test_unknown_action_rejected = function()
    local res = split_brain.resolve({ action = 'nope' }, {})
    t.assert_equals(res, {
        ok = false, action = 'nope', results = {},
        error = 'unsupported action',
    })
end

g.test_nil_action_falls_back_to_unknown = function()
    local res = split_brain.resolve({}, {})
    t.assert_equals(res.action, 'unknown')
    t.assert_equals(res.ok, false)
    t.assert_equals(res.error, 'unsupported action')
end

-- ── rebootstrap_losing happy path (no queue owner) ───────────────────

g.test_rebootstrap_dispatches_each_loser = function()
    local seen = {}
    split_brain.rebootstrap_one = function(alias)
        seen[#seen + 1] = alias
        return true, 'rebootstrap dispatched on ' .. alias
    end
    local res = split_brain.resolve(
        { action = 'rebootstrap_losing', losing_aliases = { 'tt-2', 'tt-3' } },
        {})
    t.assert_equals(seen, { 'tt-2', 'tt-3' })
    t.assert_equals(res.ok, true)
    t.assert_equals(res.action, 'rebootstrap_losing')
    t.assert_equals(#res.results, 2)
    t.assert_equals(res.results[1], { peer = 'tt-2', ok = true,
        msg = 'rebootstrap dispatched on tt-2' })
end

g.test_rebootstrap_one_failure_marks_overall_failure = function()
    split_brain.rebootstrap_one = function(alias)
        if alias == 'tt-3' then return false, 'boom' end
        return true, 'ok'
    end
    local res = split_brain.resolve(
        { action = 'rebootstrap_losing', losing_aliases = { 'tt-2', 'tt-3' } },
        {})
    t.assert_equals(res.ok, false)
    t.assert_equals(#res.results, 2)
end

-- ── rebootstrap_losing when a loser owns the synchro queue ───────────

g.test_rebootstrap_queue_owner_requires_winner = function()
    package.loaded['webui.cluster.state'] = {
        snapshot = function()
            return { servers = {
                ['tt-2'] = { box_info = {
                    id = 2,
                    synchro = { queue = { owner = 2 } },
                } },
            } }
        end,
    }
    local res = split_brain.resolve(
        { action = 'rebootstrap_losing', losing_aliases = { 'tt-2' } }, {})
    t.assert_equals(res.ok, false)
    t.assert_str_contains(res.error, 'winner_alias is required to move queue')
end

g.test_rebootstrap_queue_owner_pre_promotes_winner = function()
    package.loaded['webui.cluster.state'] = {
        snapshot = function()
            return { servers = {
                ['tt-2'] = { box_info = {
                    id = 2,
                    synchro = { queue = { owner = 2 } },
                } },
            } }
        end,
    }
    local promoted
    split_brain.force_promote = function(winner)
        promoted = winner
        return true, 'promote dispatched on ' .. winner
    end
    split_brain.rebootstrap_one = function(alias)
        return true, 'rebootstrap dispatched on ' .. alias
    end
    local res = split_brain.resolve(
        { action = 'rebootstrap_losing', winner_alias = 'tt-1',
          losing_aliases = { 'tt-2' } }, {})
    t.assert_equals(promoted, 'tt-1')
    t.assert_equals(res.ok, true)
    -- First result is the pre-rebootstrap promote, then the loser.
    t.assert_equals(res.results[1].peer, 'tt-1')
    t.assert_str_contains(res.results[1].msg, 'pre-rebootstrap promote')
    t.assert_equals(res.results[2].peer, 'tt-2')
end

g.test_rebootstrap_pre_promote_failure_bails_out = function()
    package.loaded['webui.cluster.state'] = {
        snapshot = function()
            return { servers = {
                ['tt-2'] = { box_info = {
                    id = 2,
                    synchro = { queue = { owner = 2 } },
                } },
            } }
        end,
    }
    local rebootstrapped = false
    split_brain.force_promote = function() return false, 'promote failed' end
    split_brain.rebootstrap_one = function()
        rebootstrapped = true; return true, 'ok'
    end
    local res = split_brain.resolve(
        { action = 'rebootstrap_losing', winner_alias = 'tt-1',
          losing_aliases = { 'tt-2' } }, {})
    t.assert_equals(res.ok, false)
    t.assert_equals(res.error, 'pre-rebootstrap promote failed')
    t.assert_equals(rebootstrapped, false)
end

-- ── force_promote_winner ─────────────────────────────────────────────

g.test_force_promote_winner_dispatches = function()
    local promoted
    split_brain.force_promote = function(winner)
        promoted = winner
        return true, 'promote dispatched on ' .. winner
    end
    local res = split_brain.resolve(
        { action = 'force_promote_winner', winner_alias = 'tt-1' }, {})
    t.assert_equals(promoted, 'tt-1')
    t.assert_equals(res.ok, true)
    t.assert_equals(res.action, 'force_promote_winner')
    t.assert_equals(res.results[1].peer, 'tt-1')
end

g.test_force_promote_winner_failure = function()
    split_brain.force_promote = function() return false, 'no quorum' end
    local res = split_brain.resolve(
        { action = 'force_promote_winner', winner_alias = 'tt-1' }, {})
    t.assert_equals(res.ok, false)
    t.assert_equals(res.results[1].ok, false)
end
