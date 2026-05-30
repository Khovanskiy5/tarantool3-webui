--
-- etcd helper for integration tests.
--
-- Two modes:
--   1. Attach mode (default). The helper connects to an etcd that is
--      already running and reachable at the configured endpoint. This
--      is what CI uses — `docker compose up etcd` is part of the
--      pipeline and tests share a single etcd to keep the run fast.
--   2. Ad-hoc mode. The helper starts an ephemeral etcd container via
--      `docker run`, returns control once the container is healthy,
--      and tears it down on :stop(). Useful for local debugging
--      without compose.
--
-- Operations (both modes):
--   :put(key, value), :get(key), :delete(key), :delete_prefix(prefix),
--   :endpoint(), :client(), :health()
--
-- The implementation uses the etcd v3 HTTP gateway directly, so it
-- avoids a hard dependency on the etcdctl binary.
--

local checks = require('checks')
local digest = require('digest')
local fiber  = require('fiber')
local http_client = require('http.client')
local json   = require('json')

local M = {}
M.__index = M

local DEFAULT_ENDPOINT = 'http://127.0.0.1:2379'

-- Random suffix to namespace ephemeral containers and avoid collisions
-- between parallel test runs.
local function rand_suffix()
    return tostring(math.floor(fiber.time() * 1000) % 1e8) .. '-' .. tostring(math.random(1000))
end

local function b64(s) return digest.base64_encode(s, { nowrap = true }) end
local function unb64(s) if not s then return nil end return digest.base64_decode(s) end

local function http_post(client, url, body, timeout)
    local res = client:request('POST', url, body, {
        timeout = timeout or 5,
        headers = { ['content-type'] = 'application/json' },
    })
    if res == nil then return nil, 'http request returned nil' end
    if res.status >= 400 then
        return nil, ('HTTP %d: %s'):format(res.status, tostring(res.body or ''))
    end
    local ok, parsed = pcall(json.decode, res.body or '{}')
    if not ok then return nil, 'invalid JSON: ' .. tostring(parsed) end
    return parsed
end

-- ── Attach mode ──────────────────────────────────────────────────────

function M.attach(opts)
    opts = opts or {}
    local self = setmetatable({
        _endpoint = opts.endpoint or DEFAULT_ENDPOINT,
        _ephemeral = false,
        _client = http_client.new(),
    }, M)
    return self
end

-- ── Ad-hoc mode ──────────────────────────────────────────────────────

function M.spawn(opts)
    opts = opts or {}
    local image = opts.image or 'quay.io/coreos/etcd:v3.5.18'
    local port = opts.port or (12000 + math.random(0, 999))
    local name = opts.name or ('webui-etcd-test-' .. rand_suffix())
    local endpoint = ('http://127.0.0.1:%d'):format(port)

    local cmd = table.concat({
        'docker run -d --rm',
        '--name ' .. name,
        ('-p %d:2379'):format(port),
        '-e ALLOW_NONE_AUTHENTICATION=yes',
        '-e ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379',
        '-e ETCD_ADVERTISE_CLIENT_URLS=' .. endpoint,
        '-e ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380',
        '-e ETCD_INITIAL_ADVERTISE_PEER_URLS=http://127.0.0.1:2380',
        '-e ETCD_INITIAL_CLUSTER=default=http://127.0.0.1:2380',
        '-e ETCD_INITIAL_CLUSTER_STATE=new',
        '-e ETCD_NAME=default',
        image,
    }, ' ')

    local ok = os.execute(cmd .. ' >/dev/null 2>&1')
    if not ok or ok ~= 0 and ok ~= true then
        error('cannot start ephemeral etcd container: ' .. cmd, 2)
    end

    local self = setmetatable({
        _endpoint = endpoint,
        _ephemeral = true,
        _container = name,
        _client = http_client.new(),
    }, M)

    -- Wait until the container responds to a /v3/maintenance/status probe.
    local deadline = fiber.clock() + 30
    while fiber.clock() < deadline do
        local res = self:health()
        if res then return self end
        fiber.sleep(0.3)
    end
    self:stop()
    error('etcd did not become healthy within 30s', 2)
end

-- ── teardown ─────────────────────────────────────────────────────────

function M:stop()
    if self._ephemeral and self._container then
        os.execute('docker stop ' .. self._container .. ' >/dev/null 2>&1')
    end
end

-- ── public KV API ────────────────────────────────────────────────────

function M:endpoint() return self._endpoint end

function M:health()
    local res = http_post(self._client,
        self._endpoint .. '/v3/maintenance/status', '{}', 2)
    if res == nil then return nil end
    return { version = res.version, db_size_bytes = tonumber(res.dbSize) }
end

function M:put(key, value)
    checks('table', 'string', 'string')
    local body = json.encode({ key = b64(key), value = b64(value) })
    local res, err = http_post(self._client, self._endpoint .. '/v3/kv/put', body)
    if res == nil then return nil, err end
    return tonumber(res.header and res.header.revision)
end

function M:get(key)
    checks('table', 'string')
    local body = json.encode({ key = b64(key) })
    local res, err = http_post(self._client, self._endpoint .. '/v3/kv/range', body)
    if res == nil then return nil, err end
    if type(res.kvs) ~= 'table' or res.kvs[1] == nil then return nil end
    return unb64(res.kvs[1].value),
        tonumber(res.header and res.header.revision)
end

function M:delete(key)
    checks('table', 'string')
    local body = json.encode({ key = b64(key) })
    local res, err = http_post(self._client, self._endpoint .. '/v3/kv/deleterange', body)
    if res == nil then return nil, err end
    return tonumber(res.deleted or 0)
end

function M:delete_prefix(prefix)
    checks('table', 'string')
    -- v3 range_end = key + 1 (raw byte) selects every key with the
    -- given prefix; etcd does this via {key, range_end} both base64'd.
    local range_end = prefix .. '\0'
    -- Actually etcd's prefix-delete convention is to set range_end
    -- to the prefix with the last byte incremented. Use the helper
    -- below to be safe with multi-byte prefixes.
    local last = prefix:byte(#prefix)
    if last ~= nil and last < 255 then
        range_end = prefix:sub(1, #prefix - 1) .. string.char(last + 1)
    end
    local body = json.encode({
        key = b64(prefix),
        range_end = b64(range_end),
    })
    local res, err = http_post(self._client, self._endpoint .. '/v3/kv/deleterange', body)
    if res == nil then return nil, err end
    return tonumber(res.deleted or 0)
end

return M
