--
-- Role stop sequence.
--
-- Phases:
--   0. release failover lease (synchronous, before drain wait)
--   1. flip the drain gate (new requests get 503)
--   2. wait for in-flight HTTP requests up to shutdown_timeout
--   3. stop accepting new connections
--   4. close WS subscribers
--   5. stop background fibers (audit retention, notifications,
--      suggestions, issues, poller)
--   6. close net.box pool
--
-- Called from M.apply on config rolls, from M.stop() directly by
-- Tarantool when the role is removed from the cluster config, and
-- via the box.ctl.on_shutdown hook registered in lifecycle.start
-- so process SIGTERM also runs the drain.
--

local fiber              = require('fiber')

local log_util           = require('webui.log_util')
local http_srv           = require('webui.http.server')
local peers              = require('webui.cluster.peers')
local poller             = require('webui.cluster.poller')
local issues             = require('webui.cluster.issues')
local suggestions_engine = require('webui.cluster.suggestions')

local state              = require('webui.lifecycle.state')

local logger = log_util.with_tag('init')

local M = {}

-- M.stop(opts) — opts.reload marks a config-reload-induced stop (the
-- role's apply() does stop→start to absorb new options without bouncing
-- the process). On a reload the same instance re-takes its role at once,
-- so leadership must NOT be handed off: a demote here churns the raft term
-- and poisons any peer mid-JOIN with a stale-term synchro limbo. The flag
-- is threaded into the failover agent's drain decision (mirrors Patroni,
-- where reload never demotes). A real shutdown / role-removal passes no
-- opts and drains as before.
function M.stop(opts)
    local STATE = state.STATE
    local reload = opts ~= nil and opts.reload == true

    if STATE.status == 'uninitialized' or STATE.status == 'stopped' then
        logger.debug('stop invoked while not running', {
            current_status = STATE.status,
        })
        return true
    end

    STATE.status = 'stopping'
    local uptime = STATE.started_at and (fiber.time() - STATE.started_at) or 0
    logger.info('webui role stopping', { uptime_sec = uptime, reload = reload })

    -- Phase 0a: graceful synchro-queue drain (FO-9). When the failover
    -- agent manages leadership, agent.stop() (Phase 0) drains as part of
    -- its handover. When it does NOT (election / manual / agent
    -- disabled), drain here so a stopped leader still hands off the limbo
    -- on EVERY mode — otherwise a hung sync txn becomes ER_SPLIT_BRAIN on
    -- the survivors after restart. A hard kill -9 bypasses this; there
    -- the is_sync limbo term fence + survivor self-fencing are the net.
    -- Skipped on reload: the leader keeps its limbo across a stop/start.
    if STATE.failover == nil and not reload then
        pcall(function()
            require('webui.failover.drain').drain_synchro_queue(3)
        end)
    end

    -- Phase 0: release the failover coordinator lease FIRST, before
    -- the HTTP drain wait. The lease TTL (3s) is shorter than the
    -- drain budget (5s default), so deferring this would let the
    -- lease expire naturally and cost the cluster the full TTL
    -- worth of failover latency. agent.stop() revokes the lease
    -- synchronously, so by the time the next phase starts, a
    -- surviving peer can claim coordinator within ~1s.
    if STATE.failover ~= nil then
        pcall(function() STATE.failover.stop({ reload = reload }) end)
        STATE.failover = nil
    end

    -- Phase 0b: revoke the state-reporter lease too, for the same
    -- reason — synchronous revoke makes the `<prefix>/state/by-name/
    -- <alias>` key disappear immediately on a graceful stop instead
    -- of waiting for the keepalive TTL. Observers (UI panels, other
    -- peers' diagnostics) see this instance go from "rw/ro" to
    -- "absent" within milliseconds rather than `keepalive_interval`
    -- seconds.
    if STATE.state_reporter ~= nil then
        pcall(function() STATE.state_reporter.stop() end)
        STATE.state_reporter = nil
    end

    -- Phase 1: flip the drain gate. New HTTP requests get 503 +
    -- Retry-After (Task 3a). /api/health stays open so load
    -- balancers can confirm the `degraded`/`stopping` state.
    local sh_ok, shutdown_mod = pcall(require, 'webui.http.shutdown')
    if sh_ok then
        shutdown_mod.mark_draining()
        logger.info('shutdown: draining',
            { inflight = shutdown_mod.inflight_count() })
    end

    -- Phase 2: wait for in-flight HTTP requests to finish, bounded
    -- by `roles_cfg.webui.shutdown_timeout` (default 5s). The wait
    -- wakes up exactly when the last request releases its slot.
    --
    -- The default is intentionally well under Tarantool's own
    -- `on_shutdown` grace and docker's default 10s SIGTERM window:
    -- 5s drain + the remaining teardown (audit / poller / peer
    -- pool / WS close) fits comfortably under both. Operators can
    -- raise this for long-running internal handlers — but pair the
    -- bump with `docker stop -t <N>` / Tarantool's own
    -- `shutdown_timeout` so the role is not cut off mid-drain.
    local drain_timeout = 5
    if STATE.config ~= nil and type(STATE.config.shutdown_timeout) == 'number' then
        drain_timeout = STATE.config.shutdown_timeout
    end
    if sh_ok then
        local drained = shutdown_mod.wait_drain(drain_timeout)
        if drained then
            logger.info('shutdown: in-flight drained')
        else
            logger.warn('shutdown: drain timeout, forcing close', {
                inflight = shutdown_mod.inflight_count(),
                timeout_sec = drain_timeout,
            })
        end
    end

    -- Phase 3: stop accepting new connections.
    local ok, err = pcall(function() http_srv.stop() end)
    if not ok then
        logger.error('http server stop raised', { err = tostring(err) })
    end

    -- Close every WebSocket subscriber with 1001 "Going Away"
    -- before stopping the producers. The shutdown call walks the
    -- registry and tells each per-connection fiber to drop. We
    -- swallow errors because the SPA is already disconnected
    -- by the time this runs in practice.
    local ws_ok_mod, ws_mod = pcall(require, 'webui.http.ws')
    if ws_ok_mod then pcall(function() ws_mod.shutdown() end) end

    -- Stop the audit retention fiber.
    if STATE.audit_retention ~= nil then
        pcall(function() STATE.audit_retention.stop() end)
        STATE.audit_retention = nil
    end

    -- Stop the notifications dispatcher fiber.
    if STATE.notifications ~= nil then
        pcall(function() STATE.notifications.stop() end)
        STATE.notifications = nil
    end

    -- Stop the suggestions scanner first — it reads state.snapshot()
    -- which the poller produces.
    local sg_ok, sg_err = pcall(function() suggestions_engine.stop() end)
    if not sg_ok then
        logger.warn('suggestions stop raised', { err = tostring(sg_err) })
    end

    -- Stop the issues scanner — same dependency as above.
    local is_ok, is_err = pcall(function() issues.stop() end)
    if not is_ok then
        logger.warn('issues stop raised', { err = tostring(is_err) })
    end

    -- Stop the poller before closing the pool: in-flight ticks
    -- still want to read connection state. The cluster.state cache
    -- itself does not need teardown — module-local tables are GC'd
    -- when require() drops them.
    local pl_ok, pl_err = pcall(function() poller.stop() end)
    if not pl_ok then
        logger.warn('poller stop raised', { err = tostring(pl_err) })
    end

    -- Close every outbound net.box connection before declaring stop.
    -- pcall protects against partial init paths where peers was
    -- imported but never refresh()'ed.
    local pp_ok, pp_err = pcall(function() peers.close_all() end)
    if not pp_ok then
        logger.warn('peer pool close raised', { err = tostring(pp_err) })
    end

    STATE.status = 'stopped'
    STATE.started_at = nil
    STATE.config = nil

    logger.info('webui role stopped')
    return true
end

return M
