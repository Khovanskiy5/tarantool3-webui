--
-- SQL workbench saved queries (Phase 3 Task 3.4).
--
-- A snippet has an owner (the user who created it). Visibility:
--   * owner     — sees own snippet always.
--   * admin/superuser — see every snippet.
--   * other     — sees snippet only when `shared = true`.
--
-- Writes (save / delete) require operator+ for own snippets; admin
-- for deleting/editing somebody else's. Shared toggle on save is
-- self-elected by the owner — no extra role needed to flip.
--
-- Storage is the `_webui_saved_queries` sync space (id is
-- sequence-backed); the resolver forwards to leader through the
-- audit pattern when the local instance is read-only.
--

local fiber  = require('fiber')

local rbac    = require('webui.auth.rbac')
local storage = require('webui.storage.spaces')
local audit   = require('webui.audit.log')
local log_util = require('webui.log_util')
local logger  = log_util.with_tag('graphql.saved_queries')

local M = {}

local FIELD_ID, FIELD_NAME, FIELD_SQL, FIELD_OWNER = 1, 2, 3, 4
local FIELD_CREATED_AT, FIELD_SHARED, FIELD_TAGS = 5, 6, 7

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'viewer'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

local function is_admin(roles)
    return rbac.allowed(roles or {}, 'admin')
end

local function project(tuple)
    if tuple == nil then return nil end
    return {
        id         = tuple[FIELD_ID],
        name       = tuple[FIELD_NAME],
        sql        = tuple[FIELD_SQL],
        owner      = tuple[FIELD_OWNER],
        created_at = tuple[FIELD_CREATED_AT],
        shared     = tuple[FIELD_SHARED] == true,
        tags       = tuple[FIELD_TAGS],
    }
end

-- visible(tuple, user, roles) → boolean
local function visible(tuple, user, roles)
    if tuple == nil then return false end
    if is_admin(roles) then return true end
    if tuple[FIELD_OWNER] == user then return true end
    return tuple[FIELD_SHARED] == true
end
M._visible = visible

-- ── queries ────────────────────────────────────────────────────────

function M.query_saved_queries(root)
    require_role(root, 'savedQueries')
    local space = storage.saved_queries()
    if space == nil then return { items = {} } end
    local user  = root and root.user
    local roles = (root and root.roles) or {}
    local items = {}
    for _, tuple in space:pairs() do
        if visible(tuple, user, roles) then
            table.insert(items, project(tuple))
        end
    end
    table.sort(items, function(a, b) return a.created_at > b.created_at end)
    return { items = items }
end

-- ── leader forwarding ──────────────────────────────────────────────

local function is_read_only()
    if rawget(_G, 'box') == nil or box.info == nil then return false end
    return box.info.ro == true
end

local function forward_to_leader(op, payload, root)
    local ok_state, cluster_state = pcall(require, 'webui.cluster.state')
    local ok_peers, peers         = pcall(require, 'webui.cluster.peers')
    if not (ok_state and ok_peers) then
        error('UNAVAILABLE: cluster modules not loaded')
    end
    local leader_alias = cluster_state.find_leader()
    if leader_alias == nil then error('UNAVAILABLE: no cluster leader reachable') end
    local peer = peers.get(leader_alias)
    if peer == nil or peer.conn == nil then
        error('UNAVAILABLE: leader ' .. leader_alias .. ' not reachable')
    end
    local ok, res = pcall(function()
        return peer.conn:call('webui_saved_query_remote',
            { op, payload, {
                user = root and root.user,
                roles = root and root.roles,
                request_id = root and root.request_id } },
            { timeout = 5 })
    end)
    if not ok then error('forward to leader failed: ' .. tostring(res)) end
    if type(res) == 'table' and res._error then error(res._error) end
    res.forwarded = true
    res.leader = leader_alias
    return res
end

-- ── local apply (leader side) ──────────────────────────────────────

local function local_save(payload, user)
    local name   = payload.name
    local sql    = payload.sql
    local shared = payload.shared == true
    local tags   = type(payload.tags) == 'table' and payload.tags or nil
    if type(name) ~= 'string' or name == '' then
        error('VALIDATION_ERROR: name is required')
    end
    if #name > 200 then error('VALIDATION_ERROR: name too long (max 200)') end
    if type(sql) ~= 'string' or sql == '' then
        error('VALIDATION_ERROR: sql is required')
    end
    if #sql > 64 * 1024 then
        error('VALIDATION_ERROR: sql too large (max 64 KiB)')
    end
    local space = storage.saved_queries()
    if space == nil then error('UNAVAILABLE: saved-queries space missing') end
    -- box.NULL for `id` triggers the sequence-backed primary index.
    local tuple = space:insert({
        box.NULL, name, sql, user, fiber.time(), shared, tags,
    })
    return { ok = true, item = project(tuple) }
end

local function local_delete(payload, user, roles)
    local id = tonumber(payload.id)
    if id == nil then error('VALIDATION_ERROR: id is required (number)') end
    local space = storage.saved_queries()
    if space == nil then error('UNAVAILABLE: saved-queries space missing') end
    local tuple = space:get({ id })
    if tuple == nil then error('NOT_FOUND: snippet id ' .. id) end
    -- Owner or admin only — visibility ≠ delete permission.
    if tuple[FIELD_OWNER] ~= user and not is_admin(roles) then
        error('FORBIDDEN: only the owner or an admin can delete this snippet')
    end
    space:delete({ id })
    return { ok = true, item = project(tuple) }
end

local LOCAL_APPLY = {
    save   = function(payload, user, _roles)
        return local_save(payload, user)
    end,
    delete = function(payload, user, roles)
        return local_delete(payload, user, roles)
    end,
}

local function apply(field_name, op, args, root)
    require_role(root, field_name)
    local user  = root and root.user
    local roles = (root and root.roles) or {}
    if is_read_only() then
        local res = forward_to_leader(op, args, root)
        pcall(audit.record, {
            user       = user,
            action     = 'saved_query.' .. op,
            scope      = 'sql',
            payload    = { forwarded_to = res.leader, name = args.name, id = args.id },
            request_id = root and root.request_id,
        })
        return res
    end
    local impl = LOCAL_APPLY[op]
    local res  = impl(args, user, roles)
    pcall(audit.record, {
        user       = user,
        action     = 'saved_query.' .. op,
        scope      = 'sql',
        payload    = { id = res.item and res.item.id, name = args.name },
        request_id = root and root.request_id,
    })
    logger.info(op .. ' ok', {
        user = user, id = res.item and res.item.id,
        name = args.name, shared = args.shared,
    })
    return res
end

function M.mutation_save(root, args)
    return apply('saveQuery', 'save', {
        name   = args.name,
        sql    = args.sql,
        shared = args.shared == true,
        tags   = args.tags,
    }, root)
end

function M.mutation_delete(root, args)
    return apply('deleteSavedQuery', 'delete', { id = args.id }, root)
end

-- Remote receiver. Re-applies the local op on the leader; the
-- caller's RBAC + visibility already passed on the follower side
-- but we re-verify here so a misbehaving peer can't trick us into
-- deleting someone else's snippet.
function M.remote_entry(op, payload, ctx)
    local impl = LOCAL_APPLY[op]
    if impl == nil then return { _error = 'unknown op ' .. tostring(op) } end
    local ok, res = pcall(impl, payload, ctx and ctx.user, ctx and ctx.roles)
    if not ok then return { _error = tostring(res) } end
    pcall(audit.record, {
        user       = ctx and ctx.user,
        action     = 'saved_query.' .. op,
        scope      = 'sql',
        payload    = { id = res.item and res.item.id, name = payload.name, via = 'forward' },
        request_id = ctx and ctx.request_id,
    })
    return res
end

return M
