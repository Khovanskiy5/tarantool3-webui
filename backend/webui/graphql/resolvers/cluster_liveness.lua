--
-- Reader side of the state-reporter feature.
--
-- The writer (`webui.cluster.self_reporter`) publishes one JSON
-- liveness record per instance to `<prefix>/state/by-name/<alias>`
-- in etcd. This resolver scans that range and returns the records
-- to the UI, decorated with `age_seconds` (now - ts) so the panel
-- can flag stale entries without doing math client-side.
--
-- Why a separate resolver and not a join into `cluster.servers`:
--   * The two channels are deliberately independent. peer_poller
--     hits iproto on every peer; the state-reporter writes to etcd.
--     A divergence between them is itself a useful signal (iproto
--     reachable but reporter silent → reporter misconfigured; etcd
--     entry fresh but iproto down → network split).
--   * Keeping the resolver narrow means a future read-only operator
--     dashboard can hit just `clusterLiveness` without dragging the
--     full cluster snapshot.
--

local fiber = require('fiber')
local json  = require('json')

local rbac        = require('webui.auth.rbac')
local etcd_client = require('webui.config_store.client')
local self_rep    = require('webui.cluster.self_reporter')
local logger      = require('webui.log_util').with_tag('cluster.self_reporter')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'viewer'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

-- Pure: turn a raw etcd kv entry into the GraphQL row, or nil if
-- the value is unparseable. Caller filters nils out. Extracted as
-- module-local so the resolver body stays under the cyclomatic-
-- complexity cap and so the JSON parsing is unit-testable.
function M._decode_entry(kv, now)
    if kv == nil or type(kv.value) ~= 'string' then return nil end
    local ok, parsed = pcall(json.decode, kv.value)
    if not ok or type(parsed) ~= 'table' then return nil end
    -- The reporter writes `alias` itself; falling back to the key
    -- suffix keeps the row useful even if a future writer omits it.
    local alias = parsed.alias
    if alias == nil and type(kv.key) == 'string' then
        alias = kv.key:match('([^/]+)$')
    end
    local ts = tonumber(parsed.ts) or 0
    local age = (ts > 0) and (now - ts) or nil
    return {
        alias       = alias,
        hostname    = parsed.hostname,
        pid         = tonumber(parsed.pid),
        mode        = parsed.mode,
        ro_reason   = parsed.ro_reason,
        status      = parsed.status,
        ts          = ts,
        age_seconds = age,
    }
end

-- Returns the keepalive threshold the local reporter is configured
-- with — the UI compares `age_seconds` against this to decide
-- "fresh" vs "stale". Reading from STATE keeps a single source of
-- truth even when the operator tunes the value at runtime.
local function local_keepalive_interval()
    local s = self_rep.status() or {}
    -- self_rep.status() does not currently surface the config; pull
    -- the default until the public surface widens. The number lives
    -- under DEFAULTS so a refactor of either side is loud.
    return s.keepalive_interval or self_rep.DEFAULTS.keepalive_interval
end

function M.query(root)
    require_role(root, 'clusterLiveness')

    local report = {
        reporter_enabled   = (self_rep.status() or {}).enabled == true,
        keepalive_interval = local_keepalive_interval(),
        entries            = {},
    }

    local client, err = etcd_client.get_client()
    if client == nil then
        logger.debug('liveness query: etcd unavailable', { err = tostring(err) })
        return report
    end

    local listing, range_err = client:range_prefix(self_rep.KEY_PREFIX)
    if listing == nil then
        logger.warn('liveness query: range_prefix failed', {
            err = tostring(range_err and range_err.message or range_err),
        })
        return report
    end

    local now = fiber.time()
    local rows = {}
    for _, kv in ipairs(listing.items or {}) do
        local row = M._decode_entry(kv, now)
        if row ~= nil then table.insert(rows, row) end
    end
    table.sort(rows, function(a, b)
        return (a.alias or '') < (b.alias or '')
    end)
    report.entries = rows
    return report
end

return M
