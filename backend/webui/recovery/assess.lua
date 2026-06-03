--
-- Recovery risk-assessment contract (Task RC-0).
--
-- A single place that defines the `Assessment` shape every recovery
-- action computes from live cluster state, plus the shared predicates
-- the per-module `assess()` functions lean on.
--
-- The risk class is a function of (action, payload, live_state), not of
-- the action type alone: the same leader_takeover is `safe` when the
-- candidate's vclock dominates the queue owner and `dangerous` when it
-- lags. Three classes:
--
--   * safe       — no risk of losing CONFIRMED data; UI: summary + Apply.
--   * caution    — mutates control-plane/config (reload/restart) but no
--                  confirmed-data loss; UI: summary + Apply.
--   * dangerous  — confirmed data could be lost at the current state;
--                  UI: warning banner + acknowledge + typed token.
--
-- This module is PURE: it never touches box / net.box. The live per-peer
-- view is passed in by the caller (the snapshot built by
-- `webui.recovery.snapshot`). That keeps it unit-testable and avoids a
-- second cluster RPC sweep — the assessment reads the same data the
-- diagnosis already fetched.
--
-- Lua simple/reliable rules: plain control flow, locals everywhere, no
-- metatables, defensive nil handling, no exceptions.
--

local digest   = require('digest')
local fencing  = require('webui.failover.fencing')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.assess')

local M = {}

-- Risk classes.
M.SAFE      = 'safe'
M.CAUTION   = 'caution'
M.DANGEROUS = 'dangerous'

-- ── Shared predicates ────────────────────────────────────────────────

-- Does the candidate vclock dominate the owner's? Thin wrapper over the
-- failover fencing predicate so all of recovery shares one definition.
function M.dominates(candidate_vclock, owner_vclock)
    return fencing.vclock_dominates(candidate_vclock, owner_vclock)
end

-- Is this classified peer entry reachable?
function M.is_reachable(peer)
    return type(peer) == 'table' and peer.reachable == true
end

-- Does this classified peer currently own the synchro queue?
function M.is_queue_owner(peer)
    return type(peer) == 'table' and peer.queue_owner == true
end

-- Has `peer` diverged from `leader`? A peer is diverged when it already
-- carries the split-brain role, OR it sits on a DIFFERENT synchro term
-- than the leader AND does not dominate the leader's vclock (a pure
-- vclock gap at the SAME term is just normal replication lag, not a
-- fork — mirrors the weak-subjectivity guard).
function M.is_diverged(peer, leader)
    if type(peer) ~= 'table' then return false end
    if peer.role == 'split-brain' then return true end
    if type(leader) ~= 'table' then return false end
    local pt = tonumber(peer.current_term)
    local lt = tonumber(leader.current_term)
    if pt == nil or lt == nil or pt == lt then
        return false
    end
    return not M.dominates(peer.vclock, leader.vclock)
end

-- Canonical, stable string for a single peer's risk-relevant fields.
local function vclock_str(vclock)
    if type(vclock) ~= 'table' then return '-' end
    local ids = {}
    for id in pairs(vclock) do ids[#ids + 1] = tonumber(id) or id end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, id in ipairs(ids) do
        parts[#parts + 1] = tostring(id) .. '=' .. tostring(vclock[id])
    end
    return table.concat(parts, ',')
end

-- Build the decision fingerprint: a deterministic hash over ONLY the
-- risk-relevant state (queue-owner id + per-target vclock/term/role/
-- reachable). The fast-moving poller `generation` is deliberately NOT
-- used — it ticks every second and would reject almost every operator
-- confirmation. The fingerprint changes only when something that
-- changes the verdict changes. (Task RC-2 re-checks it before mutating.)
--
-- `snapshot` is the table returned by snapshot.build(); `targets` is the
-- list of aliases the action operates on.
function M.fingerprint(snapshot, targets)
    local peers = (type(snapshot) == 'table' and snapshot.peers) or {}
    local by_alias, owner_id = {}, 0
    for _, p in ipairs(peers) do
        if type(p) == 'table' and p.alias ~= nil then
            by_alias[p.alias] = p
            if p.queue_owner == true and p.queue_owner_id ~= nil then
                owner_id = p.queue_owner_id
            end
        end
    end
    local aliases = {}
    for _, alias in ipairs(targets or {}) do
        aliases[#aliases + 1] = tostring(alias)
    end
    table.sort(aliases)
    local parts = { 'owner=' .. tostring(owner_id) }
    for _, alias in ipairs(aliases) do
        local p = by_alias[alias]
        if type(p) == 'table' then
            parts[#parts + 1] = alias
                .. ':term=' .. tostring(p.current_term)
                .. ':role=' .. tostring(p.role)
                .. ':reach=' .. tostring(p.reachable == true)
                .. ':vclock=' .. vclock_str(p.vclock)
        else
            parts[#parts + 1] = alias .. ':absent'
        end
    end
    return digest.sha256_hex(table.concat(parts, '|'))
end

-- Index the snapshot's peer array by alias and find the queue owner.
-- Returns { peers, by_alias, owner } where `owner` is the owning peer
-- entry or nil.
function M.index_peers(snapshot)
    local peers = (type(snapshot) == 'table' and snapshot.peers) or {}
    local by_alias, owner = {}, nil
    for _, p in ipairs(peers) do
        if type(p) == 'table' and p.alias ~= nil then
            by_alias[p.alias] = p
            if p.queue_owner == true then owner = p end
        end
    end
    return { peers = peers, by_alias = by_alias, owner = owner }
end

-- Is a PROMOTE/CONFIRM/ROLLBACK in flight on any reachable peer? Acting
-- while the synchro queue is busy races the in-flight system request, so
-- the assessment marks a precondition for it.
function M.any_queue_busy(snapshot)
    for _, p in ipairs((type(snapshot) == 'table' and snapshot.peers) or {}) do
        if type(p) == 'table' and p.queue_busy == true then return true end
    end
    return false
end

-- The three universal preconditions every DANGEROUS data-plane action
-- must satisfy (invariant 11). These are declarative requirements; the
-- enforcement gate (Task RC-2) recomputes the live `ok` for the pause
-- check and the action records pre-state on apply. Returned as plain
-- precondition tables ready to splice into an assessment.
function M.universal_preconditions()
    return {
        { ok = false, label = 'Failover paused',
          detail = 'Pause the failover agent (pauseFailover) so automation '
              .. 'cannot re-promote or fight the manual action; this also '
              .. 'suspends the watchdog and DCS-loss self-demote.' },
        { ok = false, label = 'Snapshot / backup taken before any wipe',
          detail = 'box.snapshot() (and a byte copy of the WAL files for '
              .. 'wal repair) before any data-erasing step.' },
        { ok = true,  label = 'Pre-state recorded',
          detail = 'vclock / term / box.info.synchro of the targets are '
              .. 'written to the audit log on apply.' },
    }
end

-- ── Assessment builder ───────────────────────────────────────────────
--
-- Closure-based builder (no metatables). Every mutator returns the
-- builder for fluent chaining; `build(fingerprint)` finalizes and
-- returns the plain Assessment table.

function M.new(action)
    local a = {
        action         = tostring(action or ''),
        risk           = M.SAFE,
        dataLoss       = false,
        summary        = '',
        effects        = {},
        preconditions  = {},
        warnings       = {},
        manualRecovery = {},
        failureCommands = {},
        confirm        = { required = false, token = nil, acknowledge = nil },
        docs           = nil,
    }
    local self = {}

    function self.risk(level)
        if level == M.SAFE or level == M.CAUTION or level == M.DANGEROUS then
            a.risk = level
        end
        return self
    end

    function self.data_loss(v)
        a.dataLoss = v == true
        return self
    end

    function self.summary(s)
        a.summary = tostring(s or '')
        return self
    end

    function self.effect(s)
        a.effects[#a.effects + 1] = tostring(s)
        return self
    end

    function self.warning(s)
        a.warnings[#a.warnings + 1] = tostring(s)
        return self
    end

    function self.manual(s)
        a.manualRecovery[#a.manualRecovery + 1] = tostring(s)
        return self
    end

    function self.failure_cmd(title, command, note)
        a.failureCommands[#a.failureCommands + 1] = {
            title   = tostring(title or ''),
            command = tostring(command or ''),
            note    = note and tostring(note) or nil,
        }
        return self
    end

    function self.precondition(ok, label, detail)
        a.preconditions[#a.preconditions + 1] = {
            ok     = ok == true,
            label  = tostring(label or ''),
            detail = detail and tostring(detail) or nil,
        }
        return self
    end

    function self.confirm(token, acknowledge)
        a.confirm.token = token and tostring(token) or nil
        a.confirm.acknowledge = acknowledge and tostring(acknowledge) or nil
        return self
    end

    function self.with_docs(anchor)
        a.docs = anchor and tostring(anchor) or nil
        return self
    end

    -- Finalize: derive autoSafe / confirm.required from the risk class
    -- and attach the fingerprint. Returns the plain Assessment table.
    function self.build(fingerprint)
        a.autoSafe = a.risk ~= M.DANGEROUS
        a.confirm.required = a.risk == M.DANGEROUS
        a.fingerprint = fingerprint and tostring(fingerprint) or ''
        logger.debug('assessment built', {
            action = a.action, risk = a.risk, data_loss = a.dataLoss,
        })
        return a
    end

    return self
end

return M
