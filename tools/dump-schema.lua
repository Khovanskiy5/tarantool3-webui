#!/usr/bin/env tarantool
--
-- Dump the WebUI GraphQL schema as SDL to stdout.
--
--   tarantool tools/dump-schema.lua [<output-file>]
--   make dump-schema
--
-- Without an argument the SDL is written to stdout, suitable for
-- shell redirection. With an argument the SDL is written to the file
-- (parent directories are created as needed).
--
-- The script loads `webui.graphql.schema` directly — it does NOT
-- start the role or open a network socket. This keeps `make gen-types`
-- working in CI without a running Tarantool cluster.
--
-- The printer walks `schema:getTypeMap()` and emits each user-defined
-- type. Built-in scalars (String, Int, Float, Boolean, ID) and the
-- introspection types (__Schema, __Type, …) are skipped because they
-- are part of the GraphQL specification and graphql-codegen knows
-- about them.

local fio = require('fio')

-- Resolve repo-local rocks tree without polluting global package.path
-- when invoked from `make` (which sets a working directory).
local repo_root = fio.abspath(arg[0]:match('(.*/)') or '.') .. '/..'
local rocks_share = repo_root .. '/.rocks/share/tarantool'
local rocks_lib = repo_root .. '/.rocks/lib/tarantool'
package.path = rocks_share .. '/?.lua;' .. rocks_share .. '/?/init.lua;' .. package.path
package.cpath = rocks_lib .. '/?.so;' .. rocks_lib .. '/?.dylib;' .. package.cpath
package.path = repo_root .. '/backend/?.lua;' .. repo_root .. '/backend/?/init.lua;' .. package.path

local ok_mod, schema_builder = pcall(require, 'webui.graphql.schema')
if not ok_mod then
    io.stderr:write('dump-schema: cannot load webui.graphql.schema:\n')
    io.stderr:write(tostring(schema_builder) .. '\n')
    os.exit(1)
end

local schema = schema_builder.build()

-- ── SDL printer ────────────────────────────────────────────────────────

local BUILTIN_SCALARS = {
    String  = true,
    Int     = true,
    Float   = true,
    Boolean = true,
    ID      = true,
}

local function is_builtin(name)
    if name == nil then return true end
    if BUILTIN_SCALARS[name] then return true end
    if string.sub(name, 1, 2) == '__' then return true end
    return false
end

-- Render a type reference (T, T!, [T], [T!]!) recursively.
local function type_ref(t)
    if t == nil then return 'Unknown' end
    if t.__type == 'NonNull' then
        return type_ref(t.ofType) .. '!'
    elseif t.__type == 'List' then
        return '[' .. type_ref(t.ofType) .. ']'
    elseif t.name ~= nil then
        return t.name
    end
    return 'Unknown'
end

local function emit_description(out, description, indent)
    if type(description) ~= 'string' or description == '' then return end
    -- Block string """…""" — works for single- or multi-line input.
    local pad = indent or ''
    out:write(pad .. '"""\n')
    for line in (description .. '\n'):gmatch('([^\n]*)\n') do
        out:write(pad .. line .. '\n')
    end
    out:write(pad .. '"""\n')
end

-- Resolve a fields table: it can be a function in the rock (lazy types
-- for cyclic schemas) or already a table.
local function resolve_fields(fields)
    if type(fields) == 'function' then return fields() end
    return fields
end

local function sorted_keys(tbl)
    local keys = {}
    for k, _ in pairs(tbl) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function emit_arguments(out, args)
    if args == nil then return end
    local arg_list = type(args) == 'function' and args() or args
    if next(arg_list) == nil then return end
    out:write('(')
    local first = true
    for _, name in ipairs(sorted_keys(arg_list)) do
        local arg = arg_list[name]
        if not first then out:write(', ') end
        first = false
        local kind = arg.kind or arg
        out:write(name .. ': ' .. type_ref(kind))
        if arg.defaultValue ~= nil then
            -- We do not attempt to render arbitrary Lua values as
            -- GraphQL literals; if a default appears, emit a comment.
            out:write(' /* default omitted */')
        end
    end
    out:write(')')
end

local function emit_object_or_interface(out, kw, t)
    emit_description(out, t.description)
    out:write(kw .. ' ' .. t.name)
    -- Interface implementations are written as `type X implements I1 & I2`.
    if t.interfaces and #t.interfaces > 0 then
        out:write(' implements ')
        for i, iface in ipairs(t.interfaces) do
            if i > 1 then out:write(' & ') end
            out:write(iface.name)
        end
    end
    out:write(' {\n')
    local fields = resolve_fields(t.fields)
    for _, fname in ipairs(sorted_keys(fields)) do
        local fdef = fields[fname]
        emit_description(out, fdef.description, '  ')
        out:write('  ' .. fname)
        emit_arguments(out, fdef.arguments)
        out:write(': ' .. type_ref(fdef.kind) .. '\n')
    end
    out:write('}\n\n')
end

local function emit_input_object(out, t)
    emit_description(out, t.description)
    out:write('input ' .. t.name .. ' {\n')
    local fields = resolve_fields(t.fields)
    for _, fname in ipairs(sorted_keys(fields)) do
        local fdef = fields[fname]
        emit_description(out, fdef.description, '  ')
        out:write('  ' .. fname .. ': ' .. type_ref(fdef.kind) .. '\n')
    end
    out:write('}\n\n')
end

local function emit_enum(out, t)
    emit_description(out, t.description)
    out:write('enum ' .. t.name .. ' {\n')
    local values = t.values
    if type(values) == 'table' then
        local names = {}
        if values[1] ~= nil then
            -- Array form
            for _, v in ipairs(values) do
                table.insert(names, type(v) == 'table' and v.name or v)
            end
        else
            -- Map form
            for k, _ in pairs(values) do table.insert(names, k) end
        end
        table.sort(names)
        for _, n in ipairs(names) do out:write('  ' .. n .. '\n') end
    end
    out:write('}\n\n')
end

local function emit_union(out, t)
    emit_description(out, t.description)
    out:write('union ' .. t.name .. ' = ')
    local member_names = {}
    for _, m in ipairs(t.types or {}) do
        table.insert(member_names, m.name)
    end
    table.sort(member_names)
    out:write(table.concat(member_names, ' | ') .. '\n\n')
end

local function emit_scalar(out, t)
    emit_description(out, t.description)
    out:write('scalar ' .. t.name .. '\n\n')
end

local function emit_type(out, t)
    if t.__type == 'Object' then
        emit_object_or_interface(out, 'type', t)
    elseif t.__type == 'Interface' then
        emit_object_or_interface(out, 'interface', t)
    elseif t.__type == 'InputObject' then
        emit_input_object(out, t)
    elseif t.__type == 'Enum' then
        emit_enum(out, t)
    elseif t.__type == 'Union' then
        emit_union(out, t)
    elseif t.__type == 'Scalar' then
        emit_scalar(out, t)
    end
end

-- ── Output stream selection ────────────────────────────────────────────

local out
local out_path = arg[1]
if out_path == nil then
    out = io.stdout
else
    out_path = fio.abspath(out_path)
    local dir = fio.dirname(out_path)
    if not fio.path.is_dir(dir) then fio.mktree(dir) end
    local fout, err = io.open(out_path, 'w')
    if fout == nil then
        io.stderr:write('dump-schema: cannot open ' .. out_path .. ': ' .. tostring(err) .. '\n')
        os.exit(2)
    end
    out = fout
end

-- ── Header ─────────────────────────────────────────────────────────────

out:write('# Generated by tools/dump-schema.lua. Do not edit by hand.\n')
out:write('# Source: backend/webui/graphql/schema.lua\n')
out:write('\n')

-- ── Walk type map (skip builtins, deterministic ordering) ─────────────

local type_map = schema:getTypeMap()

-- Categorise so the output is grouped: schema, scalars, enums, unions,
-- interfaces, objects, inputs. Within a category the keys are sorted.
local categories = {
    scalar = {}, enum = {}, union = {}, interface = {},
    object = {}, input = {},
}
local CATEGORY_ORDER = { 'scalar', 'enum', 'interface', 'union', 'object', 'input' }

for name, t in pairs(type_map) do
    if not is_builtin(name) then
        local key = t.__type
        if key == 'Object' then
            table.insert(categories.object, t)
        elseif key == 'Interface' then
            table.insert(categories.interface, t)
        elseif key == 'InputObject' then
            table.insert(categories.input, t)
        elseif key == 'Enum' then
            table.insert(categories.enum, t)
        elseif key == 'Union' then
            table.insert(categories.union, t)
        elseif key == 'Scalar' then
            table.insert(categories.scalar, t)
        end
    end
end

local function by_name(a, b) return a.name < b.name end
for _, group in pairs(categories) do
    table.sort(group, by_name)
end

-- Schema definition block. Root types come from the schema object;
-- we emit them explicitly so the SDL is self-describing.
out:write('schema {\n')
local query_t    = schema:getQueryType()
local mutation_t = schema:getMutationType()
if query_t then    out:write('  query: '    .. query_t.name    .. '\n') end
if mutation_t then out:write('  mutation: ' .. mutation_t.name .. '\n') end
out:write('}\n\n')

for _, cat in ipairs(CATEGORY_ORDER) do
    for _, t in ipairs(categories[cat]) do
        emit_type(out, t)
    end
end

if out ~= io.stdout then
    out:close()
    io.stderr:write(string.format('dump-schema: wrote SDL to %s\n', out_path))
end

os.exit(0)
