--
-- Failover surface — read-only summary plus state-provider probe.
--
-- `failover { mode, elections[] }` returns the per-instance raft
-- snapshot that peer_poller already carries into state.snapshot().
--
-- `failoverStateProviderStatus` is a deeper probe used by the
-- /failover UI panel: when `replication.failover = supervised`
-- the coordinator drives appointment via an external stateboard
-- (etcd or tarantool-instance). This resolver pings each endpoint
-- with HTTP GET /version and reports latency / errors. For
-- `election` / `manual` / `off` clusters the query short-circuits
-- to `kind=none` so the SPA can render «raft-only» state without a
-- network round trip.
--

local fiber       = require('fiber')
local http_client = require('http.client')

local rbac   = require('webui.auth.rbac')
local state  = require('webui.cluster.state')
local logger = require('webui.log_util')

local M = {}

-- Lazily-created probe client. Reused across queries to keep the
-- TCP connections warm; the etcd /version probe is tiny so a small
-- pool is enough.
local probe_client

local PROBE_TIMEOUT_S = 1.0

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

function M.query_failover(root)
    require_role(root, 'failover')
    local snap = state.snapshot() or {}
    -- `box.info.election` in Tarantool 3.x exposes `leader` (numeric
    -- replica id) and `leader_name` (alias). It does NOT expose a
    -- UUID — to surface one we would have to cross-reference
    -- `box.info.replication[leader].uuid` on every peer, which is
    -- expensive for a UI panel and not actionable. The alias is what
    -- operators recognise, so we surface that and skip the UUID.
    local elections = {}
    for alias, srv in pairs(snap.servers or {}) do
        if srv.election ~= nil then
            table.insert(elections, {
                instance    = alias,
                state       = srv.election.state,
                term        = srv.election.term,
                leader_name = srv.election.leader_name,
            })
        end
    end
    table.sort(elections, function(a, b) return a.instance < b.instance end)
    return {
        mode      = snap.failover_mode or 'election',
        elections = elections,
    }
end

-- ─────────────────────────────────────────────────────────────────────
-- failoverStateProviderStatus
-- ─────────────────────────────────────────────────────────────────────

local function probe_endpoint(uri)
    if probe_client == nil then
        probe_client = http_client.new({ max_connections = 4 })
    end
    local started = fiber.time()
    local url = uri:gsub('/+$', '') .. '/version'
    local ok, response = pcall(probe_client.get, probe_client, url,
        { timeout = PROBE_TIMEOUT_S })
    local latency_ms = (fiber.time() - started) * 1000
    if not ok then
        logger.debug('state provider probe failed', { uri = uri, err = tostring(response) })
        return {
            uri = uri, status = 'down',
            latency_ms = latency_ms, last_error = tostring(response),
        }
    end
    if response.status >= 200 and response.status < 300 then
        return {
            uri = uri, status = 'ok',
            latency_ms = latency_ms, last_error = box.NULL,
        }
    end
    return {
        uri = uri, status = 'down',
        latency_ms = latency_ms,
        last_error = 'HTTP ' .. tostring(response.status),
    }
end

-- Reads the live cluster config to locate the supervised-failover
-- state provider. Tolerates several spellings because Tarantool 3.x
-- exposes the endpoint list under different keys depending on the
-- coordinator topology.
local function read_state_provider_endpoints()
    local cfg = require('config')
    local repl = cfg:get('replication') or {}
    local mode = repl.failover or 'off'
    if mode ~= 'supervised' then
        return nil, mode, {}
    end

    local endpoints = {}

    -- Top-level `stateboard` block. Each entry typically has a
    -- `uri` and may use `endpoints` for clustered stateboards.
    local sb = cfg:get('stateboard') or {}
    if type(sb.endpoints) == 'table' then
        for _, e in ipairs(sb.endpoints) do
            if type(e) == 'string' then table.insert(endpoints, e) end
        end
    end
    if type(sb.uri) == 'string' and sb.uri ~= '' then
        table.insert(endpoints, sb.uri)
    end

    -- Tarantool also accepts `config.etcd.endpoints` when etcd is
    -- the state provider (single endpoint list shared with the
    -- config source).
    local cfg_etcd = (cfg:get('config') or {}).etcd or {}
    if type(cfg_etcd.endpoints) == 'table' then
        for _, e in ipairs(cfg_etcd.endpoints) do
            if type(e) == 'string' then table.insert(endpoints, e) end
        end
    end

    return 'etcd', mode, endpoints
end

function M.query_state_provider_status(root)
    require_role(root, 'failover')
    local kind, mode, endpoints = read_state_provider_endpoints()
    if kind == nil then
        return {
            kind = 'none',
            mode = mode,
            endpoints = {},
            lease_active = box.NULL,
            coordinator  = box.NULL,
        }
    end

    local probed = {}
    for _, uri in ipairs(endpoints) do
        table.insert(probed, probe_endpoint(uri))
    end

    return {
        kind = 'etcd',
        mode = mode,
        endpoints = probed,
        -- Lease ownership lives in an etcd key; surfacing it
        -- requires the same key path the coordinator writes to,
        -- which is not exposed in the local config. Left null for
        -- now — the panel still shows endpoint reachability,
        -- which is the actionable bit.
        lease_active = box.NULL,
        coordinator  = box.NULL,
    }
end

return M
