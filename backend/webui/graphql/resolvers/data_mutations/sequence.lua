--
-- DE-1.3 — sequence mutations.
--
-- Tarantool's standalone `_sequence` space drives auto-increment for
-- index parts that opt in via `sequence = name` at create / alter
-- time. This module manages the sequence object itself; attaching
-- it to an index lives in `index.lua` (create_index already accepts
-- a `sequence` field, alter_index lands in DE-1.4).
--
-- Conventions match the rest of `data_mutations/*`:
--   * Public entry points dispatch through `space.ddl_apply`, which
--     handles RBAC, the `_`-namespace guard, forward-to-leader, and
--     audit. We piggyback on the space dispatcher because the wire
--     contract is identical — same `webui_space_mutation_remote`
--     RPC plus an op-prefix routed through `remote.lua`.
--   * Local apply functions accept `(op, payload)` so the same
--     dispatcher table fits sequence + space + index ops.
--

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('graphql.data_mutations.sequence')

local space_resolver = require('webui.graphql.resolvers.data_mutations.space')

local M = {}

-- Shared option projection. `nil` keys are dropped so Tarantool's
-- alter path (which validates the key set against a strict
-- whitelist that excludes `if_not_exists`) accepts the table
-- unchanged. The create path adds `if_not_exists` explicitly when
-- needed.
local function build_opts(payload)
    local opts = {
        step  = payload.step,
        min   = payload.min,
        max   = payload.max,
        start = payload.start,
        cache = payload.cache,
        cycle = payload.cycle,
    }
    if payload.if_not_exists == true then
        opts.if_not_exists = true
    end
    return opts
end

-- Read the current value defensively: `seq:current()` raises when
-- the sequence has never been advanced (Tarantool only persists a
-- row in `_sequence_data` after the first :next/:set). pcall
-- swallows that case so the resolver returns nil rather than
-- propagating an error to the operator.
local function current_or_nil(seq)
    if seq == nil then return nil end
    local ok, val = pcall(seq.current, seq)
    if not ok then return nil end
    return val
end

local function apply_create(payload)
    local seq = box.schema.sequence.create(
        payload.name, build_opts(payload))
    return {
        ok      = true,
        name    = payload.name,
        id      = seq and seq.id or nil,
        current = current_or_nil(seq),
    }
end

local function apply_alter(payload)
    local seq = box.sequence[payload.name]
    if seq == nil then
        error('NOT_FOUND: sequence ' .. payload.name .. ' does not exist')
    end
    seq:alter(build_opts(payload))
    return {
        ok      = true,
        name    = payload.name,
        id      = seq.id,
        current = current_or_nil(seq),
    }
end

local function apply_set(payload)
    local seq = box.sequence[payload.name]
    if seq == nil then
        error('NOT_FOUND: sequence ' .. payload.name .. ' does not exist')
    end
    if type(payload.value) ~= 'number'
        and type(payload.value) ~= 'cdata' then
        error('VALIDATION_ERROR: value is required (integer)')
    end
    seq:set(payload.value)
    return {
        ok      = true,
        name    = payload.name,
        id      = seq.id,
        current = current_or_nil(seq),
    }
end

local function apply_reset(payload)
    local seq = box.sequence[payload.name]
    if seq == nil then
        error('NOT_FOUND: sequence ' .. payload.name .. ' does not exist')
    end
    seq:reset()
    return {
        ok      = true,
        name    = payload.name,
        id      = seq.id,
        -- After reset the value is unset (no `_sequence_data` row)
        -- so `current` is nil — let the projection report that.
        current = nil,
    }
end

local function apply_drop(payload)
    -- Tarantool raises if the sequence is attached to an index.
    -- Let that error propagate so the operator sees "sequence is
    -- in use" rather than masking it.
    local seq = box.sequence[payload.name]
    if seq == nil then
        error('NOT_FOUND: sequence ' .. payload.name .. ' does not exist')
    end
    local id = seq.id
    seq:drop()
    return { ok = true, name = payload.name, id = id }
end

local SEQUENCE_OPS = {
    sequence_create = apply_create,
    sequence_alter  = apply_alter,
    sequence_set    = apply_set,
    sequence_reset  = apply_reset,
    sequence_drop   = apply_drop,
}

local function sequence_apply_local(op, payload)
    local impl = SEQUENCE_OPS[op]
    if impl == nil then
        error('VALIDATION_ERROR: unknown sequence op ' .. tostring(op))
    end
    return impl(payload)
end

M.local_apply = sequence_apply_local

-- ── public entry points ────────────────────────────────────────────

function M.sequence_create(root, args)
    local input = args.input or {}
    local res = space_resolver.ddl_apply('sequenceCreate', 'sequence_create', {
        name          = input.name,
        step          = input.step,
        min           = input.min,
        max           = input.max,
        start         = input.start,
        cache         = input.cache,
        cycle         = input.cycle,
        if_not_exists = input.if_not_exists == true,
    }, root, sequence_apply_local)
    logger.info('sequenceCreate ok', {
        name = input.name, user = root and root.user,
        request_id = root and root.request_id,
    })
    return res
end

function M.sequence_alter(root, args)
    local input = args.input or {}
    return space_resolver.ddl_apply('sequenceAlter', 'sequence_alter', {
        name  = input.name,
        step  = input.step,
        min   = input.min,
        max   = input.max,
        start = input.start,
        cache = input.cache,
        cycle = input.cycle,
    }, root, sequence_apply_local)
end

function M.sequence_set(root, args)
    return space_resolver.ddl_apply('sequenceSet', 'sequence_set', {
        name  = args.name,
        value = args.value,
    }, root, sequence_apply_local)
end

function M.sequence_reset(root, args)
    return space_resolver.ddl_apply('sequenceReset', 'sequence_reset', {
        name = args.name,
    }, root, sequence_apply_local)
end

function M.sequence_drop(root, args)
    return space_resolver.ddl_apply('sequenceDrop', 'sequence_drop', {
        name = args.name,
    }, root, sequence_apply_local)
end

return M
