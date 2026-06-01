--
-- Snapshot operations.
--
-- POST /api/snapshots/take  → admin; triggers `box.snapshot()`.
-- GET  /api/snapshots       → admin; lists the .snap files in the
--                              memtx_dir.
--

local json = require('json')
local fio  = require('fio')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('api.snapshots')

local M = {}

local function memtx_dir()
    if rawget(_G, 'box') == nil or type(box.cfg) ~= 'table' then
        return '.'
    end
    return box.cfg.memtx_dir or box.cfg.work_dir or '.'
end

local function wal_dir()
    if rawget(_G, 'box') == nil or type(box.cfg) ~= 'table' then
        return '.'
    end
    return box.cfg.wal_dir or box.cfg.memtx_dir or box.cfg.work_dir or '.'
end

-- Resolve the directory a file basename lives in based on the
-- extension. .snap stays in memtx_dir; .xlog/.vylog stay in
-- wal_dir. We accept the same basename guard for both.
local function dir_for(file)
    if file:match('%.snap$') then return memtx_dir() end
    if file:match('%.xlog$') or file:match('%.vylog$') then return wal_dir() end
    return nil
end

-- Tarantool creates a `<signature>.snap` file in `memtx_dir` named by
-- the current vclock signature. `box.snapshot()` is a no-op when a
-- file already exists for that signature — common on followers in
-- quiet clusters, where the vclock only advances when the leader
-- produces new writes. We surface that explicitly with `created:
-- true|false` so the operator sees whether a fresh file landed
-- instead of inferring success from a generic 200.
local function snap_path_for(dir, signature)
    return string.format('%s/%020d.snap', dir, signature)
end

function M.handler_take(req)
    local dir = memtx_dir()
    local sig_before = box.info.signature
    local already_at_signature = fio.path.exists(snap_path_for(dir, sig_before))

    local ok, err = pcall(function() return box.snapshot() end)
    if not ok then
        logger.error('box.snapshot failed', { err = tostring(err) })
        return {
            status = 500,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'SNAPSHOT_FAILED', message = tostring(err) } }),
        }
    end

    -- Re-read signature in case a new write landed mid-snapshot; check
    -- both before/after positions because either could be where the
    -- new file lives.
    local sig_after = box.info.signature
    local created = (not already_at_signature)
        and (fio.path.exists(snap_path_for(dir, sig_before))
             or fio.path.exists(snap_path_for(dir, sig_after)))

    logger.info('snapshot taken', {
        user = req.user,
        instance = box.info.name,
        ro = box.info.ro,
        sig_before = sig_before, sig_after = sig_after,
        created = created,
    })
    return {
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({
            ok = true,
            created = created,
            signature = sig_after,
            instance = box.info.name,
            read_only = box.info.ro == true,
        }),
    }
end

function M.handler_list(_req)
    local mdir = memtx_dir()
    local wdir = wal_dir()
    local entries = {}
    -- .snap from memtx_dir
    for _, path in ipairs(fio.glob(mdir .. '/*.snap') or {}) do
        local stat = fio.stat(path)
        if stat ~= nil then
            table.insert(entries, {
                path = path, size = stat.size, mtime = stat.mtime,
                kind = 'snap',
            })
        end
    end
    -- .xlog and .vylog from wal_dir (may equal memtx_dir; dedupe
    -- by full path).
    local seen = {}
    for _, e in ipairs(entries) do seen[e.path] = true end
    for _, pattern in ipairs({ '/*.xlog', '/*.vylog' }) do
        for _, path in ipairs(fio.glob(wdir .. pattern) or {}) do
            if not seen[path] then
                local stat = fio.stat(path)
                if stat ~= nil then
                    local kind = path:match('%.xlog$') and 'xlog' or 'vylog'
                    table.insert(entries, {
                        path = path, size = stat.size, mtime = stat.mtime,
                        kind = kind,
                    })
                end
            end
        end
    end
    table.sort(entries, function(a, b) return a.mtime > b.mtime end)
    return {
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({
            entries = entries,
            dir = mdir,        -- back-compat with old SPA
            memtx_dir = mdir,
            wal_dir   = wdir,
        }),
    }
end

-- GET /api/snapshots/download?file=<basename>
--
-- Stream one .snap / .xlog / .vylog file from the local instance.
-- The extension decides which directory we read from (snap from
-- memtx_dir, xlog/vylog from wal_dir). Path-traversal guard
-- rejects anything outside a bare basename. Other file types are
-- refused so the operator cannot exfiltrate arbitrary container
-- files through this endpoint by accident.
function M.handler_download(req)
    -- HTTP rock parses query string into `req.query_param`-style
    -- accessors. Support both styles so the same handler works
    -- under different rock versions.
    local file
    if type(req.query_param) == 'function' then
        file = req.query_param(req, 'file') or req.query_param(req, 'name')
    elseif type(req.query) == 'string' then
        file = req.query:match('file=([^&]+)')
    end
    if type(file) == 'string' then
        file = file:gsub('%%2E', '.'):gsub('%%2F', '/')
    end
    if type(file) ~= 'string' or file == '' then
        return {
            status = 400,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'INVALID_QUERY',
                message = '`file` query parameter is required',
                request_id = req.request_id,
            } }),
        }
    end
    -- Strip any path component the operator might have pasted —
    -- we only accept a bare basename inside the snap dir.
    if file:find('/', 1, true) or file:find('\\', 1, true)
        or file:find('..', 1, true) then
        return {
            status = 400,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'INVALID_QUERY',
                message = 'file must be a bare basename inside memtx_dir',
                request_id = req.request_id,
            } }),
        }
    end
    local target_dir = dir_for(file)
    if target_dir == nil then
        return {
            status = 400,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'INVALID_QUERY',
                message = 'only .snap / .xlog / .vylog files are downloadable',
                request_id = req.request_id,
            } }),
        }
    end

    local full = target_dir .. '/' .. file
    local stat = fio.stat(full)
    if stat == nil then
        return {
            status = 404,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'NOT_FOUND',
                message = 'snapshot file not found: ' .. file,
                request_id = req.request_id,
            } }),
        }
    end

    local fd, open_err = fio.open(full, { 'O_RDONLY' })
    if fd == nil then
        return {
            status = 500,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'IO_ERROR',
                message = 'open failed: ' .. tostring(open_err),
                request_id = req.request_id,
            } }),
        }
    end
    -- Read the whole file. .snap files in the dev compose are
    -- ~kB to MB so memory is not a concern; for huge prod
    -- snapshots we will swap this for chunked transfer later.
    local body = fd:read(stat.size)
    fd:close()

    logger.info('snapshot downloaded', {
        user = req.user, file = file, size = stat.size,
        instance = box.info and box.info.name,
    })
    return {
        status = 200,
        headers = {
            ['content-type']        = 'application/octet-stream',
            ['content-disposition'] = 'attachment; filename="' .. file .. '"',
            ['content-length']      = tostring(stat.size),
        },
        body = body,
    }
end

return M
