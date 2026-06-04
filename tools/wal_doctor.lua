#!/usr/bin/env tarantool
--
-- wal_doctor — standalone WAL/snapshot corruption scanner.
--
-- Walks every .snap / .xlog in the given directories with Tarantool's own
-- xlog iterator and reports, per file, whether it reads cleanly and up to
-- which LSN. The FIRST file that raises is the corruption point.
--
-- Crucially it runs WITHOUT box.cfg() — it never bootstraps or joins a
-- cluster — so it is safe to point at the data dir of an instance that is
-- crash-looping on a corrupt WAL (where the role/console/UI never start and
-- the on-instance `wal_diagnose` is therefore unreachable). Run it from a
-- throwaway container over the dead instance's volume:
--
--   docker run --rm -v webui_tt-3-data:/opt/webui/var/lib \
--     --entrypoint wal-doctor webui-instance:dev
--
-- or directly:  tarantool wal_doctor.lua [<dir> ...]
--
-- With no dir args it auto-discovers instance dirs under
-- $TT_WORK_DIR/var/lib/* (default /opt/webui/var/lib/var/lib/*).
--
-- Exit code: 0 when every file reads cleanly, 1 when any file is corrupt
-- (so it is usable in scripts / health checks).
--

local xlog = require('xlog')
local fio  = require('fio')

-- Read a single .snap/.xlog end-to-end. -> ok, last_lsn, error.
local function probe(path)
    local last
    local ok, err = pcall(function()
        for lsn in xlog.pairs(path) do last = lsn end
    end)
    return ok, last, (not ok) and tostring(err) or nil
end

-- Resolve the directories to scan: explicit args, else auto-discover.
local function resolve_dirs(args)
    local dirs = {}
    for i = 1, #(args or {}) do dirs[#dirs + 1] = args[i] end
    if #dirs > 0 then return dirs end
    local root = os.getenv('TT_WORK_DIR') or '/opt/webui/var/lib'
    for _, d in ipairs(fio.glob(root .. '/var/lib/*') or {}) do
        if fio.path.is_dir(d) then dirs[#dirs + 1] = d end
    end
    if #dirs == 0 then dirs = { '.' } end
    return dirs
end

local function scan_dir(dir)
    local files = {}
    for _, pat in ipairs({ '/*.snap', '/*.xlog' }) do
        for _, p in ipairs(fio.glob(dir .. pat) or {}) do
            files[#files + 1] = p
        end
    end
    table.sort(files)
    print('# ' .. dir)
    if #files == 0 then
        print('  (no .snap/.xlog files here)')
        return 0
    end
    local bad = 0
    for _, p in ipairs(files) do
        local ok, last, err = probe(p)
        local name = p:gsub('.*/', '')
        if ok then
            print(string.format('  OK   %-34s last_lsn=%s', name, tostring(last)))
        else
            bad = bad + 1
            print(string.format('  BAD  %-34s %s', name, err))
        end
    end
    return bad
end

local function main(args)
    local total_bad = 0
    for _, dir in ipairs(resolve_dirs(args)) do
        total_bad = total_bad + scan_dir(dir)
    end
    if total_bad > 0 then
        print(string.format('\n%d corrupt file(s) found — quarantine the BAD '
            .. 'file(s) (and, for a mid-chain hit, the chain after it) or '
            .. 'wipe the data dir for a clean rejoin.', total_bad))
        return 1
    end
    print('\nAll .snap/.xlog files read cleanly.')
    return 0
end

os.exit(main(rawget(_G, 'arg') or {}))
