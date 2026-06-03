--
-- Session store (Task 25 fills in CRUD).
--
-- M2 lays the data layout: `_webui_sessions` is a replicated
-- space keyed by an opaque session id with `expires_at` carrying
-- the TTL. This module is a thin façade over the space so the
-- REST handlers (auth.lua) and the WS authoriser (ws.lua) speak
-- one vocabulary regardless of how the underlying table is
-- packed.
--
-- The functions below are intentionally small. Heavier flows
-- (login, logout, refresh, CSRF rotation) live in the API task.
--

local checks = require('checks')
local digest = require('digest')

local storage  = require('webui.storage.spaces')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('session')

local M = {}

-- Default session lifetime. Operators override via cluster
-- config (`roles_cfg.webui.session_ttl_sec`) once the config-edit
-- surface lands; until then the constant is the contract.
M.DEFAULT_TTL_SEC = 24 * 3600

local function now() return os.time() end

-- Insert a new session row. Caller owns generating the id /
-- csrf token — typically through `digest.urandom`.
function M.create(opts)
    checks({
        id         = 'string',
        user       = 'string',
        csrf       = 'string',
        ttl_sec    = '?number',
        ip         = '?string',
        user_agent = '?string',
    })
    local space = storage.sessions()
    assert(space ~= nil, 'session storage is not bootstrapped')
    local ttl = opts.ttl_sec or M.DEFAULT_TTL_SEC
    local created = now()
    local tuple = space:insert({
        opts.id, opts.user, created, created + ttl,
        opts.csrf, opts.ip, opts.user_agent,
    })
    logger.debug('session created', {
        id = opts.id, user = opts.user, ttl_sec = ttl,
    })
    return tuple
end

-- Insert a session into the LOCAL fallback space. Writable even under
-- read_only (the space is `is_local`), so login succeeds on a broken
-- cluster with no durable+confirmable leader. Same tuple shape as the
-- durable store; `get`/`delete`/sweep look in both. (Recovery
-- chicken-and-egg fix.)
function M.create_local(opts)
    checks({
        id         = 'string',
        user       = 'string',
        csrf       = 'string',
        ttl_sec    = '?number',
        ip         = '?string',
        user_agent = '?string',
    })
    local space = storage.sessions_local()
    assert(space ~= nil, 'local session storage is not bootstrapped')
    local ttl = opts.ttl_sec or M.DEFAULT_TTL_SEC
    local created = now()
    local tuple = space:insert({
        opts.id, opts.user, created, created + ttl,
        opts.csrf, opts.ip, opts.user_agent,
    })
    logger.warn('degraded LOCAL session created (no durable leader)', {
        id = opts.id, user = opts.user, ttl_sec = ttl,
    })
    return tuple
end

function M.get(id)
    checks('string')
    local space = storage.sessions()
    local tuple = space ~= nil and space:get({ id }) or nil
    if tuple == nil then
        -- Fall back to the local degraded store (created when the cluster
        -- had no durable leader). HAProxy stickiness keeps the operator on
        -- the instance that issued it.
        local lspace = storage.sessions_local()
        tuple = lspace ~= nil and lspace:get({ id }) or nil
    end
    if tuple == nil then return nil end
    if tuple.expires_at <= now() then
        logger.debug('session expired', { id = id })
        return nil
    end
    return tuple
end

function M.delete(id)
    checks('string')
    local deleted = false
    local space = storage.sessions()
    if space ~= nil then
        local ok, tuple = pcall(function() return space:delete({ id }) end)
        if ok and tuple ~= nil then deleted = true end
    end
    -- Always best-effort delete from the local store too.
    local lspace = storage.sessions_local()
    if lspace ~= nil then
        local ok, tuple = pcall(function() return lspace:delete({ id }) end)
        if ok and tuple ~= nil then deleted = true end
    end
    if deleted then logger.debug('session deleted', { id = id }) end
    return deleted
end

-- Generate a fresh opaque session id (256-bit entropy, url-safe).
function M.new_id()
    return digest.base64_encode(digest.urandom(32),
        { nowrap = true, urlsafe = true })
end

-- Generate a CSRF token paired with the session cookie.
function M.new_csrf()
    return digest.base64_encode(digest.urandom(32),
        { nowrap = true, urlsafe = true })
end

-- Block until the session row with `id` shows up locally (or the
-- deadline passes). Used by the login forwarder so the cookie that
-- the follower hands the browser is immediately valid against its
-- own `session.get(...)`.
function M.wait_for_local(id, deadline_sec)
    local fiber_lib = require('fiber')
    local deadline = fiber_lib.time() + (deadline_sec or 2)
    while fiber_lib.time() < deadline do
        local tuple = M.get(id)
        if tuple ~= nil then return tuple end
        fiber_lib.sleep(0.05)
    end
    return nil
end

-- Remote-invocable session creator. Lives on every instance; only
-- succeeds on the leader (the underlying space write would fail
-- under READONLY otherwise). The follower forwards through here
-- via the `webui_peer` net.box pool when its own write is blocked.
--
-- The function is exposed through `_G` so net.box `:call(...)` can
-- reach it; it's NOT a Tarantool function (`box.schema.func.create`)
-- because the peer pool authenticates as `webui_peer` which already
-- has `super`. The role's `validate` step refuses startup if the
-- system user is misconfigured.
function M.install_remote()
    rawset(_G, 'webui_session_create_remote', function(opts)
        if type(opts) ~= 'table' then
            return nil, 'bad opts'
        end
        local ok, result = pcall(M.create, opts)
        if not ok then return nil, tostring(result) end
        if result == nil then return nil, 'insert returned nil' end
        return {
            id         = result.id,
            user       = result.user,
            expires_at = result.expires_at,
        }
    end)
    rawset(_G, 'webui_session_delete_remote', function(id)
        if type(id) ~= 'string' then return nil, 'bad id' end
        local ok, result = pcall(M.delete, id)
        if not ok then return nil, tostring(result) end
        return { deleted = result == true }
    end)
end

-- Sweep expired sessions. Called from a periodic fiber once the
-- cluster.poller layer is happy with another scheduler hop;
-- exposed as a function so the caller can drive cadence.
local function sweep_space(space, now_ts)
    if space == nil or space.index.by_expires_at == nil then return 0 end
    local removed = 0
    for _, tuple in space.index.by_expires_at:pairs({ now_ts },
        { iterator = 'LE' }) do
        if tuple.expires_at <= now_ts then
            local ok = pcall(function() space:delete({ tuple.id }) end)
            if ok then removed = removed + 1 else break end
        else
            break
        end
    end
    return removed
end

function M.sweep_expired(now_ts)
    now_ts = now_ts or now()
    -- Replicated store sweep runs on the leader; the local store sweep is
    -- per-instance (its rows never replicate). Both are best-effort.
    local removed = sweep_space(storage.sessions(), now_ts)
        + sweep_space(storage.sessions_local(), now_ts)
    if removed > 0 then
        logger.info('session sweep', { removed = removed })
    end
    return removed
end

return M
