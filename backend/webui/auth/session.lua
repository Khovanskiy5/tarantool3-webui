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

function M.get(id)
    checks('string')
    local space = storage.sessions()
    if space == nil then return nil end
    local tuple = space:get({ id })
    if tuple == nil then return nil end
    if tuple.expires_at <= now() then
        logger.debug('session expired', { id = id })
        return nil
    end
    return tuple
end

function M.delete(id)
    checks('string')
    local space = storage.sessions()
    if space == nil then return false end
    local tuple = space:delete({ id })
    if tuple ~= nil then
        logger.debug('session deleted', { id = id })
        return true
    end
    return false
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

-- Sweep expired sessions. Called from a periodic fiber once the
-- cluster.poller layer is happy with another scheduler hop;
-- exposed as a function so the caller can drive cadence.
function M.sweep_expired(now_ts)
    now_ts = now_ts or now()
    local space = storage.sessions()
    if space == nil then return 0 end
    local removed = 0
    local idx = space.index.by_expires_at
    if idx == nil then return 0 end
    for _, tuple in idx:pairs({ now_ts }, { iterator = 'LE' }) do
        if tuple.expires_at <= now_ts then
            space:delete({ tuple.id })
            removed = removed + 1
        else
            break
        end
    end
    if removed > 0 then
        logger.info('session sweep', { removed = removed })
    end
    return removed
end

return M
