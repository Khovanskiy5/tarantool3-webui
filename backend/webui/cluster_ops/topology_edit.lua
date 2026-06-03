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

-- Locate the target instance, or create it when the edit carries
-- target_group + target_replicaset. A bare `{alias = ...}` reference
-- without those targets is an error — we cannot guess where to create
-- it. Returns (gname, rsname, inst) on success or (nil, nil, nil, err).
local function locate_or_create_instance(cfg, edit, ops)
    local alias = edit.alias
    local gname, rsname, inst = find_instance(cfg, alias)
    if inst ~= nil then
        return gname, rsname, inst
    end
    if edit.target_group == nil or edit.target_replicaset == nil then
        return nil, nil, nil, {
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
    return gname, rsname, inst
end

-- Each per-field validator below is a no-op when its field is absent,
-- otherwise type-checks the value, mutates `inst` in place, appends the
-- diff op and returns nil (or an {path, message} error). They run in a
-- fixed order from apply_server_edit.

-- database.mode = 'rw' | 'ro' (kept under `database.mode`).
local function validate_mode(inst, edit, path, ops)
    if edit.mode == nil then return nil end
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
    return nil
end

-- iproto.advertise.peer.uri.
local function validate_uri(inst, edit, path, ops)
    if edit.uri == nil then return nil end
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
    return nil
end

-- iproto.listen — array of {uri = ...}. The schema rejects a listen URI
-- that is not under a list; accept either a bare string (we wrap it) or
-- a list of strings.
local function validate_listen(inst, edit, path, ops)
    if edit.listen == nil then return nil end
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
    return nil
end

-- zone (logical placement; consumed by failover scoring).
local function validate_zone(inst, edit, path, ops)
    if edit.zone == nil then return nil end
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
    return nil
end

-- labels (key/value map for routing / discovery).
local function validate_labels(inst, edit, path, ops)
    if edit.labels == nil then return nil end
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
    return nil
end

-- Apply a single server-edit. Mutates `cfg` in place, appends to
-- `ops`, returns `err` (a {path, message} table) on validation
-- failure or nil on success. Fields are validated in a fixed order;
-- the first error short-circuits the `or` chain.
local function apply_server_edit(cfg, edit, ops)
    if type(edit) ~= 'table' or type(edit.alias) ~= 'string'
        or edit.alias == '' then
        return { path = '/servers', message = 'server.alias is required' }
    end

    local gname, rsname, inst, locate_err = locate_or_create_instance(cfg, edit, ops)
    if locate_err ~= nil then return locate_err end

    local path = string.format('/groups/%s/replicasets/%s/instances/%s',
        gname, rsname, edit.alias)

    return validate_mode(inst, edit, path, ops)
        or validate_uri(inst, edit, path, ops)
        or validate_listen(inst, edit, path, ops)
        or validate_zone(inst, edit, path, ops)
        or validate_labels(inst, edit, path, ops)
end

-- ── Replicaset edits ────────────────────────────────────────────────

-- Locate the target replicaset, or create it when the edit carries a
-- `group` hint. Returns (gname, rs) on success or (nil, nil, err).
local function locate_or_create_replicaset(cfg, edit, ops)
    local rs_name = edit.name
    local group_hint = edit.group
    local gname, _, rs = find_replicaset(cfg, rs_name, group_hint)
    if rs ~= nil then return gname, rs end
    if group_hint == nil then
        return nil, nil, {
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
    return gname, rs
end

-- Per-field replicaset validators. Same contract as the server-side
-- ones: no-op when absent, else type-check + mutate `rs` + append op +
-- return nil/err. Order matters — join_instances runs before
-- expel_instances so an expel of a just-joined alias resolves.

-- roles: list of role identifiers applied to every instance. Schema
-- validation is the caller's job; here we only type-check + write.
local function validate_roles(rs, edit, path, ops)
    if edit.roles == nil then return nil end
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
    return nil
end

-- leader: alias inside this replicaset (empty string clears it).
local function validate_leader(rs, edit, path, ops)
    if edit.leader == nil then return nil end
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
    return nil
end

-- failover_priority: ordered list of aliases inside this rs.
local function validate_failover_priority(rs, edit, path, ops)
    if edit.failover_priority == nil then return nil end
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
    return nil
end

-- weight (vshard bucket placement weight).
local function validate_weight(rs, edit, path, ops)
    if edit.weight == nil then return nil end
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
    return nil
end

local function validate_vshard_group(rs, edit, path, ops)
    if edit.vshard_group == nil then return nil end
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
    return nil
end

local function validate_all_rw(rs, edit, path, ops)
    if edit.all_rw == nil then return nil end
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
    return nil
end

-- join_instances: { alias -> instance-spec } — atomically adds new
-- instances to the replicaset (createReplicaset + addInstance flows).
local function validate_join_instances(rs, edit, path, ops)
    if edit.join_instances == nil then return nil end
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
    return nil
end

-- expel_instances: list of aliases to remove from this rs. Also drops
-- each alias from failover_priority and clears leader if it pointed at
-- one, so we never leave a dangling reference behind.
local function validate_expel_instances(rs, edit, path, ops)
    if edit.expel_instances == nil then return nil end
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
    return nil
end

-- Apply a single replicaset-edit. Mutates `cfg` in place, appends to
-- `ops`, returns `err` on validation failure or nil on success.
local function apply_replicaset_edit(cfg, edit, ops)
    if type(edit) ~= 'table' or type(edit.name) ~= 'string'
        or edit.name == '' then
        return { path = '/replicasets',
            message = 'replicaset.name is required' }
    end

    local gname, rs, locate_err = locate_or_create_replicaset(cfg, edit, ops)
    if locate_err ~= nil then return locate_err end

    local path = string.format('/groups/%s/replicasets/%s', gname, edit.name)

    return validate_roles(rs, edit, path, ops)
        or validate_leader(rs, edit, path, ops)
        or validate_failover_priority(rs, edit, path, ops)
        or validate_weight(rs, edit, path, ops)
        or validate_vshard_group(rs, edit, path, ops)
        or validate_all_rw(rs, edit, path, ops)
        or validate_join_instances(rs, edit, path, ops)
        or validate_expel_instances(rs, edit, path, ops)
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
