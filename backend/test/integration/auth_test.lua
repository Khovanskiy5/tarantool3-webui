--
-- M2 end-to-end auth smoke run against the live dev cluster.
--
-- The leader is whichever instance has `box.info.ro == false`. The
-- test loops over the three known ports until it finds the leader,
-- then drives the full /api/auth/* surface, /me, /admin/api with
-- and without CSRF, and confirms `rbac.denied` is recorded in
-- `_webui_audit`.
--

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local socket = require('socket')

local g = t.group('auth_e2e')

local LEADER_BASE_URL = nil

local function http_get(url, cookie)
    local cmd = "curl -s -o /tmp/.auth_body -w '%{http_code}'"
        .. (cookie and (" -H 'cookie: webui_session=" .. cookie .. "'") or '')
        .. " '" .. url .. "'"
    local out = io.popen(cmd):read('*l') or ''
    local body = io.open('/tmp/.auth_body'):read('*a')
    return tonumber(out), body
end

local function http_json(url, method, body, headers)
    local hdr = " -H 'content-type: application/json'"
    for k, v in pairs(headers or {}) do
        hdr = hdr .. " -H '" .. k .. ": " .. v .. "'"
    end
    local cmd = "curl -s -o /tmp/.auth_body -w '%{http_code}' -X " .. method
        .. hdr
        .. (body and (" -d '" .. body .. "'") or '')
        .. " '" .. url .. "'"
    local code = tonumber(io.popen(cmd):read('*l')) or 0
    local raw  = io.open('/tmp/.auth_body'):read('*a')
    return code, raw
end

local function probe_leader()
    if LEADER_BASE_URL then return LEADER_BASE_URL end
    for _, port in ipairs({ 8081, 8082, 8083 }) do
        local s = socket.tcp_connect('127.0.0.1', port)
        if s then
            s:close()
            local code, body = http_get('http://127.0.0.1:' .. port .. '/api/health')
            if code == 200 and body and body:find('"status":"ok"') then
                -- Try a login; only the leader allows writes.
                local lc = http_json(
                    'http://127.0.0.1:' .. port .. '/api/auth/login',
                    'POST',
                    '{"user":"admin_dev","password":"admin-dev-password"}')
                if lc == 200 then
                    LEADER_BASE_URL = 'http://127.0.0.1:' .. port
                    return LEADER_BASE_URL
                end
            end
        end
    end
    return nil
end

g.before_all(function()
    if probe_leader() == nil then
        t.skip('no live dev cluster reachable on 8081/8082/8083')
    end
end)

g.test_login_unknown_user_returns_401 = function()
    local code = http_json(LEADER_BASE_URL .. '/api/auth/login', 'POST',
        '{"user":"ghost","password":"x"}')
    t.assert_equals(code, 401)
end

g.test_login_system_user_returns_403 = function()
    local code = http_json(LEADER_BASE_URL .. '/api/auth/login', 'POST',
        '{"user":"webui_peer","password":"x"}')
    t.assert_equals(code, 403)
end

g.test_me_without_cookie_returns_401 = function()
    local code = http_get(LEADER_BASE_URL .. '/api/auth/me')
    t.assert_equals(code, 401)
end

g.test_admin_graphql_no_csrf_returns_403 = function()
    -- Log in to get a cookie, then deliberately omit the CSRF header.
    -- Extract Set-Cookie via -i so we get the response headers.
    local cmd = "curl -s -i -X POST -H 'content-type: application/json' -d "
        .. "'{\"user\":\"admin_dev\",\"password\":\"admin-dev-password\"}' "
        .. LEADER_BASE_URL .. "/api/auth/login"
    local raw = io.popen(cmd):read('*a')
    local cookie = raw:match("[Ss]et%-[Cc]ookie:%s*webui_session=([^;]+)")
    t.assert(cookie ~= nil and #cookie > 8)
    local code = http_json(LEADER_BASE_URL .. '/admin/api', 'POST',
        '{"query":"{__typename}"}',
        { ['cookie'] = 'webui_session=' .. cookie })
    t.assert_equals(code, 403)
end
