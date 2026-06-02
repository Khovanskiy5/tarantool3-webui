--
-- Index-level DDL: createIndex, dropIndex.
--
-- Reuses the shared DDL dispatcher and forward-to-leader path from
-- `space.lua`. The local implementation here only knows about
-- `index_create` / `index_drop`; everything else lives in space.lua.
--

local space = require('webui.graphql.resolvers.data_mutations.space')

local M = {}

local function index_apply_local(op, payload)
    if op == 'index_create' then
        local s = box.space[payload.name]
        if s == nil then
            error('NOT_FOUND: space ' .. payload.name .. ' does not exist')
        end
        if type(payload.index_name) ~= 'string' or payload.index_name == '' then
            error('VALIDATION_ERROR: index_name is required')
        end
        if type(payload.parts) ~= 'table' or #payload.parts == 0 then
            error('VALIDATION_ERROR: parts is required')
        end
        s:create_index(payload.index_name, {
            parts         = payload.parts,
            type          = payload.type or 'tree',
            unique        = payload.unique ~= false,
            if_not_exists = payload.if_not_exists == true,
        })
        return { ok = true, name = payload.name, id = s.id }
    end
    if op == 'index_drop' then
        local s = box.space[payload.name]
        if s == nil then
            error('NOT_FOUND: space ' .. payload.name .. ' does not exist')
        end
        local idx = s.index[payload.index_name]
        if idx == nil then
            error('NOT_FOUND: index ' .. tostring(payload.index_name)
                .. ' on ' .. payload.name)
        end
        idx:drop()
        return { ok = true, name = payload.name, id = s.id }
    end
    error('VALIDATION_ERROR: unknown index op ' .. tostring(op))
end

M.local_apply = index_apply_local

function M.create_index(root, args)
    return space.ddl_apply('createIndex', 'index_create', {
        name          = args.space,
        index_name    = args.name,
        parts         = args.parts,
        type          = args.type,
        unique        = args.unique,
        if_not_exists = args.if_not_exists,
    }, root, index_apply_local)
end

function M.drop_index(root, args)
    return space.ddl_apply('dropIndex', 'index_drop', {
        name       = args.space,
        index_name = args.name,
    }, root, index_apply_local)
end

return M
