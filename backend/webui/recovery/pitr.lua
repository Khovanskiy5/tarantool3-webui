--
-- Point-in-time recovery — advisory wizard (Phase 6 Task DR-4).
--
-- Tarantool 3.x PITR requires an offline pass: stop the process,
-- truncate WAL beyond the target LSN, start with
-- `force_recovery = true`, take a fresh snapshot, restart the
-- cluster against that snapshot. Since the WebUI cannot stop
-- and restart itself safely (it would lose the very request
-- the operator just made), this module is **advisory**: it
-- enumerates recovery points + assembles the plan + returns
-- the exact shell commands the operator runs on the host.
--
-- The plan covers the local instance only. Multi-peer recovery
-- is per-peer manual — wizard renders one block per peer the
-- operator selects.
--

local fio = require('fio')

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

-- Extract the LSN-prefix from a Tarantool .snap / .xlog name.
-- The runtime names every WAL/snap as 20-digit zero-padded LSN
-- of the FIRST record in the file.
function M.lsn_from_filename(path)
    local base = path:gsub('^.*/', '')
    -- Try every well-known extension explicitly. A single
    -- character-class regex would have to spell `.snap`,
    -- `.xlog`, `.vylog` simultaneously, which is awkward in
    -- Lua patterns.
    local digits = base:match('^(%d+)%.snap$')
        or base:match('^(%d+)%.xlog$')
        or base:match('^(%d+)%.vylog$')
    if digits == nil then return nil end
    return tonumber(digits)
end

-- list_recovery_points() → { current_lsn, points: [...] }
-- A "point" is one snap file (and the xlog tail you'd play
-- against it). The wizard lets the operator pick a snap then
-- shows the xlog range we'd replay on top.
function M.list_recovery_points()
    local snaps, xlogs = {}, {}
    for _, p in ipairs(fio.glob(memtx_dir() .. '/*.snap') or {}) do
        local stat = fio.stat(p)
        if stat ~= nil then
            table.insert(snaps, {
                path = p, size = stat.size, mtime = stat.mtime,
                lsn = M.lsn_from_filename(p),
            })
        end
    end
    for _, p in ipairs(fio.glob(wal_dir() .. '/*.xlog') or {}) do
        local stat = fio.stat(p)
        if stat ~= nil then
            table.insert(xlogs, {
                path = p, size = stat.size, mtime = stat.mtime,
                lsn = M.lsn_from_filename(p),
            })
        end
    end
    table.sort(snaps, function(a, b) return (a.lsn or 0) < (b.lsn or 0) end)
    table.sort(xlogs, function(a, b) return (a.lsn or 0) < (b.lsn or 0) end)

    -- Pair each snap with the xlog files whose LSN ≥ snap.lsn
    -- AND ≤ next-snap.lsn (or open-ended on the latest snap).
    local points = {}
    for i, snap in ipairs(snaps) do
        local upper = (snaps[i + 1] and snaps[i + 1].lsn) or math.huge
        local replay = {}
        for _, x in ipairs(xlogs) do
            if x.lsn and x.lsn >= snap.lsn and x.lsn < upper then
                table.insert(replay, x)
            end
        end
        table.insert(points, {
            snap     = snap,
            replay   = replay,
        })
    end
    local current_lsn
    if rawget(_G, 'box') and box.info and box.info.lsn then
        current_lsn = box.info.lsn
    end
    return {
        current_lsn = current_lsn,
        instance    = (rawget(_G, 'box') and box.info and box.info.name) or nil,
        memtx_dir   = memtx_dir(),
        wal_dir     = wal_dir(),
        snaps       = snaps,
        xlogs       = xlogs,
        points      = points,
    }
end

-- plan(target_lsn) → {snap, replay, commands}
-- Picks the latest snap whose LSN <= target_lsn, then the xlog
-- range that brings the state up to target_lsn (truncating the
-- last xlog after target). Commands are docker-flavoured by
-- default because the dev compose is the canonical deployment;
-- a Kubernetes or bare-metal operator can substitute the exec
-- prefix manually.
function M.plan(target_lsn)
    local rp = M.list_recovery_points()
    if rp.current_lsn ~= nil and target_lsn > rp.current_lsn then
        return nil,
            'target LSN ' .. target_lsn ..
            ' is in the future (current ' .. rp.current_lsn .. ')'
    end
    -- Pick the snap.
    local chosen_snap
    for _, s in ipairs(rp.snaps) do
        if s.lsn ~= nil and s.lsn <= target_lsn then
            chosen_snap = s
        end
    end
    if chosen_snap == nil then
        return nil, 'no snapshot LSN ≤ ' .. target_lsn
            .. ' (oldest is ' ..
            tostring(rp.snaps[1] and rp.snaps[1].lsn) .. ')'
    end
    -- Pick the xlog tail.
    local replay = {}
    for _, x in ipairs(rp.xlogs) do
        if x.lsn ~= nil and x.lsn >= chosen_snap.lsn and x.lsn <= target_lsn then
            table.insert(replay, x)
        end
    end

    -- Commands operator runs. Per peer, on the host that owns
    -- the container. The awk one-liner is embedded as a single
    -- long-bracket string so neither single nor double quotes
    -- need escaping.
    local instance = rp.instance or '<instance>'
    local awk_cmd = [[ls /data/*.xlog | awk -F/ '{name=$NF; lsn=substr(name,1,20)+0; if (lsn > ]]
        .. tostring(target_lsn)
        .. [[) print $0}' | xargs -r rm]]
    local commands = {
        '# Stop the instance:',
        'docker stop webui-' .. instance,
        '',
        '# Snapshot the current state aside (you can move back if needed):',
        'docker run --rm -v webui-dev_' .. instance
            .. '-data:/data alpine sh -c "cp -r /data /data.pre_pitr_$(date +%s)"',
        '',
        '# Remove every xlog after the chosen target LSN so the recovery',
        '# stops at exactly that point. Target LSN = ' .. target_lsn,
        'docker run --rm -v webui-dev_' .. instance
            .. '-data:/data alpine sh -c "' .. awk_cmd .. '"',
        '',
        '# Start the instance with force_recovery so a torn last xlog',
        '# (truncated above) does not halt the boot. The cfg flag is',
        '# read once at start; remove it after the next snapshot.',
        'docker start webui-' .. instance,
        '# (set TT_FORCE_RECOVERY=true in docker-compose.dev.yml for the',
        '# duration of this restart, then unset before the next start)',
        '',
        '# Once it boots, take a fresh snapshot to seal the new tail:',
        'curl -X POST -b /tmp/cookies http://localhost:8081/api/snapshots/take',
    }
    return {
        target_lsn   = target_lsn,
        current_lsn  = rp.current_lsn,
        instance     = instance,
        snap         = chosen_snap,
        replay       = replay,
        commands     = commands,
    }
end

return M
