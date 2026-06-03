--
-- Failover module — orchestrator for the agent + watcher pair.
--
-- The agent runs a coordinator-election loop on every instance and
-- a single elected coordinator writes appointments to etcd. The
-- watcher runs on every instance and applies whatever appointment
-- the coordinator wrote. Both are guarded by:
--
--   1. `roles_cfg.webui.failover.agent` must be `true`.
--   2. `replication.failover` must be `off` — Tarantool's own
--      raft / supervised loops would override our `box.cfg
--      .read_only` calls otherwise.
--   3. An etcd writer block must be configured (the same one used
--      by the WebUI commit path) so both modules can reach etcd.
--
-- This file owns the lifecycle: start() / stop() / status(). Other
-- subsystems (init.lua role bootstrap, GraphQL resolvers) talk
-- only through this façade.
--

local agent   = require('webui.failover.agent')
local watcher = require('webui.failover.watcher')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('failover')

local M = {}

M.AGENT   = agent
M.WATCHER = watcher

-- Validate that the cluster config is compatible with our agent.
-- Returns (true, nil) when safe to start, (false, reason) when not.
-- bootstrap strategies that keep box.cfg's RO/RW decision inside the
-- platform's "minimal-name bootstrap leader" path (the one the agent
-- relies on). `supervised`/`native` would route box.cfg into the
-- externally-managed branch that expects an EE coordinator protocol.
local AGENT_SAFE_BOOTSTRAP = {
    auto = true,
    legacy = true,
    config = true,
}

-- The agent drives leadership via box.ctl.promote/demote and needs a
-- failover mode where the platform does NOT run its own leader-election
-- loop. Two modes qualify:
--   * `supervised` (recommended) — the applier starts instances
--     read-only and leaves runtime RO/RW to an external agent (us);
--     election_mode stays `off`, so no raft fights us. Requires a
--     bootstrap strategy that keeps the minimal-name bootstrap path
--     (auto/legacy/config) and no `failover.replicasets.*.synchro_mode`
--     (which would force election_mode=manual).
--   * `off` (fallback) — legacy mode; kept working for builds that
--     might reject `supervised` on Community Edition.
-- `election`/`manual` are rejected: they manage leadership themselves
-- and would stomp our box.ctl calls.
local function check_preconditions()
    local cfg_ok, cfg = pcall(require, 'config')
    if not cfg_ok then
        return false, 'config module unavailable'
    end
    local repl = cfg:get('replication') or {}
    local mode = repl.failover or 'off'

    if mode == 'off' then
        return true
    end

    if mode ~= 'supervised' then
        return false, 'replication.failover must be "supervised" (recommended) '
            .. 'or "off" to run the agent (currently "' .. tostring(mode)
            .. '"). "election"/"manual" manage leadership themselves and '
            .. 'would fight the agent over box.cfg.read_only.'
    end

    -- supervised: verify the bootstrap strategy and synchro_mode are
    -- compatible with an external agent.
    local strategy = repl.bootstrap_strategy or 'auto'
    if not AGENT_SAFE_BOOTSTRAP[strategy] then
        return false, 'replication.bootstrap_strategy "' .. tostring(strategy)
            .. '" routes box.cfg into the externally-managed branch; '
            .. 'use auto/legacy/config with the agent.'
    end

    local fo = cfg:get('failover') or {}
    local replicasets = (type(fo) == 'table' and fo.replicasets) or {}
    if type(replicasets) == 'table' then
        for rs_name, rs in pairs(replicasets) do
            if type(rs) == 'table' and rs.synchro_mode then
                return false, 'failover.replicasets.' .. tostring(rs_name)
                    .. '.synchro_mode forces election_mode=manual, which '
                    .. 'conflicts with the agent; remove it.'
            end
        end
    end

    return true
end

function M.start(opts)
    opts = opts or {}
    if opts.agent ~= true then
        logger.info('agent disabled by config')
        return false, 'disabled'
    end
    local ok, why = check_preconditions()
    if not ok then
        logger.warn('agent precondition failed', { reason = why })
        return false, why
    end
    -- Version/mode transparency: surface which failover mode the agent
    -- is running under. `off` means the supervised fallback is active
    -- (e.g. a build that rejected `supervised`); operators should see
    -- this in the log rather than guess.
    do
        local cfg_ok, cfg = pcall(require, 'config')
        local mode = cfg_ok and (cfg:get('replication') or {}).failover or 'off'
        if mode == 'off' then
            logger.warn('failover agent running in legacy "off" mode '
                .. '(supervised recommended); RO-on-restart guarantees are '
                .. 'weaker — ensure critical spaces are is_sync')
        else
            logger.info('failover agent running under replication.failover',
                { mode = mode })
        end
    end
    local watch_ok, watch_err = watcher.start({
        poll_interval_sec = opts.watcher_poll_interval_sec,
    })
    if watch_ok == nil then
        return false, 'watcher: ' .. tostring(watch_err)
    end
    local agent_ok, agent_err = agent.start({
        lease_ttl_sec      = opts.lease_ttl_sec,
        keepalive_interval = opts.keepalive_interval,
        election_interval  = opts.election_interval,
        appointment_interval = opts.appointment_interval,
    })
    if agent_ok == nil then
        watcher.stop()
        return false, 'agent: ' .. tostring(agent_err)
    end
    logger.info('failover agent + watcher started')
    return true
end

function M.stop()
    agent.stop()
    watcher.stop()
end

function M.status()
    return {
        agent   = agent.status(),
        watcher = watcher.status(),
    }
end

return M
