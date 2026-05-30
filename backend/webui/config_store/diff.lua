--
-- Structural and textual diff for cluster-config YAML.
--
-- Used by the config editor's preview step (Task 34) and by the
-- history rollback dialog (Task 35). The structural diff is
-- shallow-recursive: a value moves into `changed` when the leaf
-- type is the same and `from ~= to`, into `added` / `removed` when
-- only one side has the key.
--

local M = {}

local function is_leaf(v)
    local k = type(v)
    return k == 'string' or k == 'number' or k == 'boolean'
        or v == nil or v == box.NULL
end

local function path_join(prefix, key)
    if prefix == nil or prefix == '' then return '/' .. tostring(key) end
    return prefix .. '/' .. tostring(key)
end

-- Pure recursion: walks `from` and `to` in parallel and produces
-- a flat list of operations.
function M.structural(from, to, prefix)
    prefix = prefix or ''
    local ops = {}
    if type(from) ~= 'table' or type(to) ~= 'table' then
        if from ~= to then
            table.insert(ops, { op = 'changed', path = prefix == '' and '/' or prefix,
                from = from, to = to })
        end
        return ops
    end
    -- removed + changed
    for k, v in pairs(from) do
        local p = path_join(prefix, k)
        if to[k] == nil then
            table.insert(ops, { op = 'removed', path = p, from = v })
        elseif is_leaf(v) and is_leaf(to[k]) then
            if v ~= to[k] then
                table.insert(ops, { op = 'changed', path = p, from = v, to = to[k] })
            end
        else
            local nested = M.structural(v, to[k], p)
            for _, e in ipairs(nested) do table.insert(ops, e) end
        end
    end
    -- added
    for k, v in pairs(to) do
        if from[k] == nil then
            table.insert(ops, { op = 'added', path = path_join(prefix, k), to = v })
        end
    end
    return ops
end

-- Best-effort unified-diff over the text form; no `diff` rock so
-- we keep it simple: line-by-line, marker '+'/'-'/' '.
function M.unified_lines(from_text, to_text)
    local from_lines, to_lines = {}, {}
    for line in (from_text or ''):gmatch('([^\n]*)\n?') do table.insert(from_lines, line) end
    for line in (to_text or ''):gmatch('([^\n]*)\n?') do table.insert(to_lines, line) end
    local out, n = {}, math.max(#from_lines, #to_lines)
    for i = 1, n do
        local a, b = from_lines[i], to_lines[i]
        if a == b then
            if a and a ~= '' then table.insert(out, ' ' .. a) end
        else
            if a then table.insert(out, '-' .. a) end
            if b then table.insert(out, '+' .. b) end
        end
    end
    return out
end

function M.categorise(ops)
    local cats = {
        replicaset = {}, instance = {}, roles = {}, credentials = {},
        failover = {}, sharding = {}, labels = {}, zones = {}, other = {},
    }
    for _, op in ipairs(ops or {}) do
        local p = op.path or ''
        -- Order matters — more specific paths win. An instance edit
        -- lives under `/groups/.../replicasets/.../instances/...`, so
        -- we test for `instances` before `replicaset`.
        if p:find('credentials', 1, true) then table.insert(cats.credentials, op)
        elseif p:find('failover',  1, true) then table.insert(cats.failover, op)
        elseif p:find('sharding',  1, true) then table.insert(cats.sharding, op)
        elseif p:find('labels',    1, true) then table.insert(cats.labels, op)
        elseif p:find('zones',     1, true) then table.insert(cats.zones, op)
        elseif p:find('instances', 1, true) then table.insert(cats.instance, op)
        elseif p:find('replicaset',1, true) then table.insert(cats.replicaset, op)
        elseif p:find('roles',     1, true) then table.insert(cats.roles, op)
        else table.insert(cats.other, op) end
    end
    return cats
end

return M
