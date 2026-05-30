--
-- Internal storage spaces bootstrap.
--
-- Three system spaces back the M2 features:
--
--   * `_webui_meta`       per-instance key/value scratch (peer
--                          cookie, schema version, future
--                          settings). `is_local = true` so values
--                          stay on the host that wrote them. The
--                          space was originally created by
--                          peer_cookie (Task 15); this module
--                          extends ownership so the rest of M2
--                          can read/write the same table.
--   * `_webui_sessions`   browser sessions for the admin SPA.
--                          Replicated so the same cookie keeps
--                          working when the user is balanced
--                          across instances (Task 25). TTL is
--                          enforced by a sweeper fiber rather
--                          than the secondary index — the index
--                          is just there to make the sweep cheap.
--   * `_webui_audit`      append-only log of security-relevant
--                          actions (login, config commit, …).
--                          Replicated; the writer fiber lives in
--                          audit/log.lua (Task 26).
--
-- DDL is idempotent and lives behind `box.is_in_txn` /
-- `box.info.ro` guards so the same `bootstrap()` call is safe to
-- run on every instance — the leader creates the schema and
-- replication pushes it to everyone else. The function returns
-- the current `schema_version` so the caller can decide whether
-- to run migrations (Task 24a).
--

local checks = require('checks')
local fiber  = require('fiber')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('storage')

local M = {}

M.NAMES = {
    META     = '_webui_meta',
    SESSIONS = '_webui_sessions',
    AUDIT    = '_webui_audit',
}

-- Bumped by migrations. Baseline is 1 — every subsequent migration
-- step (Task 24a) walks `migrations[N]` from the stored value up
-- to this constant.
M.CURRENT_SCHEMA_VERSION = 1

local SCHEMA_VERSION_KEY = 'schema_version'

-- ─────────────────────────────────────────────────────────────────────
-- Pure helpers (unit-testable)
-- ─────────────────────────────────────────────────────────────────────

-- Decide whether the local instance is allowed to mutate the
-- schema. DDL must happen on the leader; replicas pick up the
-- change through replication. Returns `(true, nil)` when DDL is
-- safe, `(false, reason)` otherwise.
function M.can_run_ddl()
    if rawget(_G, 'box') == nil then
        return false, 'box not initialised'
    end
    local ok, info = pcall(function() return box.info end)
    if not ok or type(info) ~= 'table' then
        return false, 'box.info unavailable'
    end
    if info.ro == true then
        return false, info.ro_reason or 'read_only'
    end
    return true, nil
end

-- ─────────────────────────────────────────────────────────────────────
-- Space creation
-- ─────────────────────────────────────────────────────────────────────

local function ensure_meta()
    if box.space[M.NAMES.META] ~= nil then return false end
    box.schema.space.create(M.NAMES.META, {
        if_not_exists = true,
        is_local      = true,
        format = {
            { name = 'key',   type = 'string' },
            { name = 'value', type = 'string' },
        },
    })
    box.space[M.NAMES.META]:create_index('primary', {
        parts          = { 'key' },
        if_not_exists  = true,
    })
    return true
end

local function ensure_sessions()
    if box.space[M.NAMES.SESSIONS] ~= nil then return false end
    box.schema.space.create(M.NAMES.SESSIONS, {
        if_not_exists = true,
        format = {
            { name = 'id',          type = 'string' },
            { name = 'user',        type = 'string' },
            { name = 'created_at',  type = 'unsigned' },
            { name = 'expires_at',  type = 'unsigned' },
            { name = 'csrf',        type = 'string' },
            { name = 'ip',          type = 'string',  is_nullable = true },
            { name = 'user_agent',  type = 'string',  is_nullable = true },
        },
    })
    box.space[M.NAMES.SESSIONS]:create_index('primary', {
        parts          = { 'id' },
        if_not_exists  = true,
    })
    -- Secondary by expires_at lets the sweeper fiber drop expired
    -- rows in O(expired) without scanning the whole space.
    box.space[M.NAMES.SESSIONS]:create_index('by_expires_at', {
        parts          = { 'expires_at' },
        unique         = false,
        if_not_exists  = true,
    })
    return true
end

local function ensure_audit()
    if box.space[M.NAMES.AUDIT] ~= nil then return false end
    box.schema.space.create(M.NAMES.AUDIT, {
        if_not_exists = true,
        format = {
            { name = 'id',          type = 'unsigned' },
            { name = 'ts',          type = 'unsigned' },
            { name = 'user',        type = 'string',  is_nullable = true },
            { name = 'action',      type = 'string' },
            { name = 'scope',       type = 'string',  is_nullable = true },
            { name = 'payload',     type = 'any',     is_nullable = true },
            { name = 'request_id',  type = 'string',  is_nullable = true },
        },
    })
    box.space[M.NAMES.AUDIT]:create_index('primary', {
        parts          = { 'id' },
        sequence       = true,
        if_not_exists  = true,
    })
    -- Time-range filters drive the admin UI's audit page (Task 26a).
    box.space[M.NAMES.AUDIT]:create_index('by_ts', {
        parts          = { 'ts' },
        unique         = false,
        if_not_exists  = true,
    })
    return true
end

-- ─────────────────────────────────────────────────────────────────────
-- Schema version
-- ─────────────────────────────────────────────────────────────────────

function M.get_schema_version()
    if rawget(_G, 'box') == nil
        or box.space[M.NAMES.META] == nil then
        return nil
    end
    local tuple = box.space[M.NAMES.META]:get({ SCHEMA_VERSION_KEY })
    if tuple == nil then return nil end
    return tonumber(tuple.value)
end

local function set_schema_version(version)
    box.space[M.NAMES.META]:replace({ SCHEMA_VERSION_KEY, tostring(version) })
end

-- ─────────────────────────────────────────────────────────────────────
-- Public bootstrap
-- ─────────────────────────────────────────────────────────────────────

-- Pure leader-side bootstrap. Pulled out so the deferred fiber
-- can re-use it once the instance transitions to read-write.
local function bootstrap_as_leader()
    local created_meta     = ensure_meta()
    local created_sessions = ensure_sessions()
    local created_audit    = ensure_audit()

    local current = M.get_schema_version()
    if current == nil then
        set_schema_version(M.CURRENT_SCHEMA_VERSION)
        current = M.CURRENT_SCHEMA_VERSION
        logger.info('storage schema initialised', { version = current })
    elseif current > M.CURRENT_SCHEMA_VERSION then
        return nil, string.format(
            'stored schema_version %d is newer than this build supports (%d)',
            current, M.CURRENT_SCHEMA_VERSION)
    end

    logger.info('storage spaces ready', {
        version          = current,
        created_meta     = created_meta,
        created_sessions = created_sessions,
        created_audit    = created_audit,
    })

    return {
        schema_version    = current,
        created_meta      = created_meta,
        created_sessions  = created_sessions,
        created_audit     = created_audit,
        deferred          = false,
    }
end

-- Fork a daemon that waits for this instance to become read-write
-- and runs the leader path on transition. Same pattern as
-- cluster.peer_cookie — at most one daemon per role lifecycle.
local provisioner_started = false
local function start_background_provisioner()
    if provisioner_started then return end
    provisioner_started = true
    fiber.create(function()
        fiber.name('webui_storage_provisioner', { truncate = true })
        local wait_ok, wait_err = pcall(function()
            box.ctl.wait_rw()
        end)
        if not wait_ok then
            logger.warn('wait_rw failed; storage stays deferred', {
                err = tostring(wait_err),
            })
            return
        end
        logger.info('instance became read-write; provisioning storage')
        local ok, err = pcall(bootstrap_as_leader)
        if not ok then
            logger.error('deferred storage provisioning failed', {
                err = tostring(err),
            })
        end
    end)
end

-- Returns `{schema_version, created_meta, created_sessions,
-- created_audit, deferred}` or `nil, err`. `deferred=true` means
-- the local instance is read-only — a daemon fiber will run the
-- DDL once it transitions to read-write; on a permanent replica
-- the schema arrives via replication.
function M.bootstrap()
    if rawget(_G, 'box') == nil then
        return nil, 'box is not initialised; storage.bootstrap called too early'
    end

    local can, reason = M.can_run_ddl()
    if not can then
        logger.info('storage DDL deferred — instance is read-only', {
            reason = reason,
        })
        start_background_provisioner()
        return {
            schema_version    = M.get_schema_version(),
            created_meta      = false,
            created_sessions  = false,
            created_audit     = false,
            deferred          = true,
        }
    end

    return bootstrap_as_leader()
end

-- ─────────────────────────────────────────────────────────────────────
-- Convenience getters
-- ─────────────────────────────────────────────────────────────────────

function M.meta()     return box.space[M.NAMES.META]     end
function M.sessions() return box.space[M.NAMES.SESSIONS] end
function M.audit()    return box.space[M.NAMES.AUDIT]    end

-- Generic key/value helpers around _webui_meta.
function M.meta_get(key)
    checks('string')
    local space = box.space[M.NAMES.META]
    if space == nil then return nil end
    local tuple = space:get({ key })
    return tuple and tuple.value or nil
end

function M.meta_put(key, value)
    checks('string', 'string')
    box.space[M.NAMES.META]:replace({ key, value })
end

-- Test hook.
function M._reset_schema_version()
    if box.space[M.NAMES.META] ~= nil then
        box.space[M.NAMES.META]:delete({ SCHEMA_VERSION_KEY })
    end
end

return M
