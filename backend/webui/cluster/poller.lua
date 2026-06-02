--
-- Peer poller fiber.
--
-- The poller is the single producer feeding cluster.state. It runs
-- one daemon fiber that wakes every POLL_INTERVAL_SEC, refreshes the
-- net.box pool, fans an inline `eval` probe out to every reachable
-- peer, joins the answers with the local `box.info` and pushes the
-- result into the state cache.
--
-- Failure handling:
--
--   * Unreachable peers are tagged with an exponential backoff: the
--     next poll skips them until `next_retry_at` has passed. The
--     backoff caps at MAX_BACKOFF_SEC so a permanently dead peer
--     does not chew CPU on retries while still being checked
--     occasionally.
--   * `pcall` wraps every tick body. Any unexpected raise becomes a
--     `warn` log and the fiber keeps its cadence — losing one tick
--     is preferable to crashing the poller.
--
-- Config-aware:
--
--   * `box.watch('config.info', cb)` registers a watcher that fires
--     an immediate extra tick whenever the cluster config changes
--     (config push, switch, rollback). Without this the poller
--     would still recover within POLL_INTERVAL_SEC, but the UI
--     would lag behind a successful config commit by exactly that
--     amount.
--

local checks = require('checks')
local fiber  = require('fiber')

local peers    = require('webui.cluster.peers')
local rpc      = require('webui.cluster.rpc')
local state    = require('webui.cluster.state')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('poller')

local M = {}

-- Cadence — every 1.5s by default. Aggressive enough to surface a
-- new replicaset member within a couple of seconds, slow enough not
-- to saturate the iproto thread.
M.POLL_INTERVAL_SEC = 1.5

-- Per-call deadline for the probe must be smaller than the cadence
-- or a stuck peer would push the next tick forever.
M.PROBE_TIMEOUT_SEC = 1.0

-- Exponential backoff. INITIAL is one extra tick; cap at MAX so a
-- dead peer is re-checked at least every 30 seconds in case its
-- failure was transient.
M.INITIAL_BACKOFF_SEC = 1.5
M.MAX_BACKOFF_SEC     = 30
M.MAX_BACKOFF_EXP     = 6

-- Probe payload — runs inside conn:eval() on the remote instance.
-- Keep the body small: every byte ships across the wire on every
-- tick. The `pcall` guards each box/config call so a missing field
-- on an older minor version does not blow up the whole probe.
M.PROBE_SRC = [[
    local function safe(fn)
        local ok, v = pcall(fn)
        if not ok then return nil end
        return v
    end
    local function map_alerts(alerts)
        if type(alerts) ~= 'table' then return {} end
        local out = {}
        for _, a in ipairs(alerts) do
            table.insert(out, {
                type = a.type,
                message = a.message,
            })
        end
        return out
    end
    -- box.info.replication is keyed by replica id (1..N); copy the
    -- subset the issues scanner needs (status/lag/idle/message) so
    -- the snapshot does not balloon to multi-megabyte at scale.
    local function map_replication(repl)
        if type(repl) ~= 'table' then return {} end
        local out = {}
        for id, r in pairs(repl) do
            out[tostring(id)] = {
                id   = r.id,
                uuid = r.uuid,
                lsn  = r.lsn,
                upstream = r.upstream and {
                    status   = r.upstream.status,
                    lag      = r.upstream.lag,
                    idle     = r.upstream.idle,
                    message  = r.upstream.message,
                    peer     = r.upstream.peer,
                } or nil,
                downstream = r.downstream and {
                    status  = r.downstream.status,
                    lag     = r.downstream.lag,
                    idle    = r.downstream.idle,
                    message = r.downstream.message,
                } or nil,
            }
        end
        return out
    end
    local info = box.info
    local cfg_ok, cfg = pcall(require, 'config')
    local cfg_info = cfg_ok and safe(function() return cfg:info() end) or nil
    local slab = safe(function() return box.slab.info() end)
    -- Storages that loaded vshard.storage expose buckets_count().
    -- Routers and non-vshard instances do not — keep the call guarded
    -- and let the field be nil when unavailable.
    local buckets_count = safe(function()
        local ok, vs = pcall(require, 'vshard.storage')
        if not ok or type(vs) ~= 'table' or type(vs.buckets_count) ~= 'function' then
            return nil
        end
        return vs.buckets_count()
    end)
    return {
        alias         = info.name,
        uuid          = info.uuid,
        version       = box.info.version,
        uptime        = info.uptime,
        ro            = info.ro,
        ro_reason     = info.ro_reason,
        status        = info.status,
        vclock        = info.vclock,
        clock         = safe(function() return require('clock').realtime() end),
        election      = safe(function() return info.election end),
        slab          = slab,
        buckets_count = buckets_count,
        replication   = map_replication(info.replication),
        replicaset    = safe(function()
            return info.replicaset and {
                name = info.replicaset.name,
                uuid = info.replicaset.uuid,
            } or nil
        end),
        config_status = type(cfg_info) == 'table' and cfg_info.status or nil,
        config_alerts = type(cfg_info) == 'table' and map_alerts(cfg_info.alerts) or {},
    }
]]

local STATE = {
    fiber          = nil,
    stop_flag      = false,
    backoff        = {},   -- [peer_name] = { attempt, next_retry_at }
    config_watcher = nil,
    tick_in_progress = false,
}

-- ─────────────────────────────────────────────────────────────────────
-- Pure helpers (unit-testable)
-- ─────────────────────────────────────────────────────────────────────

-- Compute the next backoff delay for a peer. `attempt >= 1` for the
-- first failure. Caps at MAX_BACKOFF_SEC so a permanently dead peer
-- still gets a retry every 30 seconds.
function M.compute_backoff_delay(attempt)
    checks('number')
    local capped_exp = math.min(attempt - 1, M.MAX_BACKOFF_EXP)
    local delay = M.INITIAL_BACKOFF_SEC * (2 ^ capped_exp)
    if delay > M.MAX_BACKOFF_SEC then delay = M.MAX_BACKOFF_SEC end
    return delay
end

-- Decide which peers to skip this tick because they are still in
-- their backoff window. Pure over inputs.
function M.peers_to_skip(backoff_state, now)
    checks('?table', 'number')
    local skip = {}
    for name, entry in pairs(backoff_state or {}) do
        if entry.next_retry_at and entry.next_retry_at > now then
            skip[name] = true
        end
    end
    return skip
end

-- Update the backoff map from the latest fan-out results. Pure: it
-- returns a new map and never mutates the input.
function M.update_backoff(backoff_state, results, now)
    checks('?table', '?table', 'number')
    local next_state = {}
    for name, entry in pairs(backoff_state or {}) do
        next_state[name] = { attempt = entry.attempt, next_retry_at = entry.next_retry_at }
    end
    for name, result in pairs(results or {}) do
        if result.ok then
            next_state[name] = nil  -- recovered, clear backoff
        else
            local entry = next_state[name] or { attempt = 0 }
            entry.attempt = entry.attempt + 1
            entry.next_retry_at = now + M.compute_backoff_delay(entry.attempt)
            next_state[name] = entry
        end
    end
    return next_state
end

-- ─────────────────────────────────────────────────────────────────────
-- Local probe (in-process, mirrors PROBE_SRC shape)
-- ─────────────────────────────────────────────────────────────────────

local function safe_call(fn)
    local ok, v = pcall(fn)
    if not ok then return nil end
    return v
end

local function map_replication(repl)
    if type(repl) ~= 'table' then return {} end
    local out = {}
    for id, r in pairs(repl) do
        out[tostring(id)] = {
            id   = r.id,
            uuid = r.uuid,
            lsn  = r.lsn,
            upstream = r.upstream and {
                status   = r.upstream.status,
                lag      = r.upstream.lag,
                idle     = r.upstream.idle,
                message  = r.upstream.message,
                peer     = r.upstream.peer,
            } or nil,
            downstream = r.downstream and {
                status  = r.downstream.status,
                lag     = r.downstream.lag,
                idle    = r.downstream.idle,
                message = r.downstream.message,
            } or nil,
        }
    end
    return out
end

local function collect_local_probe()
    if rawget(_G, 'box') == nil then return nil end
    local info = safe_call(function() return box.info end)
    if type(info) ~= 'table' then return nil end
    local cfg_ok, cfg = pcall(require, 'config')
    local cfg_info = cfg_ok and safe_call(function() return cfg:info() end) or nil
    local config_alerts = {}
    if type(cfg_info) == 'table' and type(cfg_info.alerts) == 'table' then
        for _, a in ipairs(cfg_info.alerts) do
            table.insert(config_alerts, { type = a.type, message = a.message })
        end
    end
    return {
        alias         = info.name,
        uuid          = info.uuid,
        version       = info.version,
        uptime        = info.uptime,
        ro            = info.ro,
        ro_reason     = info.ro_reason,
        status        = info.status,
        vclock        = info.vclock,
        clock         = safe_call(function() return require('clock').realtime() end),
        election      = safe_call(function() return info.election end),
        slab          = safe_call(function() return box.slab.info() end),
        buckets_count = safe_call(function()
            local ok, vs = pcall(require, 'vshard.storage')
            if not ok or type(vs) ~= 'table' or type(vs.buckets_count) ~= 'function' then
                return nil
            end
            return vs.buckets_count()
        end),
        replication   = map_replication(info.replication),
        replicaset    = safe_call(function()
            return info.replicaset and {
                name = info.replicaset.name,
                uuid = info.replicaset.uuid,
            } or nil
        end),
        config_status = type(cfg_info) == 'table' and cfg_info.status or nil,
        config_alerts = config_alerts,
    }
end

-- ─────────────────────────────────────────────────────────────────────
-- Tick — one poll cycle
-- ─────────────────────────────────────────────────────────────────────

local function tick()
    if STATE.tick_in_progress then
        -- Re-entrancy guard: an immediate-tick triggered by
        -- box.watch can collide with the daemon's cadence tick. Drop
        -- the duplicate; the cadence loop will pick the data up on
        -- its next iteration.
        return
    end
    STATE.tick_in_progress = true
    local refresh_ok, refresh_err = pcall(peers.refresh)
    if not refresh_ok then
        logger.warn('peers.refresh raised', { err = tostring(refresh_err) })
    end

    local now = fiber.clock()
    local skip = M.peers_to_skip(STATE.backoff, now)

    -- Whitelist = current pool minus peers still in backoff window.
    -- Without the whitelist, every tick would hammer dead peers and
    -- waste 1s of wait_result time each.
    local pool = peers.list()
    local active = {}
    for name in pairs(pool) do
        if not skip[name] then table.insert(active, name) end
    end

    local probed = {}
    if #active > 0 then
        local rpc_ok, rpc_results = pcall(rpc.map_eval, M.PROBE_SRC, {}, {
            timeout = M.PROBE_TIMEOUT_SEC,
            peers   = active,
        })
        if rpc_ok then probed = rpc_results end
    end

    -- Backoff is updated only for peers we actually probed this
    -- tick — skipping a peer that is in its backoff window does
    -- not count as a fresh failure, otherwise the attempt counter
    -- would grow on every tick and the backoff would explode.
    STATE.backoff = M.update_backoff(STATE.backoff, probed, now)

    -- Build the per-tick result map fed into state.apply_tick.
    -- Skipped peers appear as backoff so the UI can render
    -- "retrying in N seconds"; probed peers carry their actual
    -- outcome.
    local results = {}
    for name in pairs(skip) do
        results[name] = { ok = false, err = 'backoff' }
    end
    for name, res in pairs(probed) do
        results[name] = res
    end

    -- Topology fed into state.apply_tick. cfg:instances() returns
    -- only {group_name, instance_name, replicaset_name} — no URI —
    -- so the Server.uri column on /cluster used to render empty.
    -- Augment each entry with the advertised peer URI looked up via
    -- cfg:instance_uri('peer', {instance = name}) so the table
    -- shows where each instance is reachable.
    local topology = {}
    local cfg_ok, cfg = pcall(require, 'config')
    if cfg_ok then
        local instances_ok, instances = pcall(function() return cfg:instances() end)
        if instances_ok and type(instances) == 'table' then
            for name, meta in pairs(instances) do
                local entry = {
                    group_name      = meta.group_name,
                    instance_name   = meta.instance_name,
                    replicaset_name = meta.replicaset_name,
                }
                local uri_ok, uri_info = pcall(function()
                    return cfg:instance_uri('peer', { instance = name })
                end)
                if uri_ok and type(uri_info) == 'table' then
                    entry.uri = uri_info.uri
                end
                topology[name] = entry
            end
        end
    end

    local self_alias = peers.self_alias()
    state.apply_tick({
        self_alias   = self_alias,
        local_probe  = collect_local_probe(),
        peer_results = results,
        topology     = topology,
        backoff      = STATE.backoff,
        now          = now,
    })

    -- Wake WebSocket subscribers. The module is loaded lazily so
    -- the poller stays operational even if the WS layer fails to
    -- build (no rock dependency hard-coded into the poll loop).
    local ws_ok, ws = pcall(require, 'webui.http.ws')
    if ws_ok then pcall(ws.broadcast) end

    -- Log fresh probe failures only — skipped peers already have a
    -- backoff window and are not interesting to re-warn every tick.
    for name, res in pairs(probed) do
        if not res.ok then
            logger.warn('peer probe failed', {
                peer    = name,
                err     = res.err,
                attempt = STATE.backoff[name] and STATE.backoff[name].attempt or 0,
            })
        end
    end
    logger.debug('poller tick', {
        active = #active,
        skipped = (function()
            local n = 0; for _ in pairs(skip) do n = n + 1 end; return n
        end)(),
        generation = state.generation(),
    })

    STATE.tick_in_progress = false
end

-- ─────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────

function M.start(opts)
    checks('?table')
    opts = opts or {}
    if STATE.fiber ~= nil and STATE.fiber:status() ~= 'dead' then
        logger.warn('poller already running', { id = STATE.fiber:id() })
        return STATE.fiber
    end

    STATE.stop_flag = false
    STATE.backoff = {}

    STATE.fiber = fiber.create(function()
        fiber.name('webui_poller', { truncate = true })
        local interval = opts.interval_sec or M.POLL_INTERVAL_SEC
        logger.info('poller started', {
            interval_sec = interval,
            probe_timeout_sec = M.PROBE_TIMEOUT_SEC,
        })
        while not STATE.stop_flag do
            local ok, err = pcall(tick)
            if not ok then
                logger.warn('poller tick raised', { err = tostring(err) })
                STATE.tick_in_progress = false
            end
            -- fiber.sleep returns early when the fiber is cancelled,
            -- so the stop flag is honoured within ~one interval.
            fiber.sleep(interval)
        end
        logger.info('poller stopped')
    end)

    -- An immediate-tick hook on every config change keeps the cache
    -- in lockstep with the cluster config. The watcher fires on the
    -- watcher's own fiber; spawn the tick in a fresh fiber so the
    -- watcher returns promptly.
    local watcher_ok, watcher = pcall(function()
        return box.watch('config.info', function(_, info)
            logger.info('config.info changed; scheduling immediate poll', {
                status = (type(info) == 'table') and info.status or nil,
            })
            fiber.create(function()
                fiber.name('webui_poller_immediate', { truncate = true })
                local ok, err = pcall(tick)
                if not ok then
                    logger.warn('immediate poll tick raised', { err = tostring(err) })
                    STATE.tick_in_progress = false
                end
            end)
        end)
    end)
    if watcher_ok then
        STATE.config_watcher = watcher
    else
        logger.warn('failed to register config.info watcher', {
            err = tostring(watcher),
        })
    end

    return STATE.fiber
end

function M.stop()
    STATE.stop_flag = true
    if STATE.config_watcher ~= nil then
        pcall(function() STATE.config_watcher:unregister() end)
        STATE.config_watcher = nil
    end
    if STATE.fiber ~= nil then
        -- The daemon checks the flag once per tick; cancel makes
        -- the sleeping fiber wake up immediately so stop() is fast.
        pcall(function() STATE.fiber:cancel() end)
        STATE.fiber = nil
    end
end

function M.status()
    return {
        running        = STATE.fiber ~= nil and STATE.fiber:status() ~= 'dead',
        last_tick_at   = state.last_tick_at(),
        generation     = state.generation(),
        backoff_count  = (function()
            local n = 0; for _ in pairs(STATE.backoff) do n = n + 1 end; return n
        end)(),
    }
end

-- Test hook. Production code never calls this.
function M._reset()
    M.stop()
    STATE.backoff = {}
    STATE.tick_in_progress = false
end

return M
