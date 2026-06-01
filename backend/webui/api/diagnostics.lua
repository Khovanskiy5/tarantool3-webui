--
-- Diagnostic bundle + recovery actions.
--
-- GET /api/diagnostics/bundle — packs a JSON payload with the role
--   status, cluster snapshot, active issues, suggestions, recent
--   audit-log rows, role config echo, and runtime versions. The
--   bundle is meant for support — operators attach it to a ticket
--   without having to manually gather state from each instance.
--
-- POST /api/diagnostics/rebootstrap — destructive recovery: wipe
--   WAL/snap/vinyl files on this instance and trigger Docker's
--   restart policy via `os.exit`. On restart the empty work dir
--   forces Tarantool to bootstrap fresh from a healthy peer —
--   resolves split-brain (lsn divergence in the synchro queue) and
--   stuck replication that `box.cfg{replication=...}` alone cannot
--   recover from.
--
-- Admin only. No PII beyond what's already in the WebUI (no
-- passwords, no full cluster YAML by default — operators can opt
-- in via `?include_config=1`).
--

local fio   = require('fio')
local json  = require('json')
local fiber = require('fiber')

local state       = require('webui.cluster.state')
local storage     = require('webui.storage.spaces')
local issues      = require('webui.cluster.issues')
local suggestions = require('webui.cluster.suggestions')
local version     = require('webui.version')
local log_util    = require('webui.log_util')
local logger      = log_util.with_tag('api.diagnostics')

local M = {}

-- Resolve the work_dir the running instance writes snap/xlog to.
-- Prefer `box.cfg.wal_dir` / `box.cfg.memtx_dir` over a hard-coded
-- compose path so the helper survives operators who relocate work
-- volumes; defensive fallback covers the dev-compose layout.
--
-- IMPORTANT: Tarantool 3.x stores `box.cfg.wal_dir` as the literal
-- string from the YAML (often relative, e.g. "var/lib/tt-1"), and
-- resolves it relative to `box.cfg.work_dir` at I/O time. The wipe
-- helper opens these paths via `fio.*` which does NOT consult
-- `box.cfg.work_dir` — so passing the relative string in directly
-- looks for files in CWD and silently finds nothing. The result is
-- a "successful" wipe that left every WAL in place, which caused
-- the next boot to hit "invalid instance UUID" and crash-loop. Fix:
-- join `work_dir` + the relative segment when needed so the path
-- matches what the runtime actually reads/writes.
local function _resolve_one(p, work_dir)
    if p == nil then return nil end
    -- Absolute path — use as-is.
    if p:sub(1, 1) == '/' then return p end
    -- Relative — anchor to work_dir (Tarantool's own convention).
    if work_dir == nil or work_dir == '' then return p end
    local sep = (work_dir:sub(-1) == '/') and '' or '/'
    return work_dir .. sep .. p
end

local function resolve_work_paths()
    local work_dir  = (box.cfg and box.cfg.work_dir)  or '/opt/webui/var/lib'
    local wal_dir   = _resolve_one(box.cfg and box.cfg.wal_dir,   work_dir)
        or '/opt/webui/var/lib'
    local memtx_dir = _resolve_one(box.cfg and box.cfg.memtx_dir, work_dir)
        or '/opt/webui/var/lib'
    local vinyl_dir = _resolve_one(box.cfg and box.cfg.vinyl_dir, work_dir)
        or '/opt/webui/var/lib'
    -- De-duplicate when all three point to the same dir (default).
    local seen = {}
    local dirs = {}
    for _, d in ipairs({ wal_dir, memtx_dir, vinyl_dir }) do
        if d ~= nil and not seen[d] then
            seen[d] = true
            table.insert(dirs, d)
        end
    end
    return dirs
end

-- POST /api/diagnostics/rebootstrap.
--
-- Refuses when the responding instance is the synchro queue owner —
-- wiping the leader's state loses any uncommitted synchro txns.
-- Operators must promote a healthy peer first; the resolver behind
-- the GraphQL mutation does this fan-out check before targeting.
--
-- Cleanup is best-effort: we delete every *.snap, *.xlog, *.xlog.inprogress,
-- *.snap.inprogress, *.vylog, and the `_webui_meta.local.snap` /
-- vinyl subdirs. Then schedule `os.exit(0)` from a detached fiber so
-- the HTTP response actually flushes before the process dies. Docker
-- restart policy (`unless-stopped` in the dev compose) brings the
-- container back; Tarantool's auto bootstrap strategy then picks up
-- a healthy peer and replicates clean.
function M.rebootstrap_handler(req)
    local request_id = req.request_id

    if rawget(_G, 'box') == nil or box.info == nil then
        return {
            status = 503,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'UNAVAILABLE',
                message = 'box not initialised yet',
                request_id = request_id,
            } }),
        }
    end

    -- Don't wipe the queue owner — would lose uncommitted synchro
    -- writes the rest of the cluster expects to keep. Surface the
    -- exact constraint so the SPA can guide the operator.
    local synchro = box.info.synchro or {}
    local owner = (synchro.queue and synchro.queue.owner) or 0
    if owner == box.info.id then
        logger.warn('rebootstrap rejected: instance is synchro queue owner', {
            instance = box.info.name, owner = owner,
        })
        return {
            status = 409,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'FORBIDDEN',
                message = 'this instance owns the synchronous queue; ' ..
                    'promote another peer first, then re-bootstrap this one',
                request_id = request_id,
                details = { instance = box.info.name, queue_owner_id = owner },
            } }),
        }
    end

    -- Best-effort: drop our own row from the leader's `_cluster`
    -- space before wiping. Without this the peers keep our OLD
    -- instance_uuid in `_cluster`; on the next boot a fresh wipe
    -- gives us a NEW uuid, peers end up with both, and applier
    -- chokes on stale xlog references ("invalid instance UUID").
    -- Forward the delete to the queue owner via the peer pool;
    -- silent on failure — replication can still recover when the
    -- new UUID registers, just with extra noise in the issue panel.
    local my_uuid = box.info.uuid
    local fwd_ok, fwd_err = pcall(function()
        local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
        local peers_ok, peers = pcall(require, 'webui.cluster.peers')
        if not (rpc_ok and peers_ok) then return end
        local all = {}
        for name in pairs(peers.list() or {}) do
            table.insert(all, name)
        end
        if #all == 0 then return end
        -- Anyone may try; only the queue owner will actually mutate
        -- _cluster (others are RO and silently noop).
        rpc.map_eval(string.format(
            [[local s = box.space._cluster
              for _, t in s:pairs() do
                  if t[2] == %q then
                      pcall(function() s:delete{t[1]} end)
                  end
              end
              return true]], my_uuid), {}, { timeout = 3, peers = all })
    end)
    if not fwd_ok then
        logger.warn('rebootstrap: _cluster cleanup forward failed', {
            err = tostring(fwd_err),
        })
    end

    local dirs = resolve_work_paths()
    local deleted = {}
    local failed = {}
    -- Recursive wipe: delete files in work_dirs AND descend into
    -- subdirectories (vinyl/ for vinyl spaces lives under work_dir
    -- as nested {space_id}/{index_id} folders). A regex-only pass
    -- left those behind, which kept the "invalid instance UUID"
    -- issue alive after restart.
    local function nuke(dir)
        local listing = fio.listdir(dir)
        if listing == nil then return end
        for _, name in ipairs(listing) do
            local full = dir .. '/' .. name
            local lstat = fio.lstat(full)
            if lstat and lstat:is_dir() then
                -- Recurse, then remove the empty dir.
                nuke(full)
                local rm_ok = pcall(fio.rmdir, full)
                if rm_ok then table.insert(deleted, full .. '/')
                else table.insert(failed, full .. ': rmdir failed') end
            else
                -- Snapshot/wal/vinyl/index/run files all live as
                -- plain files; delete every regular file under the
                -- work_dir. Operators don't put config there — we
                -- bind-mount cluster.yaml at /opt/webui/etc/.
                local rm_ok = pcall(fio.unlink, full)
                if rm_ok then table.insert(deleted, full)
                else table.insert(failed, full .. ': unlink failed') end
            end
        end
    end
    for _, dir in ipairs(dirs) do
        local exists = fio.path.exists(dir)
        if exists then nuke(dir)
        else table.insert(failed, dir .. ': dir missing') end
    end

    logger.warn('rebootstrap initiated', {
        instance = box.info.name, request_id = request_id,
        deleted_count = #deleted, failed_count = #failed,
        dirs = dirs,
    })

    -- Schedule the exit so the HTTP response flushes first. 0.5s is
    -- comfortably more than the handler's serialisation + TCP send.
    fiber.create(function()
        fiber.self():name('webui_rebootstrap_exit', { truncate = true })
        fiber.sleep(0.5)
        logger.warn('rebootstrap: exiting process; Docker restart policy ' ..
            'will bring the container back', { instance = box.info.name })
        os.exit(0)
    end)

    return {
        status = 202,
        headers = { ['content-type'] = 'application/json' },
        body = json.encode({
            ok = true,
            instance = box.info.name,
            deleted_count = #deleted,
            failed_count  = #failed,
            failed        = #failed > 0 and failed or nil,
            message = 'rebootstrap initiated; process exiting in 0.5s. ' ..
                'Docker restart policy will recreate the container; ' ..
                'replication will catch up from healthy peers.',
        }),
    }
end

local function audit_tail(n)
    local space = storage.audit()
    if space == nil then return {} end
    local out = {}
    local count = 0
    for _, tuple in space:pairs({}, { iterator = 'REQ' }) do
        table.insert(out, {
            id = tuple.id, ts = tuple.ts, user = tuple.user,
            action = tuple.action, scope = tuple.scope,
        })
        count = count + 1
        if count >= n then break end
    end
    return out
end

function M.handler(req)
    local include_config = (req.query and req.query['include_config']) == '1'
    local payload = {
        generated_at = fiber.time(),
        webui = {
            version = version.SEMVER,
            tarantool = _TARANTOOL,
        },
        instance = (rawget(_G, 'box') and box.info and box.info.name) or nil,
        cluster_snapshot = state.snapshot(),
        issues      = issues.current(),
        suggestions = suggestions.current(),
        audit_tail  = audit_tail(50),
    }
    if include_config then
        -- Module-level `fio` already imported; no second require needed.
        local fio_ok = true
        if fio_ok then
            for _, p in ipairs({
                os.getenv('TT_CONFIG_PATH'),
                '/opt/webui/etc/cluster.yaml',
            }) do
                if p and #p > 0 then
                    local f = fio.open(p)
                    if f ~= nil then
                        payload.cluster_yaml = f:read()
                        f:close()
                        break
                    end
                end
            end
        end
    end
    pcall(function()
        require('webui.notifications').emit({
            type     = 'bundle.downloaded',
            severity = 'info',
            user     = req.user,
            scope    = include_config and 'with-config' or 'metadata-only',
            category = 'audit',
            message  = 'diagnostic bundle downloaded',
        })
    end)
    return {
        status = 200,
        headers = {
            ['content-type'] = 'application/json; charset=utf-8',
            ['content-disposition'] = 'attachment; filename="webui-diagnostics.json"',
        },
        body = json.encode(payload),
    }
end

-- Exposed for unit tests only — the wipe path-resolution bug
-- (relative wal_dir silently misses the real data) was hard to
-- catch without a direct seam.
M._resolve_one = _resolve_one

return M
