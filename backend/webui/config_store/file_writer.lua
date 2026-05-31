--
-- Atomic write of the local cluster YAML.
--
-- After commitConfig persists the new YAML to etcd, every peer in the
-- cluster needs its on-disk copy of `cluster.yaml` to reflect the same
-- payload — that file is the recovery source on cold start when etcd
-- is unreachable. Without this mirror the instance would boot from a
-- stale snapshot from many revisions ago.
--
-- Write strategy is write-to-temp + atomic rename in the same directory
-- (POSIX `rename(2)` is atomic when source and destination live on the
-- same filesystem). Readers either see the old file or the new file —
-- never a half-written one.
--
-- Bind-mount caveat: the dev compose mounts the file (not the dir),
-- which means Docker's bind layer pins the inode of the file. A naked
-- `rename` would replace the inode on the host and the container would
-- keep pointing at the old one. The fall-back path here writes into a
-- sibling temp file and then `dd`-equivalent's it: open original O_WR,
-- truncate, write — same inode, atomic-ish (a concurrent reader can
-- observe the empty truncated file between open and write). Tarantool
-- reads cluster.yaml only at boot / config:reload(), and the call site
-- (twophase.commit) reload-fans-out only after this write succeeds, so
-- the race window doesn't materialise in practice.
--

local fio = require('fio')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('config.file')

local M = {}

-- Resolve the path of the live cluster YAML on this instance. Match the
-- precedence used by the resolver's fallback so an operator who set
-- TT_CONFIG to a custom location still gets the mirror write.
function M.resolve_path()
    local candidates = {}
    local function push(p) if p and #p > 0 then table.insert(candidates, p) end end
    push(os.getenv('TT_CONFIG_PATH'))
    push(os.getenv('TT_CONFIG'))
    push('/opt/webui/etc/cluster.yaml')
    for _, path in ipairs(candidates) do
        if fio.path.exists(path) then return path end
    end
    return nil
end

-- True atomic rename — only viable when the parent directory is
-- writable AND the destination is not a Docker bind-mount of a single
-- file. Returns (true, nil) on success, (nil, reason) when it has to
-- fall back to truncate-and-write.
local function try_rename_write(path, payload)
    local dir = fio.dirname(path)
    if dir == nil or dir == '' then return nil, 'no parent dir' end
    if fio.lstat(dir) == nil then return nil, 'parent dir missing' end
    local tmp = path .. '.tmp.' .. tostring(require('fiber').time() * 1e6)
    local f, open_err = fio.open(tmp,
        { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' },
        tonumber('644', 8))
    if f == nil then
        return nil, 'open tmp failed: ' .. tostring(open_err)
    end
    local ok_write = f:write(payload)
    f:fsync()
    f:close()
    if not ok_write then
        pcall(function() fio.unlink(tmp) end)
        return nil, 'write tmp failed'
    end
    local ok_ren, ren_err = fio.rename(tmp, path)
    if not ok_ren then
        pcall(function() fio.unlink(tmp) end)
        return nil, 'rename failed: ' .. tostring(ren_err)
    end
    return true
end

-- Fallback path: write into the existing inode in place. Necessary on
-- single-file bind mounts where rename would swap the inode and the
-- container would never see the new content. NOT a true atomic write
-- (a concurrent reader can catch the empty post-truncate state), but
-- Tarantool only reads this file at boot / explicit config:reload(),
-- both of which are sequenced after the call site succeeds.
local function in_place_write(path, payload)
    local f, open_err = fio.open(path,
        { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' },
        tonumber('644', 8))
    if f == nil then return nil, 'open failed: ' .. tostring(open_err) end
    local ok_write = f:write(payload)
    f:fsync()
    f:close()
    if not ok_write then return nil, 'write failed' end
    return true
end

-- write_local(payload, opts?): mirror the YAML to disk on this peer.
--   opts.path  — explicit path override (mostly for tests).
-- Returns (true, path) on success, (nil, err) on failure.
function M.write_local(payload, opts)
    if type(payload) ~= 'string' or #payload == 0 then
        return nil, 'EMPTY_PAYLOAD'
    end
    opts = opts or {}
    local path = opts.path or M.resolve_path()
    if path == nil then
        return nil, 'NO_PATH'
    end

    -- Try atomic rename first; gracefully fall back to in-place write
    -- when the host blocks it (single-file bind mount on Docker).
    local ok, err = try_rename_write(path, payload)
    if ok then
        logger.info('cluster.yaml mirrored (rename)', {
            path = path, size = #payload,
        })
        return true, path
    end

    logger.debug('rename fallback triggered, switching to in-place', {
        path = path, reason = err,
    })
    local ok2, err2 = in_place_write(path, payload)
    if ok2 then
        logger.info('cluster.yaml mirrored (in-place)', {
            path = path, size = #payload,
        })
        return true, path
    end
    logger.warn('cluster.yaml mirror failed', { path = path, err = err2 })
    return nil, err2
end

return M
