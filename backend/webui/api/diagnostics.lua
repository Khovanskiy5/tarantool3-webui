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
local yaml_patch  = require('webui.config_store.yaml_patch')
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

-- Read the live cluster YAML from etcd. → (raw, nil) | (nil, err).
local function read_cluster_yaml()
    local ok_cl, client_mod = pcall(require, 'webui.config_store.client')
    if not ok_cl then return nil, 'config client unavailable' end
    local client = client_mod.get_client()
    if client == nil then return nil, 'etcd client unavailable' end
    local kv = select(1, client:read_cluster_config())
    if kv == nil or kv.value == nil then return nil, 'no current cluster config' end
    return kv.value
end

-- Write a full cluster YAML straight to etcd. We deliberately bypass the
-- two-phase commit here: a rebootstrap target often has BROKEN replication
-- (frequently the very reason it is being rebootstrapped), so the 2PC
-- prepared-row round-trip can't complete on it. The target reads the
-- config fresh from etcd on its restart, so a plain write is enough to
-- pin its uuid; healthy peers reconcile it on their next config commit.
-- → (true, nil) | (nil, err).
local function commit_cluster_yaml(new_yaml)
    local ok_cl, client_mod = pcall(require, 'webui.config_store.client')
    if not ok_cl then return nil, 'config client unavailable' end
    local client = client_mod.get_client()
    if client == nil then return nil, 'etcd client unavailable' end
    local ok, res, err = pcall(client.write_cluster_config, client, new_yaml)
    if not ok then return nil, 'etcd write raised: ' .. tostring(res) end
    if res == nil then return nil, 'etcd write failed: ' .. tostring(err) end
    return true
end

-- Pin this instance's CURRENT uuid in config before a rebootstrap, so the
-- wiped instance reclaims the SAME identity on rejoin. → (uuid, nil) |
-- (nil, err).
--
-- The named `_cluster` row (uuid -> name) is KEPT, so on restart:
--   * the row already carries the instance name, so box.cc's identity
--     check passes (no "Instance name mismatch" / "not set in snapshot");
--   * reusing the uuid avoids re-registering a new replica id.
-- Reusing the uuid would normally risk "invalid xlog order" on peers (the
-- uuid's LSN rewinds with the wipe) — but the rebootstrap QUIESCES the
-- instance before wiping, so no fresh xlog is written under the old uuid
-- and the peers' relay re-syncs cleanly. (#3740)
local function pin_self_instance_uuid()
    local self_name = box.info and box.info.name
    local my_uuid   = box.info and box.info.uuid
    if type(self_name) ~= 'string' or self_name == ''
        or type(my_uuid) ~= 'string' or my_uuid == '' then
        return nil, 'self identity unavailable'
    end
    local raw, read_err = read_cluster_yaml()
    if raw == nil then return nil, read_err end
    local yaml = require('yaml')
    local ok_p, parsed = pcall(yaml.decode, raw)
    if not ok_p or type(parsed) ~= 'table' then
        return nil, 'cluster config YAML invalid'
    end
    -- Patch the RAW text, not the decoded tree: a yaml.encode round-trip
    -- here would strip every operator comment and the original key order
    -- from the config that the editor renders verbatim. We only need the
    -- parsed tree to discover this instance's group / replicaset names.
    local inst_path = yaml_patch.find_instance_path(parsed, self_name)
    if inst_path == nil then
        return nil, 'instance ' .. self_name .. ' not found in config'
    end
    table.insert(inst_path, 'database')
    table.insert(inst_path, 'instance_uuid')
    local new_yaml, status = yaml_patch.set_field(raw, inst_path, my_uuid)
    if new_yaml == nil then return nil, status end
    if status == 'unchanged' then return my_uuid end
    local ok_w, err = commit_cluster_yaml(new_yaml)
    if not ok_w then return nil, err end
    return my_uuid
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

    -- Preserve identity across the wipe: pin our CURRENT uuid in config and
    -- KEEP the named `_cluster` row. On restart the instance reclaims the
    -- same uuid; the row already carries its name, so box.cc's identity
    -- check passes and there is no crash loop ("Instance name ... is not
    -- set in snapshot" / "Instance name mismatch"). A fresh uuid would
    -- instead orphan the name. HARD precondition: if we can't pin it, abort
    -- rather than wipe the instance into an unbootable state. (#3740)
    local pin_uuid, pin_err = pin_self_instance_uuid()
    if pin_uuid == nil then
        logger.warn('rebootstrap aborted: could not pin instance_uuid', {
            instance = box.info.name, err = tostring(pin_err),
        })
        return {
            status = 500,
            headers = { ['content-type'] = 'application/json' },
            body = json.encode({ error = {
                code = 'PIN_FAILED',
                message = 'could not pin instance_uuid before wipe ('
                    .. tostring(pin_err) .. '); aborted to avoid leaving '
                    .. 'the instance unbootable',
                request_id = request_id,
            } }),
        }
    end

    -- Quiesce BEFORE wiping. The process keeps running for a beat after the
    -- wipe (so the HTTP reply flushes) before os.exit; if replication is
    -- still live it keeps appending WAL under our uuid — both leaving a
    -- stray xlog in the just-emptied dir and rewinding the uuid's LSN, so
    -- peers reject the rejoin with "invalid xlog order". Detaching
    -- replication + going read-only stops all WAL writes, so the dir stays
    -- empty and the peers' relay re-syncs cleanly on restart.
    pcall(function() box.cfg{ replication = {} } end)
    pcall(function() box.cfg{ read_only = true } end)

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
