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
-- Returns absolute path or nil if logs go to stderr / syslog / a
-- pipe that does not tee to a file.
local function resolve_log_path()
    if rawget(_G, 'box') == nil or type(box.cfg) ~= 'table' then
        return nil
    end
    local raw = box.cfg.log
    if type(raw) ~= 'string' or raw == '' then return nil end
    local path
    -- Piped logging (`log.to: pipe`). Tarantool exposes the command
    -- as `| <cmd>` (legacy box.cfg) or `pipe:<cmd>` (3.x declarative
    -- config). We still tail a file when the pipe tees to one — the
    -- container setup pipes to `tee <file>` so `docker logs` and this
    -- in-UI viewer both see the stream. Recover the file as the `tee`
    -- target, i.e. the last token of the command. A pipe without
    -- `tee` has no file we can read.
    local pipe_cmd
    if raw:sub(1, 1) == '|' then
        pipe_cmd = raw:sub(2)
    elseif raw:lower():sub(1, 5) == 'pipe:' then
        pipe_cmd = raw:sub(6)
    end
    if pipe_cmd ~= nil then
        if pipe_cmd:find('%f[%w]tee%f[%W]') == nil then return nil end
        path = pipe_cmd:match('(%S+)%s*$')
        if path == nil then return nil end
    elseif raw:lower():sub(1, 7) == 'syslog:' then
        -- A `syslog:` prefix means rsyslog — no file we can tail.
        return nil
    else
        path = raw
        if raw:lower():sub(1, 5) == 'file:' then path = raw:sub(6) end
    end
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

-- Map Tarantool's JSON `level` word (`log.format: json`) to the
-- single-letter code the rest of the filter speaks.
local LEVEL_WORD = {
    FATAL   = 'F',
    SYSERROR = 'S',
    SYSTEM  = 'S',
    ERROR   = 'E',
    CRIT    = 'C',
    WARN    = 'W',
    INFO    = 'I',
    VERBOSE = 'V',
    DEBUG   = 'D',
}

-- Extract the severity letter from a Tarantool log line. Two
-- formats are supported:
--   * plain — `2026-06-01 09:30:00.000 [pid] main/... LEVEL> msg`,
--     where LEVEL is a single uppercase letter.
--   * json  — `{"time":...,"level":"INFO",...}` (log.format: json).
-- Returns 'I' (info) when the parse fails so the line is not
-- silently dropped by the level filter.
local function level_of(line)
    if line:sub(1, 1) == '{' then
        local ok, obj = pcall(json.decode, line)
        if ok and type(obj) == 'table' and type(obj.level) == 'string' then
            return LEVEL_WORD[obj.level:upper()] or 'I'
        end
        return 'I'
    end
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

-- Local tail core. Returns a plain table that the HTTP handler
-- wraps into a JSON response and that `webui_logs_tail_remote`
-- forwards verbatim to the calling peer. Splitting this out lets
-- the page query *any* instance's log via the peer pool without
-- duplicating the level / search filtering loop.
--
-- Returns one of:
--   { ok = true, instance, path, file_size, lines = {…} }
--   { ok = false, code = 'NOT_CONFIGURED' | 'TAIL_FAILED', message }
function M.tail(query)
    local path = resolve_log_path()
    if path == nil then
        return {
            ok = false, code = 'NOT_CONFIGURED',
            message = 'Tarantool log is not readable as a file '
                .. '(set `log.to: file`, or pipe to `tee <file>`, '
                .. 'in cluster YAML to enable tail).',
        }
    end

    local q = (type(query) == 'table' and query) or {}
    local tail_n = tonumber(q.tail) or 200
    local level  = q.level
    local needle = q.search

    local raw, err, file_size = tail_lines(path, tail_n)
    if raw == nil then
        return { ok = false, code = 'TAIL_FAILED', message = tostring(err) }
    end

    local out = {}
    for _, ln in ipairs(raw) do
        if passes_level(ln, level) and passes_search(ln, needle) then
            table.insert(out, { text = ln, level = level_of(ln) })
        end
    end

    return {
        ok = true,
        instance = (rawget(_G, 'box') and box.info and box.info.name) or nil,
        path = path,
        file_size = file_size,
        lines = out,
    }
end

-- Forward a tail request to a peer instance. Returns the same
-- table shape as `M.tail` so callers handle both paths uniformly.
-- A nil / unreachable peer surfaces as `code = 'PEER_UNREACHABLE'`.
local function tail_remote(alias, query)
    local ok_peers, peers = pcall(require, 'webui.cluster.peers')
    if not ok_peers then
        return { ok = false, code = 'PEER_UNREACHABLE',
                 message = 'peer pool unavailable' }
    end
    local peer = peers.get(alias)
    if peer == nil or peer.conn == nil then
        return { ok = false, code = 'PEER_UNREACHABLE',
                 message = 'no connection to ' .. alias }
    end
    local call_ok, res = pcall(function()
        return peer.conn:call('webui_logs_tail_remote', { query },
            { timeout = 5 })
    end)
    if not call_ok then
        return { ok = false, code = 'PEER_UNREACHABLE',
                 message = 'net.box call failed: ' .. tostring(res) }
    end
    if type(res) ~= 'table' then
        return { ok = false, code = 'PEER_UNREACHABLE',
                 message = 'peer returned non-table response' }
    end
    return res
end

-- Map an `M.tail` result table to an HTTP response.
local function reply(result, request_id)
    if not result.ok then
        local status = result.code == 'NOT_CONFIGURED' and 503
            or result.code == 'PEER_UNREACHABLE' and 502
            or 500
        return {
            status = status,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = result.code or 'UNKNOWN',
                message = result.message,
                request_id = request_id,
            } }),
        }
    end
    return {
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({
            ok = true,
            instance = result.instance,
            path = result.path,
            file_size = result.file_size,
            lines = result.lines,
        }),
    }
end

-- Read a query-string parameter regardless of which http rock
-- API the request exposes. Tarantool's bundled http rock provides
-- `req:query_param(name)`; older / lower-level setups give a
-- string (`req.query`) or rarely a pre-parsed table. Logs page
-- used to read `req.query` as a table and silently got nil
-- everywhere → search / tail / level filters were ignored.
local function get_param(req, name)
    if type(req.query_param) == 'function' then
        local ok, v = pcall(req.query_param, req, name)
        if ok and v ~= nil then return v end
    end
    if type(req.query) == 'string' then
        -- Anchor with `?` or `&` so name 'tail' doesn't match
        -- inside 'detail=…'. URL-decode the match before returning
        -- so spaces / non-ASCII in `search` survive transport.
        local pat = '[?&]' .. name .. '=([^&]*)'
        local m = ('?' .. req.query):match(pat)
        if m == nil then return nil end
        local ok_uri, uri = pcall(require, 'uri')
        if ok_uri and uri.unescape then
            local ok_dec, dec = pcall(uri.unescape, m)
            if ok_dec then return dec end
        end
        return m
    end
    if type(req.query) == 'table' then return req.query[name] end
    return nil
end

-- Handler: GET /api/logs?tail=200&level=W&search=foo&instance=tt-2
function M.handler_tail(req)
    local request_id = req.request_id or 'req:logs'
    local q = {
        tail     = get_param(req, 'tail'),
        level    = get_param(req, 'level'),
        search   = get_param(req, 'search'),
        instance = get_param(req, 'instance'),
    }
    local target = q.instance
    local self_alias = (rawget(_G, 'box') and box.info and box.info.name) or nil

    local result
    if type(target) == 'string' and target ~= '' and target ~= self_alias then
        result = tail_remote(target, q)
    else
        result = M.tail(q)
    end

    if result.ok then
        logger.info('logs.tail', {
            path = result.path,
            returned = #(result.lines or {}),
            instance = result.instance,
            level = q.level, search = q.search,
            request_id = request_id,
        })
    end
    return reply(result, request_id)
end

return M
