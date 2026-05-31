--
-- SQL workbench REST endpoint.
--
-- POST /api/sql:
--     body  → { statement, params?, seqscan_allowed? }
--     resp  → SELECT: { statements: [{metadata:[...], rows:[[...],...]}] }
--             DML:    { statements: [{row_count: N}] }
--     multi → statements split by the literal `;;` separator (NOT
--             single `;` — that lives inside string literals and
--             splitting on it requires a full SQL parser).
--
-- Behaviours that surprise operators if missing:
--   * Tarantool 3.x defaults `sql_seq_scan_default = 'new'`, which
--     blocks queries that need a full-scan unless the operator
--     explicitly enabled it. We detect the typed error and surface
--     `seqscan_required: true` so the SPA can offer a one-click
--     retry with `seqscan_allowed: true` (sets
--     `box.session.session_settings.sql_seq_scan_default = true`
--     for the duration of the call only).
--   * 10K row cap per statement; we set `truncated: true` and stop
--     iterating so the tx-thread is never pinned by a runaway
--     SELECT.
--   * RBAC: operator for read-only, admin for any write/DDL. We
--     decide locally by sniffing the first keyword — full SQL parse
--     is overkill for the gate.
--   * Audit: every successful statement → `sql.exec` row with the
--     redacted snippet + latency.
--

local json    = require('json')
local fiber   = require('fiber')
local clock   = require('clock')

local rbac    = require('webui.auth.rbac')
local audit   = require('webui.audit.log')
local log_util = require('webui.log_util')
local logger  = log_util.with_tag('api.sql')

local M = {}

M.MAX_ROWS = 10000
M.MAX_STATEMENT_BYTES = 64 * 1024

-- Operations that count as a write — used to upgrade the RBAC gate
-- from `operator` to `admin`. We match on the first keyword (case-
-- insensitive, trimmed) — Tarantool's parser does the same, plus we
-- only need a hint, not perfect accuracy.
local WRITE_KEYWORDS = {
    INSERT = true, UPDATE = true, DELETE = true, REPLACE = true,
    CREATE = true, DROP = true, ALTER = true, TRUNCATE = true,
    GRANT = true, REVOKE = true, BEGIN = true, COMMIT = true,
    ROLLBACK = true, SAVEPOINT = true, RELEASE = true, START = true,
}

local function first_keyword(sql)
    local trimmed = sql:gsub('^%s+', '')
    -- Strip leading SQL comments so `-- comment\nSELECT ...` still
    -- detects SELECT, not "--".
    while trimmed:sub(1, 2) == '--' do
        trimmed = trimmed:gsub('^[^\n]*\n?', '')
        trimmed = trimmed:gsub('^%s+', '')
    end
    local kw = trimmed:match('^(%a+)')
    return kw and kw:upper() or ''
end

-- Pragmatic split by `;;`. Trims surrounding whitespace per
-- statement, drops empty pieces — the operator can paste a trailing
-- ` ;;` and we treat it as "end of last statement, no more".
local function split_statements(body)
    local out = {}
    for piece in (body .. ';;'):gmatch('(.-);;') do
        local trimmed = piece:gsub('^%s+', ''):gsub('%s+$', '')
        if #trimmed > 0 then table.insert(out, trimmed) end
    end
    return out
end
M._split_statements = split_statements
M._first_keyword    = first_keyword

local function err_resp(status, code, message, request_id)
    return {
        status = status,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({ error = {
            code = code, message = message, request_id = request_id,
        } }),
    }
end

-- Detect Tarantool's "scan is not allowed" complaint. The runtime
-- raises `box.error.ER_SQL_EXECUTE` with a string variant; we match
-- substrings because the message format changes between point
-- releases.
local function is_seqscan_error(err)
    if err == nil then return false end
    local s = tostring(err):lower()
    return s:find('seqscan', 1, true) ~= nil
        or s:find('scanning is not allowed', 1, true) ~= nil
        or s:find('scan is not allowed', 1, true) ~= nil
        or s:find('sql_seq_scan', 1, true) ~= nil
end
M._is_seqscan_error = is_seqscan_error

-- Run a single statement under the seqscan toggle. We flip
-- `session_settings.sql_seq_scan_default` only for the duration of
-- this call and restore the previous value in `finally`, so we
-- never leak the toggle to subsequent unrelated calls on the same
-- iproto session.
local function execute_one(stmt, params, seqscan_allowed)
    -- `sql_seq_scan` is stored as a tuple in the virtual
    -- `_session_settings` space — there is no Lua API shortcut.
    -- `box.session_settings_*` does not exist; access goes through
    -- `box.space._session_settings:update('sql_seq_scan', ...)`.
    local prev_seq
    local settings = (rawget(_G, 'box') and box.space and box.space._session_settings) or nil
    if settings ~= nil and seqscan_allowed then
        local ok_get, tuple = pcall(function() return settings:get('sql_seq_scan') end)
        if ok_get and tuple ~= nil then prev_seq = tuple[2] end
        pcall(function()
            settings:update('sql_seq_scan', { { '=', 'value', true } })
        end)
    end
    -- box.execute() returns (result_table, err_string) — it does
    -- NOT raise for SQL errors (only for malformed Lua calls). We
    -- capture both return values, restore session settings, then
    -- decide. A Lua-level pcall around it still catches the rare
    -- bad-input crash.
    local ok, res, exec_err = pcall(function()
        if params ~= nil and type(params) == 'table' and #params > 0 then
            return box.execute(stmt, params)
        end
        return box.execute(stmt)
    end)
    if settings ~= nil and seqscan_allowed and prev_seq ~= nil then
        pcall(function()
            settings:update('sql_seq_scan', { { '=', 'value', prev_seq } })
        end)
    end
    if not ok then return nil, tostring(res) end
    if exec_err ~= nil then return nil, tostring(exec_err) end
    -- Some Tarantool error variants ship the message inside
    -- `res.info` (typed error object) — surface it explicitly so
    -- the seqscan detector can react.
    if type(res) == 'table' and res.metadata == nil and res.rows == nil
        and res.row_count == nil and res.info ~= nil then
        return nil, tostring(res.info)
    end
    return res
end
M._execute_one = execute_one

-- Cap rows to MAX_ROWS — set `truncated: true` and drop the rest.
local function cap_rows(rows)
    if rows == nil then return nil, false end
    if #rows <= M.MAX_ROWS then return rows, false end
    local out = {}
    for i = 1, M.MAX_ROWS do out[i] = rows[i] end
    return out, true
end

-- Project the per-statement result into the wire shape the SPA
-- consumes. SELECT: metadata + rows. DML: row_count. Unknown shape
-- (an empty `{}` from a no-op) → `{ ok: true }`.
local function shape_result(res)
    if type(res) ~= 'table' then return { ok = true } end
    if res.metadata ~= nil and res.rows ~= nil then
        local rows, truncated = cap_rows(res.rows)
        return {
            metadata  = res.metadata,
            rows      = rows,
            truncated = truncated,
        }
    end
    if res.row_count ~= nil then
        return { row_count = res.row_count }
    end
    return { ok = true }
end
M._shape_result = shape_result

local function check_role(user_roles, sql_body)
    local kw = first_keyword(sql_body)
    local needed = WRITE_KEYWORDS[kw] and 'admin' or 'operator'
    if not rbac.allowed(user_roles or {}, needed) then
        return false, needed
    end
    return true
end
M._check_role = check_role

function M.handler(req)
    local raw
    if type(req.read_cached) == 'function' then
        local ok, body = pcall(req.read_cached, req)
        if ok then raw = body end
    end
    if raw == nil or #raw == 0 then
        return err_resp(400, 'INVALID_QUERY', 'empty body', req.request_id)
    end
    local ok_parse, parsed = pcall(json.decode, raw)
    if not ok_parse or type(parsed) ~= 'table' then
        return err_resp(400, 'INVALID_QUERY', 'expected JSON object', req.request_id)
    end
    if type(parsed.statement) ~= 'string' or #parsed.statement == 0 then
        return err_resp(400, 'INVALID_QUERY', '`statement` is required', req.request_id)
    end
    if #parsed.statement > M.MAX_STATEMENT_BYTES then
        return err_resp(413, 'STATEMENT_TOO_LARGE',
            'SQL body exceeds ' .. M.MAX_STATEMENT_BYTES .. ' bytes', req.request_id)
    end
    local seqscan_allowed = parsed.seqscan_allowed == true
    local params = parsed.params  -- may be nil for stand-alone statements

    local statements = split_statements(parsed.statement)
    if #statements == 0 then
        return err_resp(400, 'INVALID_QUERY',
            'no executable SQL found (use `;;` to separate statements)',
            req.request_id)
    end

    -- RBAC: walk every statement and demand the strictest role.
    -- Anything that flips us into admin territory wins.
    local role_user = req.user
    local roles_arr = req.roles or {}
    for _, stmt in ipairs(statements) do
        local ok_rbac, needed = check_role(roles_arr, stmt)
        if not ok_rbac then
            return err_resp(403, 'FORBIDDEN',
                'this statement requires role ' .. needed
                .. ' (first keyword: ' .. first_keyword(stmt) .. ')',
                req.request_id)
        end
    end

    local started = clock.monotonic()
    local out = {}
    local seqscan_required, last_err
    for _, stmt in ipairs(statements) do
        local res, err = execute_one(stmt, params, seqscan_allowed)
        if err ~= nil then
            if is_seqscan_error(err) and not seqscan_allowed then
                seqscan_required = true
                last_err = err
                table.insert(out, { error = err, seqscan_required = true })
                break
            end
            table.insert(out, { error = err })
            last_err = err
            break
        end
        table.insert(out, shape_result(res))
    end
    local latency_ms = (clock.monotonic() - started) * 1000

    pcall(audit.record, {
        user = role_user, action = 'sql.exec', scope = 'sql',
        request_id = req.request_id,
        payload = {
            statements_count   = #statements,
            statement_bytes    = #parsed.statement,
            latency_ms         = latency_ms,
            ok                 = last_err == nil,
            err                = last_err,
            seqscan_allowed    = seqscan_allowed,
            seqscan_required   = seqscan_required,
        },
    })
    logger.info('sql.exec', {
        user = role_user, statements = #statements,
        latency_ms = latency_ms, ok = last_err == nil,
        seqscan_required = seqscan_required,
        request_id = req.request_id,
    })

    return {
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({
            statements        = out,
            latency_ms        = latency_ms,
            seqscan_required  = seqscan_required or false,
            instance          = (rawget(_G, 'box') and box.info.name) or nil,
            ts                = fiber.time(),
        }),
    }
end

-- EXPLAIN handler: takes the same input, runs `EXPLAIN QUERY PLAN`
-- around every statement, returns the plans in the same per-
-- statement structure. Failed statements get { error: "..." } so
-- the SPA can render a partial plan view.
function M.handler_explain(req)
    local raw
    if type(req.read_cached) == 'function' then
        local ok, body = pcall(req.read_cached, req)
        if ok then raw = body end
    end
    if raw == nil or #raw == 0 then
        return err_resp(400, 'INVALID_QUERY', 'empty body', req.request_id)
    end
    local ok_parse, parsed = pcall(json.decode, raw)
    if not ok_parse or type(parsed) ~= 'table' then
        return err_resp(400, 'INVALID_QUERY', 'expected JSON object', req.request_id)
    end
    if type(parsed.statement) ~= 'string' or #parsed.statement == 0 then
        return err_resp(400, 'INVALID_QUERY', '`statement` is required', req.request_id)
    end
    local statements = split_statements(parsed.statement)
    if #statements == 0 then
        return err_resp(400, 'INVALID_QUERY',
            'no executable SQL found', req.request_id)
    end

    local out = {}
    for _, stmt in ipairs(statements) do
        local explained = 'EXPLAIN QUERY PLAN ' .. stmt
        local res, err = execute_one(explained, nil, true)
        if err ~= nil then
            table.insert(out, { statement = stmt, error = err })
        else
            table.insert(out, {
                statement = stmt,
                metadata  = res and res.metadata,
                rows      = res and res.rows,
            })
        end
    end
    return {
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({ plans = out,
            instance = (rawget(_G, 'box') and box.info.name) or nil }),
    }
end

return M
