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
local json        = require('json')

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
    -- Failover mode comes straight from the live cluster config
    -- rather than the poller snapshot — the snapshot never carried
    -- `failover_mode`, so the previous `snap.failover_mode or
    -- 'election'` default lied to operators when the cluster ran
    -- in `off` / `manual` / `supervised`.
    local cfg_ok, cfg = pcall(require, 'config')
    local cfg_mode
    if cfg_ok then
        local ok, value = pcall(function()
            return (cfg:get('replication') or {}).failover
        end)
        if ok and type(value) == 'string' then cfg_mode = value end
    end
    -- `box.info.election` in Tarantool 3.x exposes `leader` (numeric
    -- replica id) and `leader_name` (alias). It does NOT expose a
    -- UUID — to surface one we would have to cross-reference
    -- `box.info.replication[leader].uuid` on every peer, which is
    -- expensive for a UI panel and not actionable. The alias is what
    -- operators recognise, so we surface that and skip the UUID.
    local elections = {}
    if cfg_mode == 'election' then
        local snap = state.snapshot() or {}
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
    end
    return {
        mode      = cfg_mode or 'off',
        elections = elections,
    }
end

-- Read the full appointment map from etcd. Any peer can call this
-- and get the same answer — the appointments live in etcd, not in
-- each agent's local memory. Returns a sorted list so the UI
-- renders deterministically across refreshes.
local function read_appointments_from_etcd()
    local client, _ = require('webui.config_store.client').get_client()
    if client == nil then return {} end
    -- etcd v3 does not have a wildcard get without range; we know
    -- the replicaset list from local cluster state, so iterate.
    local snap_ok, snap = pcall(function()
        return require('webui.cluster.state').snapshot()
    end)
    local rs_names = {}
    if snap_ok and snap and snap.replicasets then
        for name in pairs(snap.replicasets) do
            table.insert(rs_names, name)
        end
    end
    -- Fallback: use the current instance's own replicaset name.
    if #rs_names == 0 and box.info.replicaset
            and box.info.replicaset.name ~= nil then
        table.insert(rs_names, box.info.replicaset.name)
    end
    local out = {}
    for _, rs in ipairs(rs_names) do
        local key = '/failover/replicasets/' .. rs .. '/leader'
        local kv = client:get(key)
        if kv ~= nil then
            local ok, parsed = pcall(json.decode, kv.value)
            if ok and type(parsed) == 'table' then
                table.insert(out, {
                    replicaset = rs,
                    leader     = parsed.leader,
                    previous   = parsed.previous,
                    ts         = parsed.ts,
                })
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.replicaset or '') < (b.replicaset or '')
    end)
    return out
end

-- Status of the open-source failover agent + watcher. Returns null
-- fields when the agent is disabled (the default); the SPA hides
-- the panel in that case.
--
-- Appointments are read straight from etcd so every peer's
-- /failover page sees the same source-of-truth map regardless of
-- which one happens to be the coordinator at the moment.
-- watcher_current_ro reflects the LIVE `box.info.ro` rather than
-- a stale "last_applied" — that's what an operator actually wants
-- to know on the page (the local instance's RW/RO state right now).
function M.query_agent_status(root)
    require_role(root, 'failover')
    local ok, fo = pcall(require, 'webui.failover')
    if not ok then
        return { enabled = false, error = 'failover module unavailable' }
    end
    local s = fo.status()
    local agent_status = s.agent or {}
    local watcher_status = s.watcher or {}

    local appointments = {}
    if agent_status.enabled then
        local fetch_ok, fetched = pcall(read_appointments_from_etcd)
        if fetch_ok and type(fetched) == 'table' then
            appointments = fetched
        end
    end

    local current_ro
    if box.info ~= nil then current_ro = box.info.ro end

    return {
        enabled         = agent_status.enabled == true,
        self_alias      = agent_status.self_alias,
        coordinator     = agent_status.coordinator,
        is_coordinator  = agent_status.is_coordinator == true,
        lease_id        = agent_status.lease_id,
        appointments    = appointments,
        last_error      = agent_status.last_error,
        watcher_replicaset = watcher_status.replicaset,
        watcher_last_leader = watcher_status.last_seen
            and watcher_status.last_seen.leader,
        watcher_current_ro  = current_ro,
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
