--
-- In-memory cluster state cache.
--
-- The cache is the single source of truth that the GraphQL resolvers,
-- the WebSocket broadcaster (Task 32+) and the issues scanner read
-- from. The poller (Task 17 next door) is the only writer.
--
-- The state shape mirrors what the UI eventually renders, not what
-- `box.info` happens to expose — turning Tarantool fields into the
-- public API contract happens in `apply_tick()` exactly once per
-- poll, so resolvers never re-do the work and the snapshot can be
-- cheaply deep-copied for callers.
--
-- Two-phase write:
--   1. `apply_tick(data)` rebuilds the next state in a local table.
--   2. The whole table replaces the previous one in a single
--      assignment, so concurrent readers see either the old or the
--      new state but never a torn mix.
--
-- `snapshot()` returns a deep copy so callers can hold the result
-- across yields without worrying about the next tick mutating it.
--

local checks = require('checks')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('state')

local M = {}

local STATE = {
    generation   = 0,        -- incremented on each successful apply_tick
    last_tick_at = 0,        -- fiber.clock() of last tick (0 = never)
    self_alias   = nil,
    servers      = {},
    replicasets  = {},
}

-- ─────────────────────────────────────────────────────────────────────
-- Pure helpers (no side effects, easy to unit-test)
-- ─────────────────────────────────────────────────────────────────────

-- Build a fresh server record. Use as a starting point for every
-- per-instance merge so missing fields always render as nil rather
-- than referencing the previous tick's data.
function M.blank_server(alias, topology_entry)
    checks('string', '?table')
    topology_entry = topology_entry or {}
    return {
        alias            = alias,
        uri              = topology_entry.uri,
        uuid             = nil,
        status           = 'unknown',
        message          = nil,
        lag              = nil,
        uptime           = nil,
        vclock           = nil,
        version          = nil,
        replicaset_name  = topology_entry.replicaset_name,
        group_name       = topology_entry.group_name,
        labels           = topology_entry.labels or {},
        zone             = topology_entry.zone,
        config_status    = nil,
        alerts           = {},
        electable        = true,
        is_ro            = nil,
        ro_reason        = nil,
        reachable        = false,
        last_seen        = nil,
        last_error       = nil,
        next_retry_at    = nil,
    }
end

-- Group servers by replicaset name. Pure over inputs; produces the
-- replicasets sub-table that snapshot() returns.
function M.group_by_replicaset(servers)
    checks('?table')
    servers = servers or {}
    local out = {}
    for alias, server in pairs(servers) do
        local name = server.replicaset_name or '_orphan'
        local entry = out[name]
        if entry == nil then
            entry = {
                name        = name,
                group_name  = server.group_name,
                instances   = {},
                leader      = nil,
                active_leader = nil,
            }
            out[name] = entry
        end
        table.insert(entry.instances, alias)
    end
    -- Stable order for the UI.
    for _, rs in pairs(out) do
        table.sort(rs.instances)
    end
    return out
end

-- Parse a slab ratio field — Tarantool 3.x typically returns these
-- as numbers in 0..1, older builds (and box.slab.info() in some
-- combinations) emit "12.3%" strings. Normalise to a 0..1 fraction
-- so consumers (GraphQL Statistics, issues thresholds) have one
-- shape to reason about.
local function parse_ratio(value)
    if type(value) == 'number' then
        if value > 1 then return value / 100 end
        return value
    end
    if type(value) ~= 'string' then return nil end
    local stripped = (value:gsub('%%', ''))
    local num = tonumber(stripped)
    if num == nil then return nil end
    if num > 1 then return num / 100 end
    return num
end

M._parse_ratio = parse_ratio

-- Merge probe data from a single peer into the working server entry.
-- Pulled out of apply_tick so the merge rules are testable in
-- isolation. The function returns the mutated server table for
-- readability — the caller owns it.
function M.merge_probe(server, probe)
    checks('table', '?table')
    if type(probe) ~= 'table' then return server end
    server.uuid          = probe.uuid or server.uuid
    server.version       = probe.version or server.version
    server.uptime        = probe.uptime or server.uptime
    server.vclock        = probe.vclock or server.vclock
    server.status        = probe.status or server.status
    server.is_ro         = probe.ro
    server.ro_reason     = probe.ro_reason
    server.config_status = probe.config_status or server.config_status
    if type(probe.config_alerts) == 'table' then
        server.alerts = probe.config_alerts
    end
    -- box.info.replication & box.slab.info() drive the issues
    -- scanner; the GraphQL Statistics type also reads the parsed
    -- slab ratios.
    if probe.replication ~= nil then server.replication = probe.replication end
    if probe.replicaset ~= nil then server.replicaset = probe.replicaset end
    if type(probe.slab) == 'table' then
        server.slab = probe.slab
        server.arena_used_ratio = parse_ratio(probe.slab.arena_used_ratio)
        server.items_used_ratio = parse_ratio(probe.slab.items_used_ratio)
        server.quota_used_ratio = parse_ratio(probe.slab.quota_used_ratio)
    end
    server.election      = probe.election or server.election
    server.clock         = probe.clock or server.clock
    server.reachable     = true
    return server
end

-- Build the new state table from local probe + per-peer results.
-- Pure: takes inputs and returns the next state without touching
-- module-level globals.
function M.build_next_state(args)
    checks({
        self_alias = '?string',
        local_probe = '?table',
        peer_results = '?table',
        topology = '?table',
        backoff = '?table',
        now = 'number',
    })
    args = args or {}
    local servers = {}

    -- 1. Topology defines every advertised peer. Even peers we have
    -- never reached must appear in the snapshot (status 'unknown').
    for alias, topo in pairs(args.topology or {}) do
        servers[alias] = M.blank_server(alias, topo)
    end

    -- 2. Local probe overlays first; self is always reachable because
    -- the probe is in-process.
    if args.self_alias ~= nil then
        local self_entry = servers[args.self_alias]
            or M.blank_server(args.self_alias)
        if args.local_probe ~= nil then
            M.merge_probe(self_entry, args.local_probe)
            self_entry.reachable = true
            self_entry.last_seen = args.now
        end
        servers[args.self_alias] = self_entry
    end

    -- 3. Per-peer fan-out results.
    for alias, result in pairs(args.peer_results or {}) do
        if alias ~= args.self_alias then
            local entry = servers[alias] or M.blank_server(alias)
            if result.ok and type(result.value) == 'table' then
                M.merge_probe(entry, result.value)
                entry.last_seen = args.now
            else
                entry.reachable = false
                entry.status = 'unreachable'
                entry.last_error = result.err
            end
            servers[alias] = entry
        end
    end

    -- 4. Annotate next_retry_at from backoff state so the UI can
    -- show "retrying in X seconds" when a peer is down.
    if args.backoff ~= nil then
        for alias, entry in pairs(args.backoff) do
            local s = servers[alias]
            if s ~= nil then
                s.next_retry_at = entry.next_retry_at
            end
        end
    end

    return {
        servers     = servers,
        replicasets = M.group_by_replicaset(servers),
    }
end

-- ─────────────────────────────────────────────────────────────────────
-- Public surface
-- ─────────────────────────────────────────────────────────────────────

-- Replace the cached state. The new state must be the full snapshot,
-- not a partial update — see build_next_state() which is the typical
-- producer.
function M.apply_tick(args)
    checks('?table')
    args = args or {}
    local now = args.now or 0
    local built = M.build_next_state(args)
    STATE.servers      = built.servers
    STATE.replicasets  = built.replicasets
    STATE.self_alias   = args.self_alias or STATE.self_alias
    STATE.generation   = STATE.generation + 1
    STATE.last_tick_at = now
    logger.debug('state tick applied', {
        generation = STATE.generation,
        servers    = (function()
            local n = 0; for _ in pairs(STATE.servers) do n = n + 1 end; return n
        end)(),
    })
end

-- Read-only snapshot. Always a deep copy — callers can hold the
-- result across yields without racing with the next tick.
function M.snapshot()
    return table.deepcopy({
        self_alias   = STATE.self_alias,
        generation   = STATE.generation,
        last_tick_at = STATE.last_tick_at,
        servers      = STATE.servers,
        replicasets  = STATE.replicasets,
    })
end

function M.generation()  return STATE.generation end
function M.last_tick_at() return STATE.last_tick_at end

-- Test hook. Production code never calls this.
function M._reset()
    STATE.generation   = 0
    STATE.last_tick_at = 0
    STATE.self_alias   = nil
    STATE.servers      = {}
    STATE.replicasets  = {}
end

return M
