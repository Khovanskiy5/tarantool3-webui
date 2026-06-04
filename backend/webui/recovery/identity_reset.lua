--
-- Clean rebootstrap via identity reset (expel + re-add).
--
-- A broken follower in a full-mesh replicaset cannot be repaired by a
-- plain file wipe: reusing its `_cluster` id makes peers reject its
-- rewound WAL with "invalid xlog order" (peers track relay position by
-- id, not uuid), so they can never replicate FROM it again. The only
-- clean fix is to give it a BRAND-NEW id, which means expelling the old
-- `_cluster` row — and that wedges the instance name unless the old
-- holder is fully disconnected first (box.cc: ER_INSTANCE_NAME_DUPLICATE
-- when `replica_has_connections`).
--
-- This module holds the leader-side primitives used by the orchestrator
-- (M.run, added alongside): they run ON the RW leader (the orchestrator
-- forwards itself there, so the leader is never the wiped target) and
-- operate on the local `box`:
--
--   * snapshot_master()       — fold the `_cluster` DELETE into a
--     checkpoint so it is not relayed during the rejoin JOIN (#4107).
--   * wait_peer_disconnected() — bounded poll until the target holds no
--     incoming/outgoing replication connection, so the expel does not
--     orphan a relay and the name frees on rejoin.
--   * expel_cluster_row()     — guarded `_cluster:delete` of the old id.
--
-- The pure helpers (`_find_cluster_row`, `_is_disconnected`) carry the
-- decision logic so they can be unit-tested without a live box.
--

local fiber    = require('fiber')
local yaml_patch = require('webui.config_store.yaml_patch')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.identity_reset')

local M = {}

-- Default bounded-wait budget for the target to drop its connections.
M.DISCONNECT_TIMEOUT = 10      -- seconds
M.WIPE_SETTLE        = 3       -- seconds to let the wiped process exit
M.POLL_STEP          = 0.5     -- seconds
M.SNAPSHOT_TIMEOUT   = 60      -- seconds (box.snapshot can be slow)
M.NAME_FREE_TIMEOUT  = 15      -- seconds to wait for the old name to free
M.REJOIN_TIMEOUT     = 60      -- seconds to wait for the fresh JOIN
M.WIPE_RPC_TIMEOUT   = 15      -- seconds
M.RELOAD_RPC_TIMEOUT = 15      -- seconds
M.FORWARD_TIMEOUT    = 240     -- seconds (whole orchestration over rpc)
M.LIMBO_SETTLE_TIMEOUT = 30    -- seconds to wait for the leader limbo to settle
M.PAUSE_TTL          = 300     -- seconds: failover pause held during the flow
M.PEER_SYNC_TIMEOUT  = 30      -- seconds to wait for peers to pick up the rejoin

-- ── pure helpers (no box; unit-testable) ────────────────────────────

-- Find a `_cluster` row by instance name in an array of
-- { id, uuid, name } rows. -> { id, uuid } | nil.
function M._find_cluster_row(rows, name)
    if type(rows) ~= 'table' or type(name) ~= 'string' then return nil end
    for _, r in ipairs(rows) do
        if r.name == name then
            return { id = r.id, uuid = r.uuid }
        end
    end
    return nil
end

-- Decide whether a box.info.replication[id] entry represents a peer that
-- still has a live replication connection to us. An incoming relay
-- (downstream) OR an outgoing applier (upstream) in any non-terminal
-- state counts as connected. -> true when fully disconnected.
local function status_active(s)
    -- Terminal / absent states mean "no live link". Everything else
    -- (follow, sync, connect, connecting, auth, ...) is treated as live
    -- so we wait it out rather than expel under an open connection.
    return s ~= nil and s ~= 'stopped' and s ~= 'disconnected'
        and s ~= 'failed'
end

function M._is_disconnected(entry)
    if type(entry) ~= 'table' then return true end
    local up   = entry.upstream and entry.upstream.status
    local down = entry.downstream and entry.downstream.status
    if status_active(up) then return false end
    if status_active(down) then return false end
    return true
end

-- Pick the lowest `_cluster` id (1..31) that is free to assign cleanly:
-- not currently registered AND with a zero component in the cluster
-- vclock. Reusing an id whose vclock component is non-zero resurrects a
-- stale relay position at the peers ("invalid xlog order"), so such ids
-- are skipped even when their `_cluster` row is already gone — this is
-- exactly the footgun that the whole identity-reset flow exists to avoid.
-- used_ids: { [id]=true }, vclock: { [id]=lsn }. -> id | nil (exhausted).
--
-- VCLOCK_MAX-1 = 31 is the hard ceiling on replica ids; nil means every
-- slot is either live or carries history, and the caller must surface an
-- exhaustion error rather than risk an unsafe reuse.
function M._pick_fresh_id(used_ids, vclock)
    used_ids = used_ids or {}
    vclock = vclock or {}
    for id = 1, 31 do
        local v = vclock[id]
        if not used_ids[id] and (v == nil or v == 0) then
            return id
        end
    end
    return nil
end

-- Given the verify peer list, a map_eval result keyed by alias
-- ({ [alias] = { ok = bool, value = <replication-uri-count> } }) and the
-- leader's own replication-list size `want`, return the aliases that have
-- NOT yet caught up to the full topology (rpc failed, or fewer URIs than
-- the leader). Pure so the laggard decision is unit-testable without
-- rpc/box.
--
-- We compare box.cfg.replication SIZE, not box.info.replication contents:
-- box.info.replication carries a row for every `_cluster`-registered peer
-- (it replicates in), so the target appears there even on a peer that
-- never reloaded the re-added config — a false "caught up". The peer's
-- box.cfg.replication list only grows back to the full size once it
-- actually re-reads the RE-ADD config, which is the signal we want.
function M._laggards(peers, res, want)
    res = res or {}
    want = want or 0
    local out = {}
    for _, alias in ipairs(peers or {}) do
        local r = res[alias]
        local count = (type(r) == 'table' and r.ok == true
            and tonumber(r.value)) or nil
        if count == nil or count < want then
            table.insert(out, alias)
        end
    end
    return out
end

-- ── box-touching wrappers (run on the RW leader) ────────────────────

-- Read the local `_cluster` space into an array of { id, uuid, name }.
function M.cluster_rows()
    local rows = {}
    if not (rawget(_G, 'box') and box.space and box.space._cluster) then
        return rows
    end
    for _, t in box.space._cluster:pairs() do
        table.insert(rows, { id = t[1], uuid = tostring(t[2]), name = t[3] })
    end
    return rows
end

-- box.snapshot() on the leader. Call AFTER expel_cluster_row so the
-- `_cluster` DELETE is folded into the checkpoint and never relayed to
-- the rejoining replica (which would otherwise die applying a DELETE of
-- its own id, #4107). -> (true, nil) | (false, err).
function M.snapshot_master()
    local ok, err = pcall(box.snapshot)
    if not ok then
        local msg = tostring(err)
        -- A snapshot already in progress is not fatal for our purpose.
        if msg:find('snapshot is in progress') then
            logger.info('snapshot_master: already in progress, treated as ok')
            return true
        end
        logger.warn('snapshot_master failed', { err = msg })
        return false, msg
    end
    logger.info('snapshot_master: checkpoint written')
    return true
end

-- Poll the local replication view until the target holds no live
-- connection (so the expel won't orphan a relay / wedge the name).
-- target_uuid is matched against box.info.replication entries.
-- -> (true, elapsed) when disconnected; (false, elapsed) on timeout.
function M.wait_peer_disconnected(target_id, opts)
    opts = opts or {}
    local timeout = opts.timeout or M.DISCONNECT_TIMEOUT
    local step    = opts.step or M.POLL_STEP
    local started = fiber.clock()
    while true do
        local entry = (box.info.replication or {})[target_id]
        if M._is_disconnected(entry) then
            local elapsed = fiber.clock() - started
            logger.info('wait_peer_disconnected: target gone', {
                id = target_id, elapsed = elapsed,
            })
            return true, elapsed
        end
        if (fiber.clock() - started) >= timeout then
            local elapsed = fiber.clock() - started
            logger.warn('wait_peer_disconnected: timeout', {
                id = target_id, elapsed = elapsed,
            })
            return false, elapsed
        end
        fiber.sleep(step)
    end
end

-- Poll the local replication view until the target (by id) establishes a
-- LIVE link — used to confirm the fresh JOIN actually completed, rather
-- than just the pre-registered row being present (which appears the
-- instant we insert it). Inverse of wait_peer_disconnected.
-- -> (true, elapsed) | (false, elapsed) on timeout.
function M.wait_peer_connected(target_id, opts)
    opts = opts or {}
    local timeout = opts.timeout or M.REJOIN_TIMEOUT
    local step    = opts.step or M.POLL_STEP
    local started = fiber.clock()
    while true do
        local entry = (box.info.replication or {})[target_id]
        if entry ~= nil and not M._is_disconnected(entry) then
            local elapsed = fiber.clock() - started
            logger.info('wait_peer_connected: target up', {
                id = target_id, elapsed = elapsed,
            })
            return true, elapsed
        end
        if (fiber.clock() - started) >= timeout then
            local elapsed = fiber.clock() - started
            logger.warn('wait_peer_connected: timeout', {
                id = target_id, elapsed = elapsed,
            })
            return false, elapsed
        end
        fiber.sleep(step)
    end
end

-- Decide whether the local synchro limbo is settled enough to take a
-- checkpoint the target can cleanly join from: this node must own the
-- queue and be writable, with no in-flight limbo operation. Joining off a
-- transient demoted/frozen checkpoint (owner ≠ self, or RO) gives the
-- target a stale-term limbo that then rejects the next PROMOTE as a
-- split-brain (txn_limbo.c: confirmed_lsn > request lsn). Pure for tests.
function M._limbo_settled(synchro, self_id, ro)
    if ro == true then return false end
    local q = (synchro or {}).queue or {}
    return q.owner ~= nil and q.owner == self_id and q.busy ~= true
end

-- Poll until the leader's own synchro limbo is settled (see
-- M._limbo_settled). -> true when settled; false on timeout.
function M.wait_limbo_settled(opts)
    opts = opts or {}
    local timeout = opts.timeout or M.LIMBO_SETTLE_TIMEOUT
    local step    = opts.step or M.POLL_STEP
    local started = fiber.clock()
    while true do
        if M._limbo_settled(box.info.synchro, box.info.id, box.info.ro) then
            return true
        end
        if (fiber.clock() - started) >= timeout then
            logger.warn('wait_limbo_settled: timeout', {
                owner = (((box.info.synchro or {}).queue) or {}).owner,
                self_id = box.info.id, ro = box.info.ro,
            })
            return false
        end
        fiber.sleep(step)
    end
end

-- Pick a fresh `_cluster` id on the leader from the live space + vclock.
-- -> id | nil (exhausted). See M._pick_fresh_id for the safety rationale.
function M.pick_fresh_id()
    local used = {}
    if rawget(_G, 'box') and box.space and box.space._cluster then
        for _, t in box.space._cluster:pairs() do
            used[t[1]] = true
        end
    end
    local vclock = (box.info and box.info.vclock) or {}
    return M._pick_fresh_id(used, vclock)
end

-- Pre-register the target's NEW identity on the leader, BEFORE it rejoins:
-- insert a fully-formed { id, uuid, name } `_cluster` row. When the wiped
-- target JOINs with this pinned uuid, the master finds the row already
-- carrying a real id and the matching name, so box_register_replica is a
-- no-op (box.cc:4643) and the join never hits the nameless-registration →
-- name-mismatch crash loop (box.cc:5046). The named row also ships inside
-- the join snapshot, so the target boots with its name already bound.
--
-- Must run on the RW leader, AFTER expel_cluster_row freed the old id and
-- name. Even then the old `struct replica` may not be collected yet: in a
-- full mesh the leader holds an applier object to the target, and while
-- `replica_has_connections` is true (applier ≠ nil OR incoming connection)
-- the name stays occupied and the insert raises ER_INSTANCE_NAME_DUPLICATE
-- (box.cc:4883). Orphan collection is async (it runs off the
-- applier/relay disconnect triggers), so we retry on that specific error
-- for a bounded window rather than failing the whole rebootstrap on a
-- transient race. -> (true, nil) | (false, err).
function M.preregister_row(new_id, new_uuid, name, opts)
    opts = opts or {}
    local timeout = opts.timeout or M.NAME_FREE_TIMEOUT
    local step    = opts.step or M.POLL_STEP
    local started = fiber.clock()
    while true do
        local ok, err = pcall(function()
            box.space._cluster:insert({ new_id, new_uuid, name })
        end)
        if ok then
            logger.info('preregister_row: inserted', {
                id = new_id, uuid = new_uuid, name = name,
            })
            return true
        end
        local emsg = tostring(err)
        -- Name still held by the not-yet-collected old replica struct;
        -- wait for orphan collection and retry while we have budget.
        if emsg:find('Duplicate replica name', 1, true)
            and (fiber.clock() - started) < timeout then
            logger.info('preregister_row: name still held, retrying', {
                name = name, elapsed = fiber.clock() - started,
            })
            fiber.sleep(step)
        else
            logger.warn('preregister_row failed', {
                id = new_id, uuid = new_uuid, name = name, err = emsg,
            })
            return false, emsg
        end
    end
end

-- Expel the target's `_cluster` row on the leader, freeing its id+name
-- for a fresh rejoin. Must run on the RW leader (delete on a follower
-- raises READONLY). -> (true, old_id) | (false, err).
--
-- CALL ONLY AFTER wait_peer_disconnected: deleting the row while the
-- target still has an incoming connection leaves an orphaned relay whose
-- `has_incoming_connection` never clears, permanently reserving the name
-- (box.cc:5055) until the leader restarts.
function M.expel_cluster_row(target_name)
    local row = M._find_cluster_row(M.cluster_rows(), target_name)
    if row == nil then
        logger.info('expel_cluster_row: already absent', { name = target_name })
        return true   -- idempotent: nothing to delete
    end
    local ok, err = pcall(function()
        box.space._cluster:delete(row.id)
    end)
    if not ok then
        logger.warn('expel_cluster_row failed', {
            name = target_name, id = row.id, err = tostring(err),
        })
        return false, tostring(err)
    end
    logger.info('expel_cluster_row: removed', {
        name = target_name, id = row.id, uuid = row.uuid,
    })
    return true, row.id
end

-- ── config-edit + reload helpers (leader-local) ─────────────────────

local function config_client()
    local ok, mod = pcall(require, 'webui.config_store.client')
    if not ok then return nil, 'config client unavailable' end
    local client = mod.get_client()
    if client == nil then return nil, 'etcd client unavailable' end
    return client
end

-- Read the current cluster YAML from etcd. -> (raw, nil) | (nil, err).
local function config_read()
    local client, err = config_client()
    if client == nil then return nil, err end
    local kv = select(1, client:read_cluster_config())
    if kv == nil or kv.value == nil then return nil, 'no current cluster config' end
    return kv.value
end

-- Direct put of the cluster YAML to etcd, bypassing 2PC (the broken
-- target can't take part in the prepared-row round-trip). Guards on etcd
-- quorum so a non-durable write fails fast rather than half-applying.
-- -> (true, nil) | (nil, err).
local function config_write(new_yaml)
    local client, err = config_client()
    if client == nil then return nil, err end
    local healthy = select(1, pcall(function()
        return client:cluster_health(2)
    end))
    if healthy == false then
        return nil, 'etcd quorum check raised'
    end
    local ok, res, werr = pcall(client.write_cluster_config, client, new_yaml)
    if not ok then return nil, 'etcd write raised: ' .. tostring(res) end
    if res == nil then return nil, 'etcd write failed: ' .. tostring(werr) end
    return true
end

-- All instance aliases except self and the target — the peers that must
-- reload to pick up the config edit (the target is wiped / crash-looping).
local function reload_peer_aliases(target)
    local state = require('webui.cluster.state')
    local snap = state.snapshot()
    local self_name = (rawget(_G, 'box') and box.info and box.info.name) or nil
    local out = {}
    for alias in pairs(snap.servers or {}) do
        if alias ~= self_name and alias ~= target then
            table.insert(out, alias)
        end
    end
    return out
end

-- config:reload() on the peers (and, unless skip_self, on the leader too).
-- The config source is poll-on-demand, so peers will not pick up an etcd
-- edit until told to reload. Best effort: the orchestrator's bounded waits
-- absorb any laggard.
--
-- skip_self is set during EXPEL: reloading the LEADER there would drop the
-- target from the leader's peer pool, and the leader needs that connection
-- to dispatch the wipe RPC to the target. The target itself still reads the
-- expelled config straight from etcd on its restart, so the crash-loop
-- barrier holds regardless.
local function reload_cluster(target, skip_self)
    if not skip_self then
        pcall(function() require('config'):reload() end)
    end
    local peers = reload_peer_aliases(target)
    if #peers == 0 then return end
    local rpc = require('webui.cluster.rpc')
    pcall(rpc.map_call, 'webui_config_reload_remote', {},
        { timeout = M.RELOAD_RPC_TIMEOUT, peers = peers })
    logger.info('reload_cluster: fanned out', {
        peers = peers, skip_self = skip_self == true })
end

-- After RE-ADD, confirm every surviving peer ACTUALLY re-read the config
-- that puts the rejoined target back — its box.cfg.replication list has
-- grown to the full topology size (= the leader's). The RE-ADD reload
-- fan-out is best-effort: a peer that missed (or raced) the reload RPC
-- stays frozen in the EXPEL view (target absent from its
-- box.cfg.replication), so the target is invisible from that peer and
-- never replicates to/from it, with NO self-healing until the next config
-- edit. Re-issue reload to laggards and re-check, bounded. The target
-- itself already rejoined (verify_rejoin) — a stubborn laggard is a
-- degraded condition, not a flow failure, so the caller treats the return
-- as a warning, not a hard error.
-- peers: aliases to verify (excludes leader-self and the target).
-- -> (true, nil) | (false, { laggard_aliases }).
function M.ensure_peers_replicating(target, peers, opts)
    opts = opts or {}
    local timeout = opts.timeout or M.PEER_SYNC_TIMEOUT
    local step    = opts.step or M.POLL_STEP
    if type(peers) ~= 'table' or #peers == 0 then return true end
    -- The full topology size, taken from THIS leader (it reloaded the
    -- RE-ADD config in skip_self=false mode, so its list is authoritative).
    local want = #((rawget(_G, 'box') and box.cfg.replication) or {})
    local rpc = require('webui.cluster.rpc')
    local expr = 'return #(box.cfg.replication or {})'
    local started = fiber.clock()
    while true do
        local res = nil
        pcall(function()
            res = rpc.map_eval(expr, {},
                { timeout = M.RELOAD_RPC_TIMEOUT, peers = peers })
        end)
        local laggards = M._laggards(peers, res, want)
        if #laggards == 0 then
            logger.info('ensure_peers_replicating: all peers caught up', {
                target = target, peers = peers, want = want })
            return true
        end
        if (fiber.clock() - started) >= timeout then
            logger.warn('ensure_peers_replicating: laggards remain', {
                target = target, laggards = laggards, want = want })
            return false, laggards
        end
        -- Re-issue the reload to just the laggards, then wait a beat.
        pcall(rpc.map_call, 'webui_config_reload_remote', {},
            { timeout = M.RELOAD_RPC_TIMEOUT, peers = laggards })
        logger.info('ensure_peers_replicating: re-reloaded laggards', {
            laggards = laggards, want = want })
        fiber.sleep(step)
    end
end

-- ── orchestrator ────────────────────────────────────────────────────

-- Pause the supervised failover agent for the duration of the rebootstrap
-- and return an idempotent "resume" thunk. A re-appointment mid-flow bumps
-- the raft term while the target is mid-JOIN; the target then inherits a
-- stale-term limbo and wedges in split-brain against the newer PROMOTE. We
-- only pause (and later clear) if nobody else holds the pause, so an
-- operator's longer maintenance pause is never cut short by our cleanup.
-- The pause carries a TTL, so even a hard crash here self-heals.
local function pause_failover_guard()
    local client = select(1, config_client())
    if client == nil then return function() end end
    local ok_p, pause = pcall(require, 'webui.failover.pause')
    if not ok_p then return function() end end
    if pause.is_active(client) then
        logger.info('identity_reset: failover already paused; leaving as-is')
        return function() end          -- someone else owns the pause
    end
    local _, err = pause.set(client, M.PAUSE_TTL, 'recovery.identity_reset')
    if err ~= nil then
        logger.warn('identity_reset: failover pause failed', { err = tostring(err) })
        return function() end
    end
    logger.info('identity_reset: failover paused for rebootstrap', {
        ttl_sec = M.PAUSE_TTL })
    return function()
        pcall(function() pause.clear(client) end)
        logger.info('identity_reset: failover pause cleared')
    end
end

-- _run_on_leader(target, root) — pauses failover, runs the phase machine
-- (M._run_phases), and ALWAYS resumes failover afterwards. Runs ON the RW
-- leader (M.run forwards here), so every leader-side op is local and the
-- orchestrator is never the node being wiped.
function M._run_on_leader(target, root)
    local resume_failover = pause_failover_guard()
    local ok, res = pcall(M._run_phases, target, root)
    resume_failover()
    if not ok then error(res) end      -- propagate unexpected raise
    return res
end

-- The phase machine proper. Separated from _run_on_leader so the failover
-- pause is guaranteed to be released on every exit path (each phase fail
-- returns early), via the single pcall in _run_on_leader.
function M._run_phases(target, root)
    local phases = {}
    local saved_block = nil      -- instance subtree, for re-add + cleanup
    local expelled_from_config = false

    local function phase(name, fn)
        local t0 = fiber.clock()
        local ok, pok, msg = pcall(fn)
        local ms = math.floor((fiber.clock() - t0) * 1000)
        if not ok then            -- fn raised
            table.insert(phases, { name = name, ok = false, ms = ms,
                msg = tostring(pok) })
            return false, tostring(pok)
        end
        table.insert(phases, { name = name, ok = pok ~= false, ms = ms,
            msg = msg and tostring(msg) or nil })
        if pok == false then return false, msg end
        return true, msg
    end

    local function fail(stage, msg)
        logger.warn('identity_reset failed', { target = target,
            stage = stage, msg = tostring(msg) })
        -- Cleanup: if we expelled the instance from config but never got
        -- it back in, re-add it so the cluster config is not left short.
        if expelled_from_config and saved_block ~= nil then
            local raw = config_read()
            if raw ~= nil then
                local re_yaml = yaml_patch.add_instance(raw, target,
                    saved_block.instance, saved_block.group,
                    saved_block.replicaset)
                if re_yaml ~= nil and config_write(re_yaml) then
                    reload_cluster(target)
                    logger.warn('identity_reset cleanup: re-added instance '
                        .. 'to config', { target = target })
                end
            end
        end
        return { ok = false, action = 'rebootstrap',
            results = { { peer = target, ok = false,
                msg = stage .. ': ' .. tostring(msg) } },
            error = tostring(msg), phases = phases }
    end

    -- A freshly generated uuid pinned into the re-added config. This is the
    -- load-bearing detail for a clean rejoin: with NO pin the wiped node
    -- bootstraps a RANDOM uuid and writes a nameless snapshot, then dies on
    -- the next restart ("Instance name … is not set in snapshot and UUID is
    -- missing in the config", configdata.lua:542, #3740). Pinning a fresh
    -- uuid makes that check pass AND lets the leader bind the name to it,
    -- while still being a brand-NEW id (the old _cluster row is expelled),
    -- so peers relay from it cleanly.
    local new_uuid = require('uuid').str()
    -- The brand-new `_cluster` id, chosen on the leader once the old row is
    -- expelled (PRE-REGISTER phase). Pre-binding {new_id, new_uuid, name}
    -- before the target rejoins is what breaks the name chicken-and-egg.
    local new_id = nil

    logger.info('identity_reset: start', { target = target, new_uuid = new_uuid })

    -- Enforce the data-safety preconditions against a FRESH snapshot
    -- before touching the config: refuse if expelling the target would
    -- break the synchro quorum or the target is the queue owner. The
    -- assessment surfaces these too, but re-checking here means a stale
    -- UI (or a direct caller) can never push an unsafe expel through.
    do
        local ok_s, snap = pcall(function()
            return require('webui.recovery.snapshot').build()
        end)
        if ok_s and type(snap) == 'table' then
            local orphan = require('webui.recovery.orphan')
            for _, pc in ipairs(orphan._rebootstrap_preconditions(snap, target)) do
                if pc.ok == false
                    and not pc.label:find('reachable', 1, true) then
                    logger.warn('identity_reset refused: precondition', {
                        target = target, precondition = pc.label })
                    return { ok = false, action = 'rebootstrap',
                        results = { { peer = target, ok = false,
                            msg = 'precondition failed: ' .. pc.label } },
                        error = 'PRECONDITION_FAILED: ' .. pc.label,
                        phases = phases }
                end
            end
        end
    end

    -- Capture the target's current id before we touch anything.
    local old_row = M._find_cluster_row(M.cluster_rows(), target)
    local old_id = old_row and old_row.id or nil

    -- Phase EXPEL: remove the instance from config + reload peers.
    local ok, msg = phase('expel_config', function()
        local raw, rerr = config_read()
        if raw == nil then return false, rerr end
        local new_yaml, status, saved = yaml_patch.remove_instance(raw, target)
        if new_yaml == nil then return false, status end
        if status == 'removed' then saved_block = saved end
        local w_ok, werr = config_write(new_yaml)
        if not w_ok then return false, werr end
        expelled_from_config = true
        -- skip_self: keep the leader's pool connection to the target so the
        -- next phase can dispatch the wipe RPC to it.
        reload_cluster(target, true)
        return true, 'expelled (' .. tostring(status) .. ')'
    end)
    if not ok then return fail('expel_config', msg) end

    -- Phase WIPE: erase the target's local state; it crash-loops while
    -- absent from config (a synchronisation barrier) until we re-add it.
    -- The wipe handler returns a 202 BEFORE its deferred os.exit, so a
    -- successful wipe comes back with a positive response — require it, so
    -- an unreachable target (e.g. "not connected") fails loudly and triggers
    -- cleanup rather than silently skipping the wipe.
    ok, msg = phase('wipe_target', function()
        local rpc = require('webui.cluster.rpc')
        local res = rpc.map_call('webui_rebootstrap_remote', {},
            { timeout = M.WIPE_RPC_TIMEOUT, peers = { target } })
        local r = res and res[target]
        if r == nil then return false, 'no response from ' .. target end
        if r.ok ~= true then
            return false, 'wipe rpc failed: ' .. tostring(r.err)
        end
        if type(r.value) == 'table' and r.value.err ~= nil then
            return false, tostring(r.value.message or r.value.err)
        end
        return true, 'wipe dispatched'
    end)
    if not ok then return fail('wipe_target', msg) end

    -- Phase EXPEL_CLUSTER: wait for the old uuid to fully disconnect, then
    -- delete its `_cluster` row so its id and name are both free.
    ok, msg = phase('expel_cluster_row', function()
        -- Drop the leader's OWN applier to the target first. In a full mesh
        -- the leader keeps an applier object to every peer; while
        -- applier ≠ nil the target's `struct replica` is not orphan-collected
        -- even after the row delete, so its NAME stays occupied
        -- (replication.cc: replica_has_connections) and the upcoming
        -- pre-register would raise ER_INSTANCE_NAME_DUPLICATE. The target is
        -- already absent from config (expel_config, skip_self), so a leader
        -- self-reload recomputes replication without it and tears the
        -- applier down. (expel_config skipped self precisely to keep this
        -- connection alive long enough to dispatch the wipe RPC.)
        pcall(function() require('config'):reload() end)
        -- Settle: the wipe handler defers its os.exit, so wait for the old
        -- process to actually go before we wait on / delete its row (an
        -- orphan target already looks "disconnected", so the poll alone can
        -- return instantly while the old process is still up).
        fiber.sleep(M.WIPE_SETTLE)
        if old_id ~= nil then
            M.wait_peer_disconnected(old_id, { timeout = M.DISCONNECT_TIMEOUT })
        end
        local e_ok, e_err = M.expel_cluster_row(target)
        if not e_ok then return false, e_err end
        return true, 'old id expelled'
    end)
    if not ok then return fail('expel_cluster_row', msg) end

    -- Phase PRE-REGISTER: bind the target's NEW identity on the leader
    -- before it rejoins. Pick a fresh id, insert {new_id, new_uuid, name}
    -- into `_cluster`, then checkpoint so the freed-id DELETE and the new
    -- INSERT are folded into one consistent snapshot (the rejoin JOIN
    -- relays from there, #4107). The pre-bound row makes the master's
    -- join-time registration a no-op and the target boots with its name
    -- already set — breaking the nameless-registration crash loop.
    ok, msg = phase('preregister', function()
        new_id = M.pick_fresh_id()
        if new_id == nil then
            return false, 'no free _cluster id (1..31 exhausted)'
        end
        -- Wait for THIS leader's synchro limbo to be settled (owns the
        -- queue, writable, idle) so the checkpoint the target joins from
        -- carries a clean, current-term limbo. Joining off a transient
        -- demoted/frozen checkpoint wedges the target in split-brain
        -- against the next PROMOTE. Failover is paused for the whole flow,
        -- so once settled the term will not move out from under the join.
        if not M.wait_limbo_settled({ timeout = M.LIMBO_SETTLE_TIMEOUT }) then
            return false, 'leader synchro limbo did not settle'
        end
        local p_ok, p_err = M.preregister_row(new_id, new_uuid, target)
        if not p_ok then return false, p_err end
        local s_ok, s_err = M.snapshot_master()
        if not s_ok then return false, s_err end
        return true, 'pre-bound id ' .. tostring(new_id) .. ' + checkpoint'
    end)
    if not ok then return fail('preregister', msg) end

    -- Phase RE-ADD: put the instance back in config (with the same uuid we
    -- just pre-registered) + reload, so the next restart of the
    -- crash-looping target finds itself and does a clean fresh JOIN onto
    -- the pre-bound id/name.
    ok, msg = phase('readd_config', function()
        if saved_block == nil then
            return false, 'no saved instance block to re-add'
        end
        -- Pin the fresh uuid so the wiped node bootstraps a deterministic,
        -- name-bound identity instead of a random nameless one.
        local inst = saved_block.instance
        if type(inst) ~= 'table' then inst = {} end
        inst.database = inst.database or {}
        inst.database.instance_uuid = new_uuid
        local raw, rerr = config_read()
        if raw == nil then return false, rerr end
        local new_yaml, status = yaml_patch.add_instance(raw, target,
            inst, saved_block.group, saved_block.replicaset)
        if new_yaml == nil then return false, status end
        local w_ok, werr = config_write(new_yaml)
        if not w_ok then return false, werr end
        expelled_from_config = false   -- back in config; cleanup no longer needed
        reload_cluster(target)
        return true, 're-added (' .. tostring(status) .. ')'
    end)
    if not ok then return fail('readd_config', msg) end

    -- Phase VERIFY: the target re-establishes a live replication link on
    -- its pre-bound id. The row itself appeared at PRE-REGISTER time, so a
    -- presence check would pass instantly; wait for an actual connection
    -- to confirm the fresh JOIN completed.
    ok, msg = phase('verify_rejoin', function()
        local c_ok = M.wait_peer_connected(new_id, { timeout = M.REJOIN_TIMEOUT })
        if not c_ok then
            return false, 'target did not re-establish replication in time'
        end
        return true, 'rejoined as id ' .. tostring(new_id)
    end)
    if not ok then return fail('verify_rejoin', msg) end

    -- Phase SYNC_PEERS (non-fatal): make sure every OTHER surviving peer
    -- actually picked up the rejoined target — the RE-ADD reload fan-out is
    -- best-effort and a peer that missed it would keep the target invisible
    -- (absent from its box.cfg.replication) with no self-healing. We
    -- re-reload laggards and re-check; the target has already rejoined, so a
    -- stubborn laggard is surfaced as a WARNING in the result rather than
    -- failing the (successful) rebootstrap.
    local peer_warning = nil
    phase('sync_peers', function()
        local peers = reload_peer_aliases(target)
        if #peers == 0 then return true, 'no other peers to sync' end
        local synced, laggards = M.ensure_peers_replicating(target, peers)
        if synced then return true, 'all peers picked up the re-added target' end
        peer_warning = 'peers did not re-read the re-added config: '
            .. table.concat(laggards, ',') .. ' — reload them by hand '
            .. '(config:reload()) if it persists'
        return true, 'WARN: ' .. peer_warning
    end)

    pcall(function()
        local audit = require('webui.audit.log')
        audit.record({
            user = root and root.user,
            action = 'recovery.identity_reset',
            scope = 'cluster',
            payload = { target = target, old_id = old_id, new_id = new_id },
            request_id = root and root.request_id,
        })
    end)

    logger.info('identity_reset: done', {
        target = target, old_id = old_id, new_id = new_id, new_uuid = new_uuid,
    })
    return { ok = true, action = 'rebootstrap',
        results = { { peer = target, ok = true,
            msg = 'clean rebootstrap: new _cluster id ' .. tostring(new_id) } },
        new_id = new_id, new_uuid = new_uuid, warning = peer_warning,
        phases = phases }
end

-- run(payload, root) — entry point used by the recovery executor.
-- Resolves the RW leader and FORWARDS the whole orchestration there, so
-- it never runs on the target being wiped (HAProxy may have landed the
-- request anywhere, including the orphan target). The leader is the
-- synchro queue owner and the target is — by precondition — not the
-- owner, so the leader always survives the wipe.
function M.run(payload, root)
    payload = payload or {}
    local target = payload.alias or payload.target_alias
    if type(target) ~= 'string' or target == '' then
        return { ok = false, action = 'rebootstrap', results = {},
            error = 'target_alias is required' }
    end
    local self_name = (rawget(_G, 'box') and box.info and box.info.name) or nil
    local state = require('webui.cluster.state')
    local leader_alias = select(1, state.find_leader())
    if leader_alias == nil then
        return { ok = false, action = 'rebootstrap',
            results = { { peer = target, ok = false,
                msg = 'no writable leader to coordinate rebootstrap' } },
            error = 'no_leader' }
    end
    if leader_alias ~= self_name then
        logger.info('identity_reset: forwarding to leader', {
            target = target, leader = leader_alias })
        local rpc = require('webui.cluster.rpc')
        -- net.box conn:call treats the second arg as the POSITIONAL
        -- argument list, so the shim's single map argument must be
        -- wrapped in an array — passing the bare map makes net.box try
        -- to encode an associative table as the args array and raise
        -- "Tuple/Key must be MsgPack array". The shim reads args.target.
        local res = rpc.map_call('webui_identity_reset_remote',
            { { target = target } },
            { timeout = M.FORWARD_TIMEOUT, peers = { leader_alias } })
        local r = res and res[leader_alias]
        if not (r and r.ok) then
            return { ok = false, action = 'rebootstrap',
                results = { { peer = target, ok = false,
                    msg = (r and r.err) or 'forward to leader failed' } },
                error = 'forward_failed' }
        end
        return r.value
    end
    return M._run_on_leader(target, root)
end

return M
