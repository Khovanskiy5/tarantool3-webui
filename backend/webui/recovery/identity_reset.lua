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

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.identity_reset')

local M = {}

-- Default bounded-wait budget for the target to drop its connections.
M.DISCONNECT_TIMEOUT = 10      -- seconds
M.POLL_STEP          = 0.5     -- seconds
M.SNAPSHOT_TIMEOUT   = 60      -- seconds (box.snapshot can be slow)

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

return M
