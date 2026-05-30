--
-- Net.box pool keyed by Tarantool 3.x instance name.
--
-- The pool is the single owner of outbound net.box connections from
-- this instance to its peers. Higher layers (cluster.poller,
-- cluster.rpc) never call `net.box.connect` directly; they ask the
-- pool for a connection or hand a list of peers to map_call.
--
-- Responsibilities split:
--
--   * Source of truth for the peer list — `config:instances()`. The
--     pool refreshes from there on bootstrap and on every
--     `box.watch('config.info', ...)` event (Task 17 wires that).
--   * URI + TLS params — `config:instance_uri('peer', ...)`. We
--     forward `uri.params` to net.box so mTLS / SNI flow through
--     unchanged from the cluster config.
--   * Credential — peer cookie from Task 15 (`webui_peer`).
--   * Self filter — we never connect to ourselves; `box.info.name`
--     is excluded.
--   * Lifecycle — connections survive transient peer outages via
--     `reconnect_after`; refresh closes and re-opens only when the
--     advertised URI changes.
--
-- All public functions are safe to call from any fiber. The pool
-- assumes the cluster config is initialised when refresh() is
-- called — peer_cookie.bootstrap (step 5) is what guarantees that.
--

local checks = require('checks')
local net_box = require('net.box')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('peers')

local M = {}

-- net.box auto-reconnect tick. One second is the smallest value
-- that does not produce a tight loop on a partition while still
-- recovering quickly when the peer is back. The value mirrors what
-- Cartridge's pool uses by default.
local RECONNECT_AFTER_SEC = 1

-- Module-local state. Never global. Tests reset via `_reset()`.
local STATE = {
    self_alias = nil,
    peers      = {},   -- [name] = { uri, conn, replicaset_name, group_name }
    credential = {},   -- { user, password } resolved at bootstrap
}

-- ── pure helpers (unit-testable) ─────────────────────────────────────

-- Drop the current instance from the iter map so we never call
-- ourselves over net.box. Returns a new table; never mutates input.
function M.filter_self(instances, self_alias)
    checks('?table', '?string')
    if type(instances) ~= 'table' then return {} end
    local out = {}
    for name, info in pairs(instances) do
        if self_alias == nil or name ~= self_alias then
            out[name] = info
        end
    end
    return out
end

-- Given the names currently in the pool and the names the config
-- expects, decide what to add and what to remove. Pure function
-- over name sets — the actual close/connect happen in refresh().
function M.diff_peers(current_names, expected_names)
    checks('?table', '?table')
    current_names = current_names or {}
    expected_names = expected_names or {}
    local current_set, expected_set = {}, {}
    for _, name in ipairs(current_names) do current_set[name] = true end
    for _, name in ipairs(expected_names) do expected_set[name] = true end
    local to_open, to_close = {}, {}
    for name in pairs(expected_set) do
        if not current_set[name] then table.insert(to_open, name) end
    end
    for name in pairs(current_set) do
        if not expected_set[name] then table.insert(to_close, name) end
    end
    table.sort(to_open)
    table.sort(to_close)
    return { to_open = to_open, to_close = to_close }
end

-- Normalise the shape returned by `config:instance_uri('peer', ...)`.
-- Tarantool returns either `nil` (no URI declared) or a table with
-- `{ uri, params, login, password }`. The pool needs a deterministic
-- shape for diff / connect calls — separate from how the cluster
-- config stores it.
function M.normalise_uri(uri_info)
    checks('?table')
    if type(uri_info) ~= 'table' or uri_info.uri == nil then return nil end
    return {
        uri      = uri_info.uri,
        params   = uri_info.params,
        login    = uri_info.login,
        password = uri_info.password,
    }
end

-- ── self-alias resolution ────────────────────────────────────────────

local function resolve_self_alias()
    if STATE.self_alias ~= nil then return STATE.self_alias end
    local ok, info = pcall(function() return box.info end)
    if ok and type(info) == 'table' and type(info.name) == 'string'
        and info.name ~= '' then
        STATE.self_alias = info.name
    end
    return STATE.self_alias
end

function M.self_alias() return resolve_self_alias() end

-- ── credential management ────────────────────────────────────────────

-- The pool itself does not resolve credentials — Task 15 owns that.
-- `set_credential` is called by init.lua with the result from
-- peer_cookie.bootstrap so the pool can pass `{user, password}` into
-- net.box.connect.
function M.set_credential(user, password)
    checks('string', '?string')
    STATE.credential.user = user
    STATE.credential.password = password
end

-- ── connection lifecycle ─────────────────────────────────────────────

local function connect_to(name, uri_info)
    local conn_opts = {
        user             = STATE.credential.user or uri_info.login,
        password         = STATE.credential.password or uri_info.password,
        reconnect_after  = RECONNECT_AFTER_SEC,
        wait_connected   = false,
        connect_timeout  = 2,
    }
    if uri_info.params ~= nil then conn_opts.params = uri_info.params end
    local conn = net_box.connect(uri_info.uri, conn_opts)
    logger.info('peer connection opened', {
        peer    = name,
        uri     = uri_info.uri,
        tls     = uri_info.params ~= nil and uri_info.params.transport == 'ssl',
    })
    return conn
end

local function close_peer(name)
    local peer = STATE.peers[name]
    if peer == nil then return end
    pcall(function() peer.conn:close() end)
    STATE.peers[name] = nil
    logger.info('peer connection closed', { peer = name })
end

-- ── public surface ──────────────────────────────────────────────────

-- Refresh the pool against the current cluster configuration. Opens
-- connections for instances that appeared, closes for those that
-- disappeared, replaces stale connections when the URI changed.
-- Returns a snapshot of the post-refresh state.
function M.refresh()
    local cfg = require('config')
    local instances = cfg:instances()
    local self_alias = resolve_self_alias()
    local expected = M.filter_self(instances, self_alias)

    local current_names = {}
    for name in pairs(STATE.peers) do
        table.insert(current_names, name)
    end
    local expected_names = {}
    for name in pairs(expected) do
        table.insert(expected_names, name)
    end

    local diff = M.diff_peers(current_names, expected_names)
    for _, name in ipairs(diff.to_close) do close_peer(name) end

    for _, name in ipairs(diff.to_open) do
        local info = expected[name]
        local raw_uri = cfg:instance_uri('peer', { instance = name })
        local uri_info = M.normalise_uri(raw_uri)
        if uri_info == nil then
            logger.warn('no peer URI advertised for instance', { peer = name })
        else
            local conn = connect_to(name, uri_info)
            STATE.peers[name] = {
                uri             = uri_info.uri,
                conn            = conn,
                replicaset_name = info.replicaset_name,
                group_name      = info.group_name,
            }
        end
    end

    -- URI change detection: a peer kept its name but its advertised
    -- URI moved (typical: TLS roll, port reshuffle). Reconnect.
    for name, peer in pairs(STATE.peers) do
        local raw_uri = cfg:instance_uri('peer', { instance = name })
        local uri_info = M.normalise_uri(raw_uri)
        if uri_info ~= nil and uri_info.uri ~= peer.uri then
            logger.info('peer URI changed; reconnecting', {
                peer    = name,
                from    = peer.uri,
                to      = uri_info.uri,
            })
            close_peer(name)
            local conn = connect_to(name, uri_info)
            STATE.peers[name] = {
                uri             = uri_info.uri,
                conn            = conn,
                replicaset_name = expected[name].replicaset_name,
                group_name      = expected[name].group_name,
            }
        end
    end

    return M.list()
end

-- Read-only snapshot of the pool. Never returns net.box connections —
-- only metadata that callers (GraphQL, admin endpoints) can serialise.
function M.list()
    local out = {}
    for name, peer in pairs(STATE.peers) do
        local conn = peer.conn
        local state_str = 'unknown'
        if conn ~= nil then
            local ok, s = pcall(function() return conn.state end)
            if ok and type(s) == 'string' then state_str = s end
        end
        out[name] = {
            uri             = peer.uri,
            state           = state_str,
            replicaset_name = peer.replicaset_name,
            group_name      = peer.group_name,
        }
    end
    return out
end

-- Internal helper for rpc.map_call — returns live net.box connection
-- objects keyed by peer name. Callers must not store these refs;
-- the pool owns the lifecycle.
function M.connections()
    local out = {}
    for name, peer in pairs(STATE.peers) do
        out[name] = peer.conn
    end
    return out
end

function M.get(name)
    checks('string')
    return STATE.peers[name]
end

function M.close_all()
    for name in pairs(STATE.peers) do close_peer(name) end
end

-- Test hook: drop in-memory state so a unit test starts from clean.
-- Production code never calls this.
function M._reset()
    STATE.self_alias = nil
    STATE.peers      = {}
    STATE.credential = {}
end

return M
