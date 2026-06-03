local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local assess   = require('webui.recovery.assess')
local preflight = require('webui.recovery.preflight')

local g = t.group('recovery.preflight')

local function dangerous(fp)
    return assess.new('leader_takeover')
        .risk(assess.DANGEROUS).data_loss(true)
        .confirm('TAKEOVER tt-2', 'I accept')
        .build(fp or 'fp-1')
end

-- ── Gate: enforcement decision ───────────────────────────────────────

g.test_safe_action_always_allowed = function()
    local a = assess.new('restart_replication').risk(assess.SAFE).build('fp')
    t.assert_equals(assess.gate(a, { fingerprint = 'fp' }).allow, true)
end

g.test_dangerous_without_fingerprint_is_legacy_allowed = function()
    local r = assess.gate(dangerous('fp'), {})  -- no fingerprint = legacy UI
    t.assert_equals(r.allow, true)
    t.assert_equals(r.legacy, true)
end

g.test_dangerous_stale_fingerprint_refused = function()
    local r = assess.gate(dangerous('fp-new'), { fingerprint = 'fp-old',
        acknowledge = true, confirmToken = 'TAKEOVER tt-2' })
    t.assert_equals(r.allow, false)
    t.assert_equals(r.code, 'STALE_FINGERPRINT')
end

g.test_dangerous_missing_ack_refused = function()
    local r = assess.gate(dangerous('fp'), { fingerprint = 'fp',
        confirmToken = 'TAKEOVER tt-2' })  -- acknowledge omitted
    t.assert_equals(r.code, 'CONFIRMATION_REQUIRED')
end

g.test_dangerous_wrong_token_refused = function()
    local r = assess.gate(dangerous('fp'), { fingerprint = 'fp',
        acknowledge = true, confirmToken = 'WRONG' })
    t.assert_equals(r.code, 'CONFIRMATION_REQUIRED')
end

g.test_dangerous_precondition_failed = function()
    local r = assess.gate(dangerous('fp'), { fingerprint = 'fp',
        acknowledge = true, confirmToken = 'TAKEOVER tt-2' }, false)
    t.assert_equals(r.code, 'PRECONDITION_FAILED')
end

g.test_dangerous_all_satisfied_allowed = function()
    local r = assess.gate(dangerous('fp'), { fingerprint = 'fp',
        acknowledge = true, confirmToken = 'TAKEOVER tt-2' }, true)
    t.assert_equals(r.allow, true)
end

g.test_precondition_unknown_does_not_block = function()
    -- nil preconditions_ok (etcd unreachable) must not block.
    local r = assess.gate(dangerous('fp'), { fingerprint = 'fp',
        acknowledge = true, confirmToken = 'TAKEOVER tt-2' }, nil)
    t.assert_equals(r.allow, true)
end

-- ── Dispatch classification ──────────────────────────────────────────

g.test_mutating_and_diagnose_classification = function()
    t.assert_equals(preflight.is_mutating('leader_takeover'), true)
    t.assert_equals(preflight.is_mutating('wal_quarantine'), true)
    t.assert_equals(preflight.is_mutating('split_brain_resolve'), true)
    t.assert_equals(preflight.is_mutating('wal_diagnose'), false)
    t.assert_equals(preflight.is_diagnose('wal_diagnose'), true)
    t.assert_equals(preflight.is_diagnose('topology_fix_diagnose'), true)
    t.assert_equals(preflight.is_diagnose('leader_takeover'), false)
end

-- ── Idempotency ──────────────────────────────────────────────────────

g.before_each(function() preflight._reset_idem() end)

g.test_idempotent_replays_stored_result = function()
    local calls = 0
    local function run()
        calls = calls + 1
        return { ok = true, n = calls }
    end
    local first = preflight.idempotent('k1', 100, run)
    local second = preflight.idempotent('k1', 101, run)
    t.assert_equals(calls, 1)              -- ran once
    t.assert_equals(second.n, first.n)     -- same stored result
end

g.test_idempotent_no_key_runs_every_time = function()
    local calls = 0
    local function run() calls = calls + 1; return calls end
    preflight.idempotent(nil, 100, run)
    preflight.idempotent('', 100, run)
    t.assert_equals(calls, 2)
end

g.test_idempotent_expires_after_ttl = function()
    local calls = 0
    local function run() calls = calls + 1; return calls end
    preflight.idempotent('k2', 100, run)
    preflight.idempotent('k2', 100 + 601, run)  -- past TTL → re-runs
    t.assert_equals(calls, 2)
end
