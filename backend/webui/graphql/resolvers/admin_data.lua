--
-- Read-only resolvers for the admin-data pages: spaces, users.
--
-- These project Tarantool's own metadata (`box.space._space`,
-- `box.space._user`) so the SPA can render `/schema` and
-- `/users` without us having to invent a new storage layer. The
-- write surfaces (createSpace / setUserRoles) ship later via
-- two-phase commit; the queries already need RBAC gating so
-- non-admin users do not see the user list.
--

local rbac = require('webui.auth.rbac')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'viewer'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

-- ── spaces ─────────────────────────────────────────────────────────

local SYSTEM_PREFIX = '_'

local function describe_index(idx)
    local parts = {}
    for _, p in ipairs(idx.parts or {}) do
        local name
        if type(p) == 'table' then name = p.field_name or p.name or tostring(p.fieldno)
        else name = tostring(p) end
        table.insert(parts, name)
    end
    return {
        id     = idx.id,
        name   = idx.name,
        type   = idx.type,
        unique = idx.unique,
        parts  = parts,
    }
end

function M.query_spaces(root, args)
    require_role(root, 'cluster')
    if rawget(_G, 'box') == nil or box.space == nil then return { spaces = {} } end
    local include_sys = (args and args.include_system) == true
    local out = {}
    for _, sp in box.space._space:pairs() do
        local id   = sp[1]
        local name = sp[3]
        local engine = sp[4]
        if include_sys or (name:sub(1, 1) ~= SYSTEM_PREFIX) then
            local indexes = {}
            local space = box.space[name]
            if space ~= nil then
                -- `space.index` is a hybrid map: each index is reachable
                -- by both its numeric id (0, 1, ...) AND its string name.
                -- pairs() yields every index twice; iterate numeric keys
                -- only to get a single entry per index.
                for k, idx in pairs(space.index) do
                    if type(k) == 'number'
                            and type(idx) == 'table'
                            and idx.parts ~= nil then
                        table.insert(indexes, describe_index(idx))
                    end
                end
                -- Stable order: by id ascending.
                table.sort(indexes, function(a, b) return a.id < b.id end)
            end
            local rows = space and space:count() or 0
            table.insert(out, {
                id = id, name = name, engine = engine,
                row_count = rows, indexes = indexes,
            })
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return { spaces = out }
end

-- ── users ──────────────────────────────────────────────────────────

function M.query_users(root)
    require_role(root, 'users')
    if rawget(_G, 'box') == nil or box.space == nil
        or box.space._user == nil then
        return { users = {} }
    end
    local rbac_map = function(user_name)
        local roles = rbac.user_roles(user_name)
        return roles
    end
    local out = {}
    for _, row in box.space._user:pairs() do
        local kind = row[4]
        if kind == 'user' then
            local name = row[3]
            table.insert(out, {
                name = name,
                roles_app = rbac_map(name),
                kind = kind,
            })
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return { users = out }
end

return M
