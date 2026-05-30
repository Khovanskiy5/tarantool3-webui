-- Unified GraphQL error envelope.
--
-- Every error returned to a GraphQL client conforms to the standard
-- GraphQL error shape (RFC: graphql-spec § 7.1.2):
--   { message, locations?, path?, extensions: { code, request_id, … } }
--
-- The `code` is the stable contract surface (see docs/api/error-codes.md
-- and backend/webui/errors.lua). Internal errors are masked: the public
-- message becomes generic ("internal error") so file paths and Lua
-- stack traces never leak; real diagnostics stay in the structured log
-- next to the request_id.

local M = {}

-- HTTP status the surrounding REST framing should use when the response
-- carries this code. GraphQL itself nominally returns 200, but the
-- /admin/api endpoint returns 4xx/5xx for transport-level errors
-- (malformed body, no `query` field, validation failure) so HAProxy
-- and metrics see them.
M.HTTP_STATUS = {
    INVALID_QUERY    = 400,
    VALIDATION_ERROR = 400,
    UNAUTHORIZED     = 401,
    FORBIDDEN        = 403,
    NOT_FOUND        = 404,
    INTERNAL         = 500,
    UNAVAILABLE      = 503,
    TIMEOUT          = 504,
}

function M.http_status(code)
    return M.HTTP_STATUS[code] or 500
end

local function is_table(v) return type(v) == 'table' end

-- Build a single GraphQL error object. Inputs:
--   opts.code        stable error code (string)
--   opts.message     human-readable text
--   opts.request_id  cross-instance correlation id
--   opts.locations   optional list of {line, column}
--   opts.path        optional list of strings (response path)
--   opts.details     optional structured table — DROPPED for INTERNAL
function M.format_error(opts)
    local code = opts.code or 'INTERNAL'
    local message = opts.message or 'unknown error'
    if code == 'INTERNAL' then
        message = 'internal error'
    end
    local err = {
        message = message,
        extensions = {
            code = code,
            request_id = opts.request_id,
        },
    }
    if is_table(opts.locations) then err.locations = opts.locations end
    if is_table(opts.path) then err.path = opts.path end
    if code ~= 'INTERNAL' and is_table(opts.details) then
        err.extensions.details = opts.details
    end
    return err
end

-- Convenience: build the wire-level body `{errors = {…}}`.
function M.errors_body(code, message, request_id, extras)
    extras = extras or {}
    extras.code = code
    extras.message = message
    extras.request_id = request_id
    return { errors = { M.format_error(extras) } }
end

return M
