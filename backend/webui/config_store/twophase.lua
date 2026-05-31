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

local fiber = require('fiber')

local schema   = require('webui.config_store.schema')
local diff     = require('webui.config_store.diff')
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

    local diff_ops
    if opts.current_yaml then
        local current_parsed = select(1, schema.validate(opts.current_yaml))
        if current_parsed ~= nil then
            diff_ops = diff.structural(current_parsed, parsed)
        end
    end

    logger.info('prepare ok', { id = entry.id, user = opts.user, size = #opts.yaml })
    return {
        prepared_id = entry.id,
        expires_at  = entry.expires_at,
        diff        = diff_ops or {},
        categories  = diff_ops and diff.categorise(diff_ops) or nil,
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
    local payload = entry.yaml
    local result, err
    if opts.expected_revision then
        result, err = opts.etcd:txn_cas('config', payload, opts.expected_revision)
    else
        result, err = opts.etcd:put('config', payload)
    end
    if result == nil then return nil, err end
    delete_prepared(prepared_id)
    logger.info('commit ok', {
        id = prepared_id, revision = result.revision, user = entry.user,
    })
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
