--
-- Pure cluster YAML transformer for the `editTopology` mutation.
--
-- Takes a parsed Tarantool 3.x cluster config (the `yaml.decode`'d
-- table) and a TopologyEdit input — arrays of server-edits and
-- replicaset-edits — and returns a new parsed config + a structured
-- list of operations describing what changed. No I/O, no etcd, no
-- net.box; everything happens in-memory so the function is trivial
-- to unit-test and idempotent on identical input.
--
-- Contract:
--   apply(cfg, {servers = [...], replicasets = [...]})
--     -> new_cfg (table), ops [{op, path, before?, after?}], errs [{path,
--        message}]
--
-- All edits are validated *before* being applied to `new_cfg`. If
-- ANY edit fails validation the function returns `(nil, {}, errs)`
-- so the resolver can reject the whole batch atomically — Cartridge's
-- editTopology contract. Partial application is never observable.
--

local M = {}

-- Recursive deep-copy. Tables are cloned, scalars passed by value.
-- We avoid `table.deepcopy` because some Tarantool builds do not
-- ship it, and we need predictable behaviour in the test sandbox
-- (no `require('table.copy')`).
local function deep_copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deep_copy(v) end
    return out
end

-- ── Locator helpers ─────────────────────────────────────────────────

-- Walk groups → replicasets → instances to find which {group, rs}
-- owns the alias. Returns (group_name, rs_name, instance_table) or
-- (nil, nil, nil) when the alias is not yet present.
local function find_instance(cfg, alias)
    local groups = cfg and cfg.groups
    if type(groups) ~= 'table' then return nil end
    for gname, group in pairs(groups) do
        local rss = group and group.replicasets
        if type(rss) == 'table' then
            for rsname, rs in pairs(rss) do
                local instances = rs and rs.instances
                if type(instances) == 'table'
                    and instances[alias] ~= nil then
                    return gname, rsname, instances[alias]
                end
            end
        end
    end
    return nil
end

-- Find a replicaset by name. The caller may pass `group_hint` to
-- disambiguate when two groups host replicasets with the same name
-- (rare, but allowed by the schema). Returns (group_name, rs_name,
-- rs_table) or (nil, nil, nil).
local function find_replicaset(cfg, rs_name, group_hint)
    local groups = cfg and cfg.groups
    if type(groups) ~= 'table' then return nil end
    if group_hint ~= nil then
        local g = groups[group_hint]
        if type(g) == 'table'
            and type(g.replicasets) == 'table'
            and g.replicasets[rs_name] ~= nil then
            return group_hint, rs_name, g.replicasets[rs_name]
        end
        return nil
    end
    for gname, group in pairs(groups) do
        local rss = group and group.replicasets
        if type(rss) == 'table' and rss[rs_name] ~= nil then
            return gname, rs_name, rss[rs_name]
        end
    end
    return nil
end

-- Ensure cfg.groups.<g>.replicasets.<rs>.instances chain exists,
-- creating empty tables along the way. Returns the instances table.
local function ensure_instances_table(cfg, group_name, rs_name)
    cfg.groups = cfg.groups or {}
    local group = cfg.groups[group_name]
    if group == nil then
        group = {}
        cfg.groups[group_name] = group
    end
    group.replicasets = group.replicasets or {}
    local rs = group.replicasets[rs_name]
    if rs == nil then
        rs = {}
        group.replicasets[rs_name] = rs
    end
    rs.instances = rs.instances or {}
    return rs.instances, rs
end

-- ── Server edits ────────────────────────────────────────────────────

-- Apply a single server-edit. Mutates `cfg` in place, appends to
-- `ops`, returns `err` (a {path, message} table) on validation
-- failure or nil on success.
local function apply_server_edit(cfg, edit, ops)
    if type(edit) ~= 'table' or type(edit.alias) ~= 'string'
        or edit.alias == '' then
        return { path = '/servers', message = 'server.alias is required' }
    end
    local alias = edit.alias

    local gname, rsname, inst = find_instance(cfg, alias)
    if inst == nil then
        -- A bare `{alias = ...}` reference without target_group /
        -- target_replicaset is an error — we cannot guess where to
        -- create it. Use the createReplicaset / editReplicaset
        -- aliases to introduce new instances atomically.
        if edit.target_group == nil or edit.target_replicaset == nil then
            return {
                path = '/servers/' .. alias,
                message = 'instance not found; supply target_group + '
                    .. 'target_replicaset to create it, or call '
                    .. 'createReplicaset / editReplicaset',
            }
        end
        gname = edit.target_group
        rsname = edit.target_replicaset
        local instances = ensure_instances_table(cfg, gname, rsname)
        inst = {}
        instances[alias] = inst
        table.insert(ops, {
            op = 'add',
            path = string.format('/groups/%s/replicasets/%s/instances/%s',
                gname, rsname, alias),
            after = inst,
        })
    end

    local path = string.format('/groups/%s/replicasets/%s/instances/%s',
        gname, rsname, alias)

    -- database.mode = 'rw' | 'ro' (kept under `database.mode`).
    if edit.mode ~= nil then
        if edit.mode ~= 'rw' and edit.mode ~= 'ro' then
            return {
                path = path .. '/database/mode',
                message = 'mode must be "rw" or "ro"',
            }
        end
        inst.database = inst.database or {}
        local before = inst.database.mode
        inst.database.mode = edit.mode
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/database/mode',
            before = before, after = edit.mode,
        })
    end

    -- iproto.advertise.peer.uri.
    if edit.uri ~= nil then
        if type(edit.uri) ~= 'string' or edit.uri == '' then
            return {
                path = path .. '/iproto/advertise/peer/uri',
                message = 'uri must be a non-empty string',
            }
        end
        inst.iproto = inst.iproto or {}
        inst.iproto.advertise = inst.iproto.advertise or {}
        inst.iproto.advertise.peer = inst.iproto.advertise.peer or {}
        local before = inst.iproto.advertise.peer.uri
        inst.iproto.advertise.peer.uri = edit.uri
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/iproto/advertise/peer/uri',
            before = before, after = edit.uri,
        })
    end

    -- iproto.listen — array of {uri = ...}. The schema rejects a
    -- listen URI that is not under a list; accept either a bare
    -- string (we wrap it) or a list of strings.
    if edit.listen ~= nil then
        local list = {}
        if type(edit.listen) == 'string' then
            table.insert(list, { uri = edit.listen })
        elseif type(edit.listen) == 'table' then
            for _, v in ipairs(edit.listen) do
                if type(v) == 'string' then
                    table.insert(list, { uri = v })
                elseif type(v) == 'table' and v.uri ~= nil then
                    table.insert(list, { uri = v.uri })
                end
            end
        else
            return {
                path = path .. '/iproto/listen',
                message = 'listen must be a string or a list',
            }
        end
        inst.iproto = inst.iproto or {}
        local before = inst.iproto.listen
        inst.iproto.listen = list
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/iproto/listen',
            before = before, after = list,
        })
    end

    -- zone (logical placement; consumed by failover scoring).
    if edit.zone ~= nil then
        if type(edit.zone) ~= 'string' then
            return { path = path .. '/zone', message = 'zone must be a string' }
        end
        local before = inst.zone
        inst.zone = edit.zone
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/zone',
            before = before, after = edit.zone,
        })
    end

    -- labels (key/value map for routing / discovery).
    if edit.labels ~= nil then
        if type(edit.labels) ~= 'table' then
            return { path = path .. '/labels',
                message = 'labels must be a table' }
        end
        local before = inst.labels
        inst.labels = edit.labels
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/labels',
            before = before, after = edit.labels,
        })
    end

    return nil
end

-- ── Replicaset edits ────────────────────────────────────────────────

-- Apply a single replicaset-edit. Mutates `cfg` in place, appends
-- to `ops`, returns `err` on validation failure or nil on success.
local function apply_replicaset_edit(cfg, edit, ops)
    if type(edit) ~= 'table' or type(edit.name) ~= 'string'
        or edit.name == '' then
        return { path = '/replicasets',
            message = 'replicaset.name is required' }
    end
    local rs_name = edit.name
    local group_hint = edit.group

    local gname, _, rs = find_replicaset(cfg, rs_name, group_hint)
    local is_new = rs == nil
    if is_new then
        if group_hint == nil then
            return {
                path = '/replicasets/' .. rs_name,
                message = 'replicaset not found; supply `group` to create it',
            }
        end
        local _, new_rs = ensure_instances_table(cfg, group_hint, rs_name)
        gname = group_hint
        rs = new_rs
        table.insert(ops, {
            op = 'add',
            path = string.format('/groups/%s/replicasets/%s',
                gname, rs_name),
            after = rs,
        })
    end

    local path = string.format('/groups/%s/replicasets/%s', gname, rs_name)

    -- roles: list of role identifiers applied to every instance in
    -- the replicaset. Schema validation is the responsibility of the
    -- caller (validateConfig on the assembled YAML); here we only
    -- type-check and write through.
    if edit.roles ~= nil then
        if type(edit.roles) ~= 'table' then
            return { path = path .. '/roles',
                message = 'roles must be a list of strings' }
        end
        local before = rs.roles
        rs.roles = edit.roles
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/roles',
            before = before, after = edit.roles,
        })
    end

    -- leader: alias inside this replicaset.
    if edit.leader ~= nil then
        if edit.leader ~= '' and type(edit.leader) ~= 'string' then
            return { path = path .. '/leader',
                message = 'leader must be a string alias' }
        end
        if edit.leader ~= '' and rs.instances ~= nil
            and rs.instances[edit.leader] == nil
            and (edit.join_instances == nil
                 or edit.join_instances[edit.leader] == nil) then
            return { path = path .. '/leader',
                message = string.format(
                    'leader %q is not in the replicaset (declare it via '
                    .. 'join_instances or servers[] first)',
                    tostring(edit.leader)) }
        end
        local before = rs.leader
        if edit.leader == '' then
            rs.leader = nil
        else
            rs.leader = edit.leader
        end
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/leader',
            before = before, after = rs.leader,
        })
    end

    -- failover_priority: ordered list of aliases inside this rs.
    if edit.failover_priority ~= nil then
        if type(edit.failover_priority) ~= 'table' then
            return { path = path .. '/failover_priority',
                message = 'failover_priority must be a list' }
        end
        for _, alias in ipairs(edit.failover_priority) do
            if type(alias) ~= 'string' then
                return { path = path .. '/failover_priority',
                    message = 'failover_priority entries must be strings' }
            end
        end
        local before = rs.failover_priority
        rs.failover_priority = edit.failover_priority
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/failover_priority',
            before = before, after = edit.failover_priority,
        })
    end

    -- weight (vshard bucket placement weight).
    if edit.weight ~= nil then
        if type(edit.weight) ~= 'number' or edit.weight < 0 then
            return { path = path .. '/weight',
                message = 'weight must be a non-negative number' }
        end
        local before = rs.weight
        rs.weight = edit.weight
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/weight',
            before = before, after = edit.weight,
        })
    end

    if edit.vshard_group ~= nil then
        if type(edit.vshard_group) ~= 'string' then
            return { path = path .. '/sharding/group',
                message = 'vshard_group must be a string' }
        end
        rs.sharding = rs.sharding or {}
        local before = rs.sharding.group
        rs.sharding.group = edit.vshard_group
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/sharding/group',
            before = before, after = edit.vshard_group,
        })
    end

    if edit.all_rw ~= nil then
        if type(edit.all_rw) ~= 'boolean' then
            return { path = path .. '/database/use_mvcc_engine',
                message = 'all_rw must be a boolean' }
        end
        rs.database = rs.database or {}
        local before = rs.database.all_rw
        rs.database.all_rw = edit.all_rw
        table.insert(ops, {
            op = before == nil and 'add' or 'change',
            path = path .. '/database/all_rw',
            before = before, after = edit.all_rw,
        })
    end

    -- join_instances: { alias -> instance-spec } — atomically adds
    -- new instances to the replicaset. Use this for createReplicaset
    -- + addInstance flows.
    if edit.join_instances ~= nil then
        if type(edit.join_instances) ~= 'table' then
            return { path = path .. '/instances',
                message = 'join_instances must be a table { alias = spec }' }
        end
        rs.instances = rs.instances or {}
        for alias, spec in pairs(edit.join_instances) do
            if type(alias) ~= 'string' or alias == '' then
                return { path = path .. '/instances',
                    message = 'join_instances keys must be non-empty aliases' }
            end
            if type(spec) ~= 'table' then
                return { path = path .. '/instances/' .. alias,
                    message = 'instance spec must be a table' }
            end
            if rs.instances[alias] ~= nil then
                return { path = path .. '/instances/' .. alias,
                    message = 'alias already present in the replicaset' }
            end
            rs.instances[alias] = spec
            table.insert(ops, {
                op = 'add',
                path = path .. '/instances/' .. alias,
                after = spec,
            })
        end
    end

    -- expel_instances: list of aliases to remove from this rs.
    if edit.expel_instances ~= nil then
        if type(edit.expel_instances) ~= 'table' then
            return { path = path .. '/instances',
                message = 'expel_instances must be a list of aliases' }
        end
        rs.instances = rs.instances or {}
        for _, alias in ipairs(edit.expel_instances) do
            if type(alias) ~= 'string' or alias == '' then
                return { path = path .. '/instances',
                    message = 'expel_instances entries must be strings' }
            end
            local before = rs.instances[alias]
            if before == nil then
                return { path = path .. '/instances/' .. alias,
                    message = 'alias not present in the replicaset' }
            end
            rs.instances[alias] = nil
            -- Also drop from failover_priority list if present so we
            -- never leave a dangling reference behind.
            if rs.failover_priority ~= nil then
                local filtered = {}
                for _, a in ipairs(rs.failover_priority) do
                    if a ~= alias then table.insert(filtered, a) end
                end
                rs.failover_priority = filtered
            end
            if rs.leader == alias then rs.leader = nil end
            table.insert(ops, {
                op = 'remove',
                path = path .. '/instances/' .. alias,
                before = before,
            })
        end
    end

    return nil
end

-- ── Public surface ─────────────────────────────────────────────────

-- apply(cfg, edits) → (new_cfg, ops, errs)
-- All-or-nothing: returns `(nil, {}, errs)` whenever any edit
-- fails validation. On success returns the new cfg (a fresh copy
-- of the input — the caller's table is never mutated) plus the
-- ordered list of structural ops.
function M.apply(cfg, edits)
    if type(cfg) ~= 'table' then
        return nil, {}, { { path = '/', message = 'cfg must be a table' } }
    end
    if type(edits) ~= 'table' then
        return nil, {}, { { path = '/edits',
            message = 'edits must be a table' } }
    end
    local new_cfg = deep_copy(cfg)
    local ops = {}

    if edits.replicasets ~= nil then
        if type(edits.replicasets) ~= 'table' then
            return nil, {}, { { path = '/replicasets',
                message = 'replicasets must be a list' } }
        end
        for i, edit in ipairs(edits.replicasets) do
            local err = apply_replicaset_edit(new_cfg, edit, ops)
            if err ~= nil then
                err.path = err.path or ('/replicasets/' .. tostring(i))
                return nil, {}, { err }
            end
        end
    end

    if edits.servers ~= nil then
        if type(edits.servers) ~= 'table' then
            return nil, {}, { { path = '/servers',
                message = 'servers must be a list' } }
        end
        for i, edit in ipairs(edits.servers) do
            local err = apply_server_edit(new_cfg, edit, ops)
            if err ~= nil then
                err.path = err.path or ('/servers/' .. tostring(i))
                return nil, {}, { err }
            end
        end
    end

    return new_cfg, ops, {}
end

-- Exported for direct unit-testing of the helpers.
M._find_instance = find_instance
M._find_replicaset = find_replicaset
M._deep_copy = deep_copy

return M
