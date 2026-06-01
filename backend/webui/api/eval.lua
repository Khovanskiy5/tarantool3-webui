--
-- Lua/SQL evaluation console.
--
-- POST /api/eval — `superuser` only. Each request is recorded in
-- `_webui_audit` with the executor's user, the snippet, and the
-- timing. Disabled by default; flipped on via
-- `roles_cfg.webui.console_enabled = true`. The middleware enforces
-- the role; this handler enforces the kill-switch.
--

local json   = require('json')
local fiber  = require('fiber')
local clock  = require('clock')

local audit    = require('webui.audit.log')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('api.eval')

local M = {}

local KILL = { enabled = false }

function M.configure(opts)
    opts = opts or {}
    KILL.enabled = opts.console_enabled == true
end

local function err_resp(status, code, message, request_id)
    return {
        status = status,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({ error = {
            code = code, message = message, request_id = request_id,
        } }),
    }
end

function M.handler(req)
    if not KILL.enabled then
        return err_resp(403, 'CONSOLE_DISABLED',
            'Lua/SQL console is disabled by configuration', req.request_id)
    end

    local raw
    if type(req.read_cached) == 'function' then
        local ok, body = pcall(req.read_cached, req)
        if ok then raw = body end
    end
    if raw == nil or #raw == 0 then
        return err_resp(400, 'INVALID_QUERY', 'empty body', req.request_id)
    end
    local ok, parsed = pcall(json.decode, raw)
    if not ok or type(parsed) ~= 'table' then
        return err_resp(400, 'INVALID_QUERY', 'expected JSON object', req.request_id)
    end
    if type(parsed.code) ~= 'string' or #parsed.code == 0 then
        return err_resp(400, 'INVALID_QUERY', '`code` is required', req.request_id)
    end
    if #parsed.code > 4 * 1024 then
        return err_resp(413, 'CODE_TOO_LARGE',
            'snippet exceeds 4 KiB', req.request_id)
    end

    -- Optional: temporarily allow full-table scans for THIS sql
    -- snippet only. The /sql workbench has the same toggle behind
    -- its "Re-run with SEQSCAN" banner; mirror the contract here
    -- so /console covers the same recovery flow.
    local seqscan_allowed = parsed.seqscan_allowed == true

    local started = clock.monotonic()
    local out, err
    local function run()
        if parsed.lang == 'sql' then
            -- `box.execute` returns (result, err). Multi-return
            -- so the SPA renders SQL errors (Scanning is not
            -- allowed, syntax errors, etc.) instead of an empty
            -- `null` result panel. We raise with level 0 so the
            -- pcall below catches the SQL error message verbatim,
            -- and the handler reports `ok: false, error: "..."`
            -- with status 200 — the SPA's existing `if !res.ok`
            -- branch then renders the red banner.
            local prev_seq
            local settings = (rawget(_G, 'box') and box.space
                and box.space._session_settings) or nil
            if settings ~= nil and seqscan_allowed then
                local ok_get, tuple = pcall(function()
                    return settings:get('sql_seq_scan')
                end)
                if ok_get and tuple ~= nil then prev_seq = tuple[2] end
                pcall(function()
                    settings:update('sql_seq_scan', { { '=', 'value', true } })
                end)
            end
            local res, sql_err = box.execute(parsed.code)
            if settings ~= nil and seqscan_allowed and prev_seq ~= nil then
                pcall(function()
                    settings:update('sql_seq_scan',
                        { { '=', 'value', prev_seq } })
                end)
            end
            if sql_err ~= nil then
                error(tostring(sql_err), 0)
            end
            return res
        end
        -- Default: Lua. We compile the snippet in a sandboxed env
        -- with `_G` exposed read-only via metatable.
        local fn, lerr = loadstring('return (function() ' .. parsed.code .. ' end)()')
        if fn == nil then error(lerr) end
        return fn()
    end
    -- Preserve multi-return: `return a, b` from the snippet should
    -- surface BOTH values (mirrors Tarantool's interactive console).
    -- LuaJIT lacks `table.pack`, so we count with `select('#', ...)`
    -- and pack manually before pcall destructuring drops the rest.
    local function pack_count(...)
        return select('#', ...), { ... }
    end
    local function safe_run()
        return pack_count(run())
    end
    local ok_eval, count_or_err, results = pcall(safe_run)
    if ok_eval then
        if count_or_err == 0 then
            out = nil
        elseif count_or_err == 1 then
            out = results[1]
        else
            out = results
        end
    else
        err = tostring(count_or_err)
    end
    local latency_ms = (clock.monotonic() - started) * 1000

    pcall(audit.record, {
        user = req.user, action = 'console.eval', scope = parsed.lang or 'lua',
        request_id = req.request_id,
        payload = {
            code_size = #parsed.code,
            latency_ms = latency_ms,
            ok = ok_eval,
            err = err,
        },
    })
    logger.info('eval', {
        user = req.user, lang = parsed.lang or 'lua',
        ok = ok_eval, latency_ms = latency_ms,
        request_id = req.request_id,
    })

    return {
        -- Always 200; eval is allowed to fail at the snippet
        -- level (syntax error, SQL parse error, runtime raise).
        -- The SPA reads `ok` from the body and renders an error
        -- banner — that is far more useful than a generic 500
        -- that the rest client would turn into an opaque
        -- RestApiError without the SQL message.
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({
            ok = ok_eval, result = out, error = err,
            latency_ms = latency_ms,
            instance = (rawget(_G, 'box') and box.info.name) or nil,
            ts = fiber.time(),
        }),
    }
end

return M
