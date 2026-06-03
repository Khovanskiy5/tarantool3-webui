--
-- WAL chain repair — corruption quarantine (Phase 6 Task DR-6).
--
-- Symptom: an xlog file is truncated or has a bad checksum, the
-- applier stops mid-replay, `box.info.status` lands at "orphan"
-- or "loading" forever, and the local instance's logs show
-- something like:
--
--   xlog.c:445 E> var/lib/tt-2/00000000000000000178.xlog:
--     invalid instance UUID
--
-- (the same message the user hit when stale WAL referenced an
-- expelled instance UUID.)
--
-- Recovery flow:
--   1. Diagnose: walk every .xlog and run `xlog.cursor` over it.
--      The first read that raises is the corruption point —
--      report it.
--   2. Quarantine: rename the bad file to `<name>.corrupt` so
--      the next boot does not re-read it. The renamed file
--      stays in place; an operator can move it offline at
--      leisure.
--   3. Hint: tell the operator to restart with
--      `force_recovery = true` so partial last records elsewhere
--      do not block the boot either.
--

local fio = require('fio')
local xlog = require('xlog')

local audit    = require('webui.audit.log')
local assess   = require('webui.recovery.assess')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.wal_repair')

local M = {}

-- assess(payload, root) → Assessment (read-only). Quarantining the LAST
-- xlog (tail corruption) loses only the un-acked tail (caution);
-- quarantining a file with good xlogs after it truncates the chain
-- (dangerous). Snapshot / system-space corruption is NOT force-recoverable
-- and must go through rebootstrap.
function M.assess(payload, _root)
    payload = payload or {}
    local file = payload.file
    local diag = M.diagnose()
    local files = diag.files or {}
    local idx, is_tail = nil, false
    for i, f in ipairs(files) do
        if f.path:gsub('^.*/', '') == tostring(file) then idx = i end
    end
    if idx ~= nil then is_tail = (idx == #files) end
    local fp = assess.fingerprint({ peers = {} }, {})

    local b = assess.new('wal_quarantine')
        .summary('Quarantine corrupt xlog ' .. tostring(file))
        .with_docs('runbooks/wal-repair.md')
        .effect('Renames ' .. tostring(file) .. ' to .corrupt so the next '
            .. 'boot skips it.')
        .precondition(idx ~= nil, 'File present in the local wal_dir',
            'diagnose/quarantine see ONLY this instance\'s wal_dir — target '
                .. 'the corrupt node.')
        .manual('Make a separate byte copy of the file (and wal_dir) BEFORE '
            .. 'quarantine — a rename is not a backup.')
        .manual('Prefer wipe+rejoin from a healthy peer (zero loss) over local '
            .. 'quarantine when a peer with an equal-or-greater vclock exists.')
        .manual('After a forced boot: write + box.snapshot(), then turn '
            .. 'force_recovery back off. Snapshot/system-space corruption is '
            .. 'NOT force-recoverable — use rebootstrap.')
        .failure_cmd('inspect the good prefix',
            'tarantoolctl cat <wal_dir>/' .. tostring(file))
        .failure_cmd('boot past the bad record', 'force_recovery = true (then '
            .. 'box.snapshot() and disable it)')

    if is_tail then
        b.risk(assess.CAUTION)
            .effect('Tail corruption — only the un-acked tail is lost.')
    else
        b.risk(assess.DANGEROUS).data_loss(true)
            .warning('Mid-chain corruption — the WAL chain after this file '
                .. 'is truncated; committed data is lost.')
            .confirm('WAL ' .. tostring(file),
                'I accept truncating the WAL chain')
        for _, pc in ipairs(assess.universal_preconditions()) do
            b.precondition(pc.ok, pc.label, pc.detail)
        end
    end
    logger.debug('wal_repair.assess', { file = file, is_tail = is_tail })
    return b.build(fp)
end

local function wal_dir()
    if rawget(_G, 'box') == nil or type(box.cfg) ~= 'table' then
        return '.'
    end
    return box.cfg.wal_dir or box.cfg.memtx_dir or box.cfg.work_dir or '.'
end

-- probe(path) → { ok, last_lsn, error? }
-- Walks the xlog through tarantool's own iterator. If iteration
-- raises, we report the LSN of the last successfully-read entry
-- as the "good prefix" — the operator can use that to pick a
-- recovery target in DR-4.
function M.probe(path)
    local last_lsn
    local ok, err = pcall(function()
        for lsn, _record in xlog.pairs(path) do
            last_lsn = lsn
        end
    end)
    return {
        path     = path,
        ok       = ok,
        last_lsn = last_lsn,
        error    = (not ok) and tostring(err) or nil,
    }
end

-- diagnose() → { dir, files: [...] }
function M.diagnose()
    local dir = wal_dir()
    local out = {}
    for _, p in ipairs(fio.glob(dir .. '/*.xlog') or {}) do
        local stat = fio.stat(p)
        if stat ~= nil then
            local probed = M.probe(p)
            table.insert(out, {
                path     = p,
                size     = stat.size,
                mtime    = stat.mtime,
                ok       = probed.ok,
                last_lsn = probed.last_lsn,
                error    = probed.error,
            })
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return { dir = dir, files = out }
end

-- quarantine(file) → { ok, msg }
-- Renames `<dir>/<file>` to `<dir>/<file>.corrupt`. Refuses if
-- the name is not a bare basename inside the wal_dir, mirroring
-- the snapshot download guard.
function M.quarantine(payload, root)
    payload = payload or {}
    local file = payload.file
    if type(file) ~= 'string' or file == '' then
        return { ok = false, action = 'wal_quarantine', results = {},
            error = 'file is required' }
    end
    if file:find('/', 1, true) or file:find('\\', 1, true)
        or file:find('..', 1, true) then
        return { ok = false, action = 'wal_quarantine', results = {},
            error = 'file must be a bare basename' }
    end
    if not file:match('%.xlog$') then
        return { ok = false, action = 'wal_quarantine', results = {},
            error = 'only .xlog files can be quarantined' }
    end
    local src = wal_dir() .. '/' .. file
    if fio.stat(src) == nil then
        return { ok = false, action = 'wal_quarantine', results = {},
            error = 'file not found: ' .. file }
    end
    local dst = src .. '.corrupt'
    local ok, err = pcall(function() return fio.rename(src, dst) end)
    if not ok then
        return { ok = false, action = 'wal_quarantine',
            results = { { peer = '*', ok = false, msg = tostring(err) } },
            error = tostring(err) }
    end
    pcall(audit.record, {
        user   = root and root.user,
        action = 'wal.quarantine',
        scope  = 'storage',
        payload = { file = file, renamed_to = dst },
        request_id = root and root.request_id,
    })
    logger.warn('xlog quarantined', { file = file, renamed_to = dst })
    return {
        ok = true, action = 'wal_quarantine',
        results = { { peer = file, ok = true, msg = 'renamed to ' .. dst } },
    }
end

return M
