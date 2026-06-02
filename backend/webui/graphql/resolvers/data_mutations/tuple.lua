--
-- tuple_insert / tuple_replace / tuple_update / tuple_delete.
--
-- See `data_mutations/init.lua` for the public surface contract.
-- All four mutations:
--
--   1. Refuse to touch system spaces (deny-list in common.lua).
--   2. Coerce wire-format fields through `data_explorer.types`.
--   3. Run on the leader (followers forward via net.box).
--   4. Audit a `data.<op>` row with before/after payload.
--

local json     = require('json')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('graphql.data_mutations.tuple')

local de_types = require('webui.data_explorer.types')
local common   = require('webui.graphql.resolvers.data_mutations.common')

local M = {}

-- ── local apply implementations ────────────────────────────────────

local function local_insert(space_name, fields_in)
    local space = box.space[space_name]
    if space == nil then error('NOT_FOUND: space ' .. space_name) end
    local fmt = common.space_format(space)
    local coerced, err = de_types.coerce_tuple(fields_in, fmt)
    if err ~= nil then error('VALIDATION_ERROR: ' .. err) end
    local new_tuple = space:insert(coerced)
    return { ok = true, after = common.tuple_to_wire(new_tuple) }
end

local function local_replace(space_name, fields_in)
    local space = box.space[space_name]
    if space == nil then error('NOT_FOUND: space ' .. space_name) end
    local fmt = common.space_format(space)
    local pk_parts = common.space_pk_parts(space)
    -- Read the existing tuple (if any) BEFORE the replace so audit
    -- can show the before-state. We resolve the key by walking the
    -- format and pulling the PK fieldnos out of the incoming row.
    local key = {}
    for i, part in ipairs(pk_parts) do
        local fno = part.fieldno or part.field
        key[i] = fields_in[fno]
    end
    local before = pcall(function() return space:get(key) end) and space:get(key) or nil
    local coerced, err = de_types.coerce_tuple(fields_in, fmt)
    if err ~= nil then error('VALIDATION_ERROR: ' .. err) end
    local new_tuple = space:replace(coerced)
    return {
        ok     = true,
        before = common.tuple_to_wire(before),
        after  = common.tuple_to_wire(new_tuple),
    }
end

local function local_delete(space_name, key_in)
    local space = box.space[space_name]
    if space == nil then error('NOT_FOUND: space ' .. space_name) end
    local fmt = common.space_format(space)
    local pk_parts = common.space_pk_parts(space)
    local key, err = de_types.coerce_key(key_in, pk_parts, fmt)
    if err ~= nil then error('VALIDATION_ERROR: ' .. err) end
    local before = space:get(key)
    if before == nil then error('NOT_FOUND: tuple with key ' .. json.encode(key_in)) end
    local deleted = space:delete(key)
    return { ok = true, before = common.tuple_to_wire(deleted) }
end

-- Build the per-op argument list expected by `space:update()`:
--   {op_char, field, value}  for arithmetic + assign
--   {'#', field, count}       for delete-n-fields
--   {'!', field, value}       for insert-at-position
local function build_update_ops(raw_ops, fmt)
    if type(raw_ops) ~= 'table' or #raw_ops == 0 then
        error('VALIDATION_ERROR: ops list is required')
    end
    -- Map field-name → fieldno for the operator's convenience.
    local field_index = {}
    for i, f in ipairs(fmt or {}) do
        if f.name then field_index[f.name] = i end
    end
    local out = {}
    for i, op in ipairs(raw_ops) do
        local code = common.UPDATE_OPS[op.op]
        if code == nil then
            error('VALIDATION_ERROR: unsupported update op ' .. tostring(op.op))
        end
        local field_ref = op.field
        if type(field_ref) == 'string' then
            local fno = field_index[field_ref]
            if fno == nil then
                error('VALIDATION_ERROR: unknown field ' .. field_ref ..
                    ' for op #' .. i)
            end
            field_ref = fno
        end
        if type(field_ref) ~= 'number' then
            error('VALIDATION_ERROR: op #' .. i ..
                ' needs `field` (string name or numeric index)')
        end
        local declared = (fmt and fmt[field_ref] and fmt[field_ref].type) or 'any'
        local value, cerr
        if code == '#' then
            value = tonumber(op.value) or 1
        else
            value, cerr = de_types.coerce_field(op.value, declared)
            if cerr ~= nil then
                error('VALIDATION_ERROR: op #' .. i .. ': ' .. cerr)
            end
        end
        table.insert(out, { code, field_ref, value })
    end
    return out
end

local function local_update(space_name, key_in, raw_ops)
    local space = box.space[space_name]
    if space == nil then error('NOT_FOUND: space ' .. space_name) end
    local fmt = common.space_format(space)
    local pk_parts = common.space_pk_parts(space)
    local key, err = de_types.coerce_key(key_in, pk_parts, fmt)
    if err ~= nil then error('VALIDATION_ERROR: ' .. err) end
    local ops = build_update_ops(raw_ops, fmt)
    local before = space:get(key)
    if before == nil then error('NOT_FOUND: tuple with key ' .. json.encode(key_in)) end
    local after = space:update(key, ops)
    return {
        ok     = true,
        before = common.tuple_to_wire(before),
        after  = common.tuple_to_wire(after),
    }
end

-- Op dispatch table used both by the local fast path and by the
-- leader-side receiver in `remote.lua` (which re-imports it via
-- `M.LOCAL_APPLY`).
M.LOCAL_APPLY = {
    insert  = function(s, p) return local_insert(s, p.fields) end,
    replace = function(s, p) return local_replace(s, p.fields) end,
    delete  = function(s, p) return local_delete(s, p.key) end,
    update  = function(s, p) return local_update(s, p.key, p.ops) end,
}

-- ── public entry points ────────────────────────────────────────────

local function apply(field_name, op, space_name, payload, root)
    common.require_role(root, field_name)
    common.assert_safe_space(space_name, op)
    if common.is_read_only() then
        local res, err = common.forward_dml(op, space_name, payload, root)
        if res == nil then error(err) end
        -- Audit on the follower side too: the operator's intent
        -- happened here, even if the data write was forwarded.
        common.audit_record({
            user       = root and root.user,
            action     = 'data.' .. op,
            scope      = 'space:' .. space_name,
            payload    = { forwarded_to = res.leader, before = res.before, after = res.after },
            request_id = root and root.request_id,
        })
        return res
    end
    local impl = M.LOCAL_APPLY[op]
    local res = impl(space_name, payload)
    common.audit_record({
        user       = root and root.user,
        action     = 'data.' .. op,
        scope      = 'space:' .. space_name,
        payload    = { before = res.before, after = res.after },
        request_id = root and root.request_id,
    })
    logger.info('mutation ok', {
        op = op, space = space_name, user = root and root.user,
        request_id = root and root.request_id,
    })
    return res
end

function M.tuple_insert(root, args)
    return apply('tupleInsert', 'insert', args.space,
        { fields = args.fields }, root)
end

function M.tuple_replace(root, args)
    return apply('tupleReplace', 'replace', args.space,
        { fields = args.fields }, root)
end

function M.tuple_update(root, args)
    return apply('tupleUpdate', 'update', args.space,
        { key = args.key, ops = args.ops }, root)
end

function M.tuple_delete(root, args)
    return apply('tupleDelete', 'delete', args.space,
        { key = args.key }, root)
end

return M
