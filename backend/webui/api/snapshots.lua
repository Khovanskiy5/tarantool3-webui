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
