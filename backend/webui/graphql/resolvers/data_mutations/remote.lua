--
-- Leader-side entry points called by `init.lua`'s peer-bound
-- registrations (`webui_data_mutation_remote` for DML and
-- `webui_space_mutation_remote` for DDL).
--
-- Both receivers re-enforce the deny-list so a misbehaving follower
-- cannot smuggle a write past the resolver's guard, and both write
-- their own audit row on the leader so the entry is owned by the
-- leader's (sync) `_webui_audit` regardless of which peer accepted
-- the request from the operator.
--

local common   = require('webui.graphql.resolvers.data_mutations.common')
local tuple    = require('webui.graphql.resolvers.data_mutations.tuple')
local space    = require('webui.graphql.resolvers.data_mutations.space')
local index    = require('webui.graphql.resolvers.data_mutations.index')
local sequence = require('webui.graphql.resolvers.data_mutations.sequence')

local M = {}

-- DML receiver. The follower calls it via net.box; we run the local
-- apply on the leader, then bundle success / error into a table the
-- caller can distinguish from a transport failure (where pcall sees
-- `nil, err`).
function M.remote_entry(op, space_name, payload, ctx)
    local impl = tuple.LOCAL_APPLY[op]
    if impl == nil then
        return { _error = 'INTERNAL: unknown op ' .. tostring(op) }
    end
    if common.SENSITIVE_SPACES[space_name] then
        return { _error = 'FORBIDDEN: ' .. op .. ' on system space ' ..
            space_name .. ' is blocked.' }
    end
    local ok, res = pcall(impl, space_name, payload)
    if not ok then return { _error = tostring(res) } end
    common.audit_record({
        user       = ctx and ctx.user,
        action     = 'data.' .. op,
        scope      = 'space:' .. space_name,
        payload    = { before = res.before, after = res.after, via = 'forward' },
        request_id = ctx and ctx.request_id,
    })
    return res
end

-- DDL receiver. Routes by op-prefix to the right local apply and
-- re-enforces both the deny-list and the `_` namespace ban.
function M.space_remote_entry(op, payload, ctx)
    if type(payload) ~= 'table'
        or type(payload.name) ~= 'string' or payload.name == '' then
        return { _error = 'VALIDATION_ERROR: name is required' }
    end
    if common.SENSITIVE_SPACES[payload.name]
        or payload.name:sub(1, 1) == '_' then
        return { _error = 'FORBIDDEN: ' .. op .. ' on system space '
            .. payload.name .. ' is blocked.' }
    end
    local impl
    if op:sub(1, 6) == 'space_' then
        impl = space.local_apply
    elseif op:sub(1, 6) == 'index_' then
        impl = index.local_apply
    elseif op:sub(1, 9) == 'sequence_' then
        impl = sequence.local_apply
    else
        return { _error = 'INTERNAL: unknown DDL op ' .. tostring(op) }
    end
    local ok, res = pcall(impl, op, payload)
    if not ok then return { _error = tostring(res) } end
    common.audit_record({
        user       = ctx and ctx.user,
        action     = op,
        scope      = 'space:' .. payload.name,
        payload    = { name = res.name, id = res.id, via = 'forward' },
        request_id = ctx and ctx.request_id,
    })
    return res
end

return M
