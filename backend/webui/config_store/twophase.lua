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

local schema  = require('webui.config_store.schema')
local diff    = require('webui.config_store.diff')
local log_util = require('webui.log_util')
local logger  = log_util.with_tag('twophase')

local M = {}

M.PREPARED_TTL_SEC = 300 -- 5 min, same as the plan
local prepared = {} -- in-memory cache; sister space `_webui_prepared`
                     -- gets created in M3 task once schema migration
                     -- 2 ships.

local function new_prepared_id()
    return string.format('prep-%d-%d', math.floor(fiber.time() * 1000),
        math.random(1, 1000000))
end

-- Drop expired entries. Cheap to call before every read.
local function gc()
    local now = fiber.time()
    for id, entry in pairs(prepared) do
        if entry.expires_at <= now then
            prepared[id] = nil
            logger.warn('prepared TTL expired', { id = id })
        end
    end
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

    local id = new_prepared_id()
    local entry = {
        id          = id,
        yaml        = opts.yaml,
        parsed      = parsed,
        user        = opts.user,
        ts          = fiber.time(),
        expires_at  = fiber.time() + M.PREPARED_TTL_SEC,
    }
    prepared[id] = entry

    local diff_ops
    if opts.current_yaml then
        local current_parsed = select(1, schema.validate(opts.current_yaml))
        if current_parsed ~= nil then
            diff_ops = diff.structural(current_parsed, parsed)
        end
    end

    logger.info('prepare ok', { id = id, user = opts.user, size = #opts.yaml })
    return {
        prepared_id = id,
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
    local entry = prepared[prepared_id]
    if entry == nil then
        return nil, 'PREPARED_NOT_FOUND'
    end
    if opts.etcd == nil then
        -- No etcd configured: treat commit as a no-op apart from
        -- removing the prepared entry. Useful for dry-run smoke.
        prepared[prepared_id] = nil
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
    prepared[prepared_id] = nil
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
    if prepared[prepared_id] == nil then
        return nil, 'PREPARED_NOT_FOUND'
    end
    prepared[prepared_id] = nil
    logger.info('abort ok', { id = prepared_id })
    return true
end

-- ── Read accessors used by the GraphQL resolver and tests ────────────

function M.get_prepared(id)
    gc()
    return prepared[id]
end

function M.list_prepared()
    gc()
    local out = {}
    for _, entry in pairs(prepared) do table.insert(out, entry) end
    return out
end

function M._reset()
    prepared = {}
end

return M
