--
-- Tarantool log tail.
--
-- GET /api/logs?tail=N&level=L&search=S → reads the configured log
-- file (`box.cfg.log` when it is a `file:` URI) and returns the
-- last `tail` lines (capped to 5000). Optional severity filter
-- keeps only lines at-or-above the named level (E/W/I/D), and an
-- optional `search` substring narrows the result for grep-like
-- usage.
--
-- The handler does NOT stream — for live tail the SPA polls with
-- a short interval. This keeps the contract simple and avoids
-- holding the HTTP fiber open against a file the kernel may
-- truncate / rotate underneath us.
--

local fio  = require('fio')
local json = require('json')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('api.logs')

local M = {}

-- Map Tarantool's single-letter level codes to a numeric rank
-- so the `level` filter understands "warn or worse".
local LEVEL_RANK = {
    F = 1, -- fatal
    S = 2, -- system
    E = 3, -- error
    C = 3, -- crit  (alias of error)
    W = 4, -- warn
    I = 5, -- info
    V = 6, -- verbose
    D = 7, -- debug
}

-- Resolve the log file path. Tarantool accepts:
--   `file:/abs/path`, `file:rel/path`, or just `/abs/path` /
--   `rel/path` when `log.to: file`.
-- Returns absolute path or nil if logs go to stderr / pipe / syslog.
local function resolve_log_path()
    if rawget(_G, 'box') == nil or type(box.cfg) ~= 'table' then
        return nil
    end
    local raw = box.cfg.log
    if type(raw) ~= 'string' or raw == '' then return nil end
    -- A `|`-prefix means piped to a shell command — no file.
    if raw:sub(1, 1) == '|' then return nil end
    -- A `syslog:` prefix means rsyslog — no file we can tail.
    if raw:lower():sub(1, 7) == 'syslog:' then return nil end
    local path = raw
    if raw:lower():sub(1, 5) == 'file:' then path = raw:sub(6) end
    -- Resolve relative-to-work_dir the same way Tarantool does
    -- internally for log I/O; otherwise our `fio.open` looks in
    -- the process CWD which is unrelated to the data dir.
    if path:sub(1, 1) ~= '/' then
        local wd = box.cfg.work_dir or '.'
        local sep = (wd:sub(-1) == '/') and '' or '/'
        path = wd .. sep .. path
    end
    return path
end

-- Tail a file by reading the last `chunk` bytes and trimming back
-- to whole lines. Caps `chunk` at 4 MiB to keep the response
-- snappy on huge logs.
local function tail_lines(path, max_lines)
    max_lines = tonumber(max_lines) or 200
    if max_lines > 5000 then max_lines = 5000 end
    if max_lines < 1   then max_lines = 1   end

    local st = fio.stat(path)
    if st == nil then return nil, 'stat failed: ' .. path end
    local file_size = st.size or 0
    -- Read up to 4 MiB from the end of the file; that's enough for
    -- ~50000 typical Tarantool log lines.
    local chunk = math.min(file_size, 4 * 1024 * 1024)

    local fh = fio.open(path, { 'O_RDONLY' })
    if fh == nil then return nil, 'open failed: ' .. path end
    if file_size > chunk then
        local seek_ok = fh:seek(file_size - chunk, 'SEEK_SET')
        if seek_ok == nil then
            pcall(function() fh:close() end)
            return nil, 'seek failed: ' .. path
        end
    end
    local data = fh:read(chunk) or ''
    pcall(function() fh:close() end)

    -- Drop the first (possibly partial) line when we did not
    -- read from byte 0.
    if file_size > chunk then
        local nl = data:find('\n', 1, true)
        if nl ~= nil then data = data:sub(nl + 1) end
    end

    -- Split into lines, drop the trailing empty fragment so a
    -- file ending with `\n` does not surface an empty entry.
    local lines = {}
    local pos = 1
    while pos <= #data do
        local nl = data:find('\n', pos, true)
        if nl == nil then
            table.insert(lines, data:sub(pos))
            break
        end
        table.insert(lines, data:sub(pos, nl - 1))
        pos = nl + 1
    end
    if #lines > 0 and lines[#lines] == '' then
        table.remove(lines)
    end

    -- Trim to the requested tail count.
    if #lines > max_lines then
        local drop = #lines - max_lines
        local tail = {}
        for i = drop + 1, #lines do
            table.insert(tail, lines[i])
        end
        lines = tail
    end
    return lines, nil, file_size
end

-- Extract the severity letter from a Tarantool log line. Format
-- is `2026-06-01 09:30:00.000 [pid] main/... LEVEL> message`,
-- where LEVEL is a single uppercase letter. Returns 'I' (info)
-- when the parse fails so the line is not silently dropped by
-- the level filter.
local function level_of(line)
    local letter = line:match('%s+([FSECWIVD])>%s')
    return letter or 'I'
end

local function passes_level(line, min_level)
    if min_level == nil or min_level == '' then return true end
    local letter = level_of(line)
    local rank = LEVEL_RANK[letter]
    local min_rank = LEVEL_RANK[min_level]
    if rank == nil or min_rank == nil then return true end
    return rank <= min_rank
end

local function passes_search(line, needle)
    if needle == nil or needle == '' then return true end
    return line:lower():find(needle:lower(), 1, true) ~= nil
end

-- Handler: GET /api/logs?tail=200&level=W&search=foo
function M.handler_tail(req)
    local request_id = req.request_id or 'req:logs'
    local path = resolve_log_path()
    if path == nil then
        return {
            status = 503,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'NOT_CONFIGURED',
                message = 'Tarantool log is not a file (configure '
                    .. '`log.to: file` in cluster YAML to enable tail).',
                request_id = request_id,
            } }),
        }
    end

    local q = (type(req.query) == 'table' and req.query) or {}
    local tail_n = tonumber(q.tail) or 200
    local level  = q.level
    local needle = q.search

    local raw, err, file_size = tail_lines(path, tail_n)
    if raw == nil then
        return {
            status = 500,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'TAIL_FAILED',
                message = tostring(err),
                request_id = request_id,
            } }),
        }
    end

    local out = {}
    for _, ln in ipairs(raw) do
        if passes_level(ln, level) and passes_search(ln, needle) then
            table.insert(out, { text = ln, level = level_of(ln) })
        end
    end

    logger.info('logs.tail', {
        path = path, returned = #out, scanned = #raw,
        level = level, search = needle,
        request_id = request_id,
    })
    return {
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({
            ok = true,
            instance = (rawget(_G, 'box') and box.info and box.info.name) or nil,
            path = path,
            file_size = file_size,
            lines = out,
        }),
    }
end

return M
