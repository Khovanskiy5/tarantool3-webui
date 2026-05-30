-- Unified REST error envelope.
--
-- Every non-200 REST response body has the shape:
--   { "error": { "code": "<STABLE_CODE>", "message": "<human readable>", "request_id": "<uuid>", "details": <optional object> } }
--
-- Stack traces and internal paths must never leak through this envelope.
-- The `code` field is a stable part of the API contract (see error catalog).

local json = require('json')

local errors_catalog = require('webui.errors')

local M = {}

-- Normalise heterogenous error inputs into a deterministic envelope.
-- Inputs we accept:
--   * an `errors` rock object  (has .class_name, .err)
--   * a string                 (treated as INTERNAL message)
--   * a table with .code/.message/.details
--   * nil                      (treated as INTERNAL "unknown error")
local function to_envelope_table(err, request_id)
    local code = 'INTERNAL'
    local message = 'unknown error'
    local details = nil

    local t = type(err)
    if t == 'table' then
        if err.class_name and err.err then
            -- errors rock object
            code = tostring(err.class_name)
            message = tostring(err.err)
        elseif err.code then
            -- {code, message, details}
            code = tostring(err.code)
            message = tostring(err.message or code)
            details = err.details
        else
            -- unknown table; surface as INTERNAL but preserve no internal data
            code = 'INTERNAL'
            message = 'internal error'
        end
    elseif t == 'string' then
        code = 'INTERNAL'
        message = err
    end

    -- Internal-error messages are stripped to a generic phrase so we never
    -- leak file paths, panics or stack info from a crash. The real text
    -- stays in the structured log alongside the request_id.
    if code == 'INTERNAL' then
        message = 'internal error'
        details = nil
    end

    local body = {
        error = {
            code = code,
            message = message,
            request_id = request_id,
        }
    }
    if details ~= nil then
        body.error.details = details
    end
    return body, code
end

-- Build a complete HTTP response (status + body + content-type) from an
-- arbitrary error. Used by middleware to turn pcall'ed handler failures
-- into a clean response.
function M.respond(err, request_id, status_override)
    local body_t, code = to_envelope_table(err, request_id)
    local status = status_override or errors_catalog.http_status(code)
    return {
        status = status,
        headers = {
            ['content-type'] = 'application/json; charset=utf-8',
        },
        body = json.encode(body_t),
    }
end

-- Convenience: respond_internal builds a 500 envelope.
function M.respond_internal(request_id, message)
    return M.respond({ code = 'INTERNAL', message = message }, request_id, 500)
end

-- Convenience: respond_with_code skips the HTTP_STATUS lookup when the
-- caller already knows the status (e.g. middleware short-circuits).
function M.respond_with_code(code, message, request_id, status, details)
    return M.respond({
        code = code,
        message = message,
        details = details,
    }, request_id, status)
end

-- Build the body table without serialising (useful for unit tests).
M.build = to_envelope_table

return M
