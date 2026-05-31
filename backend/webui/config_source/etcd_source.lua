--
-- Community-edition implementation of the etcd config source.
--
-- Tarantool 3.x ships with a built-in etcd source as part of the
-- Enterprise-only `internal.config.extras` module. On Community
-- Edition that module is absent and the schema rejects `config.etcd`.
-- This file is the open-source analog: a config source that reads
-- cluster configuration from an etcd v3 cluster over the HTTP gateway
-- using nothing more than rocks that already ship with the rockspec
-- (`http`, `lyaml`, `json`).
--
-- Wiring:
--   * `internal.config.extras` (our companion file) registers an
--     instance of this source during `config:_initialize`.
--   * Tarantool calls `sync()` on the source whenever it (re)reads
--     configuration; the source returns the parsed cluster_config
--     YAML body fetched from `<prefix>/config` in etcd.
--   * The source contract follows the same interface as the built-in
--     `internal.config.source.file` source documented in
--     tarantool-3.7.0/src/box/lua/config/init.lua:_register_source.
--
-- Feature parity with EE (what we cover):
--   * endpoints[]                — multi-endpoint failover (sticky to
--                                  first working endpoint per sync)
--   * prefix                     — cluster-wide config key path
--   * username / password        — basic auth via /v3/auth/authenticate
--   * ssl.ca_file                — root CA bundle for TLS verification
--   * ssl.ssl_cert / ssl.ssl_key — client cert for mTLS
--   * ssl.verify_peer            — toggle TLS verification
--   * http.request.timeout       — per-request timeout
--
-- Out of scope (Task 30 will extend):
--   * etcd watch / live updates (current sync is poll-on-demand)
--   * lease / edit-lock management
--   * txn for CAS writes
--
-- Etcd v3 API quirks we honour:
--   * keys / values are base64-encoded in JSON request / response
--     bodies, so values come back as base64 strings.
--   * The /v3/auth/authenticate endpoint returns a JWT in the `token`
--     field which subsequent requests must echo via `Authorization`.

local http_client = require('http.client').new()
local digest = require('digest')
local json = require('json')
local yaml = require('yaml')
local fiber = require('fiber')
local log = require('log')

local M = {}
M.__index = M

local DEFAULT_TIMEOUT = 5

-- ── small helpers ──────────────────────────────────────────────────────

local function b64(s)
    return digest.base64_encode(s, { nowrap = true, urlsafe = false, nopad = false })
end

local function unb64(s)
    if s == nil then return nil end
    return digest.base64_decode(s)
end

-- Extract a positional or nil-safe nested field from instance config.
-- iconfig is the table produced by env + file sources before our source
-- runs; we read only the etcd-specific subtree.
local function read_etcd_iconfig(iconfig)
    if type(iconfig) ~= 'table' then return nil end
    local cfg_node = iconfig.config
    if type(cfg_node) ~= 'table' then return nil end
    local etcd = cfg_node.etcd
    if type(etcd) ~= 'table' then return nil end
    return etcd
end

-- Normalise an endpoint URL into protocol/host/port pieces and decide
-- whether TLS material applies.
local function classify_endpoint(url)
    -- url is like http://etcd-0.example.com:2379 or https://...
    local scheme = url:match('^(%w+)://')
    return {
        url = url,
        is_https = scheme == 'https',
    }
end

-- Build a request body that ranges a single key. The etcd v3 KV API
-- expects both `key` and `range_end` as base64; omitting `range_end`
-- fetches exactly that key.
local function build_range_body(key)
    return json.encode({ key = b64(key) })
end

-- ── instance lifecycle ────────────────────────────────────────────────

function M.new(opts)
    opts = opts or {}
    -- Tarantool's `_register_source` contract (see
    -- tarantool-3.7.0/src/box/lua/config/init.lua line 128 onward)
    -- requires `name` and `type` to be plain string fields on the
    -- source table; they MUST be at the top level, not hidden under
    -- underscored aliases.
    local self = setmetatable({
        name = opts.name or 'etcd',
        type = 'cluster',
        _last_payload  = nil,       -- most recently fetched YAML body
        _last_revision = nil,       -- etcd revision of that payload
        _auth_tokens   = {},        -- endpoint URL -> JWT
        _log_prefix    = '[webui.config_source.etcd]',
    }, M)
    return self
end

-- ── HTTP helpers ──────────────────────────────────────────────────────

function M:_http_request(endpoint, path, body, auth_token, ssl_cfg, timeout)
    local ep = classify_endpoint(endpoint)
    local opts = {
        timeout = timeout or DEFAULT_TIMEOUT,
        headers = {
            ['content-type'] = 'application/json',
        },
    }
    if auth_token then
        opts.headers['authorization'] = auth_token
    end
    if ep.is_https and type(ssl_cfg) == 'table' then
        opts.ca_file       = ssl_cfg.ca_file
        opts.ssl_cert      = ssl_cfg.ssl_cert
        opts.ssl_key       = ssl_cfg.ssl_key
        opts.verify_host   = ssl_cfg.verify_peer ~= false and 2 or 0
        opts.verify_peer   = ssl_cfg.verify_peer ~= false
    end
    local url = endpoint .. path
    local res = http_client:request('POST', url, body, opts)
    if res == nil then
        return nil, 'http request returned nil for ' .. url
    end
    if res.status >= 400 then
        return nil, ('%s -> HTTP %d: %s'):format(
            url, res.status, tostring(res.body or '')
        )
    end
    local ok, parsed = pcall(json.decode, res.body or '')
    if not ok then
        return nil, 'cannot decode etcd response JSON: ' .. tostring(parsed)
    end
    return parsed
end

-- Fetch (and cache) a JWT for an endpoint when basic auth is configured.
-- Etcd revokes tokens on auth changes; we refresh on every sync.
function M:_authenticate(endpoint, username, password, ssl_cfg, timeout)
    if not username or username == '' then return nil end
    local body = json.encode({ name = username, password = password })
    local parsed, err = self:_http_request(
        endpoint, '/v3/auth/authenticate', body, nil, ssl_cfg, timeout
    )
    if parsed == nil then
        return nil, err
    end
    return parsed.token
end

-- Try endpoints in order; the first successful response wins. This is
-- a simple sticky-failover; etcd's own client libs do more aggressive
-- rotation, but for cluster-config bootstrap a single attempt per
-- endpoint is sufficient and predictable.
function M:_fetch_key(endpoints, key, username, password, ssl_cfg, timeout)
    local errors = {}
    for _, endpoint in ipairs(endpoints) do
        local auth_token
        if username and username ~= '' then
            local tok, auth_err = self:_authenticate(
                endpoint, username, password, ssl_cfg, timeout
            )
            if tok == nil then
                table.insert(errors,
                    ('%s: auth failed: %s'):format(endpoint, auth_err or 'unknown'))
                goto continue
            end
            auth_token = tok
        end
        local parsed, err = self:_http_request(
            endpoint,
            '/v3/kv/range',
            build_range_body(key),
            auth_token,
            ssl_cfg,
            timeout
        )
        if parsed ~= nil then
            local revision = parsed.header and tonumber(parsed.header.revision)
            local kvs = parsed.kvs
            if type(kvs) ~= 'table' or kvs[1] == nil then
                return nil, ('%s: key %q not found'):format(endpoint, key)
            end
            return unb64(kvs[1].value), revision, endpoint
        end
        table.insert(errors, ('%s: %s'):format(endpoint, err or 'unknown'))
        ::continue::
    end
    return nil, 'all etcd endpoints failed:\n  - ' ..
        table.concat(errors, '\n  - ')
end

-- ── source interface (required by config:_register_source) ────────────

function M:sync(_config_module, iconfig)
    local etcd_cfg = read_etcd_iconfig(iconfig)
    if etcd_cfg == nil then
        -- Nothing to do; the config has no etcd section. Tarantool
        -- merges results from every registered source, and nil from
        -- get() trips a "Unexpected data type for a record" merge
        -- error. Returning an empty table keeps the merge a no-op.
        self._last_payload = {}
        return
    end

    local endpoints = etcd_cfg.endpoints
    if type(endpoints) ~= 'table' or endpoints[1] == nil then
        error(self._log_prefix ..
            ' config.etcd.endpoints must be a non-empty list', 0)
    end

    local prefix = etcd_cfg.prefix
    if type(prefix) ~= 'string' or prefix == '' then
        error(self._log_prefix ..
            ' config.etcd.prefix is required', 0)
    end
    -- Tarantool's documented contract is that the cluster config lives
    -- at `<prefix>/config/all`. Older deployments used `<prefix>/config`.
    -- Try the canonical key first and fall back to the legacy one so
    -- users migrating between layouts do not need a flag day.
    local key_primary = prefix:gsub('/+$', '') .. '/config/all'
    local key_legacy  = prefix:gsub('/+$', '') .. '/config'

    local timeout
    if type(etcd_cfg.http) == 'table' and
       type(etcd_cfg.http.request) == 'table' then
        timeout = tonumber(etcd_cfg.http.request.timeout) or DEFAULT_TIMEOUT
    else
        timeout = DEFAULT_TIMEOUT
    end

    local ssl_cfg
    if type(etcd_cfg.ssl) == 'table' then
        ssl_cfg = etcd_cfg.ssl
    end

    local body, revision, used_endpoint
    body, revision, used_endpoint = self:_fetch_key(
        endpoints, key_primary,
        etcd_cfg.username, etcd_cfg.password,
        ssl_cfg, timeout
    )
    if body == nil then
        local err1 = revision  -- on error _fetch_key returns error string in 2nd slot
        body, revision, used_endpoint = self:_fetch_key(
            endpoints, key_legacy,
            etcd_cfg.username, etcd_cfg.password,
            ssl_cfg, timeout
        )
        if body == nil then
            -- Missing key: behave as a quiet no-op source so the
            -- cluster can still boot from the file source. The
            -- WebUI's commit flow seeds the key on first save, at
            -- which point subsequent syncs pick it up and start
            -- contributing. Only hard-fail on transport errors
            -- (auth, DNS, TLS handshake) — those are operator
            -- problems that need attention.
            local err2 = revision
            local err1_s = tostring(err1)
            local err2_s = tostring(err2)
            local is_not_found = err1_s:find('not found', 1, true)
                or err2_s:find('not found', 1, true)
            if is_not_found then
                log.info(('%s key %q absent; falling back to other sources')
                    :format(self._log_prefix, key_primary))
                self._last_payload = {}
                self._last_revision = nil
                self._last_endpoint = nil
                self._last_synced_at = fiber.time()
                return
            end
            error(self._log_prefix ..
                ' cannot fetch cluster config from etcd:\n' ..
                'primary key ' .. key_primary .. ': ' .. err1_s ..
                '\nlegacy key ' .. key_legacy .. ': ' .. err2_s, 0)
        end
    end

    local ok, parsed = pcall(yaml.decode, body)
    if not ok or type(parsed) ~= 'table' then
        error(self._log_prefix ..
            ' etcd payload is not a valid YAML mapping: ' .. tostring(parsed), 0)
    end

    self._last_payload = parsed
    self._last_revision = revision
    self._last_endpoint = used_endpoint
    self._last_synced_at = fiber.time()
end

function M:get()
    -- Mirror file source semantics: when this source has nothing to
    -- contribute, return an empty table (NOT nil). cluster_config:merge
    -- explicitly rejects nil with "Unexpected data type for a record".
    return self._last_payload or {}
end

-- Helper used by /api/health (Task 30+) to expose last sync state.
function M:status()
    return {
        last_synced_at = self._last_synced_at,
        last_revision  = self._last_revision,
        last_endpoint  = self._last_endpoint,
        ready          = self._last_payload ~= nil,
    }
end

return M
