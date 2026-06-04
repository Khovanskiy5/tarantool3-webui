--
-- Formatting-preserving edits for the cluster config YAML.
--
-- The cluster config lives in etcd as a single YAML document that
-- operators hand-write and comment heavily. Any edit that goes through
-- `yaml.decode -> mutate -> yaml.encode` round-trips the document and
-- silently strips every comment, the original key order and the
-- indentation style: the operator's config comes back mangled, and the
-- config editor (which renders the etcd value verbatim) shows the
-- mangled text from then on.
--
-- This module patches the RAW text instead, so untouched lines stay
-- byte-for-byte identical. It handles SCALAR leaf edits only -- set a
-- single value at a known key path, or replace a verbatim value. It
-- deliberately does NOT model structural edits (adding or removing
-- instances / replicasets): a text merge of arbitrary subtrees is not
-- worth the risk, so those callers still re-encode.
--

local yaml = require('yaml')

local M = {}

-- Indentation step for inserted keys. Matches the config editor
-- (tabSize 2, spaces) and every checked-in cluster config.
local INDENT_STEP = 2

-- Number of leading spaces on a line (YAML forbids tabs for indent).
local function leading_spaces(line)
    local n = 0
    for i = 1, #line do
        if line:sub(i, i) == ' ' then n = n + 1 else break end
    end
    return n
end

-- A line carries structure (a mapping key or list item) when it is
-- neither blank nor a pure comment. Blank / comment lines never end a
-- block and never count as a key.
local function is_structural(line)
    local trimmed = line:gsub('^%s+', '')
    if trimmed == '' then return false end
    if trimmed:sub(1, 1) == '#' then return false end
    return true
end

-- Escape a literal string for use inside a Lua pattern.
local function pat_escape(s)
    return (s:gsub('%W', '%%%0'))
end

-- Split into an array of lines WITHOUT the newline, remembering whether
-- the source ended with a trailing newline so join() round-trips the
-- exact byte length.
local function split_lines(s)
    local lines = {}
    for line in (s .. '\n'):gmatch('(.-)\n') do
        table.insert(lines, line)
    end
    local trailing_nl = false
    if #lines > 0 and lines[#lines] == '' and s:sub(-1) == '\n' then
        trailing_nl = true
        table.remove(lines)
    end
    return lines, trailing_nl
end

local function join_lines(lines, trailing_nl)
    local body = table.concat(lines, '\n')
    if trailing_nl then body = body .. '\n' end
    return body
end

-- Within the block [lo, hi) whose parent sits at `parent_indent`, find
-- the direct-child mapping key `key`. Direct children all share the
-- minimal indentation present in the block. -> { idx, indent } | nil.
local function find_direct_child(lines, key, lo, hi, parent_indent)
    local child_indent = nil
    for i = lo, hi - 1 do
        if is_structural(lines[i]) then
            child_indent = leading_spaces(lines[i])
            break
        end
    end
    if child_indent == nil or child_indent <= parent_indent then
        return nil
    end
    local kpat = '^' .. pat_escape(key) .. ':'
    for i = lo, hi - 1 do
        local line = lines[i]
        if is_structural(line) and leading_spaces(line) == child_indent then
            if line:sub(child_indent + 1):match(kpat) then
                return { idx = i, indent = child_indent }
            end
        end
    end
    return nil
end

-- The block owned by a key at `start - 1` (indent `key_indent`) spans
-- the lines from `start` until a sibling MAPPING key dedents to
-- <= key_indent. A block sequence may sit at the key's own indent
-- (`roles:` / `listen:` followed by `- item` at the same column), so a
-- `- ...` line at <= key_indent is still the key's value, not a dedent.
-- -> exclusive end index within [start, hi).
local function block_end(lines, start, key_indent, hi)
    for i = start, hi - 1 do
        local line = lines[i]
        if is_structural(line) and leading_spaces(line) <= key_indent then
            local trimmed = line:gsub('^%s+', '')
            if trimmed ~= '-' and trimmed:sub(1, 2) ~= '- ' then
                return i
            end
        end
    end
    return hi
end

-- set_field(raw, path, value) -> (new_raw, status) | (nil, err)
--   path:  array of mapping keys from the document root to the scalar
--          leaf, e.g. { 'groups', 'default', 'replicasets', 'rs-1',
--          'instances', 'tt-1', 'database', 'instance_uuid' }.
--   value: the scalar to set, stringified by the caller. UUIDs and
--          plain enums need no quoting; this module does not quote.
-- status: 'set'       -- leaf existed, value rewritten
--         'unchanged' -- leaf existed and already equals value
--         'inserted'  -- leaf (and any missing parent keys) created
-- On failure returns (nil, err): the path could not be anchored because
-- not even the root key exists in the document.
function M.set_field(raw, path, value)
    if type(raw) ~= 'string' then return nil, 'raw must be a string' end
    if type(path) ~= 'table' or #path == 0 then
        return nil, 'path must be a non-empty array'
    end
    value = tostring(value)

    local lines, trailing_nl = split_lines(raw)
    local lo, hi = 1, #lines + 1
    local parent_indent = -1
    local matched = 0
    local last_line, last_indent = nil, nil

    for depth = 1, #path do
        local found = find_direct_child(lines, path[depth], lo, hi, parent_indent)
        if found == nil then break end
        matched = depth
        last_line, last_indent = found.idx, found.indent
        parent_indent = found.indent
        lo = found.idx + 1
        hi = block_end(lines, lo, found.indent, hi)
    end

    -- Whole path resolved -> rewrite the scalar in place.
    if matched == #path then
        local key = path[#path]
        local cur = lines[last_line]:match(
            '^%s*' .. pat_escape(key) .. ':%s*(.-)%s*$')
        if cur == value then
            return raw, 'unchanged'
        end
        lines[last_line] = string.rep(' ', last_indent) .. key .. ': ' .. value
        return join_lines(lines, trailing_nl), 'set'
    end

    -- Partial match: keys up to `matched` exist; insert the rest as a
    -- nested block under the deepest matched parent. Refuse when nothing
    -- matched at all -- there is no safe place to anchor the insert.
    if matched == 0 then
        return nil, 'no anchor: root key "' .. tostring(path[1])
            .. '" not found'
    end

    local base_indent = last_indent + INDENT_STEP
    local insert_at = hi -- end of the deepest matched parent's block
    local new_lines = {}
    for j = matched + 1, #path do
        local indent = string.rep(' ',
            base_indent + (j - matched - 1) * INDENT_STEP)
        if j < #path then
            table.insert(new_lines, indent .. path[j] .. ':')
        else
            table.insert(new_lines, indent .. path[j] .. ': ' .. value)
        end
    end

    local out = {}
    for i = 1, insert_at - 1 do table.insert(out, lines[i]) end
    for _, l in ipairs(new_lines) do table.insert(out, l) end
    for i = insert_at, #lines do table.insert(out, lines[i]) end
    return join_lines(out, trailing_nl), 'inserted'
end

-- Replace every verbatim occurrence of `old` with `new`, treating both
-- as plain strings (no Lua-pattern magic). -> (new_raw, count). Used to
-- rewrite a single existing scalar (e.g. an advertise URI) in place.
function M.replace_value(raw, old, new)
    local pat = pat_escape(old)
    local rep = new:gsub('%%', '%%%%')
    return raw:gsub(pat, rep)
end

-- Locate { groups, <g>, replicasets, <rs>, instances, <name> } for the
-- named instance in the parsed tree. Used to build a `set_field` path
-- when the group / replicaset names are not known up front (rebootstrap
-- identity pin). -> path array | nil.
function M.find_instance_path(parsed, name)
    if type(parsed) ~= 'table' then return nil end
    for gname, group in pairs(parsed.groups or {}) do
        local replicasets = (type(group) == 'table') and group.replicasets or {}
        for rsname, rs in pairs(replicasets) do
            local instances = (type(rs) == 'table') and rs.instances or {}
            if type(instances) == 'table' and instances[name] ~= nil then
                return { 'groups', gname, 'replicasets', rsname,
                         'instances', name }
            end
        end
    end
    return nil
end

-- ── render: formatting-preserving merge for structural edits ─────────
--
-- The simple set_field / replace_value helpers above cover single-scalar
-- edits. Structural mutations (add / remove an instance, flip the
-- failover mode across every instance) build a whole NEW parsed tree.
-- `render` walks the OLD raw text against the OLD and NEW trees and
-- rewrites only the parts that actually changed, so comments, key order
-- and indentation on every untouched subtree survive verbatim.
--
-- HARD guarantee: the result is always valid YAML that decodes EXACTLY
-- to `new_parsed`. The merge is verified by decoding the output and
-- deep-comparing it to `new_parsed`; on any mismatch (or any internal
-- error) it falls back to `yaml.encode(new_parsed)` -- valid, but
-- without comments, exactly like the old behaviour. So `render` is never
-- worse than a plain re-encode and usually much better.

local function deep_equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- A Lua table is a YAML sequence when its keys are exactly 1..n.
local function is_array(t)
    if type(t) ~= 'table' then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then return false end
        n = n + 1
    end
    return n > 0 and #t == n
end

local function is_empty_table(t)
    return type(t) == 'table' and next(t) == nil
end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- A scalar is plain-safe (no quotes) only when it is a simple token that
-- YAML cannot reinterpret as a number / bool / null. Anything else gets
-- single-quoted. Over-quoting is harmless -- the decode round-trip still
-- yields the same string, and `render`'s verify step would catch a real
-- mistake anyway.
local function needs_quote(s)
    if s == '' then return true end
    -- A leading indicator char starts a non-plain scalar in YAML.
    if s:sub(1, 1):match('[%s%-%?:,%[%]{}#&%*!|>\'"%%@`]') then return true end
    -- `: ` is the mapping separator and ` #` starts a comment; a trailing
    -- colon or trailing space also break a plain scalar. A bare colon
    -- inside a token (host:port, IPs) is fine, so URIs stay unquoted.
    if s:find(': ', 1, true) or s:find(' #', 1, true)
        or s:sub(-1) == ':' or s:match('%s$') then
        return true
    end
    -- Flow indicators / quotes anywhere force quoting.
    if s:find('[%[%]{},&%*!|>\'"`]') then return true end
    -- Tokens YAML would reinterpret as a non-string type.
    local low = s:lower()
    if low == 'true' or low == 'false' or low == 'null'
        or low == 'yes' or low == 'no' or low == '~' then
        return true
    end
    if tonumber(s) ~= nil then return true end -- keep number-like strings as strings
    return false
end

local function fmt_scalar(v)
    local t = type(v)
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format('%d', v)
        end
        return tostring(v)
    end
    if v == nil then return 'null' end
    local s = tostring(v)
    if needs_quote(s) then
        return "'" .. s:gsub("'", "''") .. "'"
    end
    return s
end

-- Render a value (map / sequence / scalar) as block-style YAML lines,
-- with every element indented `indent` spaces. Used for freshly inserted
-- or re-rendered subtrees. House style: sequence dashes sit at the
-- owning key's indent (`listen:` / `roles:` followed by `- item` on the
-- same column) and a map item folds its first key onto the dash line
-- (`- uri: …`), matching every checked-in cluster config.
local emit_value_lines

-- Emit sequence items with the dash at `indent`.
local function emit_array(arr, indent)
    local out = {}
    local pad = string.rep(' ', indent)
    for _, item in ipairs(arr) do
        if type(item) == 'table' and not is_empty_table(item) then
            -- Render the item one level in, then fold its first line onto
            -- the dash. `- ` occupies INDENT_STEP columns, so the trailing
            -- lines already align under the folded key.
            local sub = emit_value_lines(item, indent + INDENT_STEP)
            sub[1] = pad .. '- ' .. sub[1]:sub(indent + INDENT_STEP + 1)
            for _, l in ipairs(sub) do table.insert(out, l) end
        elseif type(item) == 'table' then
            table.insert(out, pad .. '- {}')
        else
            table.insert(out, pad .. '- ' .. fmt_scalar(item))
        end
    end
    return out
end

emit_value_lines = function(value, indent)
    if is_array(value) then return emit_array(value, indent) end
    local out = {}
    local pad = string.rep(' ', indent)
    if type(value) == 'table' then
        for _, k in ipairs(sorted_keys(value)) do
            local v = value[k]
            if is_array(v) then
                table.insert(out, pad .. tostring(k) .. ':')
                for _, l in ipairs(emit_array(v, indent)) do
                    table.insert(out, l)
                end
            elseif type(v) == 'table' and not is_empty_table(v) then
                table.insert(out, pad .. tostring(k) .. ':')
                for _, l in ipairs(emit_value_lines(v, indent + INDENT_STEP)) do
                    table.insert(out, l)
                end
            elseif type(v) == 'table' then
                table.insert(out, pad .. tostring(k) .. ': {}')
            else
                table.insert(out, pad .. tostring(k) .. ': ' .. fmt_scalar(v))
            end
        end
    else
        table.insert(out, pad .. fmt_scalar(value))
    end
    return out
end

-- The direct-child indentation inside [lo, hi); nil for an empty block.
local function child_indent_of(lines, lo, hi, parent_indent)
    for i = lo, hi - 1 do
        if is_structural(lines[i]) then
            local ind = leading_spaces(lines[i])
            if ind > parent_indent then return ind end
            return nil
        end
    end
    return nil
end

-- Parse the mapping key of a structural line at indentation `indent`.
-- Returns the key, or nil when the line is a sequence item ('- ...').
local function parse_key(line, indent)
    local rest = line:sub(indent + 1)
    if rest == '-' or rest:match('^%-%s') then return nil end
    return rest:match('^([^:%s][^:]*):')
end

-- Emit a re-rendered key (changed value that can't be patched in place).
local function emit_rerender(out, indent, key, value)
    local pad = string.rep(' ', indent)
    if is_empty_table(value) then
        table.insert(out, pad .. key .. ': {}')
    elseif is_array(value) then
        table.insert(out, pad .. key .. ':')
        for _, l in ipairs(emit_array(value, indent)) do
            table.insert(out, l)
        end
    elseif type(value) == 'table' then
        table.insert(out, pad .. key .. ':')
        for _, l in ipairs(emit_value_lines(value, indent + INDENT_STEP)) do
            table.insert(out, l)
        end
    else
        table.insert(out, pad .. key .. ': ' .. fmt_scalar(value))
    end
end

-- Merge a single mapping block [lo, hi) whose keys sit at `indent`.
-- Walks the existing text in order: unchanged keys (and the comments /
-- blank lines around them) are copied verbatim; changed map subtrees are
-- recursed into; changed scalars / lists are rewritten; removed keys are
-- dropped; new keys are appended at the end of the block.
-- Returns the new lines, or nil to signal "cannot patch -- re-render".
local merge_map_block
merge_map_block = function(lines, lo, hi, indent, old_tbl, new_tbl)
    local out = {}
    local handled = {}
    local i = lo
    while i < hi do
        local line = lines[i]
        if not is_structural(line) then
            table.insert(out, line) -- comment / blank: keep verbatim
            i = i + 1
        elseif leading_spaces(line) ~= indent then
            return nil -- unexpected shape (e.g. a sequence here): bail
        else
            local key = parse_key(line, indent)
            if key == nil then return nil end -- sequence block: bail
            local cend = block_end(lines, i + 1, indent, hi)
            handled[key] = true
            local oldv = old_tbl and old_tbl[key]
            local newv = new_tbl and new_tbl[key]
            if newv == nil then
                i = cend -- deleted: drop the key and its block
            elseif deep_equal(oldv, newv) then
                for j = i, cend - 1 do table.insert(out, lines[j]) end
                i = cend
            else
                -- An inline VALUE means `key: <value>` on one line (a
                -- block can't be merged in place). A trailing `# comment`
                -- after a bare `key:` is NOT a value -- the block follows
                -- below, so it stays recursable.
                local after = line:sub(indent + 1):match(
                    '^' .. pat_escape(key) .. ':%s*(.*)$')
                local has_inline = after ~= nil and after ~= ''
                    and after:sub(1, 1) ~= '#'
                local can_recurse =
                    type(newv) == 'table' and not is_array(newv)
                    and not is_empty_table(newv)
                    and type(oldv) == 'table' and not is_array(oldv)
                    and not is_empty_table(oldv)
                    and not has_inline
                local sub = nil
                if can_recurse then
                    local cind = child_indent_of(lines, i + 1, cend, indent)
                    if cind then
                        sub = merge_map_block(lines, i + 1, cend, cind,
                            oldv, newv)
                    end
                end
                if sub ~= nil then
                    table.insert(out, line)
                    for _, l in ipairs(sub) do table.insert(out, l) end
                else
                    emit_rerender(out, indent, key, newv)
                end
                i = cend
            end
        end
    end
    for _, k in ipairs(sorted_keys(new_tbl)) do
        if not handled[k] then
            emit_rerender(out, indent, k, new_tbl[k])
        end
    end
    return out
end

-- render(raw, old_parsed, new_parsed) -> new_raw. Always valid YAML that
-- decodes exactly to new_parsed; preserves formatting where it can.
function M.render(raw, old_parsed, new_parsed)
    if type(new_parsed) ~= 'table' then
        return yaml.encode(new_parsed)
    end
    if type(raw) == 'string' then
        local ok, merged = pcall(function()
            local lines, trailing_nl = split_lines(raw)
            local cind = child_indent_of(lines, 1, #lines + 1, -1) or 0
            local body = merge_map_block(lines, 1, #lines + 1, cind,
                old_parsed or {}, new_parsed)
            if body == nil then return nil end
            return join_lines(body, trailing_nl)
        end)
        if ok and merged ~= nil then
            local ok_d, decoded = pcall(yaml.decode, merged)
            if ok_d and deep_equal(decoded, new_parsed) then
                return merged
            end
        end
    end
    -- Fallback: guaranteed-valid re-encode (drops comments, never breaks).
    return yaml.encode(new_parsed)
end

return M
