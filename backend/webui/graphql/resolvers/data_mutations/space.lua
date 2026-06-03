--
-- Space-level DDL: createSpace, dropSpace, alterSpace.
--
-- Also hosts the shared DDL dispatcher `ddl_apply` which `index.lua`
-- reuses — both flavours forward to leader via the same remote
-- function (`webui_space_mutation_remote`) and share the safe-name
-- guard, so the dispatcher belongs to whichever module loads first.
-- We put it here because space ops are the "primary" DDL surface.
--

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('graphql.data_mutations.space')

local common = require('webui.graphql.resolvers.data_mutations.common')

local M = {}

-- Look up the sequence attached to `space_id`, if any. Mirrors
-- the helper in `admin_data.lua` (kept local so this module stays
-- self-contained and the consumer there is unaffected). Returns
-- the sequence name (`_sequence` field 3) or nil.
local function attached_sequence_name(space_id)
    if box.space._space_sequence == nil then return nil end
    local ok, link = pcall(function()
        return box.space._space_sequence:get({ space_id })
    end)
    if not ok or link == nil then return nil end
    local seq_id = link[2]
    if box.space._sequence == nil then return nil end
    local seq = box.space._sequence:get({ seq_id })
    if seq == nil then return nil end
    return seq[3]
end

-- Truncate one space, optionally resetting its attached sequence.
-- Pulled out of `space_apply_local` so the dispatcher reads as a flat
-- list of operations and this branch can be followed on its own.
local function truncate_one(payload)
    if box.is_in_txn() then
        error('TRUNCATE_INSIDE_TXN: cannot truncate while a ' ..
            'transaction is open; commit or rollback first')
    end
    local s = box.space[payload.name]
    if s == nil then
        error('NOT_FOUND: space ' .. payload.name .. ' does not exist')
    end
    s:truncate()
    local sequence_reset = false
    if payload.reset_sequence == true then
        local seq_name = attached_sequence_name(s.id)
        if seq_name ~= nil and box.sequence[seq_name] ~= nil then
            box.sequence[seq_name]:reset()
            sequence_reset = true
        end
    end
    return { ok = true, name = payload.name, id = s.id,
             sequence_reset = sequence_reset }
end

-- Local apply for space-level ops only. Index ops live in
-- `index.lua`; the dispatcher below routes by op-prefix.
local function space_apply_local(op, payload)
    if op == 'space_create' then
        local s = box.schema.space.create(payload.name, {
            engine        = payload.engine,
            if_not_exists = payload.if_not_exists == true,
            is_sync       = payload.is_sync == true,
        })
        if type(payload.format) == 'table' and #payload.format > 0 then
            local fmt = {}
            for i, f in ipairs(payload.format) do
                if type(f) ~= 'table' or type(f.name) ~= 'string'
                    or type(f.type) ~= 'string' then
                    error('VALIDATION_ERROR: format[' .. i ..
                        '] needs {name, type, is_nullable?}')
                end
                table.insert(fmt, {
                    name = f.name, type = f.type,
                    is_nullable = f.is_nullable == true,
                })
            end
            s:format(fmt)
        end
        local pk = payload.primary_key
        if type(pk) ~= 'table' or #pk == 0 then
            -- Default: single-part by the first format field — Tarantool
            -- requires at least one index before any tuple can be
            -- inserted, so we provide a sane default rather than leave
            -- the space half-initialised.
            local first = payload.format and payload.format[1]
            if first ~= nil then pk = { first.name } else pk = nil end
        end
        if pk ~= nil then
            s:create_index('primary', { parts = pk, if_not_exists = true })
        end
        return { ok = true, name = payload.name, id = s.id }
    end
    if op == 'space_drop' then
        local s = box.space[payload.name]
        if s == nil then
            error('NOT_FOUND: space ' .. payload.name .. ' does not exist')
        end
        s:drop()
        return { ok = true, name = payload.name }
    end
    if op == 'space_truncate' then return truncate_one(payload) end
    if op == 'space_alter' then
        local s = box.space[payload.name]
        if s == nil then
            error('NOT_FOUND: space ' .. payload.name .. ' does not exist')
        end
        -- Apply the parts the operator filled in; absent fields keep
        -- the current setting. Format goes first so a rename in the
        -- same call still references the old name.
        if payload.format ~= nil then
            local fmt = {}
            for i, f in ipairs(payload.format) do
                if type(f) ~= 'table' or type(f.name) ~= 'string'
                    or type(f.type) ~= 'string' then
                    error('VALIDATION_ERROR: format[' .. i ..
                        '] needs {name, type, is_nullable?}')
                end
                table.insert(fmt, {
                    name = f.name, type = f.type,
                    is_nullable = f.is_nullable == true,
                })
            end
            s:format(fmt)
        end
        if payload.is_sync ~= nil then
            s:alter({ is_sync = payload.is_sync == true })
        end
        local new_name = payload.name
        if type(payload.new_name) == 'string' and payload.new_name ~= ''
            and payload.new_name ~= payload.name then
            if payload.new_name:sub(1, 1) == '_' then
                error('FORBIDDEN: cannot rename a space into the `_` namespace')
            end
            s:rename(payload.new_name)
            new_name = payload.new_name
        end
        return { ok = true, name = new_name, id = s.id }
    end
    error('VALIDATION_ERROR: unknown space op ' .. tostring(op))
end

M.local_apply = space_apply_local

-- ── shared DDL dispatcher (used by space.lua AND index.lua) ────────
--
-- `local_impl` is the function that performs the actual op when we
-- are on the leader (space_apply_local or index.local_apply).
-- Followers go through the wire to the leader; the audit row is
-- written on both sides.

function M.ddl_apply(field_name, op, payload, root, local_impl)
    common.require_role(root, field_name)
    if type(payload.name) ~= 'string' or payload.name == '' then
        error('VALIDATION_ERROR: name is required')
    end
    common.assert_safe_ddl(payload.name, op)
    if common.is_read_only() then
        local res, err = common.forward_ddl(op, payload, root)
        if res == nil then error(err) end
        common.audit_record({
            user       = root and root.user,
            action     = op,
            scope      = 'space:' .. payload.name,
            payload    = { forwarded_to = res.leader, name = res.name },
            request_id = root and root.request_id,
        })
        return res
    end
    local ok, res = pcall(local_impl, op, payload)
    if not ok then error(res) end
    common.audit_record({
        user       = root and root.user,
        action     = op,
        scope      = 'space:' .. payload.name,
        payload    = { name = res.name, id = res.id },
        request_id = root and root.request_id,
    })
    logger.info(op .. ' ok', {
        space = payload.name, user = root and root.user,
        request_id = root and root.request_id,
    })
    return res
end

-- ── public entry points ────────────────────────────────────────────

function M.create_space(root, args)
    return M.ddl_apply('createSpace', 'space_create', {
        name          = args.name,
        engine        = args.engine,
        is_sync       = args.is_sync == true,
        if_not_exists = args.if_not_exists == true,
        format        = args.format,
        primary_key   = args.primary_key,
    }, root, space_apply_local)
end

function M.drop_space(root, args)
    return M.ddl_apply('dropSpace', 'space_drop', {
        name = args.name,
    }, root, space_apply_local)
end

function M.truncate_space(root, args)
    return M.ddl_apply('truncateSpace', 'space_truncate', {
        name           = args.name,
        reset_sequence = args.reset_sequence == true,
    }, root, space_apply_local)
end

function M.alter_space(root, args)
    return M.ddl_apply('alterSpace', 'space_alter', {
        name     = args.name,
        new_name = args.new_name,
        format   = args.format,
        is_sync  = args.is_sync,
    }, root, space_apply_local)
end

return M
