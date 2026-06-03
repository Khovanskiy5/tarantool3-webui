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
local msgpack  = require('msgpack')
local digest   = require('digest')
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

local function tuple_to_graphql(tuple, pk_parts, space_name, format, with_msgpack)
    local fields = {}
    for i = 1, #tuple do
        -- Substitute the box.NULL sentinel for a stored NULL so the
        -- list keeps its length (a Lua-nil in the middle truncates
        -- it); json.encode renders box.NULL as JSON `null`.
        local enc = de_types.encode_field(tuple[i])
        if enc == nil then enc = box.NULL end
        fields[i] = enc
    end
    fields = mask_sensitive(space_name, fields, format)
    -- Extract the primary key fields by fieldno (parts[i].fieldno
    -- is 1-based in Tarantool 3.x).
    local pk = {}
    for i, part in ipairs(pk_parts or {}) do
        local fn = part.fieldno or part.field
        pk[i] = tuple[fn]
    end
    local row = {
        fields    = fields,
        pk_string = de_types.format_pk(pk),
        _pk       = pk,
    }
    -- DE-1.6: only encode the raw msgpack when the query opted in.
    -- `tuple` is a box tuple cdata — `:totable()` would lose the
    -- exact on-the-wire bytes, so we msgpack-encode the tuple
    -- directly. msgpack.encode accepts a box tuple and emits the
    -- same bytes Tarantool stores.
    if with_msgpack then
        local ok, packed = pcall(msgpack.encode, tuple)
        if ok then row.msgpack = digest.base64_encode(packed) end
    end
    return row
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
            scan_aborted  = false,
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
    local scanned       = 0
    -- `truncated` = the page hit `limit` and at least one more tuple
    -- exists — normal pagination. The SPA uses this to enable the
    -- Next button via `next_cursor`.
    --
    -- `scan_aborted` = the residual-filter walker bailed early
    -- (`scanned >= fetch_cap * 50`) to protect the TX-thread. This
    -- is the real "results incomplete" signal — there is no
    -- `next_cursor` to resume from and the SPA shows a warning.
    local truncated     = false
    local scan_aborted  = false

    -- We over-fetch by one to detect "more pages exist" without
    -- a second probe.
    local fetch_cap = limit + 1
    for _, tuple in idx:pairs(key, { iterator = iter }) do
        scanned = scanned + 1
        if de_filter.apply_post_filter(tuple, residual, lookup) then
            if #items >= limit then truncated = true; break end
            local row = tuple_to_graphql(tuple, idx.parts, space_name,
                format_list, args.with_msgpack == true)
            last_pk = row._pk
            row._pk = nil
            table.insert(items, row)
        end
        if scanned >= fetch_cap * 50 then
            -- Bail to avoid pinning the tx-thread on a pathological
            -- residual that filters everything out. Distinct from
            -- `truncated` (which is a normal pagination boundary).
            scan_aborted = true
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
        scan_aborted  = scan_aborted,
        partial_scan  = #residual > 0,
    })

    return {
        items         = items,
        next_cursor   = next_cursor,
        total         = total,
        partial_scan  = #residual > 0,
        truncated     = truncated,
        scan_aborted  = scan_aborted,
        index_used    = idx.name,
    }
end

-- ── collations ─────────────────────────────────────────────────────
--
-- `_collation` lists every collation Tarantool can use as a string
-- index part. There are ~270 built-in ICU collations plus any extras
-- the operator added. The schema editor needs the list so the index
-- form can offer a dropdown — picking by string name is the only
-- way Tarantool addresses collations from `space:create_index`.
--
-- Read-only here; create / drop ship in DE-2.5 (superuser).

-- The "none" collation (id 0) is the implicit default for every
-- string index. Exposing it as a configurable item would tell
-- operators "pick one" while in fact it is the no-op fallback —
-- the dropdown should treat its absence as "use default" instead.
local DEFAULT_COLLATION_ID = 0

function M.query_collations(root)
    require_role(root, 'collations')
    if rawget(_G, 'box') == nil or box.space == nil
        or box.space._collation == nil then
        return { collations = {} }
    end
    local out = {}
    for _, row in box.space._collation:pairs() do
        if row[1] ~= DEFAULT_COLLATION_ID then
            -- `_collation` format: {id, name, owner, type, locale, opts}.
            -- `owner` is intentionally dropped — the schema editor does
            -- not surface authorship, and including it would force a
            -- join through `_user` just to render a name. DE-2.5 brings
            -- that back when it adds the management surface.
            table.insert(out, {
                id       = row[1],
                name     = row[2],
                type     = row[4],
                locale   = row[5],
                icu_opts = row[6],
            })
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    logger.debug('listCollations', {
        count = #out, user = root and root.user,
        request_id = root and root.request_id,
    })
    return { collations = out }
end

-- ── space stats ────────────────────────────────────────────────────
--
-- Tarantool 3.7 exposes per-space numbers (`bsize`, `count`, memtx
-- tuple memory) and engine-wide context (`box.slab.info()`,
-- `box.stat.memtx().data`, `box.stat.vinyl()`). DE-1.7's "Stats"
-- panel reads both — operators inspecting "this space" almost
-- always want the slab quota gauge in the same view.

-- The `box.slab.info()` payload prints ratios as `"30.08%"`. The
-- SPA wants floats so it can drive a progress bar without
-- re-parsing — strip the trailing `%` here.
local function parse_pct(s)
    if type(s) ~= 'string' then return 0 end
    local n = tonumber((s:gsub('%%', '')))
    return n or 0
end

local function slab_info_normalized()
    local raw = box.slab.info()
    return {
        quota_size       = raw.quota_size or 0,
        quota_used       = raw.quota_used or 0,
        quota_used_ratio = parse_pct(raw.quota_used_ratio),
        items_size       = raw.items_size or 0,
        items_used       = raw.items_used or 0,
        items_used_ratio = parse_pct(raw.items_used_ratio),
        arena_size       = raw.arena_size or 0,
        arena_used       = raw.arena_used or 0,
        arena_used_ratio = parse_pct(raw.arena_used_ratio),
    }
end

local function memtx_data_summary()
    local data = box.stat.memtx() and box.stat.memtx().data or {}
    return {
        total      = data.total or 0,
        garbage    = data.garbage or 0,
        read_view  = data.read_view or 0,
    }
end

local function memtx_tuple_for(s)
    if s.engine ~= 'memtx' then return nil end
    local stat = s:stat() or {}
    local memtx = stat.tuple and stat.tuple.memtx or {}
    return {
        data_size      = memtx.data_size or 0,
        header_size    = memtx.header_size or 0,
        waste_size     = memtx.waste_size or 0,
        field_map_size = memtx.field_map_size or 0,
    }
end

local function vinyl_engine_summary(s)
    if s.engine ~= 'vinyl' then return nil end
    local v = box.stat.vinyl() or {}
    local mem = v.memory or {}
    local disk = v.disk or {}
    return {
        memory_tuple        = mem.tuple or 0,
        memory_tuple_cache  = mem.tuple_cache or 0,
        memory_level0       = mem.level0 or 0,
        memory_page_index   = mem.page_index or 0,
        memory_bloom_filter = mem.bloom_filter or 0,
        disk_data_bytes     = disk.data or 0,
        disk_data_compacted = disk.data_compacted or 0,
        disk_index_bytes    = disk.index or 0,
    }
end

function M.query_space_stats(root, args)
    require_role(root, 'spaceStats')
    if type(args.name) ~= 'string' or args.name == '' then
        error('VALIDATION_ERROR: name is required')
    end
    if rawget(_G, 'box') == nil or box.space == nil then
        error('UNAVAILABLE: box not initialised')
    end
    local s = box.space[args.name]
    if s == nil then
        error('NOT_FOUND: space ' .. args.name .. ' does not exist')
    end
    logger.debug('spaceStats', {
        space = args.name, user = root and root.user,
        request_id = root and root.request_id,
    })
    return {
        name         = s.name,
        id           = s.id,
        engine       = s.engine,
        byte_size    = s:bsize(),
        row_count    = s:count(),
        memtx_tuple  = memtx_tuple_for(s),
        vinyl_engine = vinyl_engine_summary(s),
        slab         = slab_info_normalized(),
        memtx_data   = memtx_data_summary(),
    }
end

-- ── index utility actions (DE-1.5) ────────────────────────────────
--
-- Single read-only resolver that dispatches over the 6 read-only
-- methods exposed by `space_object.index[name]`. The SPA opens a
-- per-index menu that calls this one resolver — six round-trips
-- per index would be too much network chatter for what amounts to
-- "show me a number".

local INDEX_ACTIONS = {
    min = true, max = true, random = true,
    count = true, stat = true, bsize = true,
}

local COUNT_ITERATORS = {
    EQ = true, GT = true, GE = true,
    LT = true, LE = true, REQ = true, ALL = true,
}

-- Map a Tarantool tuple to a list of GraphQL-Json-safe scalars.
-- Pulled inline (rather than reused via data_mutations.common) so
-- the read-only resolver does not depend on the mutation module.
local function tuple_fields(tuple)
    if tuple == nil then return nil end
    local out = {}
    for i = 1, #tuple do
        -- box.NULL sentinel for stored NULLs, same as tuple_to_graphql
        -- (keeps the list length; json.encode renders it as null).
        local enc = de_types.encode_field(tuple[i])
        if enc == nil then enc = box.NULL end
        out[i] = enc
    end
    return out
end

function M.query_index_action(root, args)
    require_role(root, 'indexAction')
    if type(args.space) ~= 'string' or args.space == '' then
        error('VALIDATION_ERROR: space is required')
    end
    if type(args.index) ~= 'string' or args.index == '' then
        error('VALIDATION_ERROR: index is required')
    end
    local action = tostring(args.action or '')
    if not INDEX_ACTIONS[action] then
        error('VALIDATION_ERROR: unsupported action ' .. action)
    end
    local s = box.space[args.space]
    if s == nil then
        error('NOT_FOUND: space ' .. args.space .. ' does not exist')
    end
    local idx = s.index[args.index]
    if idx == nil then
        error('NOT_FOUND: index ' .. args.index ..
            ' does not exist on ' .. args.space)
    end
    local key = args.key

    local res = { action = action }
    if action == 'min' or action == 'max' then
        local t = idx[action](idx, key)
        res.tuple = tuple_fields(t)
    elseif action == 'random' then
        -- `idx:random(seed)` requires a numeric seed. We mix in
        -- `clock.realtime()` because Math.random's state is not
        -- per-request reproducible — the operator clicking
        -- RANDOM twice in a row should not get the same row.
        local seed
        if key ~= nil and type(key[1]) == 'number' then
            seed = key[1]
        else
            local clock = require('clock')
            seed = math.floor(clock.realtime() * 1e6) % (2 ^ 31)
        end
        res.tuple = tuple_fields(idx:random(seed))
    elseif action == 'count' then
        local iter = args.iterator
        if iter ~= nil and not COUNT_ITERATORS[iter] then
            error('VALIDATION_ERROR: unsupported iterator ' .. tostring(iter))
        end
        if iter == nil then
            iter = key ~= nil and 'EQ' or 'ALL'
        end
        res.count = idx:count(key, { iterator = iter })
    elseif action == 'stat' then
        res.stat = idx:stat()
    elseif action == 'bsize' then
        res.bytes = idx:bsize()
    end
    logger.debug('indexAction', {
        space = args.space, index = args.index,
        action = action, user = root and root.user,
        request_id = root and root.request_id,
    })
    return res
end

-- ── sequence info (DE-1.3) ────────────────────────────────────────
--
-- Reads `_sequence` for the static metadata and `_sequence_data`
-- for the current value. The current value is nullable: Tarantool
-- only writes a `_sequence_data` row after the first `:next()` /
-- `:set()`, so a fresh sequence reports `current=null` until used.
--
-- `attached_to` walks `_space_sequence` and resolves space ids to
-- names so the SPA can warn before drop: "this sequence drives
-- two indexes; detach first".

local function sequence_attached_to(seq_id)
    if box.space._space_sequence == nil then return {} end
    local out = {}
    for _, row in box.space._space_sequence:pairs() do
        -- Format: {space_id, sequence_id, is_generated, field, path}
        if row[2] == seq_id then
            local space_tuple
            pcall(function() space_tuple = box.space._space:get({ row[1] }) end)
            local space_name = space_tuple and space_tuple[3] or tostring(row[1])
            table.insert(out, {
                space = space_name,
                field = row[4],
                path  = row[5] ~= '' and row[5] or nil,
            })
        end
    end
    return out
end

function M.query_sequence_info(root, args)
    require_role(root, 'sequenceInfo')
    if type(args.name) ~= 'string' or args.name == '' then
        error('VALIDATION_ERROR: name is required')
    end
    if rawget(_G, 'box') == nil or box.space == nil
        or box.space._sequence == nil then
        error('UNAVAILABLE: _sequence not initialised')
    end
    local seq_tuple = box.space._sequence.index.name:get({ args.name })
    if seq_tuple == nil then
        error('NOT_FOUND: sequence ' .. args.name .. ' does not exist')
    end
    -- `_sequence` tuple format:
    -- {id, owner, name, step, min, max, start, cache, cycle}
    local id = seq_tuple[1]
    local seq = box.sequence[args.name]
    local current
    if seq ~= nil then
        local ok, val = pcall(seq.current, seq)
        if ok then current = val end
    end
    logger.debug('sequenceInfo', {
        name = args.name, id = id,
        user = root and root.user,
        request_id = root and root.request_id,
    })
    return {
        id          = id,
        name        = seq_tuple[3],
        step        = seq_tuple[4],
        min         = seq_tuple[5],
        max         = seq_tuple[6],
        start       = seq_tuple[7],
        cache       = seq_tuple[8],
        cycle       = seq_tuple[9],
        current     = current,
        attached_to = sequence_attached_to(id),
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
