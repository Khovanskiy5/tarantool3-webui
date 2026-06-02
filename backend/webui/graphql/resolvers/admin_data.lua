--
-- Read-only resolvers for the admin-data pages: spaces, users,
-- tuples.
--
-- These project Tarantool's own metadata (`box.space._space`,
-- `box.space._user`) so the SPA can render `/data-explorer` and
-- `/users` without us having to invent a new storage layer. The
-- write surfaces (createSpace / setUserRoles / tuple-mutations)
-- ship in Phase 2 Task 2.3 + Phase 5; the queries here already
-- gate via RBAC so non-admin users do not see the user list and
-- system-space passwords are masked.
--

local rbac     = require('webui.auth.rbac')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('data_explorer')

local de_types  = require('webui.data_explorer.types')
local de_filter = require('webui.data_explorer.filter')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'viewer'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

-- ── spaces ─────────────────────────────────────────────────────────

local SYSTEM_PREFIX = '_'

-- describe_index(idx, format) → { id, name, type, unique, parts }
-- `parts` is the list of human-readable field names — the SPA uses
-- them to look up fieldnos through `space.format` on the wire, so we
-- MUST emit names, not fieldnos. Tarantool sometimes hands us back
-- parts with only `fieldno` set (no `field_name`), e.g. when the
-- index was created with `parts = {'id'}` instead of
-- `parts = {{field='id'}}`. In that case we resolve the fieldno
-- through the passed-in `format` array before falling back to the
-- numeric string — which the SPA cannot match against any field name.
local function describe_index(idx, format)
    local parts = {}
    for _, p in ipairs(idx.parts or {}) do
        local name
        if type(p) == 'table' then
            name = p.field_name or p.name
            if name == nil and p.fieldno ~= nil and format ~= nil then
                local fmt = format[p.fieldno]
                name = fmt and fmt.name or nil
            end
            if name == nil then name = tostring(p.fieldno) end
        else
            name = tostring(p)
        end
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

-- _space tuple layout (Tarantool 3.x, `_space:format()`):
--   [1] id        [4] engine
--   [2] owner     [5] field_count
--   [3] name      [6] flags (table)  [7] format (list)
local SPACE_F_ID, SPACE_F_NAME, SPACE_F_ENGINE = 1, 3, 4
local SPACE_F_FLAGS, SPACE_F_FORMAT = 6, 7

-- Count triggers on a space. `space:on_replace()` etc. return the
-- registered handlers when called with no argument — we call all
-- three trigger surfaces and sum them.
local function triggers_count(space)
    if space == nil then return 0 end
    local total = 0
    for _, surface in ipairs({ 'on_replace', 'before_replace', 'on_recovery_replace' }) do
        local fn = space[surface]
        if type(fn) == 'function' then
            local ok, list = pcall(fn, space)
            if ok and type(list) == 'table' then total = total + #list end
        end
    end
    return total
end

-- Find a sequence attached to a space. Tarantool stores the link
-- inside `_space_sequence`; absence means "no autoincrement".
local function attached_sequence(space_id)
    if box.space._space_sequence == nil then return nil end
    local ok, tuple = pcall(function() return box.space._space_sequence:get({ space_id }) end)
    if not ok or tuple == nil then return nil end
    local seq_id = tuple[2]
    if box.space._sequence == nil then return nil end
    local seq = box.space._sequence:get({ seq_id })
    if seq == nil then return nil end
    return seq[3]
end

-- A space is synchronous when `is_sync` is set in its flags.
local function space_is_sync(raw_flags)
    if type(raw_flags) ~= 'table' then return false end
    return raw_flags.is_sync == true or raw_flags.group_id == 0 and raw_flags.is_sync == true
        or raw_flags.is_sync == 'true'
end

-- Project a single `_space` tuple into the SpaceInfo GraphQL type.
local function project_space(sp)
    local id         = sp[SPACE_F_ID]
    local name       = sp[SPACE_F_NAME]
    local engine     = sp[SPACE_F_ENGINE]
    local raw_flags  = sp[SPACE_F_FLAGS]
    local raw_format = sp[SPACE_F_FORMAT]

    local space = box.space[name]
    local normalised_format = de_types.normalize_format(raw_format)
    local indexes, rows, bytes = {}, 0, nil
    if space ~= nil then
        for k, idx in pairs(space.index) do
            if type(k) == 'number'
                and type(idx) == 'table' and idx.parts ~= nil then
                table.insert(indexes, describe_index(idx, normalised_format))
            end
        end
        table.sort(indexes, function(a, b) return a.id < b.id end)
        -- `:count()` is O(n) on vinyl; protect the tx-thread with
        -- pcall and skip on engines that do not support it.
        if engine ~= 'vinyl' then
            pcall(function() rows = space:count() end)
        end
        if type(space.bsize) == 'function' then
            pcall(function() bytes = space:bsize() end)
        end
    end

    return {
        id              = id,
        name            = name,
        engine          = engine,
        row_count       = rows,
        size_bytes      = bytes,
        is_sync         = space_is_sync(raw_flags),
        triggers_count  = triggers_count(space),
        sequence        = attached_sequence(id),
        format          = normalised_format,
        indexes         = indexes,
    }
end

function M.query_spaces(root, args)
    require_role(root, 'cluster')
    if rawget(_G, 'box') == nil or box.space == nil then return { spaces = {} } end
    local include_sys = (args and args.include_system) == true
    local out = {}
    for _, sp in box.space._space:pairs() do
        local name = sp[SPACE_F_NAME]
        if include_sys or (name:sub(1, 1) ~= SYSTEM_PREFIX) then
            table.insert(out, project_space(sp))
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return { spaces = out }
end

-- ── tuples ─────────────────────────────────────────────────────────

-- System spaces whose passwords / credentials we must mask in
-- read responses. Direct mutations on these are blocked separately
-- in Phase 2 Task 2.3 (`data_mutations.lua`).
--
-- `_vuser` is a sysview over `_user` — same tuples, same hashes,
-- different space id. Reading from the view bypasses the mask
-- unless we list it explicitly here, so the UI's "System on"
-- toggle would otherwise leak credentials in plain sight.
local SENSITIVE_AUTH = { ['chap-sha1'] = true, ['scram-sha-256'] = true }
local SENSITIVE_READ_FIELDS = {
    _user  = SENSITIVE_AUTH,
    _vuser = SENSITIVE_AUTH,
}

local function mask_sensitive(space_name, fields, format)
    local masks = SENSITIVE_READ_FIELDS[space_name]
    if masks == nil then return fields end
    -- _user[5] is the `auth` map. Wipe entries by name.
    for i, f in ipairs(format or {}) do
        if f.name == 'auth' and type(fields[i]) == 'table' then
            local copy = {}
            for k, v in pairs(fields[i]) do
                copy[k] = masks[k] and '<hidden>' or v
            end
            fields[i] = copy
        end
    end
    return fields
end

local function tuple_to_graphql(tuple, pk_parts, space_name, format)
    local fields = {}
    for i = 1, #tuple do
        fields[i] = de_types.encode_field(tuple[i])
    end
    fields = mask_sensitive(space_name, fields, format)
    -- Extract the primary key fields by fieldno (parts[i].fieldno
    -- is 1-based in Tarantool 3.x).
    local pk = {}
    for i, part in ipairs(pk_parts or {}) do
        local fn = part.fieldno or part.field
        pk[i] = tuple[fn]
    end
    return {
        fields    = fields,
        pk_string = de_types.format_pk(pk),
        _pk       = pk,
    }
end

function M.query_tuples(root, args)
    require_role(root, 'cluster')
    if rawget(_G, 'box') == nil or box.space == nil then
        error('UNAVAILABLE: storage not available')
    end
    args = args or {}
    local space_name = args.space
    if type(space_name) ~= 'string' or space_name == '' then
        error('VALIDATION_ERROR: space is required')
    end
    local space = box.space[space_name]
    if space == nil then
        error('NOT_FOUND: space ' .. space_name)
    end

    -- Normalize filter ops. The GraphQL enum surfaces values as
    -- their UPPER_SNAKE name (`'EQ'`) at the resolver boundary —
    -- the lib does not run our `enum.values[name].value` map
    -- through coerceValue. We normalize once here so the filter
    -- compiler stays unaware of the wire format.
    -- `args.filter` is `box.NULL` (cdata 'void') when the SPA omits
    -- it, not a Lua nil — `or {}` would not short-circuit. Guard
    -- explicitly via type().
    local filter_in = (type(args.filter) == 'table') and args.filter or {}
    local raw_filter = {}
    for _, c in ipairs(filter_in) do
        if type(c) ~= 'table' or type(c.field) ~= 'string'
            or type(c.op) ~= 'string' then
            error('VALIDATION_ERROR: invalid filter condition (need {field, op, value}, op in '
                .. table.concat({ 'eq', 'ne', 'gt', 'ge', 'lt', 'le', 'like', 'prefix' }, '|') .. ')')
        end
        local op = c.op:lower()
        if not de_filter.OPS[op] then
            error('VALIDATION_ERROR: unsupported filter op ' .. tostring(c.op))
        end
        table.insert(raw_filter, { field = c.field, op = op, value = c.value })
    end

    -- Full-scan guard. The operator can override with
    -- allow_full_scan=true; we audit the override (see Task 5.21).
    local ok_scan, err_scan = de_filter.check_full_scan(
        space, raw_filter,
        { allow_full_scan = args.allow_full_scan == true })
    if not ok_scan then error(err_scan) end

    -- Index selection. If the caller named an index, use it as a
    -- hint; otherwise pick the best-covering one.
    local idx, covered
    if args.index ~= nil and args.index ~= '' then
        idx = space.index[args.index]
        if idx == nil then
            error('NOT_FOUND: index ' .. tostring(args.index) .. ' on ' .. space_name)
        end
        -- Trust the hint: cover only matches for `eq` on leading parts.
        local _
        _, covered = de_filter.pick_index(space, raw_filter)
    else
        idx, covered = de_filter.pick_index(space, raw_filter)
    end
    if idx == nil then idx, covered = space.index[0], 0 end
    -- Some space engines (blackhole, sysview shims around empty
    -- system tables) ship without any usable index — `space.index`
    -- is an empty table and `space.index[0]` is nil. We surface
    -- an empty connection instead of crashing the resolver so the
    -- UI can still render the table header.
    if idx == nil then
        logger.info('tuples scan skipped (no index)', {
            space = space_name,
        })
        return {
            items         = {},
            next_cursor   = nil,
            total         = 0,
            partial_scan  = false,
            truncated     = false,
            index_used    = nil,
        }
    end

    local key, iter = de_filter.build_key(idx, covered, raw_filter)
    local residual  = de_filter.residual(raw_filter, idx, covered)

    -- Cursor decode. A bad cursor degrades to "fresh scan" rather
    -- than 500.
    local after_key = de_types.cursor_decode(args.after)
    if after_key ~= nil then
        -- `after=...` semantics: continue strictly after the given
        -- key. GT for ascending iterators, GE otherwise — we only
        -- support ascending here so GT is correct.
        key  = after_key
        iter = 'GT'
    end

    local limit = math.min(tonumber(args.limit) or 100, de_filter.HARD_LIMIT)
    local items, last_pk = {}, nil
    local format_list = de_types.normalize_format(box.space._space:get({ space.id })[7])
    local lookup      = de_filter._build_field_lookup(format_list)
    local scanned, truncated = 0, false

    -- We over-fetch by one to detect "more pages exist" without
    -- a second probe.
    local fetch_cap = limit + 1
    for _, tuple in idx:pairs(key, { iterator = iter }) do
        scanned = scanned + 1
        if de_filter.apply_post_filter(tuple, residual, lookup) then
            if #items >= limit then truncated = true; break end
            local row = tuple_to_graphql(tuple, idx.parts, space_name, format_list)
            last_pk = row._pk
            row._pk = nil
            table.insert(items, row)
        end
        if scanned >= fetch_cap * 50 then
            -- Bail to avoid pinning the tx-thread on a pathological
            -- residual that filters everything out.
            truncated = true
            break
        end
    end

    -- Total: ONLY when the iterator is EQ on a non-vinyl space.
    local total
    if iter == 'EQ' and space.engine ~= 'vinyl' then
        pcall(function() total = idx:count(key, { iterator = 'EQ' }) end)
    end

    local next_cursor
    if truncated and last_pk ~= nil then
        next_cursor = de_types.cursor_encode(last_pk)
    end

    logger.info('tuples scan', {
        space         = space_name,
        index         = idx.name,
        iter          = iter,
        covered_parts = covered,
        filter_size   = #raw_filter,
        residual      = #residual,
        scanned       = scanned,
        returned      = #items,
        truncated     = truncated,
        partial_scan  = #residual > 0,
    })

    return {
        items         = items,
        next_cursor   = next_cursor,
        total         = total,
        partial_scan  = #residual > 0,
        truncated     = truncated,
        index_used    = idx.name,
    }
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
