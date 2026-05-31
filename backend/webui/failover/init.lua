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
local function check_preconditions()
    local cfg_ok, cfg = pcall(require, 'config')
    if not cfg_ok then
        return false, 'config module unavailable'
    end
    local repl = cfg:get('replication') or {}
    local mode = repl.failover or 'off'
    if mode ~= 'off' then
        return false, 'replication.failover must be "off" to run the '
            .. 'agent (currently "' .. tostring(mode) .. '"). '
            .. 'Built-in raft / supervised loops would fight the agent '
            .. 'over box.cfg.read_only.'
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
