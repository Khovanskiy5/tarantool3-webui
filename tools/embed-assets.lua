#!/usr/bin/env tarantool
--
-- Pack the production SPA bundle from frontend/dist/ into a Lua module
-- consumable at runtime by the webui role's static file handler.
--
-- Invocation:
--   tarantool tools/embed-assets.lua [<source-dir>] [<output-file>]
--   make embed-assets
--
-- Defaults:
--   source-dir  = ./frontend/dist
--   output-file = ./backend/webui/assets/bundle.lua
--
-- Output shape:
--   return {
--     ["/index.html"] = {
--       mime     = "text/html; charset=utf-8",
--       etag     = '"3a7bd3...e1d"',           -- strong ETag, SHA-1 of raw
--       size_raw = 2185,
--       size_br  = 766,
--       size_gz  = 851,
--       body_raw = <decoded bytes>,
--       body_br  = <decoded bytes>,
--       body_gz  = <decoded bytes>,
--     },
--     ["/assets/index-XXX.js"] = { ... },
--     ...
--   }
--
-- Bodies are stored as base64 inside long brackets and decoded at module
-- load time. base64 stays within the ASCII alphabet `A-Za-z0-9+/=` so it
-- never collides with the closing `]]` delimiter of Lua long strings.
--
-- The script does NOT re-compress: vite-plugin-compression2 already
-- emits .br and .gz siblings that are bit-identical to what the http
-- static handler will serve. Re-compressing here would double the work
-- and produce slightly different bytes due to different compressor
-- settings, complicating reproducibility.

local fio = require('fio')
local digest = require('digest')

-- ── arguments and paths ────────────────────────────────────────────────

local SOURCE_DIR  = fio.abspath(arg[1] or 'frontend/dist')
local OUTPUT_FILE = fio.abspath(arg[2] or 'backend/webui/assets/bundle.lua')

if not fio.path.is_dir(SOURCE_DIR) then
    io.stderr:write(string.format(
        'embed-assets: source directory not found: %s\n' ..
        '  Build the frontend first: make build-frontend\n',
        SOURCE_DIR))
    os.exit(1)
end

-- ── MIME table ─────────────────────────────────────────────────────────

local MIME = {
    html  = 'text/html; charset=utf-8',
    js    = 'application/javascript; charset=utf-8',
    mjs   = 'application/javascript; charset=utf-8',
    css   = 'text/css; charset=utf-8',
    json  = 'application/json; charset=utf-8',
    map   = 'application/json; charset=utf-8',
    svg   = 'image/svg+xml; charset=utf-8',
    png   = 'image/png',
    jpg   = 'image/jpeg',
    jpeg  = 'image/jpeg',
    gif   = 'image/gif',
    webp  = 'image/webp',
    ico   = 'image/x-icon',
    woff  = 'font/woff',
    woff2 = 'font/woff2',
    ttf   = 'font/ttf',
    otf   = 'font/otf',
    eot   = 'application/vnd.ms-fontobject',
    txt   = 'text/plain; charset=utf-8',
    wasm  = 'application/wasm',
    xml   = 'application/xml; charset=utf-8',
    pdf   = 'application/pdf',
}
local DEFAULT_MIME = 'application/octet-stream'

local function ext_of(path)
    return string.lower(string.match(path, '%.([^./]+)$') or '')
end

local function mime_for(path)
    return MIME[ext_of(path)] or DEFAULT_MIME
end

-- ── directory walk ─────────────────────────────────────────────────────

local function walk(root)
    local results = {}
    local function recurse(dir)
        for _, name in ipairs(fio.listdir(dir)) do
            local full = fio.pathjoin(dir, name)
            local st = fio.stat(full)
            if st ~= nil then
                if st:is_dir() then
                    recurse(full)
                elseif st:is_reg() then
                    local rel = string.sub(full, #root + 2)
                    table.insert(results, { full = full, rel = rel })
                end
            end
        end
    end
    recurse(root)
    return results
end

local function read_file(path)
    local f, err = fio.open(path, { 'O_RDONLY' })
    if f == nil then
        return nil, string.format('cannot open %s: %s', path, tostring(err))
    end
    local data = f:read()
    f:close()
    if data == nil then
        return nil, 'empty file: ' .. path
    end
    return data
end

-- ── entry collection ──────────────────────────────────────────────────

-- Each canonical asset has up to three companions:
--   raw  → the asset itself
--   br   → asset.br (pre-compressed brotli)
--   gz   → asset.gz (pre-compressed gzip)
--
-- entries is keyed by the canonical relative path (with forward slashes)
-- and stores absolute paths to each variant present on disk.
local entries = {}

for _, item in ipairs(walk(SOURCE_DIR)) do
    local rel = string.gsub(item.rel, '\\', '/')
    local key, kind
    if string.sub(rel, -3) == '.br' then
        key = string.sub(rel, 1, -4)
        kind = 'br'
    elseif string.sub(rel, -3) == '.gz' then
        key = string.sub(rel, 1, -4)
        kind = 'gz'
    else
        key = rel
        kind = 'raw'
    end
    entries[key] = entries[key] or {}
    entries[key][kind] = item.full
end

-- Stable iteration order so the generated bundle is reproducible.
local ordered_keys = {}
for k, _ in pairs(entries) do
    table.insert(ordered_keys, k)
end
table.sort(ordered_keys)

-- ── render bundle.lua ─────────────────────────────────────────────────

local function b64(bytes)
    return digest.base64_encode(bytes, { nowrap = true })
end

local lines = {
    '-- Generated by tools/embed-assets.lua. DO NOT EDIT.',
    '-- Source: ' .. SOURCE_DIR,
    '--',
    '-- This module is rebuilt on every `make embed-assets` invocation.',
    '-- The webui http.static handler imports it at role start time and',
    '-- holds the decoded bodies in process memory for the lifetime of',
    '-- the instance.',
    '',
    'local base64_decode = require("digest").base64_decode',
    '',
    'local function decode(b)',
    '    return base64_decode(b)',
    'end',
    '',
    'return {',
}

local function add_field(name, value, has_more)
    table.insert(lines, string.format(
        '        %s = %s%s',
        name, value, has_more and ',' or ''
    ))
end

local function add_entry(route, entry, mime, etag, raw_b, br_b, gz_b)
    table.insert(lines, string.format('    [%q] = {', route))
    table.insert(lines, string.format('        mime     = %q,', mime))
    table.insert(lines, string.format('        etag     = %q,', etag))
    table.insert(lines, string.format('        size_raw = %d,', #raw_b))
    if br_b ~= nil then
        table.insert(lines, string.format('        size_br  = %d,', #br_b))
    end
    if gz_b ~= nil then
        table.insert(lines, string.format('        size_gz  = %d,', #gz_b))
    end
    table.insert(lines, string.format(
        '        body_raw = decode([[%s]]),', b64(raw_b)
    ))
    if br_b ~= nil then
        table.insert(lines, string.format(
            '        body_br  = decode([[%s]]),', b64(br_b)
        ))
    end
    if gz_b ~= nil then
        table.insert(lines, string.format(
            '        body_gz  = decode([[%s]]),', b64(gz_b)
        ))
    end
    table.insert(lines, '    },')
    -- Suppress unused locals warning from older Lua linters.
    local _ = entry
    local _, _ = add_field, _
end

-- Summary accumulators for the final report.
local count = 0
local total_raw = 0
local total_br = 0
local total_gz = 0
local skipped_no_raw = 0
local report_rows = {}

for _, key in ipairs(ordered_keys) do
    local paths = entries[key]
    if paths.raw == nil then
        -- Orphan .br or .gz without a sibling raw file. Vite always
        -- emits the raw alongside compressed variants, so this is
        -- usually a build cleanup glitch worth surfacing.
        skipped_no_raw = skipped_no_raw + 1
        io.stderr:write(string.format(
            'embed-assets: WARN no raw for %s (br=%s gz=%s); skipping\n',
            key, tostring(paths.br ~= nil), tostring(paths.gz ~= nil)
        ))
    else
        local raw, raw_err = read_file(paths.raw)
        if raw == nil then
            io.stderr:write(string.format(
                'embed-assets: ERROR %s\n', raw_err))
            os.exit(2)
        end
        local br = nil
        if paths.br then
            local body, err = read_file(paths.br)
            if body == nil then
                io.stderr:write(string.format(
                    'embed-assets: ERROR %s\n', err))
                os.exit(2)
            end
            br = body
        end
        local gz = nil
        if paths.gz then
            local body, err = read_file(paths.gz)
            if body == nil then
                io.stderr:write(string.format(
                    'embed-assets: ERROR %s\n', err))
                os.exit(2)
            end
            gz = body
        end

        local route = '/' .. key
        local mime = mime_for(key)
        local etag = '"' .. digest.sha1_hex(raw) .. '"'

        add_entry(route, key, mime, etag, raw, br, gz)
        count = count + 1
        total_raw = total_raw + #raw
        if br then total_br = total_br + #br end
        if gz then total_gz = total_gz + #gz end

        table.insert(report_rows, {
            route = route,
            mime = mime,
            raw = #raw,
            br = br and #br or 0,
            gz = gz and #gz or 0,
        })
    end
end

table.insert(lines, '}')
table.insert(lines, '')

-- ── write output ──────────────────────────────────────────────────────

local out_dir = fio.dirname(OUTPUT_FILE)
if not fio.path.is_dir(out_dir) then
    fio.mktree(out_dir)
end

local out_f = fio.open(OUTPUT_FILE, { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' }, tonumber('644', 8))
if out_f == nil then
    io.stderr:write('embed-assets: cannot open output ' .. OUTPUT_FILE .. '\n')
    os.exit(2)
end
out_f:write(table.concat(lines, '\n'))
out_f:close()

-- ── reporting ────────────────────────────────────────────────────────

local function human(bytes)
    if bytes < 1024 then
        return string.format('%d B', bytes)
    elseif bytes < 1024 * 1024 then
        return string.format('%.1f KiB', bytes / 1024)
    else
        return string.format('%.2f MiB', bytes / 1048576)
    end
end

io.stdout:write(string.format(
    'embed-assets: bundled %d asset(s) from %s\n', count, SOURCE_DIR
))

-- Pretty per-asset report. Stable, sorted by route.
io.stdout:write(string.format(
    '%-60s %-44s %10s %10s %10s\n',
    'route', 'mime', 'raw', 'br', 'gz'
))
io.stdout:write(string.rep('-', 138) .. '\n')
for _, r in ipairs(report_rows) do
    local route_display = r.route
    if #route_display > 58 then
        route_display = '…' .. string.sub(route_display, -57)
    end
    io.stdout:write(string.format(
        '%-60s %-44s %10s %10s %10s\n',
        route_display,
        r.mime:sub(1, 44),
        human(r.raw),
        r.br > 0 and human(r.br) or '—',
        r.gz > 0 and human(r.gz) or '—'
    ))
end
io.stdout:write(string.rep('-', 138) .. '\n')
io.stdout:write(string.format(
    '%-60s %-44s %10s %10s %10s\n',
    'TOTAL', '', human(total_raw), human(total_br), human(total_gz)
))
local out_size = 0
local out_stat = fio.stat(OUTPUT_FILE)
if out_stat ~= nil then
    out_size = out_stat.size or 0
end
io.stdout:write(string.format(
    '\noutput:        %s (%s on disk)\n',
    OUTPUT_FILE, human(out_size)
))
if skipped_no_raw > 0 then
    io.stdout:write(string.format(
        'skipped:       %d orphan compressed file(s) without raw sibling\n',
        skipped_no_raw))
end
io.stdout:write('\n')

os.exit(0)
