--
-- Issues scanner.
--
-- A daemon fiber periodically walks `cluster.state.snapshot()` and
-- builds a list of issues — short, structured findings the UI shows
-- on the cluster page. Categories covered in M1:
--
--   * `replication` — broken upstream / non-`follow` state /
--     `lag > sync_lag` / `idle > 2 * timeout`.
--   * `memory` — slab arena / items / quota ratios crossing
--     warning or critical thresholds.
--   * `clock` — wall-clock skew between peers above a threshold.
--   * `config` — pass-through of `config:info().alerts` per peer.
--
-- The scanner has no opinion on supervised-failover or vshard
-- alerts — those land in Task 46 (failover) and Task 47 (vshard)
-- respectively. The category list is exposed as a constant so
-- consumers (GraphQL enum, UI filter) stay in lockstep with the
-- rule set as more rules land.
--
-- Each issue carries a stable ID derived from (category, scope,
-- target, key) so the UI can correlate the same problem across
-- ticks without flicker. Severity is `warning` or `critical`.
--
-- Implementation split:
--
--   * Pure rule functions (`check_replication`, `check_memory`,
--     `check_clock`, `check_config`) take the snapshot + thresholds
--     and return a list of issues. No side effects, easy to test.
--   * `scan(snapshot, opts)` runs every rule and produces a sorted
--     deduplicated result.
--   * The fiber side (`start`/`stop`/`current`) is a tiny wrapper
--     that caches the latest scan output for resolvers.
--

local checks = require('checks')
local fiber  = require('fiber')

local state    = require('webui.cluster.state')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('issues')

local M = {}

-- Cadence — five seconds is the threshold suggested by the plan:
-- often enough to surface a regression within human reaction time,
-- rare enough not to compete with the cooperative poller (1.5s).
M.SCAN_INTERVAL_SEC = 5

M.CATEGORIES = {
    REPLICATION = 'replication',
    MEMORY      = 'memory',
    CLOCK       = 'clock',
    CONFIG      = 'config',
}

M.SEVERITY = {
    WARNING  = 'warning',
    CRITICAL = 'critical',
}

M.SCOPE = {
    CLUSTER    = 'cluster',
    REPLICASET = 'replicaset',
    INSTANCE   = 'instance',
}

-- Default thresholds. Operators can override via `start({thresholds={...}})`.
-- The values match Cartridge's defaults so on-call muscle memory carries
-- over without retraining.
M.DEFAULT_THRESHOLDS = {
    replication_sync_lag       = 10,    -- seconds; matches Cartridge
    replication_idle_factor    = 2,     -- multiplier of replication_timeout
    default_replication_timeout = 1,    -- seconds; Tarantool default
    arena_warn                 = 0.85,
    arena_critical             = 0.95,
    items_warn                 = 0.85,
    items_critical             = 0.95,
    quota_warn                 = 0.85,
    quota_critical             = 0.95,
    clock_delta_sec            = 5,
}

local SCANNER_STATE = {
    fiber          = nil,
    stop_flag      = false,
    last_snapshot  = nil,
    last_scan_at   = 0,
    thresholds     = nil,
}

-- ─────────────────────────────────────────────────────────────────────
-- Pure helpers
-- ─────────────────────────────────────────────────────────────────────

local function make_issue(opts)
    return {
        id          = opts.id,
        severity    = opts.severity,
        category    = opts.category,
        scope       = opts.scope,
        message     = opts.message,
        instance    = opts.instance,
        replicaset  = opts.replicaset,
        created_at  = opts.now,
        updated_at  = opts.now,
    }
end

-- Stable issue ID: `category:scope:target:key`. The target identifies
-- where the issue applies (instance alias for instance scope, replica-
-- set name for replicaset scope, "cluster" for cluster scope). `key`
-- disambiguates issues of the same category against the same target
-- (e.g., replication issues between tt-1 and tt-2 vs tt-1 and tt-3).
function M.make_id(category, scope, target, key)
    return string.format('%s:%s:%s:%s',
        tostring(category),
        tostring(scope),
        tostring(target or '_'),
        tostring(key or '_'))
end

-- ─────────────────────────────────────────────────────────────────────
-- Rules
-- ─────────────────────────────────────────────────────────────────────

-- Replication issues: per-server upstream / downstream entries.
-- The probe collects only the fields the scanner cares about
-- (status / lag / idle / message) so this rule is a straightforward
-- threshold check.
function M.check_replication(snapshot, thresholds, now)
    thresholds = thresholds or M.DEFAULT_THRESHOLDS
    now = now or fiber.clock()
    local out = {}
    for alias, server in pairs((snapshot and snapshot.servers) or {}) do
        if server.reachable and type(server.replication) == 'table' then
            for _, entry in pairs(server.replication) do
                local upstream = entry.upstream
                if upstream ~= nil then
                    if upstream.status == nil then
                        -- `upstream.status == nil` is the local
                        -- self-entry of box.info.replication; skip
                        -- without raising an issue. Explicit `_`
                        -- assignment keeps luacheck quiet.
                        local _ = nil
                    elseif upstream.status ~= 'follow' then
                        table.insert(out, make_issue {
                            id = M.make_id('replication', 'instance', alias,
                                'upstream-status-' .. tostring(entry.uuid or entry.id)),
                            category = M.CATEGORIES.REPLICATION,
                            severity = M.SEVERITY.CRITICAL,
                            scope    = M.SCOPE.INSTANCE,
                            instance = alias,
                            replicaset = server.replicaset_name,
                            message = string.format(
                                'replication upstream from %s is %s%s',
                                entry.uuid or '?',
                                tostring(upstream.status),
                                upstream.message and (': ' .. upstream.message) or ''),
                            now = now,
                        })
                    elseif type(upstream.lag) == 'number'
                        and upstream.lag > thresholds.replication_sync_lag then
                        table.insert(out, make_issue {
                            id = M.make_id('replication', 'instance', alias,
                                'lag-' .. tostring(entry.uuid or entry.id)),
                            category = M.CATEGORIES.REPLICATION,
                            severity = M.SEVERITY.WARNING,
                            scope    = M.SCOPE.INSTANCE,
                            instance = alias,
                            replicaset = server.replicaset_name,
                            message = string.format(
                                'replication lag %.2fs from %s exceeds threshold %.2fs',
                                upstream.lag, entry.uuid or '?',
                                thresholds.replication_sync_lag),
                            now = now,
                        })
                    elseif type(upstream.idle) == 'number'
                        and upstream.idle > thresholds.replication_idle_factor
                            * thresholds.default_replication_timeout then
                        table.insert(out, make_issue {
                            id = M.make_id('replication', 'instance', alias,
                                'idle-' .. tostring(entry.uuid or entry.id)),
                            category = M.CATEGORIES.REPLICATION,
                            severity = M.SEVERITY.WARNING,
                            scope    = M.SCOPE.INSTANCE,
                            instance = alias,
                            replicaset = server.replicaset_name,
                            message = string.format(
                                'replication idle %.2fs from %s exceeds %dx timeout',
                                upstream.idle, entry.uuid or '?',
                                thresholds.replication_idle_factor),
                            now = now,
                        })
                    end
                end
            end
        end
    end
    return out
end

-- Memory issues: arena / items / quota usage against warn/critical
-- thresholds. The state cache stores ratios as 0..1 fractions.
function M.check_memory(snapshot, thresholds, now)
    thresholds = thresholds or M.DEFAULT_THRESHOLDS
    now = now or fiber.clock()
    local out = {}
    local function emit(alias, server, ratio, kind, warn, critical, friendly)
        if type(ratio) ~= 'number' then return end
        local severity, threshold
        if ratio >= critical then
            severity, threshold = M.SEVERITY.CRITICAL, critical
        elseif ratio >= warn then
            severity, threshold = M.SEVERITY.WARNING, warn
        else
            return
        end
        table.insert(out, make_issue {
            id = M.make_id('memory', 'instance', alias, kind),
            category = M.CATEGORIES.MEMORY,
            severity = severity,
            scope    = M.SCOPE.INSTANCE,
            instance = alias,
            replicaset = server.replicaset_name,
            message = string.format(
                '%s memory usage %.1f%% exceeds %s threshold %.1f%%',
                friendly, ratio * 100, severity, threshold * 100),
            now = now,
        })
    end
    for alias, server in pairs((snapshot and snapshot.servers) or {}) do
        if server.reachable then
            emit(alias, server, server.arena_used_ratio, 'arena',
                thresholds.arena_warn, thresholds.arena_critical, 'arena')
            emit(alias, server, server.items_used_ratio, 'items',
                thresholds.items_warn, thresholds.items_critical, 'items')
            emit(alias, server, server.quota_used_ratio, 'quota',
                thresholds.quota_warn, thresholds.quota_critical, 'quota')
        end
    end
    return out
end

-- Clock skew issues. The local probe captures `clock.realtime()`
-- and the poller stores the value on each server entry. We pick
-- the local instance's clock as the reference; any peer drifting
-- by more than the threshold gets an issue.
function M.check_clock(snapshot, thresholds, now)
    thresholds = thresholds or M.DEFAULT_THRESHOLDS
    now = now or fiber.clock()
    snapshot = snapshot or { servers = {} }
    local self_alias = snapshot.self_alias
    local self_clock
    if self_alias ~= nil and snapshot.servers and snapshot.servers[self_alias] then
        self_clock = snapshot.servers[self_alias].clock
    end
    if type(self_clock) ~= 'number' then return {} end
    local out = {}
    for alias, server in pairs(snapshot.servers) do
        if alias ~= self_alias
            and server.reachable
            and type(server.clock) == 'number' then
            local delta = math.abs(server.clock - self_clock)
            if delta > thresholds.clock_delta_sec then
                table.insert(out, make_issue {
                    id = M.make_id('clock', 'instance', alias, 'skew'),
                    category = M.CATEGORIES.CLOCK,
                    severity = M.SEVERITY.WARNING,
                    scope    = M.SCOPE.INSTANCE,
                    instance = alias,
                    replicaset = server.replicaset_name,
                    message = string.format(
                        'clock skew %.2fs against %s exceeds threshold %.2fs',
                        delta, self_alias, thresholds.clock_delta_sec),
                    now = now,
                })
            end
        end
    end
    return out
end

-- Config issues: bubble up `config:info().alerts` reported by each
-- peer (we already collect them via the probe). The peer is the
-- authoritative source for its own config status.
function M.check_config(snapshot, _, now)
    now = now or fiber.clock()
    local out = {}
    for alias, server in pairs((snapshot and snapshot.servers) or {}) do
        if server.reachable and type(server.alerts) == 'table' then
            for idx, alert in ipairs(server.alerts) do
                local severity = M.SEVERITY.WARNING
                if alert.type == 'critical' or alert.type == 'error' then
                    severity = M.SEVERITY.CRITICAL
                end
                table.insert(out, make_issue {
                    id = M.make_id('config', 'instance', alias,
                        (alert.type or 'alert') .. '-' .. idx),
                    category = M.CATEGORIES.CONFIG,
                    severity = severity,
                    scope    = M.SCOPE.INSTANCE,
                    instance = alias,
                    replicaset = server.replicaset_name,
                    message = tostring(alert.message
                        or 'config alert without message'),
                    now = now,
                })
            end
        end
    end
    return out
end

-- Combine all rules. Output is sorted by (severity desc, id asc)
-- so the UI can show critical issues first; ties broken by ID for
-- deterministic ordering.
function M.scan(snapshot, opts)
    checks('?table', '?table')
    opts = opts or {}
    local thresholds = opts.thresholds or M.DEFAULT_THRESHOLDS
    local now = opts.now or fiber.clock()
    local result = {}
    for _, fn in ipairs({
        M.check_replication, M.check_memory,
        M.check_clock, M.check_config,
    }) do
        local rule_issues = fn(snapshot, thresholds, now)
        for _, issue in ipairs(rule_issues) do
            table.insert(result, issue)
        end
    end
    table.sort(result, function(a, b)
        if a.severity ~= b.severity then
            -- critical < warning when ordering lexicographically,
            -- which is exactly what we want.
            return a.severity < b.severity
        end
        return a.id < b.id
    end)
    return result
end

-- Aggregate counts for the issuesSummary GraphQL field.
function M.summarise(issues)
    checks('?table')
    local counts = { warning = 0, critical = 0, total = 0 }
    for _, issue in ipairs(issues or {}) do
        counts.total = counts.total + 1
        if issue.severity == M.SEVERITY.CRITICAL then
            counts.critical = counts.critical + 1
        else
            counts.warning = counts.warning + 1
        end
    end
    return counts
end

-- ─────────────────────────────────────────────────────────────────────
-- Fiber lifecycle
-- ─────────────────────────────────────────────────────────────────────

local function run_one_scan()
    local snap = state.snapshot()
    local issues = M.scan(snap, { thresholds = SCANNER_STATE.thresholds })
    local previous = SCANNER_STATE.last_snapshot or {}
    local prev_by_id = {}
    for _, issue in ipairs(previous) do prev_by_id[issue.id] = issue end
    local appeared, disappeared = 0, 0
    local new_by_id = {}
    for _, issue in ipairs(issues) do
        new_by_id[issue.id] = true
        if prev_by_id[issue.id] == nil then
            appeared = appeared + 1
            logger.info('issue appeared', {
                id = issue.id, severity = issue.severity,
                category = issue.category, message = issue.message,
            })
            if issue.severity == M.SEVERITY.CRITICAL then
                logger.warn('critical issue', {
                    id = issue.id, message = issue.message,
                })
            end
        end
    end
    for id, issue in pairs(prev_by_id) do
        if new_by_id[id] == nil then
            disappeared = disappeared + 1
            logger.info('issue cleared', {
                id = id, message = issue.message,
            })
        end
    end
    SCANNER_STATE.last_snapshot = issues
    SCANNER_STATE.last_scan_at  = fiber.clock()
    logger.debug('issues tick', {
        total       = #issues,
        appeared    = appeared,
        disappeared = disappeared,
    })

    -- Nudge WS subscribers on every scan that produced an
    -- appeared/disappeared transition. Lazy require keeps the
    -- scanner standalone for unit tests.
    if appeared > 0 or disappeared > 0 then
        local ws_ok, ws = pcall(require, 'webui.http.ws')
        if ws_ok then pcall(ws.broadcast) end
    end
end

function M.start(opts)
    checks('?table')
    opts = opts or {}
    SCANNER_STATE.thresholds = opts.thresholds or M.DEFAULT_THRESHOLDS
    if SCANNER_STATE.fiber ~= nil and SCANNER_STATE.fiber:status() ~= 'dead' then
        logger.warn('scanner already running', { id = SCANNER_STATE.fiber:id() })
        return SCANNER_STATE.fiber
    end
    SCANNER_STATE.stop_flag = false
    SCANNER_STATE.fiber = fiber.create(function()
        fiber.name('webui_issues_scanner', { truncate = true })
        local interval = opts.interval_sec or M.SCAN_INTERVAL_SEC
        logger.info('issues scanner started', { interval_sec = interval })
        while not SCANNER_STATE.stop_flag do
            local ok, err = pcall(run_one_scan)
            if not ok then
                logger.warn('issues tick raised', { err = tostring(err) })
            end
            fiber.sleep(interval)
        end
        logger.info('issues scanner stopped')
    end)
    return SCANNER_STATE.fiber
end

function M.stop()
    SCANNER_STATE.stop_flag = true
    if SCANNER_STATE.fiber ~= nil then
        pcall(function() SCANNER_STATE.fiber:cancel() end)
        SCANNER_STATE.fiber = nil
    end
end

-- The current cached scan output for resolvers. Returns a deep copy
-- so the GraphQL layer can sort / filter / paginate without racing
-- with the next tick.
function M.current()
    return table.deepcopy(SCANNER_STATE.last_snapshot or {})
end

function M.status()
    return {
        running       = SCANNER_STATE.fiber ~= nil
            and SCANNER_STATE.fiber:status() ~= 'dead',
        last_scan_at  = SCANNER_STATE.last_scan_at,
        issue_count   = #(SCANNER_STATE.last_snapshot or {}),
    }
end

-- Test hook. Production code never calls this.
function M._reset()
    M.stop()
    SCANNER_STATE.last_snapshot = nil
    SCANNER_STATE.last_scan_at  = 0
    SCANNER_STATE.thresholds    = nil
end

return M
