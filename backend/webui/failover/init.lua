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
local timings = require('webui.failover.timings')

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

-- Resolved version-guard state, populated on M.start and exposed via
-- M.status() so the failover UI / diagnostics can show whether the
-- recommended supervised mode is in effect or the legacy fallback is.
local version_guard_state = nil

-- Does THIS Tarantool build accept `replication.failover: supervised`?
-- Checked against the live config jsonschema (the schema always matches
-- the running binary). Returns true / false / nil(unknown — schema
-- shape unexpected). There is intentionally no runtime auto-degrade:
-- the cluster config is validated by the platform at box.cfg time, so
-- a build that rejected `supervised` would never have booted this
-- instance. The guard's job is therefore detection + visibility:
-- surface a loud WARN + a status flag so operators switch deliberately.
function M.supervised_supported()
    local cfg_ok, cfg = pcall(require, 'config')
    if not cfg_ok then return nil end
    local ok, schema = pcall(function() return cfg:jsonschema() end)
    if not ok or type(schema) ~= 'table' then return nil end
    local props = schema.properties
    local node = props and props.replication
        and props.replication.properties
        and props.replication.properties.failover
    if type(node) ~= 'table' or type(node.enum) ~= 'table' then
        return nil
    end
    for _, v in ipairs(node.enum) do
        if v == 'supervised' then return true end
    end
    return false
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
    -- Version-guard: detect mode + whether supervised is supported, log
    -- loudly when the legacy fallback is active, and stash the verdict
    -- for M.status().
    do
        local cfg_ok, cfg = pcall(require, 'config')
        local mode = cfg_ok and (cfg:get('replication') or {}).failover or 'off'
        local supported = M.supervised_supported()
        version_guard_state = {
            mode = mode,
            supervised_supported = supported,
            fallback_active = (mode == 'off'),
        }
        if mode == 'off' then
            if supported == true then
                logger.warn('failover agent in legacy "off" mode while this '
                    .. 'build SUPPORTS supervised — switch '
                    .. 'replication.failover to supervised for '
                    .. 'RO-on-restart safety; until then critical spaces '
                    .. 'must be is_sync')
            else
                logger.warn('failover agent in legacy "off" fallback '
                    .. '(supervised unsupported/unknown on this build); '
                    .. 'ensure critical spaces are is_sync',
                    { supervised_supported = supported })
            end
        else
            logger.info('failover agent running under replication.failover',
                { mode = mode, supervised_supported = supported })
        end
    end
    -- FO-5: validate + auto-correct the lease/keepalive/probe timings
    -- against the canonical invariants before starting either loop. A
    -- triple that cannot satisfy keepalive + 2*probe <= lease_ttl even at
    -- the minimums is a hard stop — starting with degenerate timings is
    -- worse than not starting at all.
    local adj, warns, terr = timings.validate_and_adjust(opts)
    if terr ~= nil then
        logger.error('failover timing invariant violated; refusing to start',
            { reason = terr })
        return false, terr
    end
    for _, w in ipairs(warns) do
        logger.warn('failover timing adjusted', { detail = w })
    end

    local watch_ok, watch_err = watcher.start({
        poll_interval_sec = opts.watcher_poll_interval_sec,
        -- Self-fencing timings (FO-1). renew_deadline is derived inside
        -- the watcher as lease_ttl_sec - safety_margin. Corrected values
        -- (FO-5) are forwarded so the watcher and agent agree.
        lease_ttl_sec  = adj.ttl,
        safety_margin  = adj.safety_margin,
        probe_interval = adj.retry_timeout,
        -- FO-15 dead-man switch; on by default, operators may disable
        -- via roles_cfg.webui.failover.watchdog_enabled: false.
        watchdog_enabled = opts.watchdog_enabled,
        -- FO-16 failsafe; opt-in via roles_cfg.webui.failover.failsafe_enabled.
        failsafe_enabled = opts.failsafe_enabled,
        -- FO-7 push watch; on by default, degrades to poll if unavailable.
        watch_enabled = opts.watch_enabled,
        watch_idle_timeout = opts.watch_idle_timeout,
    })
    if watch_ok == nil then
        return false, 'watcher: ' .. tostring(watch_err)
    end
    local agent_ok, agent_err = agent.start({
        lease_ttl_sec      = adj.ttl,
        keepalive_interval = adj.loop_wait,
        probe_timeout_sec  = adj.retry_timeout,
        election_interval  = opts.election_interval,
        appointment_interval = opts.appointment_interval,
        -- FO-6 anti-flap tunables (all optional; antiflap falls back to
        -- its own defaults when unset).
        dampen_cycles         = opts.dampen_cycles,
        primary_start_timeout = opts.primary_start_timeout,
        suppress_threshold    = opts.suppress_threshold,
        suppress_window       = opts.suppress_window,
        suppress_cooldown     = opts.suppress_cooldown,
        promote_backoff_base  = opts.promote_backoff_base,
        min_misses            = opts.min_misses,
        phi_threshold         = opts.phi_threshold,
        phi_min_samples       = opts.phi_min_samples,
        phi_max_samples       = opts.phi_max_samples,
        phi_min_stddev        = opts.phi_min_stddev,
        -- FO-7 push watch.
        watch_enabled         = opts.watch_enabled,
        watch_idle_timeout    = opts.watch_idle_timeout,
        -- FO-18 weak-subjectivity rejoin guard.
        auto_rejoin_rebootstrap       = opts.auto_rejoin_rebootstrap,
        weak_subjectivity_max_term_gap = opts.weak_subjectivity_max_term_gap,
    })
    if agent_ok == nil then
        watcher.stop()
        return false, 'agent: ' .. tostring(agent_err)
    end
    logger.info('failover agent + watcher started')
    return true
end

-- Live-reconfigure the running agent + watcher from new role opts
-- WITHOUT dropping the coordinator lease or re-electing (the loops read
-- their config every tick; only the dead-man watchdog fiber is
-- restarted, which does not touch leadership). Called on config:reload
-- when failover tunables change. No-op if the agent isn't running.
function M.reconfigure(opts)
    opts = opts or {}
    if opts.agent ~= true then return false end
    -- FO-5: re-validate on reload too. If the new timings are
    -- unsatisfiable, keep the running config rather than applying a
    -- degenerate one (the loops stay on their last valid STATE.config).
    local adj, warns, terr = timings.validate_and_adjust(opts)
    if terr ~= nil then
        logger.error('failover timing invariant violated on reload; '
            .. 'keeping previous timings', { reason = terr })
        return false
    end
    for _, w in ipairs(warns) do
        logger.warn('failover timing adjusted (reload)', { detail = w })
    end
    local a = agent.reconfigure({
        lease_ttl_sec        = adj.ttl,
        keepalive_interval   = adj.loop_wait,
        probe_timeout_sec    = adj.retry_timeout,
        election_interval    = opts.election_interval,
        appointment_interval = opts.appointment_interval,
        dampen_cycles         = opts.dampen_cycles,
        primary_start_timeout = opts.primary_start_timeout,
        suppress_threshold    = opts.suppress_threshold,
        suppress_window       = opts.suppress_window,
        suppress_cooldown     = opts.suppress_cooldown,
        promote_backoff_base  = opts.promote_backoff_base,
        min_misses            = opts.min_misses,
        phi_threshold         = opts.phi_threshold,
        phi_min_samples       = opts.phi_min_samples,
        phi_max_samples       = opts.phi_max_samples,
        phi_min_stddev        = opts.phi_min_stddev,
        -- FO-7: forwarded for config consistency. The watch fiber's
        -- lifecycle is tied to start/stop (a live toggle needs a
        -- restart); reconfigure does not churn the stream.
        watch_enabled         = opts.watch_enabled,
        watch_idle_timeout    = opts.watch_idle_timeout,
        -- FO-18 weak-subjectivity rejoin guard (live-reconfigurable).
        auto_rejoin_rebootstrap       = opts.auto_rejoin_rebootstrap,
        weak_subjectivity_max_term_gap = opts.weak_subjectivity_max_term_gap,
    })
    local w = watcher.reconfigure({
        poll_interval_sec = opts.watcher_poll_interval_sec,
        lease_ttl_sec     = adj.ttl,
        safety_margin     = adj.safety_margin,
        probe_interval    = adj.retry_timeout,
        watchdog_enabled  = opts.watchdog_enabled,
        failsafe_enabled  = opts.failsafe_enabled,
        watch_enabled     = opts.watch_enabled,
        watch_idle_timeout = opts.watch_idle_timeout,
    })
    return a == true and w == true
end

-- M.stop(opts) — opts.reload is forwarded to agent.stop so a
-- config-reload-induced stop skips the synchro drain/demote (it would only
-- churn the raft term; the same instance re-takes its role immediately).
function M.stop(opts)
    agent.stop(opts)
    watcher.stop()
end

-- Full restart of the agent + watcher fibers: stop, then start fresh
-- from `opts`. Unlike reconfigure() (which keeps the coordinator lease
-- and only bounces the watchdog), this DROPS the lease and re-runs
-- start() — the loops restart and the coordinator re-elects on the next
-- tick. The recovery `restart_failover` action uses it to recover a
-- wedged agent fiber. `opts` is the same failover cfg block start() took
-- (the caller passes `STATE.config.failover`). Returns (started, err)
-- like start(); a disabled agent (`agent ~= true`) returns (false, ...).
function M.restart(opts)
    M.stop()
    return M.start(opts or {})
end

function M.status()
    return {
        agent         = agent.status(),
        watcher       = watcher.status(),
        version_guard = version_guard_state,
    }
end

return M
