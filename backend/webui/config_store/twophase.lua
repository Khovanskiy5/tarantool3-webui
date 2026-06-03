--
-- Two-phase commit pipeline for cluster-wide config.
--
-- Lives next to the etcd HTTP client (`config_store/etcd.lua`) and
-- orchestrates the propose → validate → commit → reload pipeline.
--
--   prepare(yaml, opts) → ok, prepared_id|nil, errors|nil
--   commit(prepared_id, expected_rev) → ok, revision|nil, err|nil
--   abort(prepared_id) → ok|nil, err|nil
--
-- Prepare validates locally and (best-effort) on every peer via
-- net.box (handled in the resolver). When `etcd_client` is
-- supplied, commit performs a CAS write at `<prefix>/config`
-- guarded by `expected_rev`. Without a backing etcd the module
-- still works as a per-instance dry-run: validate + diff + store
-- in `_webui_prepared`.
--

local fiber  = require('fiber')
local digest = require('digest')

local schema   = require('webui.config_store.schema')
local diff     = require('webui.config_store.diff')
local history  = require('webui.config_store.history')
local storage  = require('webui.storage.spaces')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('twophase')

local M = {}

M.PREPARED_TTL_SEC = 300 -- 5 min, same as the plan

local function new_prepared_id()
    return string.format('prep-%d-%d', math.floor(fiber.time() * 1000),
        math.random(1, 1000000))
end

-- Drop expired rows from `_webui_prepared`. Only the leader can
-- delete from a replicated space, so on a follower this is a no-op
-- (the leader's gc will clean up and replication will catch up).
-- Cheap to call before every read.
local function gc()
    local space = storage.prepared()
    if space == nil then return end
    local idx = space.index.by_expires_at
    if idx == nil then return end
    local now = fiber.time()
    -- box.info.ro means we cannot mutate the replicated space; the
    -- leader runs the cleanup on its next call.
    if box.info and box.info.ro then return end
    for _, tuple in idx:pairs({ now }, { iterator = 'LE' }) do
        if tuple.expires_at <= now then
            pcall(function() space:delete({ tuple.id }) end)
            logger.warn('prepared TTL expired', { id = tuple.id })
        else
            break
        end
    end
end

local function tuple_to_entry(t)
    if t == nil then return nil end
    return {
        id          = t.id,
        yaml        = t.yaml,
        user        = t.user,
        ts          = t.ts,
        expires_at  = t.expires_at,
        parsed      = nil,  -- re-validated by commit if it needs the AST
    }
end

-- Forward a put/delete to the cluster leader via the net.box peer
-- pool. The `_webui_prepared` space is replicated, so direct
-- mutation on a follower raises READONLY; we proxy through the
-- existing `webui_peer` connection used for session and audit
-- forwarding. Returns the call result or (nil, err).
local function forward_to_leader(fn_name, args)
    local ok_state, cluster_state = pcall(require, 'webui.cluster.state')
    local ok_peers, peers         = pcall(require, 'webui.cluster.peers')
    if not (ok_state and ok_peers) then
        return nil, 'cluster modules not loaded'
    end
    local leader = cluster_state.find_leader()
    if leader == nil then return nil, 'no leader' end
    local peer = peers.get(leader)
    if peer == nil or peer.conn == nil then
        return nil, 'leader connection unavailable'
    end
    local ok, res = pcall(function()
        return peer.conn:call(fn_name, args, { timeout = 3 })
    end)
    if not ok then return nil, tostring(res) end
    if type(res) == 'table' and res.err ~= nil then
        return nil, res.err
    end
    return res
end

local function is_read_only()
    if rawget(_G, 'box') == nil or box.info == nil then return false end
    return box.info.ro == true
end

local function put_prepared(entry)
    local space = storage.prepared()
    if space == nil then
        return nil, 'prepared storage is not bootstrapped'
    end
    if is_read_only() then
        local res, err = forward_to_leader('webui_prepared_put_remote',
            { entry })
        if res == nil then return nil, err end
        return entry
    end
    local ok, err = pcall(function()
        space:replace({
            entry.id,
            entry.yaml,
            entry.user or '',
            entry.ts,
            entry.expires_at,
        })
    end)
    if not ok then return nil, tostring(err) end
    return entry
end

local function delete_prepared(id)
    local space = storage.prepared()
    if space == nil then return end
    if is_read_only() then
        forward_to_leader('webui_prepared_delete_remote', { id })
        return
    end
    pcall(function() space:delete({ id }) end)
end

-- ─────────────────────────────────────────────────────────────────────
-- Public surface
-- ─────────────────────────────────────────────────────────────────────

-- prepare(opts):
--   * `yaml` (string)            required
--   * `user` (string)            optional; only carried in audit/log
--   * `current_yaml` (string)    optional; if present, returned diff
--                                is computed against it
-- Returns (result, nil) on success, (nil, errors[]) otherwise.
function M.prepare(opts)
    opts = opts or {}
    gc()
    local parsed, errs = schema.validate(opts.yaml)
    if parsed == nil then return nil, errs end

    -- Advisory guardrails (FO-11): non-blocking — surfaced in the
    -- prepare result for the SPA preview and logged, but do NOT reject
    -- the commit (hard rejects live in schema.cross_validate).
    local warnings = schema.guardrail_warnings(parsed)
    if #warnings > 0 then
        logger.warn('config guardrail warnings', {
            count = #warnings, user = opts.user,
            first = warnings[1] and warnings[1].message,
        })
    end

    -- No-op guard: reject the prepare only when the submitted YAML is
    -- byte-for-byte identical to the current one — comment-only and
    -- whitespace-only edits are legitimate (audit trail, formatting
    -- pass) and must not be silently swallowed. The structural diff
    -- is then computed for the SPA preview, but its emptiness alone
    -- is not a rejection reason — a YAML parser drops comments, and
    -- "structurally same" ≠ "textually same".
    --
    -- Diff is computed BEFORE writing the prepared row so a real
    -- no-op leaves no garbage behind in `_webui_prepared`.
    local diff_ops
    if opts.current_yaml then
        if opts.yaml == opts.current_yaml then
            logger.info('prepare no-op rejected (byte-identical)', {
                user = opts.user, size = #opts.yaml,
            })
            return nil, { {
                code    = 'NO_CHANGES',
                message = 'submitted YAML is identical to current',
            } }
        end
        local current_parsed = select(1, schema.validate(opts.current_yaml))
        if current_parsed ~= nil then
            diff_ops = diff.structural(current_parsed, parsed)
        end
    end

    local now = fiber.time()
    local entry = {
        id          = new_prepared_id(),
        yaml        = opts.yaml,
        user        = opts.user,
        ts          = now,
        expires_at  = now + M.PREPARED_TTL_SEC,
    }
    local stored, put_err = put_prepared(entry)
    if stored == nil then return nil, { { message = put_err } } end

    logger.info('prepare ok', { id = entry.id, user = opts.user, size = #opts.yaml })
    return {
        prepared_id = entry.id,
        expires_at  = entry.expires_at,
        diff        = diff_ops or {},
        categories  = diff_ops and diff.categorise(diff_ops) or nil,
        warnings    = warnings,
    }
end

-- commit(prepared_id, opts):
--   * `etcd`              etcd client (Task 30)
--   * `expected_revision` optional; CAS guard
function M.commit(prepared_id, opts)
    gc()
    opts = opts or {}
    local space = storage.prepared()
    if space == nil then return nil, 'PREPARED_NOT_FOUND' end
    local tuple = space:get({ prepared_id })
    local entry = tuple_to_entry(tuple)
    if entry == nil then
        return nil, 'PREPARED_NOT_FOUND'
    end
    if opts.etcd == nil then
        -- No etcd configured: treat commit as a no-op apart from
        -- removing the prepared entry. Useful for dry-run smoke.
        delete_prepared(prepared_id)
        return { revision = 0, dry_run = true }
    end

    -- FO-8: refuse to commit when the etcd control-plane has lost
    -- quorum. A write without quorum cannot durably land — failing fast
    -- here returns a clear error instead of a confusing timeout, and
    -- avoids the file-mirror / reload fan-out running against a write
    -- that never committed. We only block on a DEFINITE loss (we reached
    -- at least one member and a majority is NOT in quorum); a total
    -- outage (no member reachable) falls through to the write, whose own
    -- error path reports the transport failure.
    if type(opts.etcd.cluster_health) == 'function' then
        local ok_h, health = pcall(function() return opts.etcd:cluster_health() end)
        if ok_h and type(health) == 'table'
            and health.has_quorum == false and health.reachable > 0 then
            logger.error('commit refused: etcd quorum lost', {
                total = health.total, in_quorum = health.in_quorum,
                needed = health.needed, reachable = health.reachable,
            })
            return nil, string.format(
                'ETCD_QUORUM_LOST: %d/%d etcd members in quorum (need %d); '
                .. 'config commit aborted to avoid a non-durable write',
                health.in_quorum, health.total, health.needed)
        end
    end

    local payload = entry.yaml
    local result, err
    if opts.expected_revision then
        result, err = opts.etcd:cas_cluster_config(payload, opts.expected_revision)
    else
        result, err = opts.etcd:write_cluster_config(payload)
    end
    if result == nil then return nil, err end
    delete_prepared(prepared_id)
    logger.info('commit ok', {
        id = prepared_id, revision = result.revision, user = entry.user,
    })

    -- Mirror the YAML to the on-disk file on EVERY peer (atomic rename
    -- or in-place truncate-and-write — see file_writer.lua). The file
    -- is the recovery source when etcd is unreachable at cold start;
    -- keep it in lockstep with the etcd source of truth. Fan-out is
    -- best-effort: per-peer outcome is captured in `result.file_mirror`
    -- so the resolver can surface partial failures (e.g. one read-only
    -- volume on a single peer) to the operator without rolling back
    -- the etcd commit. etcd is authoritative — the file is the cache.
    do
        local mirror = { ok = {}, failed = {}, skipped_no_peers = true }
        local fw_ok, fw = pcall(require, 'webui.config_store.file_writer')
        if fw_ok then
            local self_ok, self_err = fw.write_local(payload)
            if self_ok then
                table.insert(mirror.ok, '_self')
            else
                table.insert(mirror.failed, '_self=' .. tostring(self_err))
            end
        end
        local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
        local peers_ok, peers = pcall(require, 'webui.cluster.peers')
        if rpc_ok and peers_ok then
            local peer_names = {}
            for name in pairs(peers.list() or {}) do
                table.insert(peer_names, name)
            end
            if #peer_names > 0 then
                mirror.skipped_no_peers = false
                local call_ok, per_peer = pcall(rpc.map_call,
                    'webui_config_file_write_remote', { payload },
                    { timeout = 5, peers = peer_names })
                if call_ok and type(per_peer) == 'table' then
                    for name, r in pairs(per_peer) do
                        if r and r.ok and r.value and r.value.path
                            and not r.value.err then
                            table.insert(mirror.ok, name)
                        else
                            local msg = (r and r.err)
                                or (r and r.value and r.value.err)
                                or 'unknown'
                            table.insert(mirror.failed,
                                name .. '=' .. tostring(msg))
                        end
                    end
                else
                    table.insert(mirror.failed,
                        'fan-out errored: ' .. tostring(per_peer))
                end
            end
        end
        result.file_mirror = mirror
        if #mirror.failed > 0 then
            logger.warn('cluster.yaml mirror partial', {
                ok = mirror.ok, failed = mirror.failed,
            })
        else
            logger.info('cluster.yaml mirror ok', { peers = mirror.ok })
        end
    end

    -- Opt-in: force `config:reload()` on every peer (and self) after
    -- the new YAML has landed in etcd AND on each peer's local file
    -- (file_mirror above). Without this each peer would only refresh
    -- on its own polling tick, which makes a fresh bootstrap UX feel
    -- "did anything happen?" — the reload makes the new replication
    -- topology apply immediately. Existing call-sites (commitConfig
    -- from the config-editor) leave the flag off so running clusters
    -- pick up changes on their own cadence — same behaviour as before.
    --
    -- Best-effort: per-peer outcome is captured in
    -- `result.reload_failures`; partial failures do not roll back the
    -- etcd commit (etcd is authoritative). Self reload is counted in
    -- `reloaded_count` alongside peers.
    if opts.fanout_reload == true then
        local reloaded_count = 0
        local reload_failures = {}

        local self_t0 = fiber.time()
        local self_ok, self_err = pcall(function()
            require('config'):reload()
        end)
        local self_ms = math.floor((fiber.time() - self_t0) * 1000)
        if self_ok then
            reloaded_count = reloaded_count + 1
            logger.debug('fanout_reload self ok', { elapsed_ms = self_ms })
        else
            table.insert(reload_failures, {
                alias = '_self', err = tostring(self_err),
            })
            logger.warn('fanout_reload self failed', {
                err = tostring(self_err), elapsed_ms = self_ms,
            })
        end

        local rpc_ok2, rpc2 = pcall(require, 'webui.cluster.rpc')
        local peers_ok2, peers2 = pcall(require, 'webui.cluster.peers')
        if rpc_ok2 and peers_ok2 then
            local peer_names = {}
            for name in pairs(peers2.list() or {}) do
                table.insert(peer_names, name)
            end
            if #peer_names == 0 then
                logger.warn('fanout_reload no peers', {
                    reason = 'peers.list() empty',
                })
            else
                logger.info('fanout_reload start', {
                    prepared_id = prepared_id,
                    peers_count = #peer_names,
                })
                local t0 = fiber.time()
                local call_ok, per_peer = pcall(rpc2.map_call,
                    'webui_config_reload_remote', {},
                    { timeout = 5, peers = peer_names })
                local elapsed_ms = math.floor((fiber.time() - t0) * 1000)
                if call_ok and type(per_peer) == 'table' then
                    for name, r in pairs(per_peer) do
                        local val = r and r.value
                        if r and r.ok and type(val) == 'table' and val.ok
                            and not val.err then
                            reloaded_count = reloaded_count + 1
                            logger.debug('fanout_reload peer ok', {
                                alias = name,
                                status = val.status,
                                elapsed_ms = val.elapsed_ms,
                            })
                        else
                            local msg = (r and r.err)
                                or (val and val.err)
                                or 'unknown'
                            table.insert(reload_failures, {
                                alias = name, err = tostring(msg),
                            })
                            logger.warn('fanout_reload peer failed', {
                                alias = name, err = tostring(msg),
                            })
                        end
                    end
                else
                    table.insert(reload_failures, {
                        alias = '_fanout',
                        err = 'map_call errored: ' .. tostring(per_peer),
                    })
                    logger.warn('fanout_reload map_call errored', {
                        err = tostring(per_peer),
                    })
                end
                logger.info('fanout_reload done', {
                    reloaded = reloaded_count,
                    failed = #reload_failures,
                    total = #peer_names + 1,
                    total_elapsed_ms = elapsed_ms,
                })
            end
        else
            logger.warn('fanout_reload modules unavailable', {
                rpc_ok = rpc_ok2, peers_ok = peers_ok2,
            })
        end

        result.reloaded_count = reloaded_count
        result.reload_failures = reload_failures
    end

    -- Record the snapshot in our own /history/ timeline. We deliberately
    -- key the history entry by etcd's commit revision so the timeline
    -- maps 1:1 to what `:get('config')` would return at that point. Soft
    -- failure: a history write blowing up must NOT roll back the commit
    -- itself — operators expect "committed" to mean "the cluster will
    -- pick it up", not "the timeline panel will render it".
    if result.revision ~= nil then
        pcall(function()
            local _, h_err = history.record(opts.etcd, result.revision, payload)
            if h_err then
                logger.warn('history snapshot record failed', {
                    revision = result.revision, err = h_err,
                })
            end
            local meta_ok, meta_err = history.record_metadata(opts.etcd,
                result.revision, {
                    ts     = fiber.time(),
                    user   = entry.user,
                    size   = #payload,
                    hash   = digest.sha1_hex(payload):sub(1, 16),
                    action = opts.action or 'commit',
                })
            if meta_ok == nil and meta_err ~= nil then
                logger.warn('history metadata record failed', {
                    revision = result.revision, err = meta_err,
                })
            end
        end)
    end

    pcall(function()
        require('webui.notifications').emit({
            type     = 'config.committed',
            severity = 'info',
            user     = entry.user,
            scope    = 'cluster',
            category = 'config',
            message  = 'Cluster config committed (revision '
                .. tostring(result.revision) .. ')',
        })
    end)
    return result
end

function M.abort(prepared_id)
    local space = storage.prepared()
    if space == nil or space:get({ prepared_id }) == nil then
        return nil, 'PREPARED_NOT_FOUND'
    end
    delete_prepared(prepared_id)
    logger.info('abort ok', { id = prepared_id })
    return true
end

-- ── Read accessors used by the GraphQL resolver and tests ────────────

function M.get_prepared(id)
    gc()
    local space = storage.prepared()
    if space == nil then return nil end
    return tuple_to_entry(space:get({ id }))
end

function M.list_prepared()
    gc()
    local out = {}
    local space = storage.prepared()
    if space == nil then return out end
    for _, tuple in space:pairs() do
        table.insert(out, tuple_to_entry(tuple))
    end
    return out
end

function M._reset()
    local space = storage.prepared()
    if space == nil then return end
    if box.info and box.info.ro then return end
    pcall(function() space:truncate() end)
end

return M
