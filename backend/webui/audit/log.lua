--
-- Audit log writer (Task 26a fills in retention + query helpers).
--
-- Every security-relevant action — login, logout, config commit,
-- mutation dispatch, RBAC denial — appends a row to
-- `_webui_audit`. The space is replicated so an audit query
-- against any peer sees the full history.
--

local checks = require('checks')

local storage  = require('webui.storage.spaces')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('audit')

local M = {}

local function now()
    -- Microsecond precision so close-in-time events keep a
    -- deterministic order even if the autoincrement id is gapped
    -- by another writer.
    return math.floor(require('fiber').time() * 1e6)
end

-- Append a row. Returns the new tuple or `nil, err`.
function M.record(entry)
    checks({
        user       = '?string',
        action     = 'string',
        scope      = '?string',
        payload    = '?',
        request_id = '?string',
    })
    local space = storage.audit()
    if space == nil then
        return nil, 'audit storage is not bootstrapped'
    end
    -- box.NULL drives the primary key's sequence.
    local tuple = space:insert({
        box.NULL,
        now(),
        entry.user,
        entry.action,
        entry.scope,
        entry.payload,
        entry.request_id,
    })
    logger.debug('audit entry recorded', {
        id = tuple.id, action = entry.action, user = entry.user,
    })
    return tuple
end

return M
