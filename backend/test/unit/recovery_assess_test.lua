local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local assess = require('webui.recovery.assess')

local g = t.group('recovery.assess')

-- ── Builder shape & finalize logic ───────────────────────────────────

g.test_safe_builder_is_auto_safe = function()
    local a = assess.new('restart_replication')
        .risk(assess.SAFE)
        .summary('reconnect replication')
        .effect('re-applies replication config')
        .build('fp-1')
    t.assert_equals(a.action, 'restart_replication')
    t.assert_equals(a.risk, 'safe')
    t.assert_equals(a.dataLoss, false)
    t.assert_equals(a.autoSafe, true)
    t.assert_equals(a.confirm.required, false)
    t.assert_equals(a.fingerprint, 'fp-1')
    t.assert_equals(a.effects, { 're-applies replication config' })
end

g.test_dangerous_builder_requires_confirm = function()
    local a = assess.new('quorum_loss_escape')
        .risk(assess.DANGEROUS)
        .data_loss(true)
        .warning('a partition during the window can fork the WAL')
        .manual('restore the real quorum instead of lowering it')
        .failure_cmd('restore quorum', 'box.cfg{ replication_synchro_quorum = 2 }')
        .precondition(false, 'all peers reachable', 'tt-3 is unreachable')
        .confirm('QUORUM tt-1', 'I accept the split-brain risk')
        .with_docs('runbooks/recovery-overview.md')
        .build('fp-2')
    t.assert_equals(a.risk, 'dangerous')
    t.assert_equals(a.dataLoss, true)
    t.assert_equals(a.autoSafe, false)
    t.assert_equals(a.confirm.required, true)
    t.assert_equals(a.confirm.token, 'QUORUM tt-1')
    t.assert_equals(a.confirm.acknowledge, 'I accept the split-brain risk')
    t.assert_equals(#a.warnings, 1)
    t.assert_equals(#a.manualRecovery, 1)
    t.assert_equals(a.failureCommands[1].command,
        'box.cfg{ replication_synchro_quorum = 2 }')
    t.assert_equals(a.preconditions[1].ok, false)
    t.assert_equals(a.preconditions[1].detail, 'tt-3 is unreachable')
    t.assert_equals(a.docs, 'runbooks/recovery-overview.md')
end

g.test_caution_is_auto_safe_without_token = function()
    local a = assess.new('topology_fix').risk(assess.CAUTION).build('fp')
    t.assert_equals(a.autoSafe, true)
    t.assert_equals(a.confirm.required, false)
end

g.test_invalid_risk_is_ignored = function()
    local a = assess.new('x').risk('bogus').build('fp')
    t.assert_equals(a.risk, 'safe')
end

-- ── Predicates ───────────────────────────────────────────────────────

g.test_dominates_wraps_fencing = function()
    t.assert_equals(assess.dominates({ [1] = 10, [2] = 5 }, { [1] = 10 }), true)
    t.assert_equals(assess.dominates({ [1] = 9 }, { [1] = 10 }), false)
end

g.test_is_queue_owner_and_reachable = function()
    t.assert_equals(assess.is_queue_owner({ queue_owner = true }), true)
    t.assert_equals(assess.is_queue_owner({ queue_owner = false }), false)
    t.assert_equals(assess.is_reachable({ reachable = true }), true)
    t.assert_equals(assess.is_reachable({ reachable = false }), false)
    t.assert_equals(assess.is_reachable(nil), false)
end

g.test_is_diverged_split_brain_role = function()
    t.assert_equals(assess.is_diverged({ role = 'split-brain' }, {}), true)
end

g.test_is_diverged_same_term_is_not_divergence = function()
    -- Same synchro term + a vclock gap = ordinary replication lag.
    local peer = { current_term = 5, vclock = { [1] = 5 } }
    local leader = { current_term = 5, vclock = { [1] = 10 } }
    t.assert_equals(assess.is_diverged(peer, leader), false)
end

g.test_is_diverged_different_term_without_dominance = function()
    local peer = { current_term = 4, vclock = { [1] = 5 } }
    local leader = { current_term = 5, vclock = { [1] = 10 } }
    t.assert_equals(assess.is_diverged(peer, leader), true)
end

-- ── Fingerprint ──────────────────────────────────────────────────────

local function snapshot()
    return {
        generation = 7,
        peers = {
            { alias = 'tt-1', queue_owner = true, queue_owner_id = 1,
              current_term = 5, role = 'queue-owner', reachable = true,
              vclock = { [1] = 10 } },
            { alias = 'tt-2', queue_owner = false,
              current_term = 5, role = 'follower', reachable = true,
              vclock = { [1] = 10 } },
        },
    }
end

g.test_fingerprint_is_deterministic = function()
    local a = assess.fingerprint(snapshot(), { 'tt-2', 'tt-1' })
    local b = assess.fingerprint(snapshot(), { 'tt-1', 'tt-2' })
    t.assert_equals(a, b)  -- target order must not matter
    t.assert_equals(type(a), 'string')
end

g.test_fingerprint_changes_on_relevant_state = function()
    local base = assess.fingerprint(snapshot(), { 'tt-2' })
    local moved = snapshot()
    moved.peers[2].current_term = 6  -- risk-relevant change
    t.assert_not_equals(assess.fingerprint(moved, { 'tt-2' }), base)
end

g.test_fingerprint_ignores_poller_generation = function()
    local base = assess.fingerprint(snapshot(), { 'tt-1' })
    local ticked = snapshot()
    ticked.generation = 999  -- fast-moving poller counter, not risk-relevant
    t.assert_equals(assess.fingerprint(ticked, { 'tt-1' }), base)
end
