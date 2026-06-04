local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local takeover   = require('webui.recovery.leader_takeover')
local orphan     = require('webui.recovery.orphan')
local quorum     = require('webui.recovery.quorum_loss')
local topology   = require('webui.recovery.topology_fix')
local splitbrain = require('webui.recovery.split_brain')
local wal        = require('webui.recovery.wal_repair')

local g = t.group('recovery.assess.modules')

local function peer(o)
    local base = {
        alias = 'tt-1', reachable = true, role = 'follower',
        current_term = 5, queue_owner = false, queue_busy = false,
        vclock = { [1] = 10 },
    }
    for k, v in pairs(o or {}) do base[k] = v end
    return base
end

-- ── leader_takeover ──────────────────────────────────────────────────

g.test_takeover_dominating_candidate_is_safe = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, queue_owner_id = 1,
               vclock = { [1] = 10 } }),
        peer({ alias = 'tt-2', vclock = { [1] = 10 } }),
    } }
    local a = takeover.assess({ target_alias = 'tt-2' }, nil, snap)
    t.assert_equals(a.risk, 'caution')
    t.assert_equals(a.autoSafe, true)
    t.assert_equals(a.dataLoss, false)
end

g.test_takeover_lagging_candidate_is_dangerous = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, queue_owner_id = 1,
               vclock = { [1] = 10 } }),
        peer({ alias = 'tt-2', vclock = { [1] = 9 } }),
    } }
    local a = takeover.assess({ target_alias = 'tt-2' }, nil, snap)
    t.assert_equals(a.risk, 'dangerous')
    t.assert_equals(a.dataLoss, true)
    t.assert_equals(a.confirm.required, true)
    t.assert_equals(a.confirm.token, 'TAKEOVER tt-2')
end

g.test_takeover_no_owner_must_dominate_all = function()
    -- No owner: tt-2 lags tt-3 -> dangerous.
    local snap = { peers = {
        peer({ alias = 'tt-2', vclock = { [1] = 9 } }),
        peer({ alias = 'tt-3', vclock = { [1] = 12 } }),
    } }
    local a = takeover.assess({ target_alias = 'tt-2' }, nil, snap)
    t.assert_equals(a.risk, 'dangerous')
end

g.test_takeover_queue_busy_precondition = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, queue_owner_id = 1,
               queue_busy = true, vclock = { [1] = 10 } }),
        peer({ alias = 'tt-2', vclock = { [1] = 10 } }),
    } }
    local a = takeover.assess({ target_alias = 'tt-2' }, nil, snap)
    local busy_pc
    for _, pc in ipairs(a.preconditions) do
        if pc.label == 'Synchro queue not busy' then busy_pc = pc end
    end
    t.assert_not_equals(busy_pc, nil)
    t.assert_equals(busy_pc.ok, false)
end

-- ── orphan ───────────────────────────────────────────────────────────

g.test_orphan_force_reconnect_is_safe = function()
    local a = orphan.assess({ action = 'force_reconnect', target_alias = 'tt-2' },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'safe')
    t.assert_equals(a.confirm.required, false)
end

g.test_orphan_rebootstrap_is_dangerous = function()
    local a = orphan.assess({ action = 'rebootstrap', target_alias = 'tt-2' },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'dangerous')
    t.assert_equals(a.dataLoss, true)
    t.assert_equals(a.confirm.token, 'ORPHAN tt-2')
end

g.test_orphan_solo_promote_is_dangerous = function()
    local a = orphan.assess({ action = 'solo_promote', target_alias = 'tt-2' },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'dangerous')
end

-- ── rebootstrap safety preconditions (quorum / owner / reachable) ────

-- Pick a precondition's ok flag by a substring of its label.
local function precond_ok(list, needle)
    for _, pc in ipairs(list) do
        if pc.label:find(needle, 1, true) then return pc.ok end
    end
    return nil
end

g.test_rebootstrap_preconditions_all_pass_with_healthy_trio = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, reachable = true }),
        peer({ alias = 'tt-2', reachable = true }),
        peer({ alias = 'tt-3', reachable = true }),
    } }
    local pc = orphan._rebootstrap_preconditions(snap, 'tt-3')
    t.assert_equals(precond_ok(pc, 'queue owner'), true)
    t.assert_equals(precond_ok(pc, 'reachable over iproto'), true)
    t.assert_equals(precond_ok(pc, 'synchro quorum after expel'), true)
end

g.test_rebootstrap_quorum_fails_when_a_peer_is_down = function()
    -- target tt-3; tt-2 already down → after expel only tt-1 reachable,
    -- quorum 2 not met.
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, reachable = true }),
        peer({ alias = 'tt-2', reachable = false }),
        peer({ alias = 'tt-3', reachable = true }),
    } }
    local pc = orphan._rebootstrap_preconditions(snap, 'tt-3')
    t.assert_equals(precond_ok(pc, 'synchro quorum after expel'), false)
end

g.test_rebootstrap_rejects_queue_owner_target = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, reachable = true }),
        peer({ alias = 'tt-2', reachable = true }),
        peer({ alias = 'tt-3', reachable = true }),
    } }
    local pc = orphan._rebootstrap_preconditions(snap, 'tt-1')
    t.assert_equals(precond_ok(pc, 'queue owner'), false)
end

g.test_rebootstrap_rejects_unreachable_target = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', queue_owner = true, reachable = true }),
        peer({ alias = 'tt-2', reachable = true }),
        peer({ alias = 'tt-3', reachable = false }),
    } }
    local pc = orphan._rebootstrap_preconditions(snap, 'tt-3')
    t.assert_equals(precond_ok(pc, 'reachable over iproto'), false)
end

-- ── quorum_loss ──────────────────────────────────────────────────────

g.test_quorum_is_dangerous_with_failsafe_precondition_ok = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', reachable = true }),
        peer({ alias = 'tt-2', reachable = true }),
    } }
    local a = quorum.assess({ target_alias = 'tt-1' }, nil, snap)
    t.assert_equals(a.risk, 'dangerous')
    local pc
    for _, p in ipairs(a.preconditions) do
        if p.label:find('All peers reachable') then pc = p end
    end
    t.assert_equals(pc.ok, true)
end

g.test_quorum_precondition_fails_on_unreachable_peer = function()
    local snap = { peers = {
        peer({ alias = 'tt-1', reachable = true }),
        peer({ alias = 'tt-2', reachable = false }),
    } }
    local a = quorum.assess({ target_alias = 'tt-1' }, nil, snap)
    local pc
    for _, p in ipairs(a.preconditions) do
        if p.label:find('All peers reachable') then pc = p end
    end
    t.assert_equals(pc.ok, false)
end

-- ── topology_fix ─────────────────────────────────────────────────────

g.test_topology_fix_is_caution = function()
    local a = topology.assess({ fixes = { ['tt-2'] = 'host:3302' } },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'caution')
    t.assert_equals(a.autoSafe, true)
    t.assert_equals(a.dataLoss, false)
end

-- ── split_brain ──────────────────────────────────────────────────────

g.test_split_brain_manual_is_safe = function()
    local a = splitbrain.assess({ action = 'manual', winner_alias = 'tt-1' },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'safe')
end

g.test_split_brain_rebootstrap_losing_is_dangerous = function()
    local a = splitbrain.assess(
        { action = 'rebootstrap_losing', winner_alias = 'tt-1',
          losing_aliases = { 'tt-2' } }, nil, { peers = {} })
    t.assert_equals(a.risk, 'dangerous')
    t.assert_equals(a.confirm.token, 'SPLIT BRAIN tt-1')
end

g.test_split_brain_force_promote_is_dangerous = function()
    local a = splitbrain.assess(
        { action = 'force_promote_winner', winner_alias = 'tt-1' },
        nil, { peers = {} })
    t.assert_equals(a.risk, 'dangerous')
    t.assert_equals(a.dataLoss, true)
end

-- ── wal_repair ───────────────────────────────────────────────────────

g.test_wal_unknown_file_is_dangerous = function()
    -- No matching xlog in the local wal_dir -> not tail -> dangerous,
    -- and the "file present" precondition fails.
    local a = wal.assess({ file = 'nope.xlog' })
    t.assert_equals(a.risk, 'dangerous')
    local pc
    for _, p in ipairs(a.preconditions) do
        if p.label:find('File present') then pc = p end
    end
    t.assert_equals(pc.ok, false)
end
