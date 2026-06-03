-- Unit tests for the weak-subjectivity rejoin detector (Task FO-18).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('weak_subjectivity')

local ws = require('webui.recovery.weak_subjectivity')

local function probe(opts)
    opts = opts or {}
    return {
        reachable = opts.reachable ~= false,
        status = opts.status or 'running',
        ro = opts.ro,
        vclock = opts.vclock,
        synchro = opts.term and { queue = { term = opts.term } } or nil,
    }
end

-- ── find_leader_probe ───────────────────────────────────────────────

g.test_find_leader_probe_picks_rw_running = function()
    local probes = {
        ['tt-1'] = probe({ ro = true, vclock = { [1] = 10 } }),
        ['tt-2'] = probe({ ro = false, vclock = { [1] = 12 } }),
    }
    local alias = ws.find_leader_probe(probes)
    t.assert_equals(alias, 'tt-2')
end

g.test_find_leader_probe_nil_when_leaderless = function()
    local probes = {
        ['tt-1'] = probe({ ro = true }), ['tt-2'] = probe({ ro = true }),
    }
    t.assert_equals(ws.find_leader_probe(probes), nil)
end

-- ── evaluate ────────────────────────────────────────────────────────

local function leader(vclock, term)
    return { vclock = vclock, synchro = term and { queue = { term = term } } }
end

g.test_in_sync_follower_allowed = function()
    -- follower behind the leader → leader dominates → not diverged.
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ vclock = { [1] = 8 }, term = 3 }),
        leader = leader({ [1] = 12 }, 3),
        leader_alias = 'tt-1',
    })
    t.assert_equals(v.needs_recovery, false)
    t.assert_equals(v.action, 'allow')
end

g.test_behind_in_term_but_no_divergence_allowed = function()
    -- older term but vclock still dominated (no excess entries) → normal
    -- catch-up, allow. Term lag alone never triggers recovery.
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ vclock = { [1] = 5 }, term = 2 }),
        leader = leader({ [1] = 12 }, 4),
        leader_alias = 'tt-1',
    })
    t.assert_equals(v.needs_recovery, false)
    t.assert_equals(v.action, 'allow')
end

g.test_vclock_excess_at_same_term_is_benign = function()
    -- healthy follower with local-write vclock excess but the SAME term →
    -- not divergence (this is the live false-positive case FO-18 must not
    -- flag).
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ vclock = { [1] = 10, [2] = 7 }, term = 3 }),
        leader = leader({ [1] = 12 }, 3),  -- SAME term
        leader_alias = 'tt-1',
        opts = {},
    })
    t.assert_equals(v.needs_recovery, false)
    t.assert_equals(v.action, 'allow')
    t.assert_str_contains(v.reason, 'local writes')
end

g.test_vclock_excess_unknown_term_not_flagged = function()
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ vclock = { [1] = 10, [2] = 7 } }),  -- no term
        leader = leader({ [1] = 12 }),                      -- no term
        leader_alias = 'tt-1',
    })
    t.assert_equals(v.needs_recovery, false)
    t.assert_str_contains(v.reason, 'cannot confirm')
end

g.test_divergent_tail_old_term_default_routes_to_operator = function()
    -- vclock excess AND an OLDER term → real divergent tail.
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ vclock = { [1] = 10, [2] = 7 }, term = 2 }),
        leader = leader({ [1] = 12 }, 3),
        leader_alias = 'tt-1',
        opts = {},  -- auto off by default
    })
    t.assert_equals(v.needs_recovery, true)
    t.assert_equals(v.diverged, true)
    t.assert_equals(v.action, 'operator')
    t.assert_str_contains(v.reason, 'divergent tail')
end

g.test_divergent_within_window_auto_rebootstraps = function()
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ vclock = { [1] = 10, [2] = 7 }, term = 2 }),
        leader = leader({ [1] = 12 }, 3),  -- term gap 1
        leader_alias = 'tt-1',
        opts = { auto_rejoin_rebootstrap = true, max_term_gap = 1 },
    })
    t.assert_equals(v.needs_recovery, true)
    t.assert_equals(v.action, 'rebootstrap')
end

g.test_self_promoted_higher_term_routes_to_operator = function()
    -- peer ahead in term (self-promoted while partitioned) → always operator.
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ vclock = { [1] = 10, [2] = 7 }, term = 5 }),
        leader = leader({ [1] = 12 }, 3),
        leader_alias = 'tt-1',
        opts = { auto_rejoin_rebootstrap = true, max_term_gap = 5 },
    })
    t.assert_equals(v.needs_recovery, true)
    t.assert_equals(v.beyond_window, true)
    t.assert_equals(v.action, 'operator')
end

g.test_divergent_beyond_window_routes_to_operator_even_with_auto = function()
    -- term gap 5 > max_term_gap 1 → operator despite auto on.
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ vclock = { [1] = 10, [2] = 7 }, term = 1 }),
        leader = leader({ [1] = 12 }, 6),
        leader_alias = 'tt-1',
        opts = { auto_rejoin_rebootstrap = true, max_term_gap = 1 },
    })
    t.assert_equals(v.needs_recovery, true)
    t.assert_equals(v.beyond_window, true)
    t.assert_equals(v.action, 'operator')
end

g.test_leader_itself_allowed = function()
    local v = ws.evaluate({
        alias = 'tt-1', leader_alias = 'tt-1',
        peer = probe({ ro = false, vclock = { [1] = 12 } }),
        leader = leader({ [1] = 12 }, 3),
    })
    t.assert_equals(v.needs_recovery, false)
end

g.test_unreachable_peer_allowed = function()
    local v = ws.evaluate({
        alias = 'tt-2',
        peer = probe({ reachable = false }),
        leader = leader({ [1] = 12 }, 3),
        leader_alias = 'tt-1',
    })
    t.assert_equals(v.needs_recovery, false)
    t.assert_str_contains(v.reason, 'not running')
end

g.test_maintain_collects_only_recovery_verdicts = function()
    -- no etcd client (nil) → checkpoint skipped, scan still runs.
    local probes = {
        ['tt-1'] = probe({ ro = false, vclock = { [1] = 12 }, term = 3 }),
        ['tt-2'] = probe({ vclock = { [1] = 8, [2] = 99 }, term = 3 }), -- same term: benign local writes
        ['tt-3'] = probe({ vclock = { [1] = 9, [3] = 4 }, term = 2 }),  -- OLD term + excess: diverged
    }
    local written, verdicts = ws.maintain(nil, 'rs-1', probes, {})
    t.assert_equals(written, false)
    t.assert_equals(#verdicts, 1)
    t.assert_equals(verdicts[1].alias, 'tt-3')
    t.assert_equals(verdicts[1].action, 'operator')
end
