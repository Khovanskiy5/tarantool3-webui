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

function M.handler_take(req)
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
    logger.info('snapshot taken', { user = req.user })
    return {
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({ ok = true, signature = box.info.signature }),
    }
end

function M.handler_list(_req)
    local dir = memtx_dir()
    local entries = {}
    local listing = fio.glob(dir .. '/*.snap')
    if type(listing) == 'table' then
        for _, path in ipairs(listing) do
            local stat = fio.stat(path)
            if stat ~= nil then
                table.insert(entries, {
                    path = path,
                    size = stat.size,
                    mtime = stat.mtime,
                })
            end
        end
    end
    table.sort(entries, function(a, b) return a.mtime > b.mtime end)
    return {
        status = 200,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({ entries = entries, dir = dir }),
    }
end

return M
