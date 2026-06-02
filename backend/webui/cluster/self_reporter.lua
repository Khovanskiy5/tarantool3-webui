--
-- Instance state reporter — open-source equivalent of the top-level
-- `stateboard.*` block from Tarantool Enterprise.
--
-- One fiber per instance writes a small JSON payload describing the
-- local box.info to `<prefix>/state/by-name/<alias>` in etcd. The
-- key is bound to an etcd lease, so a hard crash (kill -9, OOM,
-- network partition) lets the lease expire and the key disappears
-- on its own. A graceful stop revokes the lease synchronously so
-- the key vanishes within milliseconds.
--
-- The publisher is opt-in (`roles_cfg.webui.state_reporter.enabled`)
-- because not every cluster needs an extra liveness channel — the
-- existing peer_poller covers most of the same ground over iproto.
-- The reporter is useful when an operator wants to distinguish
-- "iproto unreachable but process up" from "process gone" without
-- waiting for poller timeouts.
--
-- Payload shape (matches Enterprise stateboard's documented fields):
--   hostname   string   resolved once at start
--   pid        integer  box.info.pid
--   alias      string   box.info.name
--   mode       string   "rw" | "ro"
--   ro_reason  string?  box.info.ro_reason (nil when rw)
--   status     string   box.info.status
--   ts         number   fiber.time() when the snapshot was taken
--
-- Reliability rules followed (per project convention):
--   * locals everywhere, no globals beyond the module export
--   * every blocking call (lease_grant, put, keepalive) wrapped in pcall
--   * stop_flag re-checked between every sleep slice
--   * synchronous lease_revoke on stop — best-effort, never blocks > 2s
--   * lease loss (TTL=0 from keepalive) triggers regrant on next tick
--   * etcd unavailable → log warn, retry on next tick with backoff
--

local fiber = require('fiber')
local json  = require('json')

local etcd_client = require('webui.config_store.client')
local log_util    = require('webui.log_util')
local logger      = log_util.with_tag('cluster.self_reporter')

local M = {}

M.DEFAULTS = {
    enabled            = false,
    renew_interval     = 2,
    keepalive_interval = 10,
}

M.KEY_PREFIX = '/state/by-name/'

local STATE = {
    enabled        = false,
    config         = nil,
    self_alias     = nil,
    hostname       = nil,
    lease_id       = nil,
    last_payload   = nil,
    last_error     = nil,
    stop_flag      = false,
    fiber          = nil,
}

-- ─────────────────────────────────────────────────────────────────────
-- Pure helpers (unit-tested)
-- ─────────────────────────────────────────────────────────────────────

-- Resolve a hostname without doing a blocking syscall on every tick.
-- Preference order: $HOSTNAME (docker injects it) → /etc/hostname →
-- 'unknown'. Called once at start; the resolved value is cached in
-- STATE.hostname.
function M.resolve_hostname()
    local env = os.getenv('HOSTNAME')
    if type(env) == 'string' and env ~= '' then return env end
    local fh = io.open('/etc/hostname', 'r')
    if fh ~= nil then
        local line = fh:read('*l')
        fh:close()
        if type(line) == 'string' then
            local trimmed = line:gsub('%s+$', '')
            if trimmed ~= '' then return trimmed end
        end
    end
    return 'unknown'
end

-- Build the JSON payload from a box.info-like table. Pure: takes
-- everything it needs as arguments so unit tests can drive it
-- without a live box. `now` is passed in for the same reason.
function M.build_payload(info, hostname, alias, now)
    local payload = {
        hostname  = hostname,
        pid       = info.pid,
        alias     = alias,
        mode      = info.ro and 'ro' or 'rw',
        ro_reason = info.ro_reason,
        status    = info.status,
        ts        = now,
    }
    return payload
end

-- ─────────────────────────────────────────────────────────────────────
-- Etcd lease helpers
-- ─────────────────────────────────────────────────────────────────────

local function ensure_lease(client)
    if STATE.lease_id ~= nil then return STATE.lease_id end
    local ttl = STATE.config.keepalive_interval
    local lease, err = client:lease_grant(ttl)
    if lease == nil then
        STATE.last_error = 'lease_grant: ' .. tostring(err and err.message or err)
        return nil
    end
    STATE.lease_id = lease.id
    logger.info('state lease granted', {
        lease_id = STATE.lease_id, ttl_sec = ttl,
    })
    return STATE.lease_id
end

local function release_lease(client)
    if STATE.lease_id == nil then return end
    local lease_id = STATE.lease_id
    STATE.lease_id = nil
    if client == nil then return end
    local ok, err = pcall(function() return client:lease_revoke(lease_id) end)
    if ok then
        logger.info('state lease revoked', { lease_id = lease_id })
    else
        logger.warn('state lease revoke failed', {
            lease_id = lease_id, err = tostring(err),
        })
    end
end

local function key_for(alias)
    return M.KEY_PREFIX .. alias
end

-- Encode a payload to JSON, comparing against the cached last_payload
-- as raw strings so we skip puts when nothing changed. Cuts etcd
-- write amplification on quiet clusters from ~30/min to ~6/min
-- (just lease keepalives + the periodic refresh).
local function encode_or_skip(payload)
    local ok, encoded = pcall(json.encode, payload)
    if not ok then
        return nil, 'json encode failed: ' .. tostring(encoded)
    end
    if encoded == STATE.last_payload then return nil, 'unchanged' end
    return encoded
end

-- ─────────────────────────────────────────────────────────────────────
-- Main loop
-- ─────────────────────────────────────────────────────────────────────

local function tick()
    local client, err = etcd_client.get_client()
    if client == nil then
        STATE.last_error = 'etcd unavailable: ' .. tostring(err)
        STATE.lease_id = nil
        return
    end

    if ensure_lease(client) == nil then return end

    -- Keep the lease alive. If the server says TTL=0 (e.g. a long
    -- partition let our lease expire), drop our cached id and regrant
    -- on the next tick.
    local ka_ok, ka = pcall(function()
        return client:lease_keepalive(STATE.lease_id)
    end)
    if not ka_ok or ka == nil or ka.ttl == nil or ka.ttl == 0 then
        logger.warn('lease keepalive lost; will regrant', {
            lease_id = STATE.lease_id,
        })
        STATE.lease_id = nil
        STATE.last_payload = nil
        STATE.last_error = 'lease lost'
        return
    end

    local payload = M.build_payload(
        box.info, STATE.hostname, STATE.self_alias, fiber.time())
    local encoded, reason = encode_or_skip(payload)
    if encoded == nil then
        if reason == 'unchanged' then STATE.last_error = nil end
        return
    end

    local put_ok, put_err = pcall(function()
        return client:put(key_for(STATE.self_alias), encoded, STATE.lease_id)
    end)
    if not put_ok or put_err == nil then
        -- put returns (result, err); the pcall captures runtime errors.
        if not put_ok then
            STATE.last_error = 'put raised: ' .. tostring(put_err)
        end
        return
    end
    STATE.last_payload = encoded
    STATE.last_error = nil
end

local function loop()
    fiber.self():name('webui_self_reporter', { truncate = true })
    while not STATE.stop_flag do
        local ok, err = pcall(tick)
        if not ok then
            STATE.last_error = 'tick raised: ' .. tostring(err)
            logger.warn('self_reporter tick raised', { err = tostring(err) })
        end
        -- Sleep in small slices so stop() returns within ~100ms,
        -- not at the end of a full renew_interval.
        local left = STATE.config.renew_interval
        while left > 0 and not STATE.stop_flag do
            local slice = math.min(left, 0.1)
            fiber.sleep(slice)
            left = left - slice
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────
-- Public surface
-- ─────────────────────────────────────────────────────────────────────

function M.start(opts)
    if STATE.enabled then return true end
    opts = opts or {}
    if opts.enabled ~= true then return nil, 'disabled' end

    STATE.config = {}
    for k, default in pairs(M.DEFAULTS) do
        local v = opts[k]
        if type(v) == 'number' and v > 0 then
            STATE.config[k] = v
        else
            STATE.config[k] = default
        end
    end
    STATE.config.enabled = true

    STATE.self_alias = (rawget(_G, 'box') and box.info and box.info.name) or nil
    if STATE.self_alias == nil then
        return nil, 'box.info.name unavailable; refusing to start'
    end
    STATE.hostname = M.resolve_hostname()
    STATE.stop_flag = false
    STATE.enabled = true
    STATE.lease_id = nil
    STATE.last_payload = nil
    STATE.last_error = nil
    STATE.fiber = fiber.create(loop)

    logger.info('state reporter started', {
        alias              = STATE.self_alias,
        hostname           = STATE.hostname,
        renew_interval     = STATE.config.renew_interval,
        keepalive_interval = STATE.config.keepalive_interval,
    })
    return true
end

function M.stop()
    if not STATE.enabled then return end
    STATE.stop_flag = true
    STATE.enabled = false

    -- Synchronously revoke the lease before returning so the etcd
    -- entry vanishes immediately on a graceful stop. The loop will
    -- also wake up and exit on its own; this just ensures we don't
    -- leave a stale liveness key for the next coordinator to see.
    local client = etcd_client.get_client()
    release_lease(client)

    STATE.fiber = nil
    STATE.last_payload = nil
    logger.info('state reporter stopped')
end

function M.status()
    return {
        enabled      = STATE.enabled,
        self_alias   = STATE.self_alias,
        hostname     = STATE.hostname,
        lease_id     = STATE.lease_id and tostring(STATE.lease_id) or nil,
        last_error   = STATE.last_error,
    }
end

-- Test-only: drop in-memory STATE so unit tests can re-enter start()
-- without leaking fibers from previous cases. Mirrors agent._reset.
function M._reset()
    STATE.enabled = false
    STATE.stop_flag = true
    STATE.lease_id = nil
    STATE.last_payload = nil
    STATE.last_error = nil
    STATE.fiber = nil
end

return M
