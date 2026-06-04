--
-- Diagnostic bundle + recovery actions.
--
-- GET /api/diagnostics/bundle — packs a JSON payload with the role
--   status, cluster snapshot, active issues, suggestions, recent
--   audit-log rows, role config echo, and runtime versions. The
--   bundle is meant for support — operators attach it to a ticket
--   without having to manually gather state from each instance.
--
-- POST /api/diagnostics/rebootstrap — destructive recovery WIPE
--   primitive: erase WAL/snap/vinyl files on this instance and trigger
--   Docker's restart policy via `os.exit`. On restart the empty work
--   dir forces Tarantool to bootstrap fresh from a healthy peer.
--   Cluster identity (uuid / `_cluster` row) is reset by the leader-side
--   orchestrator (webui.recovery.identity_reset) around this call, so the
--   wiped node rejoins as a brand-new replica id — that is what lets the
--   peers replicate FROM it again in a full mesh.
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

-- Quiesce + wipe this instance's snap/xlog/vinyl work dirs, in place.
-- Reusable target-side primitive: the clean-rebootstrap orchestrator (on
-- the leader) drives identity reset around this call; here we only erase
-- local state so the next boot re-joins from scratch. → (deleted, failed)
-- as arrays of paths.
--
-- QUIESCE first (detach replication + go read-only) so no fresh WAL is
-- appended under the doomed identity between the wipe and os.exit.
-- Recursive: descends into subdirectories (vinyl/ lives under work_dir as
-- nested {space_id}/{index_id} folders) so a regex-only pass can't leave
-- files behind that keep "invalid instance UUID" alive after restart.
local function wipe_self_workdir()
    pcall(function() box.cfg{ replication = {} } end)
    pcall(function() box.cfg{ read_only = true } end)

    local dirs = resolve_work_paths()
    local deleted = {}
    local failed = {}
    local function nuke(dir)
        local listing = fio.listdir(dir)
        if listing == nil then return end
        for _, name in ipairs(listing) do
            local full = dir .. '/' .. name
            local lstat = fio.lstat(full)
            if lstat and lstat:is_dir() then
                nuke(full)
                local rm_ok = pcall(fio.rmdir, full)
                if rm_ok then table.insert(deleted, full .. '/')
                else table.insert(failed, full .. ': rmdir failed') end
            else
                local rm_ok = pcall(fio.unlink, full)
                if rm_ok then table.insert(deleted, full)
                else table.insert(failed, full .. ': unlink failed') end
            end
        end
    end
    for _, dir in ipairs(dirs) do
        if fio.path.exists(dir) then nuke(dir)
        else table.insert(failed, dir .. ': dir missing') end
    end
    return deleted, failed, dirs
end

-- POST /api/diagnostics/rebootstrap — target-side WIPE primitive.
--
-- Erases the local snap/xlog/vinyl state and exits; Docker's restart
-- policy recreates the container and Tarantool re-joins from healthy
-- peers. This handler does NOT manage cluster identity: the clean
-- rebootstrap orchestrator (webui.recovery.identity_reset, run on the
-- leader) expels the instance from config + `_cluster` BEFORE calling
-- here and re-adds it AFTER, so the wiped node rejoins as a brand-new
-- replica id. Called directly it is a raw wipe (the node would reuse its
-- existing id) — operators should drive recovery through /cluster-recovery.
--
-- Refuses when the responding instance is the synchro queue owner —
-- wiping the leader's state loses any uncommitted synchro txns.
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

    -- Quiesce + wipe local state. Identity (uuid / `_cluster` row) is
    -- managed by the orchestrator on the leader, NOT here — see the handler
    -- comment above. Quiescing detaches replication + goes read-only so no
    -- fresh WAL is appended under the doomed identity before os.exit.
    local deleted, failed, dirs = wipe_self_workdir()

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
