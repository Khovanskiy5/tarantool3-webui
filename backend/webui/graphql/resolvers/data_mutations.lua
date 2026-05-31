--
-- Tuple-level CRUD mutations for the data-explorer.
--
-- Four mutations: tupleInsert, tupleReplace, tupleUpdate,
-- tupleDelete. All four:
--
--   1. Refuse to touch system spaces by name (deny-list below).
--      The catalog has dedicated mutations for the legitimate use
--      cases (`setUserRoles`, `grantPrivilege`, …). A raw
--      `tupleUpdate('_user', ...)` would let an admin set the
--      `chap-sha1` field to an arbitrary hash → password bypass.
--
--   2. Coerce every field through `data_explorer.types.coerce_tuple`
--      so the JSON-wire payload reaches the storage engine in the
--      shape Tarantool expects (uuid cdata, decimal cdata, raw
--      bytes for binary, json-decoded map / array, …) and so
--      non-trailing null positions become `box.NULL` instead of
--      being truncated.
--
--   3. Run on the leader. A follower forwards via net.box to the
--      cluster leader, mirroring the pattern in `audit/log.lua`
--      and `config_store/twophase.lua`. The forwarded path uses a
--      registered `webui_data_mutation_remote` function so peers
--      can call it without `super` privileges (the function runs
--      under the peer-cookie user, who already has CRUD on user
--      spaces via the WebUI role registration).
--
--   4. Record a `data.<op>` audit row with before/after payload
--      so destructive edits are reconstructable post-incident.
--

local json     = require('json')

local rbac     = require('webui.auth.rbac')
local audit    = require('webui.audit.log')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('graphql.data_mutations')

local de_types = require('webui.data_explorer.types')

local M = {}

-- Spaces the GraphQL surface refuses to mutate at the tuple level.
-- Read access stays open under admin (with masked credential fields
-- — see `admin_data.lua`).
M.SENSITIVE_SPACES = {
    _user             = true,
    _priv             = true,
    _func             = true,
    _schema           = true,
    _cluster          = true,
    _session_settings = true,
}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

local function assert_safe_space(space_name, op)
    if M.SENSITIVE_SPACES[space_name] then
        error('FORBIDDEN: ' .. op .. ' on system space ' .. space_name ..
            ' is blocked. Use dedicated mutations (setUserRoles, ' ..
            'grantPrivilege, hotReloadModule, ...) so the change ' ..
            'goes through validation + audit + the matching ' ..
            'forward-to-leader path.')
    end
end

-- Build the `format` array for type lookups. We pull from
-- `box.space[name]:format()` rather than `_space[id][7]` because
-- the former resolves inherited types through aliases.
local function space_format(space)
    local raw = type(space.format) == 'function' and space:format() or {}
    return de_types.normalize_format(raw)
end

local function space_pk_parts(space)
    local idx = space.index[0]
    if idx == nil then return {} end
    return idx.parts or {}
end

-- ── leader forwarding ──────────────────────────────────────────────

local function is_read_only()
    if rawget(_G, 'box') == nil or box.info == nil then return false end
    return box.info.ro == true
end

local function forward_to_leader(op, space, payload, root)
    local ok_state, cluster_state = pcall(require, 'webui.cluster.state')
    local ok_peers, peers         = pcall(require, 'webui.cluster.peers')
    if not (ok_state and ok_peers) then
        return nil, 'UNAVAILABLE: cluster modules not loaded'
    end
    local leader_alias = cluster_state.find_leader()
    if leader_alias == nil then
        return nil, 'UNAVAILABLE: no cluster leader reachable'
    end
    local peer = peers.get(leader_alias)
    if peer == nil or peer.conn == nil then
        return nil, 'UNAVAILABLE: leader ' .. leader_alias .. ' not reachable'
    end
    -- Synchronous call: the user is waiting on the response, so we
    -- cannot fire-and-forget like audit does. Tarantool's net.box
    -- call signals errors via the second return value; we re-raise
    -- as the same envelope the local path would have produced.
    local timeout = 5
    local ok, res, err = pcall(function()
        return peer.conn:call('webui_data_mutation_remote',
            { op, space, payload, {
                user       = root and root.user,
                request_id = root and root.request_id,
                roles      = root and root.roles,
            } }, { timeout = timeout })
    end)
    if not ok then
        return nil, 'forward to leader ' .. leader_alias .. ' failed: ' .. tostring(res)
    end
    if type(res) == 'table' and res._error ~= nil then
        return nil, res._error
    end
    if err ~= nil then
        return nil, tostring(err)
    end
    res.forwarded = true
    res.leader = leader_alias
    return res
end

-- ── tuple → wire ───────────────────────────────────────────────────

local function tuple_to_wire(tuple)
    if tuple == nil then return nil end
    local fields = {}
    for i = 1, #tuple do fields[i] = de_types.encode_field(tuple[i]) end
    return fields
end

-- ── local apply implementations ────────────────────────────────────

local function local_insert(space_name, fields_in)
    local space = box.space[space_name]
    if space == nil then error('NOT_FOUND: space ' .. space_name) end
    local fmt = space_format(space)
    local coerced, err = de_types.coerce_tuple(fields_in, fmt)
    if err ~= nil then error('VALIDATION_ERROR: ' .. err) end
    local new_tuple = space:insert(coerced)
    return { ok = true, after = tuple_to_wire(new_tuple) }
end

local function local_replace(space_name, fields_in)
    local space = box.space[space_name]
    if space == nil then error('NOT_FOUND: space ' .. space_name) end
    local fmt = space_format(space)
    local pk_parts = space_pk_parts(space)
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
        before = tuple_to_wire(before),
        after  = tuple_to_wire(new_tuple),
    }
end

local function local_delete(space_name, key_in)
    local space = box.space[space_name]
    if space == nil then error('NOT_FOUND: space ' .. space_name) end
    local fmt = space_format(space)
    local pk_parts = space_pk_parts(space)
    local key, err = de_types.coerce_key(key_in, pk_parts, fmt)
    if err ~= nil then error('VALIDATION_ERROR: ' .. err) end
    local before = space:get(key)
    if before == nil then error('NOT_FOUND: tuple with key ' .. json.encode(key_in)) end
    local deleted = space:delete(key)
    return { ok = true, before = tuple_to_wire(deleted) }
end

local UPDATE_OPS = {
    set = '=', SET = '=', ['='] = '=',
    add = '+', ADD = '+', ['+'] = '+',
    sub = '-', SUB = '-', ['-'] = '-',
    band = '&', BAND = '&', ['&'] = '&',
    bor  = '|', BOR  = '|', ['|'] = '|',
    bxor = '^', BXOR = '^', ['^'] = '^',
    splice = ':', SPLICE = ':', [':'] = ':',
    insert = '!', INSERT = '!', ['!'] = '!',
    delete = '#', DELETE = '#', ['#'] = '#',
}

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
        local code = UPDATE_OPS[op.op]
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
    local fmt = space_format(space)
    local pk_parts = space_pk_parts(space)
    local key, err = de_types.coerce_key(key_in, pk_parts, fmt)
    if err ~= nil then error('VALIDATION_ERROR: ' .. err) end
    local ops = build_update_ops(raw_ops, fmt)
    local before = space:get(key)
    if before == nil then error('NOT_FOUND: tuple with key ' .. json.encode(key_in)) end
    local after = space:update(key, ops)
    return {
        ok     = true,
        before = tuple_to_wire(before),
        after  = tuple_to_wire(after),
    }
end

local LOCAL_APPLY = {
    insert  = function(s, p) return local_insert(s, p.fields) end,
    replace = function(s, p) return local_replace(s, p.fields) end,
    delete  = function(s, p) return local_delete(s, p.key) end,
    update  = function(s, p) return local_update(s, p.key, p.ops) end,
}

-- ── public entry points ────────────────────────────────────────────

local function apply(field_name, op, space_name, payload, root)
    require_role(root, field_name)
    assert_safe_space(space_name, op)
    if is_read_only() then
        local res, err = forward_to_leader(op, space_name, payload, root)
        if res == nil then error(err) end
        -- Audit on the follower side too: the operator's intent
        -- happened here, even if the data write was forwarded.
        pcall(audit.record, {
            user       = root and root.user,
            action     = 'data.' .. op,
            scope      = 'space:' .. space_name,
            payload    = { forwarded_to = res.leader, before = res.before, after = res.after },
            request_id = root and root.request_id,
        })
        return res
    end
    local impl = LOCAL_APPLY[op]
    local res = impl(space_name, payload)
    pcall(audit.record, {
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

-- ── space create / drop ─────────────────────────────────────────────
--
-- DDL via box.schema. We forward to leader on followers (replicated
-- DDL otherwise rejects with READONLY), enforce the same sensitive-
-- name guard that protects tuple writes, and audit every change.

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
    error('VALIDATION_ERROR: unknown space op ' .. tostring(op))
end

local function space_apply(field_name, op, payload, root)
    require_role(root, field_name)
    if type(payload.name) ~= 'string' or payload.name == '' then
        error('VALIDATION_ERROR: name is required')
    end
    if M.SENSITIVE_SPACES[payload.name]
        or payload.name:sub(1, 1) == '_' then
        error('FORBIDDEN: ' .. op .. ' on system space ' .. payload.name ..
            ' is blocked. The `_`-prefix namespace belongs to Tarantool ' ..
            'and dedicated mutations (createUser, hotReloadModule, …).')
    end
    if is_read_only() then
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
        local ok_call, res = pcall(function()
            return peer.conn:call('webui_space_mutation_remote',
                { op, payload, { user = root and root.user,
                                 request_id = root and root.request_id } },
                { timeout = 5 })
        end)
        if not ok_call then error('forward to leader failed: ' .. tostring(res)) end
        if type(res) == 'table' and res._error then error(res._error) end
        res.forwarded = true
        res.leader = leader_alias
        pcall(audit.record, {
            user = root and root.user, action = op,
            scope = 'space:' .. payload.name,
            payload = { forwarded_to = leader_alias, name = res.name },
            request_id = root and root.request_id,
        })
        return res
    end
    local ok, res = pcall(space_apply_local, op, payload)
    if not ok then error(res) end
    pcall(audit.record, {
        user = root and root.user, action = op,
        scope = 'space:' .. payload.name,
        payload = { name = res.name, id = res.id },
        request_id = root and root.request_id,
    })
    logger.info(op .. ' ok', {
        space = payload.name, user = root and root.user,
        request_id = root and root.request_id,
    })
    return res
end

function M.create_space(root, args)
    return space_apply('createSpace', 'space_create', {
        name        = args.name,
        engine      = args.engine,
        is_sync     = args.is_sync == true,
        if_not_exists = args.if_not_exists == true,
        format      = args.format,
        primary_key = args.primary_key,
    }, root)
end

function M.drop_space(root, args)
    return space_apply('dropSpace', 'space_drop', {
        name = args.name,
    }, root)
end

function M.alter_space(root, args)
    return space_apply('alterSpace', 'space_alter', {
        name     = args.name,
        new_name = args.new_name,
        format   = args.format,
        is_sync  = args.is_sync,
    }, root)
end

function M.create_index(root, args)
    return space_apply('createIndex', 'index_create', {
        name          = args.space,
        index_name    = args.name,
        parts         = args.parts,
        type          = args.type,
        unique        = args.unique,
        if_not_exists = args.if_not_exists,
    }, root)
end

function M.drop_index(root, args)
    return space_apply('dropIndex', 'index_drop', {
        name       = args.space,
        index_name = args.name,
    }, root)
end

-- Remote receiver for space DDL — same idea as
-- webui_data_mutation_remote, re-checks the deny-list on the
-- leader side so a misbehaving follower can't smuggle a write.
function M.space_remote_entry(op, payload, ctx)
    if type(payload) ~= 'table'
        or type(payload.name) ~= 'string' or payload.name == '' then
        return { _error = 'VALIDATION_ERROR: name is required' }
    end
    if M.SENSITIVE_SPACES[payload.name]
        or payload.name:sub(1, 1) == '_' then
        return { _error = 'FORBIDDEN: ' .. op .. ' on system space '
            .. payload.name .. ' is blocked.' }
    end
    local ok, res = pcall(space_apply_local, op, payload)
    if not ok then return { _error = tostring(res) } end
    pcall(audit.record, {
        user = ctx and ctx.user, action = op,
        scope = 'space:' .. payload.name,
        payload = { name = res.name, id = res.id, via = 'forward' },
        request_id = ctx and ctx.request_id,
    })
    return res
end

-- ── leader-side forwarded entry point ──────────────────────────────
--
-- Registered by init.lua as `webui_data_mutation_remote`. The
-- follower calls it via net.box; it runs the local apply on the
-- leader, then bundles success / error into a table the caller can
-- distinguish from a transport failure (where pcall sees `nil, err`).
function M.remote_entry(op, space_name, payload, ctx)
    local impl = LOCAL_APPLY[op]
    if impl == nil then
        return { _error = 'INTERNAL: unknown op ' .. tostring(op) }
    end
    -- Re-enforce deny-list at the leader so a misbehaving follower
    -- cannot get around it by talking to us directly.
    if M.SENSITIVE_SPACES[space_name] then
        return { _error = 'FORBIDDEN: ' .. op .. ' on system space ' ..
            space_name .. ' is blocked.' }
    end
    local ok, res = pcall(impl, space_name, payload)
    if not ok then return { _error = tostring(res) } end
    -- Audit on the leader side as well so the row is owned by the
    -- leader's `_webui_audit` (which is sync) regardless of which
    -- peer accepted the request.
    pcall(audit.record, {
        user       = ctx and ctx.user,
        action     = 'data.' .. op,
        scope      = 'space:' .. space_name,
        payload    = { before = res.before, after = res.after, via = 'forward' },
        request_id = ctx and ctx.request_id,
    })
    return res
end

return M
