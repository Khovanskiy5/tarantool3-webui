--
-- Minimal etcd v3 client over the gRPC-gateway HTTP/JSON API.
--
-- We deliberately do NOT depend on a third-party `etcd-client`
-- rock — it isn't published in the public LuaRocks repos at the
-- moment. The v3 gateway exposes the same operations via plain
-- JSON over HTTP/1.1, which is enough for the WebUI cluster-
-- config flow: get/put/txn/delete + lease + a poll-based watch
-- that compares revisions.
--
-- Public surface is intentionally narrow. Callers always receive
-- `(result, err)` where `err` is one of the documented error
-- categories (CONNECTION, AUTH, NOT_FOUND, CAS_CONFLICT, ...).
-- HTTP details never escape the module.
--
-- Limitations:
--   * Watch is implemented as a polling loop on `revision` —
--     watch streaming over HTTP/2 is out of reach for the http
--     rock 1.6. Default interval 500ms balances reactivity vs
--     load; callers tune through `opts.poll_interval`.
--   * Auth uses Basic via the `/v3/auth/authenticate` token flow.
--   * No prepare/commit-2pc against etcd itself — the WebUI's
--     two-phase commit lives at a higher level (Task 34).
--

local http_client = require('http.client')
local fiber  = require('fiber')
local digest = require('digest')
local json   = require('json')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('etcd')

local M = {}

local DEFAULT_TIMEOUT = 5

-- ─────────────────────────────────────────────────────────────────────
-- Errors
-- ─────────────────────────────────────────────────────────────────────

local function err(category, message, extra)
    return { category = category, message = message, extra = extra }
end

-- ─────────────────────────────────────────────────────────────────────
-- Endpoint helpers
-- ─────────────────────────────────────────────────────────────────────

local function pick_endpoint(state)
    state.cursor = ((state.cursor or 0) % #state.endpoints) + 1
    return state.endpoints[state.cursor]
end

local function b64(s)
    if s == nil then return nil end
    return digest.base64_encode(tostring(s), { nowrap = true })
end

local function from_b64(s)
    if s == nil then return nil end
    local ok, decoded = pcall(digest.base64_decode, s)
    if not ok then return nil end
    return decoded
end

local function post(state, path, body)
    local endpoint = pick_endpoint(state)
    local url = endpoint .. path
    local hdr = { ['content-type'] = 'application/json' }
    if state.token then hdr['Authorization'] = state.token end
    local payload = json.encode(body or {})
    local ok, response = pcall(state.client.post, state.client,
        url, payload, { headers = hdr, timeout = state.timeout })
    if not ok then
        return nil, err('CONNECTION', tostring(response), { endpoint = endpoint })
    end
    if response.status >= 500 then
        return nil, err('INTERNAL',
            'etcd ' .. tostring(response.status), { endpoint = endpoint })
    end
    if response.status == 401 then
        return nil, err('AUTH', 'unauthorized', { endpoint = endpoint })
    end
    if response.status == 404 then
        return nil, err('NOT_FOUND', 'endpoint missing', { endpoint = endpoint })
    end
    local parsed
    if response.body and #response.body > 0 then
        local ok_dec, decoded = pcall(json.decode, response.body)
        if ok_dec then parsed = decoded end
    end
    if response.status >= 400 then
        return nil, err('INTERNAL',
            (parsed and parsed.message) or response.body or 'bad request',
            { endpoint = endpoint, status = response.status })
    end
    return parsed or {}
end

-- ─────────────────────────────────────────────────────────────────────
-- Client
-- ─────────────────────────────────────────────────────────────────────

-- new({ endpoints = { 'http://etcd:2379' }, prefix = '/webui',
--       username = nil, password = nil, timeout = 5 })
function M.new(opts)
    opts = opts or {}
    if type(opts.endpoints) ~= 'table' or #opts.endpoints == 0 then
        return nil, err('CONNECTION', 'no endpoints configured')
    end
    local state = {
        endpoints = opts.endpoints,
        cursor    = 0,
        prefix    = opts.prefix or '/webui',
        timeout   = opts.timeout or DEFAULT_TIMEOUT,
        client    = http_client.new({ max_connections = 4 }),
        token     = nil,
        creds     = (opts.username and {
            name     = opts.username,
            password = opts.password or '',
        }) or nil,
    }

    function state:_authenticate()
        if self.creds == nil then return true end
        local resp, e = post(self, '/v3/auth/authenticate', {
            name = self.creds.name, password = self.creds.password,
        })
        if resp == nil then return nil, e end
        self.token = resp.token
        return true
    end

    if state.creds then
        local _, auth_err = state:_authenticate()
        if auth_err then return nil, auth_err end
    end

    return setmetatable(state, { __index = M.proto })
end

M.proto = {}

local function full_key(state, key)
    return state.prefix .. (key:sub(1, 1) == '/' and key or ('/' .. key))
end

function M.proto:get(key)
    local resp, e = post(self, '/v3/kv/range', { key = b64(full_key(self, key)) })
    if resp == nil then return nil, e end
    local kvs = resp.kvs or {}
    if #kvs == 0 then return nil, nil end
    local kv = kvs[1]
    return {
        key      = from_b64(kv.key),
        value    = from_b64(kv.value),
        revision = tonumber(kv.mod_revision),
        version  = tonumber(kv.version),
    }
end

-- Compute the next byte-sequence after `s` for an etcd v3 prefix
-- range_end: increment the last byte. The trailing byte of every
-- prefix we use is `/` (0x2F), so the 0xFF overflow case never
-- fires for our keys; keep the defensive branch anyway.
local function next_byte_sequence(s)
    if s == nil or #s == 0 then return s end
    local last = string.byte(s, -1)
    if last == 255 then return s .. '\0' end
    return s:sub(1, -2) .. string.char(last + 1)
end

-- range_prefix(prefix, limit?) — list every kv whose key starts with
-- the (already prefix-resolved) `prefix`. Returns
-- `{ items = [{key, value, revision, version}, ...], count, more }`.
-- `prefix` is relative to the client's configured `state.prefix`,
-- the same way `:get(key)` resolves the full key path.
-- Used by config_store.history.list and by future prefix-scoped
-- range readers (failover/disabled, _webui_failover_commands export).
function M.proto:range_prefix(prefix, limit)
    local fk = full_key(self, prefix)
    local body = {
        key       = b64(fk),
        range_end = b64(next_byte_sequence(fk)),
    }
    if type(limit) == 'number' and limit > 0 then
        body.limit = tostring(limit)
    end
    local resp, e = post(self, '/v3/kv/range', body)
    if resp == nil then return nil, e end
    local items = {}
    for _, kv in ipairs(resp.kvs or {}) do
        table.insert(items, {
            key      = from_b64(kv.key),
            value    = from_b64(kv.value),
            revision = tonumber(kv.mod_revision),
            version  = tonumber(kv.version),
        })
    end
    return {
        items = items,
        count = tonumber(resp.count) or #items,
        more  = resp.more == true,
    }
end

-- Optional `lease_id`: when supplied, the key is bound to the lease
-- and disappears when the lease expires (no keepalive ⇒ TTL eviction).
-- Used by the failover agent for the coordinator-election key.
function M.proto:put(key, value, lease_id)
    local body = { key = b64(full_key(self, key)), value = b64(value) }
    if lease_id ~= nil then body.lease = tostring(lease_id) end
    local resp, e = post(self, '/v3/kv/put', body)
    if resp == nil then return nil, e end
    logger.debug('etcd put', { key = key, lease = lease_id })
    return { revision = tonumber((resp.header or {}).revision) }
end

-- Atomic "put if absent" via txn: succeed only when the key has
-- never been written (mod_revision == 0). Returns `(result, nil)`
-- on success or `(nil, 'CAS_CONFLICT')` when the key already
-- exists. Foundation of lease-based leader election.
function M.proto:txn_create(key, value, lease_id)
    local fk = b64(full_key(self, key))
    local put_req = { key = fk, value = b64(value) }
    if lease_id ~= nil then put_req.lease = tostring(lease_id) end
    local body = {
        compare = {{
            target = 'MOD', key = fk, result = 'EQUAL',
            mod_revision = '0',
        }},
        success = {{ request_put = put_req }},
        failure = {{ request_range = { key = fk } }},
    }
    local resp, e = post(self, '/v3/kv/txn', body)
    if resp == nil then return nil, e end
    if resp.succeeded then
        return { revision = tonumber((resp.header or {}).revision),
                 created = true }
    end
    return nil, err('CAS_CONFLICT', 'key already exists', { key = key })
end

-- Conditional put fenced on a witness key's mod_revision. Used by
-- the failover coordinator to ensure appointments are only written
-- while THIS coordinator's lease is still alive: if a slower
-- coordinator wakes up after its lease expired and another peer
-- already acquired the lease (different mod_revision on the
-- coordinator key), the write fails atomically.
function M.proto:put_if_witness_unchanged(key, value, witness_key,
        witness_revision)
    local fk = b64(full_key(self, key))
    local wk = b64(full_key(self, witness_key))
    local body = {
        compare = {{
            target = 'MOD', key = wk, result = 'EQUAL',
            mod_revision = tostring(witness_revision or 0),
        }},
        success = {{ request_put = { key = fk, value = b64(value) } }},
        failure = {{ request_range = { key = wk } }},
    }
    local resp, e = post(self, '/v3/kv/txn', body)
    if resp == nil then return nil, e end
    if resp.succeeded then
        return { revision = tonumber((resp.header or {}).revision) }
    end
    return nil, err('CAS_CONFLICT', 'witness key changed',
        { witness = witness_key, expected = witness_revision })
end

function M.proto:delete(key)
    local _, e = post(self, '/v3/kv/deleterange', {
        key = b64(full_key(self, key)),
    })
    if e then return nil, e end
    return true
end

-- CAS write: succeed iff current `mod_revision` matches `expected`.
function M.proto:txn_cas(key, value, expected_revision)
    local fk = b64(full_key(self, key))
    local body = {
        compare = {{
            target = 'MOD',
            key    = fk,
            result = 'EQUAL',
            mod_revision = tostring(expected_revision or 0),
        }},
        success = {{ request_put = { key = fk, value = b64(value) } }},
        failure = {{ request_range = { key = fk } }},
    }
    local resp, e = post(self, '/v3/kv/txn', body)
    if resp == nil then return nil, e end
    if resp.succeeded then
        return { revision = tonumber((resp.header or {}).revision),
                 committed = true }
    end
    return nil, err('CAS_CONFLICT', 'expected revision mismatch',
        { expected = expected_revision })
end

-- ── Lease ────────────────────────────────────────────────────────────

function M.proto:lease_grant(ttl_sec)
    local resp, e = post(self, '/v3/lease/grant', { TTL = tostring(ttl_sec) })
    if resp == nil then return nil, e end
    return { id = resp.ID, ttl = tonumber(resp.TTL) }
end

function M.proto:lease_keepalive(lease_id)
    local resp, e = post(self, '/v3/lease/keepalive', { ID = lease_id })
    if resp == nil then return nil, e end
    local result = resp.result or {}
    return { ttl = tonumber(result.TTL) }
end

function M.proto:lease_revoke(lease_id)
    local _, e = post(self, '/v3/lease/revoke', { ID = lease_id })
    if e then return nil, e end
    return true
end

-- ── Watch (polling) ──────────────────────────────────────────────────

-- watch(key, callback, opts) spawns a fiber that polls the key and
-- invokes the callback with the latest value when its mod_revision
-- advances. Returns a handle with `stop()`. The polling interval is
-- a compromise; M5/M6 may add proper streaming when http rock 2.x
-- ships.
function M.proto:watch(key, callback, opts)
    opts = opts or {}
    local interval = opts.poll_interval or 0.5
    local handle = { stop_flag = false }
    handle.fiber = fiber.create(function()
        fiber.self():name('etcd_watch_' .. key, { truncate = true })
        local last_rev = 0
        while not handle.stop_flag do
            local kv, e = self:get(key)
            if kv == nil and e then
                logger.warn('etcd watch fetch failed', { err = e.message })
            elseif kv and kv.revision and kv.revision > last_rev then
                last_rev = kv.revision
                pcall(callback, kv)
            end
            local left = interval
            while left > 0 and not handle.stop_flag do
                local slice = math.min(left, 0.1)
                fiber.sleep(slice)
                left = left - slice
            end
        end
    end)
    handle.stop = function(h) h.stop_flag = true end
    return handle
end

return M
