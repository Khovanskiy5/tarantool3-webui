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

-- Disable-server suggestion (Task 5.15). A peer that has been
-- unreachable for more than DISABLE_SERVER_DOWNTIME_SEC is a hot
-- candidate for setInstanceState(enabled: false): the supervised
-- agent stops considering it for promotion, so the cluster does
-- not spend cycles probing a corpse. The operator can re-enable
-- once the peer is back.
M.DISABLE_SERVER_DOWNTIME_SEC = 300  -- 5 minutes; matches Cartridge

function M.detect_disable_server(snapshot)
    snapshot = snapshot or { servers = {} }
    local now = require('fiber').time()
    local out = {}
    for alias, server in pairs(snapshot.servers or {}) do
        if server.reachable == false
            and type(server.last_seen) == 'number'
            and server.last_seen > 0
            and (now - server.last_seen) >= M.DISABLE_SERVER_DOWNTIME_SEC then
            local downtime = now - server.last_seen
            table.insert(out, {
                id     = 'disable_server:' .. tostring(server.uuid or alias),
                alias  = alias,
                uuid   = server.uuid,
                reason = string.format(
                    'unreachable for %ds — exclude from agent score map ' ..
                    'until it recovers',
                    math.floor(downtime)),
            })
        end
    end
    table.sort(out, function(a, b) return a.alias < b.alias end)
    return out
end

-- The remaining detectors return an empty list — they require
-- probe-layer fields that we do not yet surface (advertise_uri for
-- refine_uri; synchro.queue.len for restart_failover; vshard
-- topology data for refresh / bootstrap). Wired as no-ops to keep
-- the GraphQL surface stable; will fill in once the probe schema
-- expands in Phase F/G.
function M.detect_refresh_vshard(_)    return {} end
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

-- Force-reset every upstream by detaching and re-attaching the
-- replication URI list. `box.cfg{replication=box.cfg.replication}`
-- alone is a no-op for sockets that are already established —
-- Tarantool short-circuits on equality. Going through the empty list
-- tears every connection down, then re-attaching forces a fresh
-- handshake. This recovers from transient-network outages.
--
-- IMPORTANT: this is NOT enough to fix a real split-brain (lsn
-- divergence) — those report `upstream.status == 'stopped'` with a
-- reason like "Split-Brain discovered". Surface still-stopped peers
-- in the result so the UI can render a clear "manual rebootstrap
-- required" hint instead of pretending the click solved it.
local RESTART_REPLICATION_EXPR = [[
    local saved = box.cfg.replication
    pcall(function() box.cfg{ replication = {} } end)
    pcall(function() box.cfg{ replication = saved } end)
    local still_stopped = {}
    for _, r in pairs(box.info.replication or {}) do
        if r.upstream and r.upstream.status == 'stopped' then
            table.insert(still_stopped, {
                id     = r.id,
                uuid   = r.uuid,
                reason = r.upstream.message or 'stopped',
            })
        end
    end
    return {
        upstream_count = #(box.info.replication or {}),
        still_stopped  = still_stopped,
        recovered      = #still_stopped == 0,
    }
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

-- Split the affected aliases into peers already in split-brain (a
-- reconnect cycle won't help — Tarantool would just hit the same
-- conflicting term next applier round, so they escalate straight to
-- rebootstrap) and the rest, which get the regular reconnect path.
-- Returns (split_brain_peers set, reconnect_peers list).
local function classify_split_brain(snapshot, aliases)
    local split_brain_peers = {}
    local reconnect_peers = {}
    for _, alias in ipairs(aliases) do
        local server = snapshot.servers and snapshot.servers[alias]
        local broken_reason = nil
        if server and type(server.replication) == 'table' then
            for _, entry in pairs(server.replication) do
                if entry.upstream and entry.upstream.status ~= 'follow' then
                    broken_reason = entry.upstream.message or ''
                    break
                end
            end
        end
        if broken_reason ~= nil
            and broken_reason:lower():find('split.brain', 1, false) then
            split_brain_peers[alias] = true
        else
            table.insert(reconnect_peers, alias)
        end
    end
    return split_brain_peers, reconnect_peers
end

-- Reconnect-cycle the non-split-brain peers and tally outcomes.
-- Late-detected split-brain (applier came back STOPPED with a
-- split-brain reason after our reconnect) is folded into the passed
-- `split_brain_peers` set for escalation. Returns (results, recovered,
-- still_stopped, peer_fail).
local function run_reconnect(reconnect_peers, split_brain_peers)
    local results = execute(RESTART_REPLICATION_EXPR, reconnect_peers)
    local recovered, still_stopped, peer_fail = 0, {}, {}
    for peer, r in pairs(results or {}) do
        if not (r and r.ok) then
            table.insert(peer_fail, peer .. '=' ..
                tostring(r and r.err or 'unknown'))
        else
            local v = r.value or {}
            if v.recovered == true then
                recovered = recovered + 1
            end
            if type(v.still_stopped) == 'table' and #v.still_stopped > 0 then
                for _, s in ipairs(v.still_stopped) do
                    local reason = tostring(s.reason or '')
                    table.insert(still_stopped, string.format(
                        '%s upstream id=%s: %s',
                        peer, tostring(s.id), reason))
                    if reason:lower():find('split.brain', 1, false) then
                        split_brain_peers[peer] = true
                    end
                end
            end
        end
    end
    return results, recovered, still_stopped, peer_fail
end

-- Auto-escalate: any peer reporting "Split-Brain" gets a rebootstrap
-- kick. The receiver refuses if the peer owns the synchro queue
-- (Phase 5 contract), so a healthy queue-owner cannot be wiped by
-- accident. Self-loop: rpc.map_eval excludes the current instance, so
-- for the self peer we call the global directly so the operator can
-- recover the very peer they are connected to. Returns (rebooted,
-- reboot_fail) lists.
local function escalate_rebootstrap(split_brain_peers)
    local self_alias
    if box.info and box.info.name then self_alias = box.info.name end
    local rebooted, reboot_fail = {}, {}
    for peer in pairs(split_brain_peers) do
        if peer == self_alias then
            local fn = rawget(_G, 'webui_rebootstrap_remote')
            if type(fn) == 'function' then
                local ok_self, res_self = pcall(fn)
                if ok_self and (res_self == nil or res_self.err == nil) then
                    table.insert(rebooted, peer)
                else
                    table.insert(reboot_fail, peer .. '=' ..
                        tostring((res_self and res_self.err) or res_self or 'self-call failed'))
                end
            else
                table.insert(reboot_fail, peer .. '=no rebootstrap rpc on self')
            end
        else
            local ok_reboot, reboot_res = pcall(rpc.map_eval,
                'return _G.webui_rebootstrap_remote and ' ..
                '_G.webui_rebootstrap_remote() or { err = "no rebootstrap rpc" }',
                {}, { timeout = 5, peers = { peer } })
            if not ok_reboot or type(reboot_res) ~= 'table'
                or reboot_res[peer] == nil then
                table.insert(reboot_fail, peer .. '=transport-err')
            else
                local rr = reboot_res[peer]
                if rr.ok and rr.value and rr.value.err == nil then
                    table.insert(rebooted, peer)
                else
                    table.insert(reboot_fail, peer .. '=' ..
                        tostring((rr.value and rr.value.err) or rr.err or 'unknown'))
                end
            end
        end
    end
    return rebooted, reboot_fail
end

-- ── Per-suggestion-type handlers ────────────────────────────────────
-- Uniform signature (resolved, snapshot, opts) → (result, nil) | (nil,
-- err) so M.apply can dispatch through a table.

local function apply_force_apply(resolved, _snapshot, _opts)
    local results = execute(FORCE_APPLY_EXPR, resolved.aliases)
    logger.info('applied force_apply suggestion', {
        targets = resolved.aliases,
        unknown = resolved.unknown,
        count   = #resolved.aliases,
    })
    return { ok = true, results = results, unknown = resolved.unknown }
end

local function apply_restart_replication(resolved, snapshot, _opts)
    local split_brain_peers, reconnect_peers =
        classify_split_brain(snapshot, resolved.aliases)
    local results, recovered, still_stopped, peer_fail =
        run_reconnect(reconnect_peers, split_brain_peers)
    local rebooted, reboot_fail = escalate_rebootstrap(split_brain_peers)

    local parts = {}
    if recovered > 0 then
        table.insert(parts, string.format('reconnected on %d peer(s)',
            recovered))
    end
    if #rebooted > 0 then
        table.insert(parts, string.format(
            'split-brain detected, dispatched rebootstrap to: %s ' ..
            '(container will restart and bootstrap clean from the leader)',
            table.concat(rebooted, ', ')))
    end
    if #reboot_fail > 0 then
        table.insert(parts, 'rebootstrap failures: ' ..
            table.concat(reboot_fail, '; '))
    end
    if #still_stopped > 0 and #rebooted == 0 then
        table.insert(parts, string.format(
            'STILL STOPPED on %d upstream(s): %s — manual rebootstrap ' ..
            'required (POST /api/diagnostics/rebootstrap)',
            #still_stopped, table.concat(still_stopped, '; ')))
    end
    if #peer_fail > 0 then
        table.insert(parts, 'peer error(s): ' ..
            table.concat(peer_fail, '; '))
    end
    if #parts == 0 then
        table.insert(parts, string.format(
            'dispatched to %d peer(s)', #resolved.aliases))
    end
    logger.info('applied restart_replication suggestion', {
        targets       = resolved.aliases,
        unknown       = resolved.unknown,
        count         = #resolved.aliases,
        recovered     = recovered,
        still_stopped = #still_stopped,
    })
    return {
        ok      = #still_stopped == 0 and #peer_fail == 0,
        message = table.concat(parts, '; '),
        results = results,
        unknown = resolved.unknown,
    }
end

-- Disable-server suggestion (Task 5.15): mark each affected alias in the
-- etcd `<prefix>/failover/disabled/<alias>` set via the same
-- `failover.disabled` module the agent reads each coordinator tick. We
-- deliberately do NOT go through the GraphQL setInstanceState resolver:
-- the caller already passed the RBAC gate on applyDisableServer (admin),
-- and this runs from the suggestions-engine context with no root.user.
local function apply_disable_server(resolved, _snapshot, opts)
    local ok_etcd, etcd_client = pcall(require, 'webui.config_store.client')
    local ok_disabled, disabled = pcall(require, 'webui.failover.disabled')
    if not (ok_etcd and ok_disabled) then
        return nil, 'failover.disabled module unavailable'
    end
    local client, client_err = etcd_client.get_client()
    if client == nil then
        return nil, 'etcd unavailable: ' .. tostring(client_err)
    end
    local marked, failed = {}, {}
    for _, alias in ipairs(resolved.aliases) do
        local _, derr = disabled.set(client, alias,
            (opts and opts.user) or 'suggestion-engine')
        if derr == nil then
            table.insert(marked, alias)
        else
            table.insert(failed, alias .. '=' .. tostring(derr))
        end
    end
    local msg
    if #failed == 0 then
        msg = string.format('disabled %d instance(s): %s',
            #marked, table.concat(marked, ', '))
    else
        msg = string.format(
            'disabled %d instance(s): %s; failed: %s',
            #marked, table.concat(marked, ', '),
            table.concat(failed, '; '))
    end
    logger.warn('applied disable_server suggestion', {
        marked = marked, failed = failed, unknown = resolved.unknown,
    })
    return {
        ok      = #failed == 0,
        message = msg,
        unknown = resolved.unknown,
    }
end

-- Apply a suggestion. The handler contract is uniform, so dispatch is a
-- table keyed by suggestion type; an unknown type is "not implemented".
local HANDLERS = {
    [M.TYPES.FORCE_APPLY]         = apply_force_apply,
    [M.TYPES.RESTART_REPLICATION] = apply_restart_replication,
    [M.TYPES.DISABLE_SERVER]      = apply_disable_server,
}

function M.apply(type_, payload, opts)
    checks('string', '?table', '?table')
    opts = opts or {}
    payload = payload or {}
    local snapshot = opts.snapshot or state.snapshot()
    local target_uuids = payload.instance_uuids or payload.uuids or {}
    local resolved = M.resolve_targets(snapshot, target_uuids)

    local handler = HANDLERS[type_]
    if handler == nil then
        return nil, string.format(
            'suggestion type %q is not implemented yet', type_)
    end
    return handler(resolved, snapshot, opts)
end

-- ─────────────────────────────────────────────────────────────────────
-- Fiber lifecycle (mirrors issues scanner)
-- ─────────────────────────────────────────────────────────────────────

local function run_one_scan()
    local snap = state.snapshot()
    local result = M.scan(snap)
    local prev_total = 0
    for _, list in pairs(SCANNER.last_result or {}) do
        prev_total = prev_total + #list
    end
    local total = 0
    for _, list in pairs(result) do total = total + #list end
    SCANNER.last_result = result
    SCANNER.last_at     = fiber.clock()
    logger.debug('suggestions tick', { total = total })

    -- Notify WS subscribers when the total changed; redundant
    -- broadcasts are cheap (no connections → no-op) but skipping
    -- silent ticks keeps the wire chatter down.
    if total ~= prev_total then
        local ws_ok, ws = pcall(require, 'webui.http.ws')
        if ws_ok then pcall(ws.broadcast) end
    end
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
