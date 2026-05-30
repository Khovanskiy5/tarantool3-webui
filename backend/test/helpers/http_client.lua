--
-- Test HTTP client for the WebUI admin surface.
--
-- Wraps the http.client rock with cookie / CSRF / JSON envelope
-- handling so tests do not repeat the same five lines every call.
--
--   local Client = require('test.helpers.http_client')
--   local c = Client:new({ base_url = 'http://127.0.0.1:8080' })
--   c:graphql_query('{ ping }')
--   c:graphql_mutation('mutation X { ... }', { foo = 1 })
--   c:rest_post('/api/eval', { language = 'lua', code = '...' })
--   c:login('admin', 'password')   -- M2; stub today
--

local checks = require('checks')
local http_client = require('http.client')
local json = require('json')

local M = {}
M.__index = M

-- The WebUI backend emits at most one Set-Cookie per response and our
-- cookies do not embed commas in their values, so a tiny parser is
-- enough here. If the backend ever starts batching cookies, swap to
-- http_client's cookie_jar support instead of growing this code.
local CookieJar = {}
CookieJar.__index = CookieJar

function CookieJar.new() return setmetatable({ entries = {} }, CookieJar) end

function CookieJar:get(name)
    local entry = self.entries[name]
    return entry and entry.value
end

function CookieJar:merge_set_cookie(header)
    if type(header) ~= 'string' or header == '' then return end
    local cookie_name, cookie_value = header:match('^%s*([^=;]+)=([^;]+)')
    if cookie_name and cookie_value then
        self.entries[cookie_name] = { value = cookie_value }
    end
end

function CookieJar:to_header()
    local out = {}
    for n, e in pairs(self.entries) do
        table.insert(out, n .. '=' .. e.value)
    end
    return #out > 0 and table.concat(out, '; ') or nil
end

-- ── construction ─────────────────────────────────────────────────────

function M:new(opts)
    checks('table', {
        base_url = 'string',
        timeout  = '?number',
        graphql_path = '?string',
    })
    local instance = setmetatable({
        _base_url     = opts.base_url:gsub('/$', ''),
        _timeout      = opts.timeout or 5,
        _graphql_path = opts.graphql_path or '/admin/api',
        _client       = http_client.new(),
        _cookies      = CookieJar.new(),
        _csrf_token   = nil,
        _request_id_seq = 0,
    }, M)
    return instance
end

-- ── low-level request ────────────────────────────────────────────────

local function next_request_id(self)
    self._request_id_seq = self._request_id_seq + 1
    return ('test-%d-%d'):format(self._request_id_seq, math.floor(os.time()))
end

function M:request(method, path, body, opts)
    opts = opts or {}
    local headers = { ['accept'] = 'application/json' }
    if opts.headers then
        for k, v in pairs(opts.headers) do headers[k] = v end
    end
    headers['x-request-id'] = headers['x-request-id'] or next_request_id(self)
    if method ~= 'GET' and self._csrf_token and headers['x-csrf-token'] == nil then
        headers['x-csrf-token'] = self._csrf_token
    end
    local cookie_header = self._cookies:to_header()
    if cookie_header then
        headers['cookie'] = cookie_header
    end

    local encoded
    if body ~= nil then
        if type(body) == 'string' then
            encoded = body
        else
            encoded = json.encode(body)
            headers['content-type'] = headers['content-type']
                or 'application/json; charset=utf-8'
        end
    end

    local url = self._base_url .. path
    local res = self._client:request(method, url, encoded, {
        timeout = opts.timeout or self._timeout,
        headers = headers,
    })
    if res == nil then
        error('HTTP request returned nil: ' .. method .. ' ' .. url)
    end

    -- Stash session / CSRF on subsequent requests.
    if res.headers then
        local set_cookie = res.headers['set-cookie']
        if set_cookie then self._cookies:merge_set_cookie(set_cookie) end
        local csrf = res.headers['x-csrf-token']
        if csrf and csrf ~= '' then self._csrf_token = csrf end
    end

    local parsed_body
    if res.body and res.body ~= '' then
        local ok, parsed = pcall(json.decode, res.body)
        if ok then parsed_body = parsed end
    end

    return {
        status = res.status,
        headers = res.headers or {},
        body = res.body,
        json = parsed_body,
        request_id = headers['x-request-id'],
    }
end

-- ── REST shortcuts ───────────────────────────────────────────────────

function M:rest_get(path, opts)
    return self:request('GET', path, nil, opts)
end

function M:rest_post(path, body, opts)
    return self:request('POST', path, body, opts)
end

function M:rest_put(path, body, opts)
    return self:request('PUT', path, body, opts)
end

function M:rest_delete(path, opts)
    return self:request('DELETE', path, nil, opts)
end

-- ── GraphQL shortcuts ────────────────────────────────────────────────

local function graphql_call(self, query, variables, operation_name)
    local body = { query = query }
    if variables ~= nil then body.variables = variables end
    if operation_name then body.operationName = operation_name end
    local res = self:request('POST', self._graphql_path, body)
    -- Tests routinely care about res.json.data / res.json.errors;
    -- expose them directly as a convenience.
    if res.json then
        res.data = res.json.data
        res.errors = res.json.errors
    end
    return res
end

function M:graphql_query(query, variables, operation_name)
    return graphql_call(self, query, variables, operation_name)
end

function M:graphql_mutation(query, variables, operation_name)
    return graphql_call(self, query, variables, operation_name)
end

-- ── auth (stub until Task 26) ───────────────────────────────────────

function M:login(_user, _password)
    -- Real login lands in Task 25. The stub mirrors the eventual API
    -- so existing test code does not need to be rewritten when the
    -- backend ships.
    error('login is not implemented yet; will be wired in Task 25', 2)
end

-- ── assertions tests routinely run ───────────────────────────────────

function M:assert_status(response, expected_status)
    if response.status ~= expected_status then
        error(('expected HTTP %d, got %d (request_id=%s, body=%s)'):format(
            expected_status,
            response.status,
            tostring(response.request_id),
            tostring(response.body)
        ), 2)
    end
    return response
end

function M:assert_graphql_ok(response)
    self:assert_status(response, 200)
    if response.json == nil then
        error('GraphQL response has no JSON body', 2)
    end
    if response.errors and #response.errors > 0 then
        local first = response.errors[1]
        local code = first.extensions and first.extensions.code
        error(('GraphQL errors[0]: code=%s, message=%s'):format(
            tostring(code), tostring(first.message)), 2)
    end
    if response.data == nil then
        error('GraphQL response has no data field', 2)
    end
    return response
end

return M
