--
-- Suggestions engine.
--
-- The poller surfaces facts (`box.info`, `config:info()`), the
-- issues scanner converts a subset of those facts into human-
-- readable diagnostics, and the suggestions engine sits one level
-- up: it decides which automated recovery the UI should offer for
-- the current cluster state, and how to execute it when the
-- operator clicks the action button.
--
-- The plan's full set of suggestion types is exposed on the
-- GraphQL surface so the frontend schema is stable. M1 only
-- implements the two rules + actions that the available
-- subsystems can support:
--
--   * `force_apply` — a peer's `config:info().status` is not
--     "ready". Recovery: call `require('config'):reload()` on
--     the affected peer over net.box.
--   * `restart_replication` — at least one upstream on a peer is
--     not in the `follow` state. Recovery: re-apply the
--     replication URI list (`box.cfg{replication=box.cfg.replication}`),
--     which forces Tarantool to drop and rebuild the upstreams.
--
-- The remaining types (refresh_vshard, disable_server,
-- refine_uri, restart_failover, bootstrap_vshard) get empty
-- detector lists today; their rules will fill in as Task 30
-- (etcd / config edit), Task 46 (failover) and Task 47 (vshard)
-- land.
--
-- The scanner fiber runs at the same cadence as the issues
-- scanner (5s) and shares the same lifecycle pattern:
-- `start/stop/current/status`. Per-call dispatch lives in
-- `apply(...)`.
--

local checks = require('checks')
local fiber  = require('fiber')

local peers    = require('webui.cluster.peers')
local rpc      = require('webui.cluster.rpc')
local state    = require('webui.cluster.state')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('suggestions')

local M = {}

M.SCAN_INTERVAL_SEC = 5

M.TYPES = {
    FORCE_APPLY         = 'force_apply',
    RESTART_REPLICATION = 'restart_replication',
    REFRESH_VSHARD      = 'refresh_vshard',
    DISABLE_SERVER      = 'disable_server',
    REFINE_URI          = 'refine_uri',
    RESTART_FAILOVER    = 'restart_failover',
    BOOTSTRAP_VSHARD    = 'bootstrap_vshard',
}

local SCANNER = {
    fiber       = nil,
    stop_flag   = false,
    last_result = nil,
    last_at     = 0,
}

-- ─────────────────────────────────────────────────────────────────────
-- Pure detectors
-- ─────────────────────────────────────────────────────────────────────

-- Collect aliases (and UUIDs when known) of peers whose config has
-- not converged. The action restarts `config:reload()` on each.
function M.detect_force_apply(snapshot)
    snapshot = snapshot or { servers = {} }
    local affected = {}
    for alias, server in pairs(snapshot.servers or {}) do
        if server.reachable
            and server.config_status ~= nil
            and server.config_status ~= 'ready' then
            table.insert(affected, {
                alias = alias,
                uuid  = server.uuid,
                config_status = server.config_status,
            })
        end
    end
    table.sort(affected, function(a, b) return a.alias < b.alias end)
    if #affected == 0 then return {} end
    -- One suggestion per affected peer keeps the UI fan-out
    -- straightforward — the operator can dismiss one without
    -- losing the others. The action handler still accepts a
    -- batch.
    local out = {}
    for _, entry in ipairs(affected) do
        table.insert(out, {
            id     = 'force_apply:' .. tostring(entry.uuid or entry.alias),
            alias  = entry.alias,
            uuid   = entry.uuid,
            reason = string.format('config status is %s', entry.config_status),
        })
    end
    return out
end

-- Collect aliases / UUIDs of peers reporting a broken upstream
-- replicator. The action re-applies `box.cfg.replication` which
-- forces Tarantool to drop and rebuild upstreams.
function M.detect_restart_replication(snapshot)
    snapshot = snapshot or { servers = {} }
    local affected = {}
    for alias, server in pairs(snapshot.servers or {}) do
        if server.reachable and type(server.replication) == 'table' then
            local broken = nil
            for _, entry in pairs(server.replication) do
                local upstream = entry.upstream
                if upstream ~= nil and upstream.status ~= nil
                    and upstream.status ~= 'follow' then
                    -- Pick the first broken upstream for the
                    -- suggestion message; the action restarts
                    -- every upstream regardless.
                    broken = {
                        peer_uuid = entry.uuid,
                        status    = upstream.status,
                        message   = upstream.message,
                    }
                    break
                end
            end
            if broken ~= nil then
                table.insert(affected, {
                    alias  = alias,
                    uuid   = server.uuid,
                    reason = string.format(
                        'replication from %s is %s%s',
                        tostring(broken.peer_uuid or '?'),
                        tostring(broken.status),
                        broken.message and (': ' .. broken.message) or ''),
                })
            end
        end
    end
    table.sort(affected, function(a, b) return a.alias < b.alias end)
    local out = {}
    for _, entry in ipairs(affected) do
        table.insert(out, {
            id     = 'restart_replication:' .. tostring(entry.uuid or entry.alias),
            alias  = entry.alias,
            uuid   = entry.uuid,
            reason = entry.reason,
        })
    end
    return out
end

-- The remaining detectors return an empty list — the underlying
-- subsystems are not implemented yet. Keeping them named here
-- (rather than absent) makes the GraphQL surface stable and the
-- plug-in points obvious.
function M.detect_refresh_vshard(_)    return {} end
function M.detect_disable_server(_)    return {} end
function M.detect_refine_uri(_)        return {} end
function M.detect_restart_failover(_)  return {} end
function M.detect_bootstrap_vshard(_)  return {} end

-- Combine every detector into one map. Keys mirror the GraphQL
-- field names so the resolver can return the struct as-is.
function M.scan(snapshot)
    return {
        force_apply         = M.detect_force_apply(snapshot),
        restart_replication = M.detect_restart_replication(snapshot),
        refresh_vshard      = M.detect_refresh_vshard(snapshot),
        disable_server      = M.detect_disable_server(snapshot),
        refine_uri          = M.detect_refine_uri(snapshot),
        restart_failover    = M.detect_restart_failover(snapshot),
        bootstrap_vshard    = M.detect_bootstrap_vshard(snapshot),
    }
end

-- ─────────────────────────────────────────────────────────────────────
-- Action dispatch
-- ─────────────────────────────────────────────────────────────────────

-- Translate a list of target UUIDs (or aliases) into the alias
-- whitelist `rpc.map_eval` accepts. Pure: tests pass the snapshot
-- explicitly.
function M.resolve_targets(snapshot, uuids)
    checks('?table', '?table')
    snapshot = snapshot or { servers = {} }
    uuids = uuids or {}
    local by_uuid = {}
    for alias, server in pairs(snapshot.servers or {}) do
        if server.uuid ~= nil then
            by_uuid[server.uuid] = alias
        end
    end
    local resolved, unknown = {}, {}
    for _, uuid in ipairs(uuids) do
        local alias = by_uuid[uuid]
        if alias ~= nil then
            table.insert(resolved, alias)
        else
            -- Treat an unknown UUID as a possibly-still-valid
            -- alias so an operator who types an alias into the
            -- action call does not get a silent miss. The pool
            -- itself will return `not connected` for a truly
            -- bogus name.
            local self_alias = snapshot.self_alias
            if uuid == self_alias then
                table.insert(resolved, self_alias)
            elseif snapshot.servers and snapshot.servers[uuid] ~= nil then
                table.insert(resolved, uuid)
            else
                table.insert(unknown, uuid)
            end
        end
    end
    table.sort(resolved)
    return { aliases = resolved, unknown = unknown }
end

local FORCE_APPLY_EXPR = [[
    local cfg = require('config')
    cfg:reload()
    return { status = cfg:info().status }
]]

local RESTART_REPLICATION_EXPR = [[
    box.cfg{ replication = box.cfg.replication }
    return { upstream_count = #(box.info.replication or {}) }
]]

local function execute(expr, aliases)
    if #aliases == 0 then
        return {}
    end
    return rpc.map_eval(expr, {}, {
        timeout = 5,
        peers   = aliases,
    })
end

-- Apply a suggestion. The dispatch is small and explicit because
-- the action space is going to grow with M2/M5/M6 and a registry
-- pattern would just hide the per-type contract.
function M.apply(type_, payload, opts)
    checks('string', '?table', '?table')
    opts = opts or {}
    payload = payload or {}
    local snapshot = opts.snapshot or state.snapshot()
    local target_uuids = payload.instance_uuids or payload.uuids or {}
    local resolved = M.resolve_targets(snapshot, target_uuids)
    if type_ == M.TYPES.FORCE_APPLY then
        local results = execute(FORCE_APPLY_EXPR, resolved.aliases)
        logger.info('applied force_apply suggestion', {
            targets = resolved.aliases,
            unknown = resolved.unknown,
            count   = #resolved.aliases,
        })
        return { ok = true, results = results, unknown = resolved.unknown }
    elseif type_ == M.TYPES.RESTART_REPLICATION then
        local results = execute(RESTART_REPLICATION_EXPR, resolved.aliases)
        logger.info('applied restart_replication suggestion', {
            targets = resolved.aliases,
            unknown = resolved.unknown,
            count   = #resolved.aliases,
        })
        return { ok = true, results = results, unknown = resolved.unknown }
    end
    return nil, string.format('suggestion type %q is not implemented yet', type_)
end

-- ─────────────────────────────────────────────────────────────────────
-- Fiber lifecycle (mirrors issues scanner)
-- ─────────────────────────────────────────────────────────────────────

local function run_one_scan()
    local snap = state.snapshot()
    local result = M.scan(snap)
    SCANNER.last_result = result
    SCANNER.last_at     = fiber.clock()
    local total = 0
    for _, list in pairs(result) do total = total + #list end
    logger.debug('suggestions tick', { total = total })
end

function M.start(opts)
    checks('?table')
    opts = opts or {}
    if SCANNER.fiber ~= nil and SCANNER.fiber:status() ~= 'dead' then
        return SCANNER.fiber
    end
    SCANNER.stop_flag = false
    SCANNER.fiber = fiber.create(function()
        fiber.name('webui_suggestions_scanner', { truncate = true })
        local interval = opts.interval_sec or M.SCAN_INTERVAL_SEC
        logger.info('suggestions scanner started', { interval_sec = interval })
        while not SCANNER.stop_flag do
            local ok, err = pcall(run_one_scan)
            if not ok then
                logger.warn('suggestions tick raised', { err = tostring(err) })
            end
            fiber.sleep(interval)
        end
        logger.info('suggestions scanner stopped')
    end)
    return SCANNER.fiber
end

function M.stop()
    SCANNER.stop_flag = true
    if SCANNER.fiber ~= nil then
        pcall(function() SCANNER.fiber:cancel() end)
        SCANNER.fiber = nil
    end
end

function M.current()
    return table.deepcopy(SCANNER.last_result or M.scan(nil))
end

function M.status()
    return {
        running     = SCANNER.fiber ~= nil
            and SCANNER.fiber:status() ~= 'dead',
        last_scan_at = SCANNER.last_at,
    }
end

function M._reset()
    M.stop()
    SCANNER.last_result = nil
    SCANNER.last_at     = 0
end

-- For unit tests that want to call apply() without mock'ing the
-- pool. Production code never reads this.
M._FORCE_APPLY_EXPR         = FORCE_APPLY_EXPR
M._RESTART_REPLICATION_EXPR = RESTART_REPLICATION_EXPR
M._peers_module             = peers  -- exposed for diagnostic dumps

return M
