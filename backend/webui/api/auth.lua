--
-- REST handlers for /api/auth/{login,logout,me}.
--
-- Login: validates the user/password pair locally via
-- `box.schema.user.auth_password`. The `webui_peer` system user
-- is explicitly forbidden — it is for net.box and never for
-- humans. Successful logins issue a session cookie + CSRF token.
--
-- Logout: drops the session row. The Task 26a hook on the WS
-- registry tears down active WS connections for the session.
--
-- /me returns the current user and the role set. RBAC role
-- resolution lands in Task 26; for now we expose the user name
-- and an empty roles array as the contract placeholder.
--

local json = require('json')

local session    = require('webui.auth.session')
local rate_limit = require('webui.auth.rate_limit')
local audit      = require('webui.audit.log')
local log_util   = require('webui.log_util')
local logger     = log_util.with_tag('api.auth')

local M = {}

local COOKIE_NAME = 'webui_session'
local CSRF_HEADER = 'x-csrf-token'

local function client_ip(req)
    if req.peer and req.peer.host then return tostring(req.peer.host) end
    return req.headers and (req.headers['x-forwarded-for'] or req.headers['x-real-ip'])
        or '_'
end

local function user_agent(req)
    if req.headers == nil then return nil end
    return req.headers['user-agent']
end

-- The cookie's flags depend on whether the request arrived over
-- HTTPS. HAProxy in the prod compose terminates TLS upstream and
-- sets `x-forwarded-proto: https`; honour that header so the
-- secure flag survives the proxy.
local function build_cookie(value, opts)
    opts = opts or {}
    local parts = {
        COOKIE_NAME .. '=' .. value,
        'Path=/',
        'HttpOnly',
        'SameSite=Strict',
    }
    if opts.secure then table.insert(parts, 'Secure') end
    if opts.max_age then
        table.insert(parts, 'Max-Age=' .. tostring(opts.max_age))
    elseif opts.expire then
        table.insert(parts, 'Max-Age=0')
        table.insert(parts, 'Expires=Thu, 01 Jan 1970 00:00:00 GMT')
    end
    return table.concat(parts, '; ')
end

local function is_secure(req)
    local h = req.headers or {}
    if h['x-forwarded-proto'] == 'https' then return true end
    return false
end

local function parse_cookie(req)
    local raw = req.headers and req.headers['cookie']
    if type(raw) ~= 'string' then return nil end
    for piece in raw:gmatch('([^; ]+)') do
        local name, value = piece:match('^([^=]+)=(.+)$')
        if name == COOKIE_NAME then return value end
    end
    return nil
end

local function json_response(status, body, headers)
    headers = headers or {}
    headers['content-type'] = 'application/json; charset=utf-8'
    return {
        status = status,
        headers = headers,
        body = json.encode(body),
    }
end

-- ─────────────────────────────────────────────────────────────────────
-- /api/auth/login
-- ─────────────────────────────────────────────────────────────────────

local function decode_body(req)
    -- The http rock exposes the request body via `req:read_cached()`
    -- (it streams from the socket on first call and memoises the
    -- result). `req.body` is unset; using it would always return
    -- nil and turn every login into INVALID_QUERY.
    local raw
    if type(req.read_cached) == 'function' then
        local ok_read
        ok_read, raw = pcall(req.read_cached, req)
        if not ok_read then return nil end
    else
        raw = req.body
    end
    if raw == nil or raw == '' then return nil end
    local ok, parsed = pcall(json.decode, raw)
    if not ok then return nil end
    return parsed
end

function M.handler_login(req)
    local ip = client_ip(req)

    local allowed, _count, _retry = rate_limit.check(ip, 'login')
    if not allowed then
        logger.error('login rate limited', { ip = ip })
        return json_response(429, {
            error = { code = 'RATE_LIMITED', message = 'too many attempts' },
        })
    end

    local body = decode_body(req)
    if type(body) ~= 'table' or type(body.user) ~= 'string'
        or type(body.password) ~= 'string' then
        return json_response(400, {
            error = { code = 'INVALID_QUERY',
                message = 'user and password are required' },
        })
    end

    if body.user == 'webui_peer' or body.user == 'replicator' then
        rate_limit.fail(ip, 'login')
        logger.warn('login attempt for system user blocked', {
            user = body.user, ip = ip,
        })
        return json_response(403, {
            error = { code = 'FORBIDDEN', message = 'system user' },
        })
    end

    -- Tarantool 3.x does not expose `box.schema.user.auth_password`.
    -- Match `box.schema.user.password(input)` (chap-sha1 base64) against
    -- the row in `_user` directly — both sides are deterministic strings
    -- so a plain equality check suffices.
    local function check_password(user, password)
        local row = box.space._user.index.name:get(user)
        if row == nil then return false end
        local auth = row[5]
        if type(auth) ~= 'table' then return false end
        local stored = auth['chap-sha1']
        if type(stored) ~= 'string' or stored == '' then return false end
        return box.schema.user.password(password) == stored
    end
    local ok_check, authed = pcall(check_password, body.user, body.password)
    if not ok_check or not authed then
        local fails = rate_limit.fail(ip, 'login')
        logger.warn('login failed', { user = body.user, ip = ip, fails = fails })
        return json_response(401, {
            error = { code = 'LOGIN_FAILED', message = 'invalid credentials' },
        })
    end

    -- Successful auth.
    rate_limit.success(ip, 'login')
    local id = session.new_id()
    local csrf = session.new_csrf()
    local create_opts = {
        id = id, user = body.user, csrf = csrf,
        ttl_sec = nil, ip = ip, user_agent = user_agent(req),
    }

    -- `_webui_sessions` is a replicated space, so INSERT lands on
    -- the leader. On a follower the local call raises READONLY.
    -- We detect that and forward to the leader through the existing
    -- `webui_peer` net.box pool, then wait for replication to push
    -- the row back so the cookie we return is immediately valid
    -- against this instance's own `session.get(...)`.
    local sess_ok, sess_err = pcall(session.create, create_opts)
    local sess_err_str = tostring(sess_err or '')
    local is_readonly = (not sess_ok)
        and (sess_err_str:find('read[- ]only', 1, false)
            or sess_err_str:find('READONLY', 1, true))
    if not sess_ok and is_readonly then
        logger.info('login: local instance is read-only, forwarding to leader',
            { user = body.user })
        local ok_state, cluster_state = pcall(require, 'webui.cluster.state')
        local ok_peers, peers         = pcall(require, 'webui.cluster.peers')
        local leader_alias
        if ok_state then leader_alias = cluster_state.find_leader() end
        if leader_alias == nil or not ok_peers then
            logger.warn('login forward failed: no leader available')
            return json_response(503, {
                error = { code = 'NO_LEADER',
                    message = 'no cluster leader reachable; retry shortly' },
            })
        end
        local peer = peers.get(leader_alias)
        if peer == nil or peer.conn == nil then
            logger.warn('login forward failed: leader connection unavailable',
                { leader = leader_alias })
            return json_response(503, {
                error = { code = 'NO_LEADER',
                    message = 'leader connection unavailable; retry shortly' },
            })
        end
        local call_ok, call_res = pcall(function()
            return peer.conn:call('webui_session_create_remote',
                { create_opts }, { timeout = 3 })
        end)
        if not call_ok or call_res == nil then
            logger.error('login forward to leader failed', {
                leader = leader_alias, err = tostring(call_res),
            })
            return json_response(503, {
                error = { code = 'UNAVAILABLE',
                    message = 'leader rejected session create' },
            })
        end
        -- Wait for the replicated row to be visible locally so the
        -- cookie we just issued is immediately accepted.
        local replicated = session.wait_for_local(id, 2)
        if replicated == nil then
            logger.warn('login forward ok but replication lag exceeded',
                { leader = leader_alias })
            return json_response(503, {
                error = { code = 'REPLICATION_LAG',
                    message = 'session not yet replicated; retry shortly' },
            })
        end
        logger.info('login forwarded ok', {
            user = body.user, leader = leader_alias,
        })
    elseif not sess_ok then
        logger.error('session create failed', { err = sess_err_str })
        return json_response(503, {
            error = { code = 'UNAVAILABLE',
                message = 'session storage unavailable' },
        })
    end

    pcall(audit.record, {
        user = body.user, action = 'auth.login', scope = 'session',
        request_id = req.request_id, payload = { ip = ip },
    })
    logger.info('login ok', { user = body.user, ip = ip })

    -- Two cookies on a successful login:
    --   * `webui_session`  HttpOnly — the cookie the browser sends
    --                      on every request, never visible to JS.
    --   * `webui_csrf`     readable (no HttpOnly) — the SPA reads
    --                      this to mirror back into `X-Csrf-Token`
    --                      on every state-changing request, i.e.
    --                      a classic double-submit CSRF token.
    local ttl = require('webui.auth.session').DEFAULT_TTL_SEC
    local csrf_cookie = table.concat({
        'webui_csrf=' .. csrf,
        'Path=/',
        'SameSite=Strict',
        'Max-Age=' .. tostring(ttl),
    }, '; ')
    if is_secure(req) then csrf_cookie = csrf_cookie .. '; Secure' end
    return json_response(200, {
        user = body.user, csrf = csrf, expiresIn = ttl,
    }, {
        ['set-cookie'] = {
            build_cookie(id, { secure = is_secure(req), max_age = ttl }),
            csrf_cookie,
        },
        [CSRF_HEADER] = csrf,
    })
end

-- ─────────────────────────────────────────────────────────────────────
-- /api/auth/logout
-- ─────────────────────────────────────────────────────────────────────

function M.handler_logout(req)
    local id = parse_cookie(req)
    local user
    if id ~= nil then
        local tuple = session.get(id)
        if tuple ~= nil then user = tuple.user end

        -- `_webui_sessions` is replicated, so DELETE lands on the
        -- leader; on a follower we forward through the existing
        -- net.box pool exactly like login does. Logout being a
        -- best-effort operation, READONLY without a reachable
        -- leader is downgraded to a warning — the SPA still drops
        -- the cookie and the session expires naturally.
        local del_ok, del_err = pcall(session.delete, id)
        local del_err_str = tostring(del_err or '')
        local is_readonly = (not del_ok)
            and (del_err_str:find('read[- ]only', 1, false)
                or del_err_str:find('READONLY', 1, true))
        if not del_ok and is_readonly then
            logger.info('logout: local instance is read-only, forwarding to leader',
                { user = user })
            local ok_state, cluster_state = pcall(require, 'webui.cluster.state')
            local ok_peers, peers         = pcall(require, 'webui.cluster.peers')
            local leader_alias
            if ok_state then leader_alias = cluster_state.find_leader() end
            if leader_alias ~= nil and ok_peers then
                local peer = peers.get(leader_alias)
                if peer ~= nil and peer.conn ~= nil then
                    local fwd_ok, fwd_err = pcall(function()
                        peer.conn:call('webui_session_delete_remote',
                            { id }, { timeout = 3 })
                    end)
                    if fwd_ok then
                        logger.info('logout forwarded ok',
                            { user = user, leader = leader_alias })
                    else
                        logger.warn('logout forward to leader failed',
                            { leader = leader_alias, err = tostring(fwd_err) })
                    end
                end
            end
        elseif not del_ok then
            logger.warn('session delete failed', { err = del_err_str })
        end

        -- Close any live WS connections owned by this session.
        local ws_ok, ws_reg = pcall(require, 'webui.http.ws_registry')
        if ws_ok and ws_reg.close_by_session ~= nil then
            pcall(ws_reg.close_by_session, id, 'logout')
        end
    end
    pcall(audit.record, {
        user = user, action = 'auth.logout', scope = 'session',
        request_id = req.request_id,
    })
    logger.info('logout', { user = user })
    local expire_csrf = 'webui_csrf=; Path=/; SameSite=Strict; Max-Age=0'
    return json_response(204, {}, {
        ['set-cookie'] = {
            build_cookie('', { expire = true, secure = is_secure(req) }),
            expire_csrf,
        },
    })
end

-- ─────────────────────────────────────────────────────────────────────
-- /api/auth/me
-- ─────────────────────────────────────────────────────────────────────

function M.handler_me(req)
    local id = parse_cookie(req)
    if id == nil then
        return json_response(401, {
            error = { code = 'UNAUTHORIZED', message = 'no session' },
        })
    end
    local tuple = session.get(id)
    if tuple == nil then
        return json_response(401, {
            error = { code = 'UNAUTHORIZED', message = 'session expired' },
        })
    end
    local rbac_ok, rbac = pcall(require, 'webui.auth.rbac')
    local roles = rbac_ok and rbac.user_roles(tuple.user) or {}
    return json_response(200, {
        user      = tuple.user,
        roles     = roles,
        expiresAt = tuple.expires_at,
        csrf      = tuple.csrf,
    })
end

M.COOKIE_NAME = COOKIE_NAME
M.CSRF_HEADER = CSRF_HEADER

return M
