--
-- Declarative role interface (Tarantool 3.x): apply config.
--
-- Called once on initial bootstrap and again on every cluster config
-- change that touches roles_cfg.webui. Internally re-routes to start
-- or to a stop/start cycle so a running role picks up new options
-- without the operator having to bounce the process.
--

local checks   = require('checks')

local log_util = require('webui.log_util')
local state    = require('webui.lifecycle.state')
local start    = require('webui.lifecycle.start')
local stop     = require('webui.lifecycle.stop')

local logger = log_util.with_tag('init')

local M = {}

function M.apply(cfg)
    checks('?table')
    cfg = cfg or {}

    state.configure_logging(cfg)
    logger.debug('apply requested', {
        first_apply = (state.STATE.status == 'uninitialized'),
        current_status = state.STATE.status,
    })

    if state.STATE.status == 'uninitialized' or state.STATE.status == 'stopped' then
        return start.start(cfg)
    end

    -- reload=true: this is a config roll, not a shutdown. The stop must
    -- NOT hand off leadership (demote) — the same instance restarts its
    -- role immediately below, and a demote/re-promote only churns the raft
    -- term (poisoning any peer mid-JOIN). See lifecycle/stop + failover
    -- agent.stop. Mirrors Patroni: reload never triggers a failover.
    local ok, err = stop.stop({ reload = true })
    if not ok then
        return nil, err
    end
    return start.start(cfg)
end

return M
