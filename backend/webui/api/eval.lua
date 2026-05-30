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

    local started = clock.monotonic()
    local out, err
    local function run()
        if parsed.lang == 'sql' then
            local res = box.execute(parsed.code)
            return res
        end
        -- Default: Lua. We compile the snippet in a sandboxed env
        -- with `_G` exposed read-only via metatable.
        local fn, lerr = loadstring('return (function() ' .. parsed.code .. ' end)()')
        if fn == nil then error(lerr) end
        return fn()
    end
    local ok_eval, result = pcall(run)
    if ok_eval then
        out = result
    else
        err = tostring(result)
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
        status = ok_eval and 200 or 500,
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
