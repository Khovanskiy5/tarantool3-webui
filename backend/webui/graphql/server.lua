-- GraphQL HTTP transport.
--
-- POST /admin/api          accepts a JSON body { query, variables, operationName }
-- GET  /admin/api/explore  serves a self-contained, single-page query explorer
--                          gated by roles_cfg.webui.graphiql_enabled (default false)
--
-- Error policy:
--   * Body parse / "missing query" → 400 INVALID_QUERY
--   * GraphQL parse failure        → 400 INVALID_QUERY
--   * Schema validation failure    → 400 VALIDATION_ERROR
--   * Resolver crash               → 500 INTERNAL (masked message)
--   * No schema (init not run)     → 503 UNAVAILABLE
-- All transport-level error responses still follow the GraphQL spec:
--   { errors: [ { message, extensions: { code, request_id } } ] }
--
-- The full RBAC gate for /admin/api/explore lands in Task 26 — the
-- placeholder here only honours the config-level toggle.

local json = require('json')
local clock = require('clock')

local parse = require('graphql.parse')
local validate = require('graphql.validate')
local execute = require('graphql.execute')

local log_util = require('webui.log_util')
local error_envelope = require('webui.graphql.error_envelope')
local schema_builder = require('webui.graphql.schema')

local logger = log_util.with_tag('graphql')

local M = {}

local STATE = {
    schema = nil,
    graphiql_enabled = false,
    initialized_at = nil,
}

-- ── helpers ────────────────────────────────────────────────────────────

local function json_response(status, body_t)
    return {
        status = status,
        headers = { ['content-type'] = 'application/json; charset=utf-8' },
        body = json.encode(body_t),
    }
end

local function error_response(request_id, code, message)
    return json_response(
        error_envelope.http_status(code),
        error_envelope.errors_body(code, message, request_id)
    )
end

local function read_body(req)
    -- read_cached() returns the full body on first invocation and
    -- caches it for subsequent calls. The http rock guarantees this
    -- is bounded by content-length; the role refuses oversized bodies
    -- at the listening socket level via box.cfg's net_msg_max equivalent.
    local ok, body = pcall(req.read_cached, req)
    if not ok then return nil, tostring(body) end
    return body or ''
end

-- ── init ──────────────────────────────────────────────────────────────

function M.init(opts)
    opts = opts or {}
    STATE.schema = schema_builder.build()
    STATE.graphiql_enabled = opts.graphiql_enabled == true
    STATE.initialized_at = clock.monotonic()
    logger.info('graphql initialized', {
        graphiql_enabled = STATE.graphiql_enabled,
    })
end

function M.stop()
    STATE.schema = nil
    STATE.graphiql_enabled = false
    STATE.initialized_at = nil
end

function M.status()
    return {
        ready = STATE.schema ~= nil,
        graphiql_enabled = STATE.graphiql_enabled,
        initialized_at = STATE.initialized_at,
    }
end

-- ── POST /admin/api ───────────────────────────────────────────────────

function M.handler(req)
    if STATE.schema == nil then
        return error_response(req.request_id, 'UNAVAILABLE',
            'graphql server is not initialised')
    end

    -- 1. read & decode body
    local body_str, read_err = read_body(req)
    if body_str == nil then
        return error_response(req.request_id, 'INVALID_QUERY',
            'cannot read request body: ' .. read_err)
    end
    if body_str == '' then
        return error_response(req.request_id, 'INVALID_QUERY',
            'empty request body')
    end

    local ok_json, parsed = pcall(json.decode, body_str)
    if not ok_json or type(parsed) ~= 'table' then
        return error_response(req.request_id, 'INVALID_QUERY',
            'request body is not a JSON object')
    end

    local query = parsed.query
    local variables = parsed.variables
    local operation_name = parsed.operationName

    if type(query) ~= 'string' or query == '' then
        return error_response(req.request_id, 'INVALID_QUERY',
            'request body must contain a non-empty "query" string')
    end

    -- 2. parse GraphQL document
    local started = clock.monotonic()
    local ok_parse, doc = pcall(parse.parse, query)
    if not ok_parse then
        logger.warn('graphql parse error', {
            request_id = req.request_id,
            err = tostring(doc),
            operation_name = operation_name,
        })
        return error_response(req.request_id, 'INVALID_QUERY',
            'graphql parse error: ' .. tostring(doc))
    end

    -- 3. validate against schema
    local ok_validate, validation_err = pcall(validate.validate, STATE.schema, doc)
    if not ok_validate then
        logger.warn('graphql validation error', {
            request_id = req.request_id,
            err = tostring(validation_err),
            operation_name = operation_name,
        })
        return error_response(req.request_id, 'VALIDATION_ERROR',
            tostring(validation_err))
    end

    -- 4. execute
    -- The graphql rock's execute() expects 5 positional args:
    --   schema, document, rootValue, variables, operationName
    -- There is no separate "context" argument; per-request data
    -- (request_id, future user) rides on rootValue and is reachable
    -- to resolvers via the parent argument at root.
    local root_value = {
        request_id = req.request_id,
        -- A user object will be plumbed in once Task 26 lands auth.
    }
    local ok_exec, exec_result = pcall(
        execute.execute, STATE.schema, doc, root_value, variables, operation_name
    )
    local latency_ms = (clock.monotonic() - started) * 1000

    if not ok_exec then
        -- A resolver crashed without returning (nil, err). The real
        -- message lives in the structured log; the public envelope is
        -- intentionally generic.
        logger.error('graphql execute crash', {
            request_id = req.request_id,
            err = tostring(exec_result),
            operation_name = operation_name,
            latency_ms = latency_ms,
        })
        return error_response(req.request_id, 'INTERNAL', 'execution error')
    end

    -- 5. success
    local body = json.encode({ data = exec_result })
    logger.debug('graphql request handled', {
        request_id = req.request_id,
        operation_name = operation_name,
        latency_ms = latency_ms,
        response_size = #body,
    })
    return {
        status = 200,
        headers = { ['content-type'] = 'application/json; charset=utf-8' },
        body = body,
    }
end

-- ── GET /admin/api/explore ────────────────────────────────────────────

-- Self-contained minimal explorer. It is intentionally not GraphiQL:
-- shipping the full GraphiQL UI requires vendoring React, ProseMirror
-- and ~1 MB of JS. The explorer below covers the same primary use
-- (paste a query, execute, see the response) without any external
-- assets, which keeps it safe under our default CSP.
local EXPLORER_HTML = [[<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>WebUI GraphQL Explorer</title>
  <style>
    html, body { height: 100%; margin: 0; font-family: system-ui, -apple-system, sans-serif; background: #0e1117; color: #e6e6e6; }
    body { display: flex; flex-direction: column; }
    header { padding: 0.6rem 1rem; background: #161b22; border-bottom: 1px solid #30363d; display: flex; justify-content: space-between; align-items: center; }
    h1 { margin: 0; font-size: 0.95rem; letter-spacing: 0.02em; }
    main { display: flex; flex: 1; min-height: 0; }
    textarea, pre { flex: 1; padding: 1rem; background: #0d1117; color: #e6e6e6; border: none; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 13px; line-height: 1.45; resize: none; outline: none; }
    textarea { border-right: 1px solid #30363d; }
    pre { overflow: auto; margin: 0; white-space: pre-wrap; }
    footer { padding: 0.5rem 1rem; background: #161b22; border-top: 1px solid #30363d; display: flex; align-items: center; gap: 1rem; }
    button { background: #4ea8de; color: #0e1117; border: none; padding: 0.4rem 0.9rem; border-radius: 4px; cursor: pointer; font-weight: 600; }
    button:disabled { opacity: 0.6; cursor: progress; }
    .hint { color: #8b949e; font-size: 0.85rem; }
    .latency { color: #8b949e; font-size: 0.85rem; }
  </style>
</head>
<body>
  <header>
    <h1>WebUI GraphQL Explorer</h1>
    <span class="hint">POST /admin/api</span>
  </header>
  <main>
    <textarea id="q" spellcheck="false">{
  ping
  serverTime
  webuiVersion
  roleStatus { state version tarantool uptimeSec instance }
}</textarea>
    <pre id="r">Press the button or Ctrl+Enter to execute.</pre>
  </main>
  <footer>
    <button id="go" type="button">Execute</button>
    <span class="hint">Ctrl+Enter</span>
    <span class="latency" id="lat"></span>
  </footer>
  <script>
    var q = document.getElementById('q');
    var r = document.getElementById('r');
    var go = document.getElementById('go');
    var lat = document.getElementById('lat');
    function exec() {
      var query = q.value;
      r.textContent = '…';
      lat.textContent = '';
      go.disabled = true;
      var t0 = performance.now();
      fetch('/admin/api', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ query: query }),
        credentials: 'same-origin'
      }).then(function (resp) {
        var t1 = performance.now();
        lat.textContent = (t1 - t0).toFixed(1) + ' ms · HTTP ' + resp.status;
        return resp.json();
      }).then(function (data) {
        r.textContent = JSON.stringify(data, null, 2);
      }).catch(function (e) {
        r.textContent = String(e);
      }).finally(function () {
        go.disabled = false;
      });
    }
    go.addEventListener('click', exec);
    q.addEventListener('keydown', function (e) {
      if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') { e.preventDefault(); exec(); }
    });
  </script>
</body>
</html>
]]

function M.graphiql_handler(_req)
    if not STATE.graphiql_enabled then
        return {
            status = 404,
            headers = { ['content-type'] = 'text/plain; charset=utf-8' },
            body = 'GraphiQL is disabled. Enable it via roles_cfg.webui.graphiql_enabled = true.',
        }
    end

    -- The explorer ships its own inline script; relax CSP for THIS
    -- response only so the page works in browsers that honour CSP
    -- strictly. The body still loads no external resources.
    local relaxed_csp = table.concat({
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline'",
        "style-src 'self' 'unsafe-inline'",
        "connect-src 'self'",
        "img-src 'self' data:",
        "frame-ancestors 'none'",
        "base-uri 'self'",
    }, '; ')

    return {
        status = 200,
        headers = {
            ['content-type'] = 'text/html; charset=utf-8',
            ['content-security-policy'] = relaxed_csp,
            ['cache-control'] = 'no-cache, no-store, must-revalidate',
        },
        body = EXPLORER_HTML,
    }
end

return M
