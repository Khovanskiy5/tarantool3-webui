--
-- HMAC-SHA256 signature for outbound webhooks (Task 53a).
--
-- Receivers verify with the shared secret:
--
--   X-Webui-Signature: sha256=<lowercase hex>
--
-- Single-pass: digest.hmac.sha256_hex computes the digest and
-- returns the hex encoding directly. Empty / nil secrets short-
-- circuit to nil so the dispatcher knows to skip the header
-- (generic public webhooks with no secret stay supported).
--

-- `crypto.hmac.sha256_hex` lives in the built-in Tarantool `crypto`
-- module (OpenSSL-backed). `digest` has the raw hashes but not the
-- HMAC variants, so we import crypto here even though the rest of
-- the project uses digest.
local crypto = require('crypto')

local M = {}

local HEADER = 'X-Webui-Signature'

function M.header_name() return HEADER end

-- Returns the value for the X-Webui-Signature header, or nil when
-- no signature is required (empty secret).
function M.sign(secret, body)
    if secret == nil or type(secret) ~= 'string' or #secret == 0 then
        return nil
    end
    body = body or ''
    local hex = crypto.hmac.sha256_hex(secret, body)
    return 'sha256=' .. hex
end

return M
