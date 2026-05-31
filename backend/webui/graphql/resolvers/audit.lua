--
-- Audit-log resolvers: `audit(filter, limit, after)` query and
-- `exportAudit(filter)` mutation.
--
-- Both honour the role-level RBAC map (`rbac.GRAPHQL_FIELD.audit`,
-- `rbac.GRAPHQL_FIELD.exportAudit`) — defaults to `admin`.
--

local json = require('json')

local storage  = require('webui.storage.spaces')
local rbac     = require('webui.auth.rbac')

local M = {}

local DEFAULT_LIMIT = 100
local MAX_LIMIT     = 1000

-- The graphql rock's resolver signature is `(root, args)`. We pass
-- the authenticated session through root_value (see
-- `backend/webui/graphql/server.lua`), so RBAC reads from there.
local function require_role(root, field_name)
    local required = rbac.GRAPHQL_FIELD[field_name] or 'admin'
    local user_roles = (root and root.roles) or {}
    if not rbac.allowed(user_roles, required) then
        error('FORBIDDEN: ' .. field_name .. ' requires ' .. required)
    end
end

-- Pure helper exposed for unit tests.
function M.matches_filter(tuple, filter)
    if filter == nil then return true end
    if filter.user   ~= nil and tuple.user   ~= filter.user   then return false end
    if filter.action ~= nil and tuple.action ~= filter.action then return false end
    -- Prefix match lets the SPA group whole families of actions
    -- behind a single chip (e.g. `cluster.` covers every Phase 5
    -- operator mutation: cluster.promote, cluster.set_failover_mode,
    -- cluster.expel_instance …). Both `action` and `action_prefix`
    -- may be set — they AND, mirroring the rest of the filter
    -- contract.
    if filter.action_prefix ~= nil and filter.action_prefix ~= '' then
        local p = filter.action_prefix
        if type(tuple.action) ~= 'string'
            or tuple.action:sub(1, #p) ~= p then
            return false
        end
    end
    if filter.scope  ~= nil and tuple.scope  ~= filter.scope  then return false end
    if filter.from_ts ~= nil and tuple.ts < filter.from_ts then return false end
    if filter.to_ts   ~= nil and tuple.ts > filter.to_ts   then return false end
    return true
end

-- Pure helper for the page assembly. `after` is the last id from
-- the previous page; `limit` caps the result size; entries are
-- returned in descending id order so the SPA shows newest first.
-- `iter` must be a stateful next-style function returning
-- `(state, tuple)` pairs (zero values stops iteration). The
-- caller is responsible for wrapping `space:pairs(...)` into
-- such a closure if needed.
function M.collect_page(iter, filter, limit, after)
    local out = {}
    while true do
        local _, tuple = iter()
        if tuple == nil then break end
        if (after == nil or tuple.id < after)
            and M.matches_filter(tuple, filter) then
            table.insert(out, tuple)
            if #out >= limit + 1 then break end
        end
    end
    local has_more = #out > limit
    if has_more then out[#out] = nil end
    local next_cursor = nil
    if has_more and #out > 0 then next_cursor = out[#out].id end
    return out, has_more, next_cursor
end

local function encode_entry(tuple)
    local payload
    if tuple.payload ~= nil then
        local ok, encoded = pcall(json.encode, tuple.payload)
        payload = ok and encoded or nil
    end
    return {
        id         = tuple.id,
        ts         = tuple.ts,
        user       = tuple.user,
        action     = tuple.action,
        scope      = tuple.scope,
        request_id = tuple.request_id,
        payload    = payload,
    }
end

function M.query_audit(root, args)
    require_role(root, 'audit')
    local space = storage.audit()
    if space == nil then
        return { entries = {}, has_more = false, next_cursor = nil }
    end
    local limit = math.min(tonumber(args.limit) or DEFAULT_LIMIT, MAX_LIMIT)
    local after = args.after
    -- Descending by primary key gives newest first. Wrap the
    -- iterator so `collect_page` does not have to know about the
    -- triple-return `(state, control, init)` shape used by Lua
    -- iterators.
    local gen, param, ctrl = space:pairs({}, { iterator = 'REQ' })
    local function next_row()
        local k, v = gen(param, ctrl)
        ctrl = k
        if k == nil then return nil end
        return k, v
    end
    local entries, has_more, next_cursor = M.collect_page(
        next_row, args.filter, limit, after)
    local out = {}
    for _, t in ipairs(entries) do table.insert(out, encode_entry(t)) end
    return { entries = out, has_more = has_more, next_cursor = next_cursor }
end

function M.mutation_export_audit(root, args)
    require_role(root, 'exportAudit')
    local space = storage.audit()
    if space == nil then
        return { format = 'json', body = '[]', record_count = 0 }
    end
    local entries = {}
    local gen, param, ctrl = space:pairs({}, { iterator = 'REQ' })
    while true do
        local k, tuple = gen(param, ctrl)
        if tuple == nil then break end
        ctrl = k
        if M.matches_filter(tuple, args.filter) then
            table.insert(entries, encode_entry(tuple))
        end
    end
    return {
        format       = 'json',
        body         = json.encode(entries),
        record_count = #entries,
    }
end

return M
