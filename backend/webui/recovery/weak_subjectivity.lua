--
-- Weak-subjectivity guard for a long-dead node rejoining (FO-18).
--
-- A node that was partitioned/stopped and accepted writes in isolation
-- comes back with a DIVERGENT TAIL — entries under its own replica id (or
-- an old term) that the current leader never confirmed. If it were
-- allowed in as a sync source it would either resurrect unconfirmed
-- writes or trip ER_SPLIT_BRAIN on the leader. The blockchain
-- "weak-subjectivity" idea applies: a trusted checkpoint
-- `{term, leader, confirmed_vclock}` is a revert-limit — below it we
-- never accept a node's history; we re-bootstrap it from the leader.
--
-- This module is PURE for the decision (`evaluate` / `find_leader_probe`)
-- so it is fully unit-testable; the impure `maintain` writes the etcd
-- checkpoint and returns the per-peer verdicts for the agent to act on.
--
-- Signals (Kafka KIP-903 stale-epoch / KIP-320 epoch-mismatch analog):
--   * diverged    — leader.vclock does NOT dominate peer.vclock, i.e.
--                   the peer holds entries the leader never confirmed.
--                   This is the hard signal: such a tail must not be
--                   pushed; the node re-bootstraps.
--   * stale_term  — peer's synchro term is below the leader's (it took
--                   part in an older term). Corroborating, not decisive
--                   on its own (a plainly-lagging follower is fine).
--
-- Action policy:
--   * allow       — not diverged (normal catch-up, or it IS the leader).
--   * rebootstrap — diverged, within the staleness window, and operator
--                   opted into auto-rejoin recovery.
--   * operator    — diverged but auto-rejoin is off, OR the staleness is
--                   beyond the window (term gap too large): never wipe a
--                   long-dead node automatically; require a human via the
--                   existing rebootstrapInstance flow.
--

local fencing = require('webui.failover.fencing')

local M = {}

M.KEY_CHECKPOINT = '/failover/checkpoint'

M.DEFAULTS = {
    -- Auto-rebootstrap a diverged rejoining node (default OFF — safest;
    -- a divergent tail is only wiped after an operator confirms).
    auto_rejoin_rebootstrap = false,
    -- Largest synchro-term gap still eligible for AUTO rebootstrap. A
    -- bigger gap (long-dead node) always routes to the operator.
    max_term_gap            = 1,
}

local function synchro_term(probe)
    local s = probe and probe.synchro and probe.synchro.queue
    return s and tonumber(s.term) or nil
end
M._synchro_term = synchro_term

-- The trusted leader probe in a replicaset map: the reachable, running,
-- read-write instance. nil when the replicaset has no confirmed leader
-- (we cannot anchor a checkpoint without one).
function M.find_leader_probe(probes)
    for alias, p in pairs(probes or {}) do
        if p ~= nil and p.reachable == true and p.status == 'running'
            and p.ro == false then
            return alias, p
        end
    end
    return nil
end

-- Pure decision for ONE peer against the current leader. See the module
-- header for the action policy. `args`:
--   { alias, peer, leader, leader_alias, opts = { auto_rejoin_rebootstrap,
--     max_term_gap } }
function M.evaluate(args)
    args = args or {}
    local peer = args.peer or {}
    local leader = args.leader
    local opts = args.opts or {}
    local max_gap = tonumber(opts.max_term_gap) or M.DEFAULTS.max_term_gap
    local auto = opts.auto_rejoin_rebootstrap == true

    -- Nothing to judge: the peer itself is the leader, is unreachable, or
    -- is not running (a down/booting node is handled elsewhere).
    if args.alias ~= nil and args.alias == args.leader_alias then
        return { needs_recovery = false, action = 'allow', reason = 'is leader' }
    end
    if peer.reachable ~= true or peer.status ~= 'running' then
        return { needs_recovery = false, action = 'allow',
            reason = 'not running' }
    end
    if type(leader) ~= 'table' or type(leader.vclock) ~= 'table' then
        return { needs_recovery = false, action = 'allow',
            reason = 'no leader vclock to compare' }
    end

    -- vclock excess: the leader does NOT dominate the peer's vclock, so
    -- the peer holds entries the confirmed history lacks. On its own this
    -- is NOT proof of divergence — a healthy read-only follower legitimately
    -- advances its OWN vclock component via local-only space writes
    -- (audit, etc.) the leader never replicates. The decisive signal is a
    -- TERM MISMATCH: every instance that took the current leader's promote
    -- converges to the same synchro term, so a peer holding extra entries
    -- under a DIFFERENT term is a partitioned tail (old-term leftover or a
    -- self-promoted split-brain), not benign local writes.
    local excess = not fencing.vclock_dominates(leader.vclock, peer.vclock)
    local lt = synchro_term(leader)
    local pt = synchro_term(peer)

    -- Can only confirm divergence when both terms are known and differ.
    if not excess or lt == nil or pt == nil or lt == pt then
        local why
        if not excess then
            why = 'in sync'
        elseif lt == nil or pt == nil then
            why = 'vclock excess but term unknown — cannot confirm divergence'
        else
            why = 'vclock excess at the same term (benign local writes)'
        end
        return {
            needs_recovery = false, action = 'allow',
            diverged = false, term_gap = (lt and pt) and (lt - pt) or 0,
            reason = why,
        }
    end

    local term_gap = lt - pt
    local peer_ahead = pt > lt          -- self-promoted to a higher term
    local beyond_window = peer_ahead or (term_gap > max_gap)
    local action
    if not auto or beyond_window then
        action = 'operator'
    else
        action = 'rebootstrap'
    end

    return {
        needs_recovery = true,
        diverged = true,
        stale_term = term_gap > 0,
        term_gap = term_gap,
        beyond_window = beyond_window,
        action = action,
        reason = string.format(
            'divergent tail vs leader %s (peer term %d, leader term %d%s); %s',
            tostring(args.leader_alias or '?'), pt, lt,
            beyond_window and ', beyond auto window' or '',
            action == 'rebootstrap' and 'auto re-bootstrap'
                or 'operator confirmation required'),
    }
end

-- Impure: write the trusted checkpoint for `rs_name` from the leader
-- probe, then evaluate every other peer. Returns
--   (checkpoint_written_bool, verdicts) where verdicts is a list of
--   { alias, action, reason, term_gap } for peers that NEED recovery.
-- Best-effort: a checkpoint write failure does not stop the scan.
function M.maintain(client, rs_name, probes, opts)
    opts = opts or {}
    local leader_alias, leader = M.find_leader_probe(probes)
    local verdicts = {}
    if leader == nil then
        return false, verdicts  -- no confirmed leader; cannot anchor.
    end

    local checkpoint_written = false
    if client ~= nil then
        local json = require('json')
        local fiber = require('fiber')
        local key = string.format(M.KEY_CHECKPOINT .. '/%s', rs_name)
        local payload = json.encode({
            term = synchro_term(leader),
            leader = leader_alias,
            confirmed_vclock = leader.vclock,
            ts = fiber.time(),
        })
        local _, perr = client:put(key, payload)
        checkpoint_written = (perr == nil)
    end

    for alias, peer in pairs(probes or {}) do
        if alias ~= leader_alias then
            local verdict = M.evaluate({
                alias = alias, peer = peer,
                leader = leader, leader_alias = leader_alias,
                opts = opts,
            })
            if verdict.needs_recovery then
                verdicts[#verdicts + 1] = {
                    alias = alias, action = verdict.action,
                    reason = verdict.reason, term_gap = verdict.term_gap,
                }
            end
        end
    end
    return checkpoint_written, verdicts
end

return M
