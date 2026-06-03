--
-- Graceful synchro-queue drain on shutdown (Task FO-9).
--
-- If this instance owns the synchronous queue (it is the effective
-- leader), demote it before the process exits. box.ctl.demote()
-- synchronously drains the limbo: every pending synchro transaction
-- either reaches quorum and gets a CONFIRM record, or hits ROLLBACK —
-- both durable.
--
-- Without this drain a fast SIGTERM (docker stop -t1, --force-recreate)
-- kills the process while a sync txn is still in limbo. On restart that
-- LSN is on disk with no CONFIRM/ROLLBACK marker; when a peer later
-- becomes leader and writes at the same LSN you get the canonical
-- "got a request with lsn from an already processed range" split-brain
-- on every applier connection.
--
-- Extracted so BOTH the failover agent (agent.stop) and the role's
-- generic stop path (lifecycle/stop) can call it — the drain must run
-- on every shutdown, not only when the agent is enabled (election /
-- manual / agent-off clusters need it too).
--
-- Best-effort + bounded: never block shutdown forever if demote can't
-- reach quorum. A hard kill -9 bypasses this entirely — there the limbo
-- term fence (is_sync data) + self-fencing on the survivors are the
-- safety net.
--

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('failover.drain')

local M = {}

-- Demote + wait_ro if we own the synchro queue. `timeout` bounds the
-- wait_ro (default 3s). Returns true if a drain ran (or wasn't needed),
-- false on a demote/wait error. Safe to call when box is absent.
function M.drain_synchro_queue(timeout)
    timeout = tonumber(timeout) or 3
    if rawget(_G, 'box') == nil or box.info == nil then return true end
    local synchro = box.info.synchro or {}
    local owner = (synchro.queue and synchro.queue.owner) or 0
    if owner ~= box.info.id then
        -- Not the queue owner — nothing to hand off.
        return true
    end
    logger.info('graceful demote: this instance owns the synchro queue; '
        .. 'draining limbo before exit')
    local demote_ok, demote_err = pcall(function() box.ctl.demote() end)
    if not demote_ok then
        logger.warn('graceful demote failed', { err = tostring(demote_err) })
        return false
    end
    -- wait_ro confirms the demote landed and the limbo handed ownership
    -- off (or expired).
    local wait_ok, wait_err = pcall(function() box.ctl.wait_ro(timeout) end)
    if not wait_ok then
        logger.warn('wait_ro after demote failed', { err = tostring(wait_err) })
        return false
    end
    logger.info('graceful demote: limbo drained, instance RO')
    return true
end

return M
