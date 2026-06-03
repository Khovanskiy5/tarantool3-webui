--
-- Safe restart orchestration (FO-12).
--
-- Coordinates rolling restarts so the cluster never loses its write
-- majority and never drops a leader abruptly:
--
--   1. Rolling — restart ONE instance at a time, waiting for the
--      restarted peer to rejoin and its replication to converge
--      (upstreams follow/sync) before touching the next.
--   2. Demote-first — before restarting the current leader, hand
--      leadership to a healthy follower (manual appointment + wait for
--      the new leader to go read-write), then restart the old leader as
--      a follower.
--   3. Majority-guard — refuse any stop/restart that would leave fewer
--      than N/2+1 instances alive.
--
-- The planning half (count_alive / majority_after_stop / leader_alias /
-- restart_order / is_converged / plan_rolling_restart) is PURE over a
-- `servers` map (the shape produced by cluster.state.snapshot().servers)
-- so it is fully unit-testable. The execution half drives the real
-- restart through the existing peer RPC shims + the failover agent's
-- manual-appointment path, and only sequences already-tested pieces.
--

local M = {}

-- ── Pure planning ────────────────────────────────────────────────────

-- A server is "alive" for quorum purposes when we can reach it AND it is
-- fully running (not orphan / loading / unknown).
local function is_alive(srv)
    return srv ~= nil and srv.reachable == true and srv.status == 'running'
end
M.is_alive = is_alive

function M.count_alive(servers)
    local n = 0
    for _, srv in pairs(servers or {}) do
        if is_alive(srv) then n = n + 1 end
    end
    return n
end

function M.majority_needed(total)
    return math.floor((tonumber(total) or 0) / 2) + 1
end

-- Normalise a list OR a set of aliases into a set.
local function to_set(aliases)
    local set = {}
    if type(aliases) == 'table' then
        if aliases[1] ~= nil then
            for _, a in ipairs(aliases) do set[a] = true end
        else
            for a, v in pairs(aliases) do if v then set[a] = true end end
        end
    end
    return set
end

local function sorted_keys(set)
    local list = {}
    for a in pairs(set) do list[#list + 1] = a end
    table.sort(list)
    return list
end

-- Would stopping `stop_aliases` leave a majority of the replicaset
-- alive? Pure. Returns { total, alive, alive_after, needed, ok, reason }.
function M.majority_after_stop(servers, stop_aliases)
    local stop = to_set(stop_aliases)
    local total, alive, alive_after = 0, 0, 0
    for alias, srv in pairs(servers or {}) do
        total = total + 1
        local live = is_alive(srv)
        if live then
            alive = alive + 1
            if not stop[alias] then alive_after = alive_after + 1 end
        end
    end
    local needed = M.majority_needed(total)
    local ok = alive_after >= needed
    local reason
    if not ok then
        reason = string.format(
            'stopping {%s} would leave %d/%d instances alive (need %d for '
            .. 'write majority)', table.concat(sorted_keys(stop), ', '),
            alive_after, total, needed)
    end
    return {
        total = total, alive = alive, alive_after = alive_after,
        needed = needed, ok = ok, reason = reason,
    }
end

-- The current leader alias: the synchro-queue owner, falling back to the
-- read-write instance. Pure over the servers map. nil when leaderless.
function M.leader_alias(servers)
    for alias, srv in pairs(servers or {}) do
        local q = srv and srv.synchro and srv.synchro.queue
        if q ~= nil and srv.id ~= nil and q.owner ~= nil
            and q.owner == srv.id then
            return alias
        end
    end
    for alias, srv in pairs(servers or {}) do
        if srv and srv.is_ro == false then return alias end
    end
    return nil
end

-- Has a (re)started instance converged? Reachable + running + every
-- replication upstream in follow/sync. A peer with no upstream info
-- (single instance) is treated as converged.
function M.is_converged(srv)
    if not is_alive(srv) then return false end
    local repl = srv.replication
    if type(repl) ~= 'table' then return true end
    for _, peer in pairs(repl) do
        local up = peer and peer.upstream
        if type(up) == 'table' and up.status ~= nil then
            if up.status ~= 'follow' and up.status ~= 'sync' then
                return false
            end
        end
    end
    return true
end

-- Rolling order: healthy followers first (alphabetical, deterministic),
-- the leader LAST (demote-first applies to it). Returns (order, leader).
function M.restart_order(servers)
    local leader = M.leader_alias(servers)
    local followers = {}
    for alias, srv in pairs(servers or {}) do
        if alias ~= leader and is_alive(srv) then
            followers[#followers + 1] = alias
        end
    end
    table.sort(followers)
    if leader ~= nil then followers[#followers + 1] = leader end
    return followers, leader
end

-- Build a rolling-restart plan: ordered steps (leader flagged
-- demote_first) plus the single-stop majority verdict (a rolling restart
-- stops one at a time, so we guard against a single stop breaking
-- majority — true only for a 1- or 2-node cluster).
function M.plan_rolling_restart(servers)
    local order, leader = M.restart_order(servers)
    local steps = {}
    for _, alias in ipairs(order) do
        steps[#steps + 1] = {
            alias = alias,
            is_leader = (alias == leader),
            demote_first = (alias == leader),
        }
    end
    local guard = M.majority_after_stop(servers, { order[1] or '__none__' })
    return {
        steps = steps,
        leader = leader,
        total = guard.total,
        blocked = (#order > 0) and (not guard.ok) or false,
        reason = guard.ok and nil or guard.reason,
    }
end

-- ── Execution (drives real restarts via existing safe primitives) ─────

local function logger()
    return require('webui.log_util').with_tag('lifecycle.orchestrator')
end

local function self_alias()
    return (rawget(_G, 'box') and box.info and box.info.name) or nil
end

-- Is `alias` reachable through the peer pool right now?
local function peer_in_pool(alias)
    local ok, peers = pcall(require, 'webui.cluster.peers')
    if not ok then return false end
    for name in pairs(peers.list() or {}) do
        if name == alias then return true end
    end
    return false
end

-- Trigger a graceful restart of ONE instance via the shim (drain + exit;
-- Docker's restart policy respins a fresh process that rejoins as a
-- follower). Returns (true) on dispatch, (nil, err) otherwise.
--
-- We confirm the target is dispatchable BEFORE firing so a genuine
-- "peer not in pool" failure is reported instead of being masked by the
-- expected connection drop on exit. `self` is restarted via a local
-- shim call (it is never in its own peer pool).
local function trigger_restart(alias)
    if alias == self_alias() then
        local shim = rawget(_G, 'webui_graceful_restart_remote')
        if type(shim) ~= 'function' then
            return nil, 'graceful-restart shim unavailable'
        end
        local ok, res = pcall(shim)
        if not ok then return nil, tostring(res) end
        if type(res) == 'table' and res.ok == false then
            return nil, tostring(res.err or res.message or 'restart refused')
        end
        return true
    end

    if not peer_in_pool(alias) then
        return nil, 'peer not in pool / unreachable: ' .. tostring(alias)
    end
    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    if not rpc_ok then return nil, 'rpc unavailable' end
    local ok, per_peer = pcall(rpc.map_call, 'webui_graceful_restart_remote',
        {}, { timeout = 3, peers = { alias } })
    -- pcall raised: the peer dropped the connection as it exited — that
    -- is the expected, successful path for a restart.
    if not ok then return true end
    local r = type(per_peer) == 'table' and per_peer[alias]
    if r == nil then
        -- Reached map_call but the target produced no result: it did not
        -- exit (no dropped connection) and did not reply — treat as a
        -- failed dispatch rather than a silent success.
        return nil, 'no response from ' .. tostring(alias)
    end
    if r.ok == false and r.err then return nil, tostring(r.err) end
    return true
end

-- Wait until `alias` has actually restarted AND reconverged. Polling the
-- poller's cached snapshot is racy on its own: right after we fire the
-- restart the snapshot can still show the pre-restart converged state.
-- Two guards close that window:
--   1. Freshness — ignore the snapshot until the poller generation has
--      advanced past the one captured when we started waiting (so we are
--      never reading a pre-restart tick).
--   2. Down-then-up — only count convergence AFTER we have observed the
--      instance leave the converged set at least once (it went down /
--      orphan / disconnected on restart). Then require two consecutive
--      converged reads.
local function wait_converged(alias, timeout)
    local fiber = require('fiber')
    local state = require('webui.cluster.state')
    local deadline = fiber.clock() + (tonumber(timeout) or 45)
    local start_gen = state.generation()
    local saw_down = false
    local hits = 0
    while fiber.clock() < deadline do
        fiber.sleep(0.5)
        -- Ignore the snapshot until the poller has produced a fresh tick
        -- past the one we started on (never read a pre-restart tick).
        if state.generation() > start_gen then
            local snap = state.snapshot()
            local srv = snap.servers and snap.servers[alias]
            if not M.is_converged(srv) then
                saw_down = true
                hits = 0
            elseif saw_down then
                hits = hits + 1
                if hits >= 2 then return true end
            end
        end
    end
    return false
end

-- Wait until a read-write leader exists that is NOT `exclude_alias`.
local function wait_new_leader(exclude_alias, timeout)
    local fiber = require('fiber')
    local state = require('webui.cluster.state')
    local deadline = fiber.clock() + (tonumber(timeout) or 30)
    while fiber.clock() < deadline do
        local snap = state.snapshot()
        local leader = M.leader_alias(snap.servers or {})
        if leader ~= nil and leader ~= exclude_alias then
            return leader
        end
        fiber.sleep(0.5)
    end
    return nil
end

-- The most-caught-up healthy, electable follower (smallest replication
-- lag; ties broken alphabetically for determinism). Promoting the least-
-- lagged peer shortens the vclock catch-up the new leader must do before
-- going read-write. Pure over the servers map.
function M.best_follower(servers, leader)
    local best, best_lag
    for alias, srv in pairs(servers or {}) do
        if alias ~= leader and is_alive(srv) and srv.is_ro ~= false
            and srv.electable ~= false then
            local lag = tonumber(srv.lag) or math.huge
            if best == nil or lag < best_lag
                or (lag == best_lag and alias < best) then
                best, best_lag = alias, lag
            end
        end
    end
    return best
end

-- Hand leadership away from `leader` to a healthy follower before
-- restarting it (demote-first). Uses the failover agent's manual
-- appointment path. Returns (new_leader_alias) or (nil, reason).
local function demote_first(servers, leader, rs_name, by_user)
    -- Promote the most-caught-up healthy follower (least replication lag).
    local candidate = M.best_follower(servers, leader)
    if candidate == nil then
        return nil, 'no healthy follower to promote before restarting leader'
    end
    local client_ok, client_mod = pcall(require, 'webui.config_store.client')
    local agent_ok, agent = pcall(require, 'webui.failover.agent')
    if not (client_ok and agent_ok) then
        return nil, 'failover modules unavailable'
    end
    local client = client_mod.get_client()
    if client == nil then return nil, 'etcd unavailable' end
    local _, ap_err = agent.appoint_manually(client, rs_name, candidate,
        120, by_user or 'rolling-restart')
    if ap_err ~= nil then return nil, 'appoint failed: ' .. tostring(ap_err) end
    local new_leader = wait_new_leader(leader, 30)
    if new_leader == nil then
        return nil, 'new leader did not come up within timeout'
    end
    return new_leader
end

-- ── Cluster-wide restart lock (serialise concurrent operations) ──────

M.KEY_RESTART_LOCK = '/lifecycle/restart_lock'

-- Acquire the cluster-wide restart lock so two concurrent restart
-- operations cannot each pass the majority guard against the same
-- snapshot and stop a quorum together (TOCTOU). The lock is an etcd key
-- bound to a lease — a crashed holder's lock auto-releases by TTL — and
-- a keepalive fiber renews it for the duration of a long rolling run.
-- Returns (handle) on success or (nil, reason) when already held.
function M.acquire_lock(holder, ttl)
    ttl = tonumber(ttl) or 120
    local ok, client_mod = pcall(require, 'webui.config_store.client')
    if not ok then return nil, 'config store unavailable' end
    local client = client_mod.get_client()
    if client == nil then return nil, 'etcd unavailable' end
    local json  = require('json')
    local fiber = require('fiber')
    local lease, lerr = client:lease_grant(ttl)
    if lease == nil then return nil, 'lease grant failed: ' .. tostring(lerr) end
    local payload = json.encode({ holder = holder or '?', ts = fiber.time() })
    local _, terr = client:txn_create(M.KEY_RESTART_LOCK, payload, lease.id)
    if terr ~= nil then
        pcall(function() client:lease_revoke(lease.id) end)
        local who = '?'
        local kv = client:get(M.KEY_RESTART_LOCK)
        if kv ~= nil and kv.value ~= nil then
            local okd, d = pcall(json.decode, kv.value)
            if okd and type(d) == 'table' then who = d.holder or '?' end
        end
        return nil, 'another restart is already in progress (holder: '
            .. tostring(who) .. ')'
    end
    local handle = { lease_id = lease.id, client = client, stop_flag = false }
    handle.fiber = fiber.create(function()
        fiber.self():name('webui_restart_lock', { truncate = true })
        while not handle.stop_flag do
            fiber.sleep(ttl / 3)
            if handle.stop_flag then break end
            pcall(function() client:lease_keepalive(handle.lease_id) end)
        end
    end)
    return handle
end

function M.release_lock(handle)
    if type(handle) ~= 'table' or handle.lease_id == nil then return end
    handle.stop_flag = true
    local client = handle.client
    if client ~= nil then
        pcall(function() client:lease_revoke(handle.lease_id) end)
    end
end

-- Safely restart ONE instance (the bounded building block the GraphQL
-- layer exposes; an operator/script calls it per instance to roll the
-- cluster at its own pace). Majority-guards, demotes first if the target
-- is the leader, then dispatches the restart. Returns promptly after
-- dispatch (does NOT block for convergence). opts: { rs_name, by_user }.
function M.safe_restart_instance(alias, opts)
    opts = opts or {}
    local log = logger()
    local state = require('webui.cluster.state')
    if (state.snapshot().servers or {})[alias] == nil then
        return { ok = false, err = 'unknown instance: ' .. tostring(alias) }
    end
    -- Serialise against any other restart operation (closes the TOCTOU on
    -- the majority guard for concurrent callers).
    local lock, lock_err = M.acquire_lock('restart:' .. tostring(alias), 120)
    if lock == nil then
        log.warn('safe restart blocked: lock held', { reason = lock_err })
        return { ok = false, blocked = true, err = lock_err }
    end
    local ok, result = pcall(function()
        -- Re-read AFTER taking the lock so the guard runs on a snapshot no
        -- other restart can be racing against.
        local servers = state.snapshot().servers or {}
        local guard = M.majority_after_stop(servers, { alias })
        if not guard.ok then
            log.warn('safe restart blocked by majority guard',
                { alias = alias, reason = guard.reason })
            return { ok = false, blocked = true, err = guard.reason }
        end
        local rs_name = opts.rs_name or servers[alias].replicaset_name
        local new_leader
        if M.leader_alias(servers) == alias then
            log.info('demote-first before restarting leader', { leader = alias })
            local nl, derr = demote_first(servers, alias, rs_name, opts.by_user)
            if nl == nil then
                return { ok = false,
                    err = 'demote-first failed: ' .. tostring(derr) }
            end
            new_leader = nl
            log.info('leadership handed off', { from = alias, to = new_leader })
        end
        local _, terr = trigger_restart(alias)
        if terr ~= nil then
            return { ok = false,
                err = 'restart dispatch failed: ' .. tostring(terr) }
        end
        log.info('safe restart dispatched',
            { alias = alias, new_leader = new_leader })
        return {
            ok = true, alias = alias, new_leader = new_leader,
            message = new_leader
                and ('leadership handed to ' .. new_leader
                    .. '; restarting ' .. alias)
                or ('restarting ' .. alias),
        }
    end)
    M.release_lock(lock)
    if not ok then
        return { ok = false, err = 'restart errored: ' .. tostring(result) }
    end
    return result
end

-- Inner rolling-restart runner (lock already held by the caller).
local function run_rolling_restart(opts)
    local log = logger()
    local state = require('webui.cluster.state')
    local snap = state.snapshot()
    local servers = snap.servers or {}

    local plan = M.plan_rolling_restart(servers)
    if plan.blocked then
        log.warn('rolling restart blocked by majority guard',
            { reason = plan.reason })
        return { blocked = true, reason = plan.reason, steps = {} }
    end

    local rs_name = opts.rs_name
    if rs_name == nil then
        -- single-replicaset clusters: derive from any server entry.
        for _, srv in pairs(servers) do
            rs_name = srv.replicaset_name
            if rs_name ~= nil then break end
        end
    end

    local results = {}
    log.info('rolling restart starting', {
        total = plan.total, leader = plan.leader,
        order = (function()
            local t = {}
            for _, s in ipairs(plan.steps) do t[#t + 1] = s.alias end
            return t
        end)(),
    })

    for _, step in ipairs(plan.steps) do
        -- Re-check the majority guard against the LIVE state before each
        -- stop — an unrelated failure mid-sequence must abort us.
        local live = state.snapshot().servers or {}
        local guard = M.majority_after_stop(live, { step.alias })
        if not guard.ok then
            log.warn('rolling restart aborted: majority guard',
                { alias = step.alias, reason = guard.reason })
            results[#results + 1] = { alias = step.alias, action = 'skip',
                ok = false, err = guard.reason }
            return { completed = false, aborted = true, steps = results }
        end

        if step.demote_first then
            log.info('demote-first before restarting leader',
                { leader = step.alias })
            local new_leader, derr = demote_first(live, step.alias, rs_name,
                opts.by_user)
            if new_leader == nil then
                log.warn('demote-first failed; aborting', { err = derr })
                results[#results + 1] = { alias = step.alias,
                    action = 'demote', ok = false, err = derr }
                return { completed = false, aborted = true, steps = results }
            end
            log.info('leadership handed off', {
                from = step.alias, to = new_leader })
        end

        log.info('restarting instance', { alias = step.alias })
        local _, terr = trigger_restart(step.alias)
        if terr ~= nil then
            results[#results + 1] = { alias = step.alias, action = 'restart',
                ok = false, err = terr }
            return { completed = false, aborted = true, steps = results }
        end

        -- Give the process a moment to actually exit before we start
        -- polling for it to come back converged.
        require('fiber').sleep(2)
        local converged = wait_converged(step.alias, opts.converge_timeout)
        results[#results + 1] = { alias = step.alias, action = 'restart',
            ok = converged, err = converged or 'did not converge in time' }
        if not converged then
            log.warn('instance did not converge; aborting rolling restart',
                { alias = step.alias })
            return { completed = false, aborted = true, steps = results }
        end
        log.info('instance back and converged', { alias = step.alias })
    end

    log.info('rolling restart complete', { steps = #results })
    return { completed = true, steps = results }
end

-- Execute a rolling restart of one replicaset under the cluster-wide
-- restart lock. Stops one instance at a time, demotes the leader first,
-- and re-checks the majority guard before every step. opts:
-- { rs_name, by_user, converge_timeout }.
function M.execute_rolling_restart(opts)
    opts = opts or {}
    local lock, lock_err = M.acquire_lock('rolling-restart', 180)
    if lock == nil then
        logger().warn('rolling restart blocked: lock held',
            { reason = lock_err })
        return { blocked = true, reason = lock_err, steps = {} }
    end
    local ok, result = pcall(run_rolling_restart, opts)
    M.release_lock(lock)
    if not ok then
        return { completed = false, aborted = true,
            reason = 'errored: ' .. tostring(result), steps = {} }
    end
    return result
end

return M
