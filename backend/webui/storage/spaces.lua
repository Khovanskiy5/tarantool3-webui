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
    META                = '_webui_meta',
    SESSIONS            = '_webui_sessions',
    AUDIT               = '_webui_audit',
    WEBHOOK_QUEUE       = '_webui_webhook_queue',
    WEBHOOK_DEAD_LETTER = '_webui_webhook_dead_letter',
    PREPARED            = '_webui_prepared',
    FAILOVER_COMMANDS   = '_webui_failover_commands',
    SAVED_QUERIES       = '_webui_saved_queries',
}

-- Bumped by migrations. Every schema change adds an entry to
-- backend/webui/storage/migrations.lua and bumps this constant in
-- lockstep. Fresh installs go straight to CURRENT; existing
-- deployments roll forward through the catalog.
--
-- Version log:
--   1 — baseline. Three spaces created at boot.
--   2 — by_user secondary on _webui_audit for faster filter-by-user.
--   3 — _webui_webhook_queue + _webui_webhook_dead_letter spaces
--       for the outbound notifications dispatcher.
--   4 — _webui_prepared for the two-phase commit pipeline. The
--       prepared entry must outlive a single instance so the user
--       can prepare on one peer and commit on another (round-robin
--       balanced cluster, no session-pinning required).
--   5 — Flip every replicated WebUI space to `is_sync = true`.
--       Required under the open-source supervised-failover agent:
--       writes acknowledged by one peer MUST survive an
--       immediate leader crash, otherwise the data the API just
--       confirmed disappears on the next promote. Local space
--       `_webui_meta` stays async because it never replicates.
--   6 — `_webui_failover_commands` (TCM-style journal for every
--       operator-issued cluster mutation: promote, pause,
--       force_apply, expel, set_failover_mode). Replicated +
--       sync. Time-based retention (default 30 days, 1000/tick)
--       runs on the leader; see backend/webui/failover/commands.lua.
--   7 — `_webui_saved_queries` (SQL workbench library — Phase 3
--       Task 3.4). Per-user snippets with optional `shared = true`
--       visibility. Replicated + sync so a saved query the
--       operator wrote on leader survives an immediate failover.
M.CURRENT_SCHEMA_VERSION = 7

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
        -- is_sync=true → every INSERT/UPDATE/DELETE waits for
        -- replication-quorum confirmation before commit. Required
        -- under the supervised-failover agent: a session row that
        -- is acknowledged to the user MUST survive an immediate
        -- leader crash, otherwise the cookie we just issued points
        -- at a non-existent row on the new leader.
        is_sync = true,
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
        -- is_sync=true → audit entries are quorum-confirmed before
        -- the originating request returns. Compliance frameworks
        -- (SOX/PCI/ISO27001) treat "security event recorded" as a
        -- contract; an async row that is lost on leader crash
        -- breaks the contract. The write latency cost is paid
        -- once per request and is dwarfed by the request itself.
        is_sync = true,
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
    -- User-scoped filter (Task 24a migration 2). Fresh installs
    -- get the index here; existing deployments pick it up via the
    -- migration runner. Either path produces the same DDL.
    box.space[M.NAMES.AUDIT]:create_index('by_user', {
        parts          = { { field = 'user', is_nullable = true } },
        unique         = false,
        if_not_exists  = true,
    })
    return true
end

-- Outbound notifications queue (Task 53a). Replicated so a
-- leader change does not drop pending deliveries; the dispatcher
-- fiber runs only on the leader and consumes rows by the
-- `next_attempt_at` secondary so it can pick the oldest due
-- entry in O(log n).
local function ensure_webhook_queue()
    if box.space[M.NAMES.WEBHOOK_QUEUE] ~= nil then return false end
    box.schema.space.create(M.NAMES.WEBHOOK_QUEUE, {
        if_not_exists = true,
        -- is_sync=true → outbox guarantees at-least-once delivery
        -- even when the dispatcher's leader crashes mid-tick.
        -- Without sync, an enqueue that the API confirmed back to
        -- the caller could be lost if the leader dies before
        -- replication catches up, silently dropping the event.
        is_sync = true,
        format = {
            { name = 'id',              type = 'unsigned' },
            { name = 'enqueued_at',     type = 'unsigned' },
            { name = 'next_attempt_at', type = 'unsigned' },
            { name = 'attempt',         type = 'unsigned' },
            { name = 'webhook',         type = 'string' },
            { name = 'event',           type = 'any' },
            { name = 'last_error',      type = 'string', is_nullable = true },
        },
    })
    box.space[M.NAMES.WEBHOOK_QUEUE]:create_index('primary', {
        parts          = { 'id' },
        sequence       = true,
        if_not_exists  = true,
    })
    box.space[M.NAMES.WEBHOOK_QUEUE]:create_index('by_next_attempt', {
        parts          = { 'next_attempt_at', 'id' },
        unique         = false,
        if_not_exists  = true,
    })
    return true
end

-- Two-phase commit prepared entries. Replicated so a prepare()
-- on tt-1 can be commit()-ed on tt-2 — the round-robin balancer
-- has no obligation to land both calls on the same instance.
-- TTL is enforced by the gc() pass at the top of every twophase
-- call; we keep the row instead of relying on an in-memory cache
-- so a leader change between prepare and commit doesn't drop the
-- bundle on the floor.
local function ensure_prepared()
    if box.space[M.NAMES.PREPARED] ~= nil then return false end
    box.schema.space.create(M.NAMES.PREPARED, {
        if_not_exists = true,
        -- is_sync=true → the two-phase commit contract demands
        -- that a prepared bundle survives any single-instance
        -- failure between prepare() and commit(). Without sync, a
        -- prepare that the API acknowledged could vanish on
        -- leader crash; the SPA would then see PREPARED_NOT_FOUND
        -- on commit even though the operator was told prepare
        -- succeeded.
        is_sync = true,
        format = {
            { name = 'id',          type = 'string' },
            { name = 'yaml',        type = 'string' },
            { name = 'user',        type = 'string',   is_nullable = true },
            { name = 'ts',          type = 'number' },
            { name = 'expires_at',  type = 'number' },
        },
    })
    box.space[M.NAMES.PREPARED]:create_index('primary', {
        parts          = { 'id' },
        if_not_exists  = true,
    })
    box.space[M.NAMES.PREPARED]:create_index('by_expires_at', {
        parts          = { 'expires_at' },
        unique         = false,
        if_not_exists  = true,
    })
    return true
end

-- Dead-letter for events that exhausted their retry budget. Kept
-- replicated for operator review; the dispatcher never reads
-- back from this space.
local function ensure_webhook_dead_letter()
    if box.space[M.NAMES.WEBHOOK_DEAD_LETTER] ~= nil then return false end
    box.schema.space.create(M.NAMES.WEBHOOK_DEAD_LETTER, {
        if_not_exists = true,
        -- is_sync=true → the DLQ is the operator's source of
        -- truth for "what we could not deliver". Losing entries
        -- silently on a leader crash would mean operators see a
        -- shorter problem list than reality and miss actionable
        -- failures. Same quorum cost as the queue it complements.
        is_sync = true,
        format = {
            { name = 'id',           type = 'unsigned' },
            { name = 'failed_at',    type = 'unsigned' },
            { name = 'webhook',      type = 'string' },
            { name = 'event',        type = 'any' },
            { name = 'attempts',     type = 'unsigned' },
            { name = 'last_error',   type = 'string', is_nullable = true },
        },
    })
    box.space[M.NAMES.WEBHOOK_DEAD_LETTER]:create_index('primary', {
        parts          = { 'id' },
        sequence       = true,
        if_not_exists  = true,
    })
    return true
end

-- TCM-style commands journal (Task 5.13). Every operator mutation
-- on cluster state (promote, pause/resume, force_apply, expel,
-- set_failover_mode) writes a row that walks pending → taken →
-- success/failed. Replicated + sync so the leader's view never
-- diverges from followers; the SPA reads it for the "command
-- history" tab.
local function ensure_failover_commands()
    if box.space[M.NAMES.FAILOVER_COMMANDS] ~= nil then return false end
    box.schema.space.create(M.NAMES.FAILOVER_COMMANDS, {
        if_not_exists = true,
        is_sync       = true,
        format = {
            { name = 'id',           type = 'unsigned' },
            { name = 'ts',           type = 'number' },
            { name = 'command_type', type = 'string' },
            { name = 'params',       type = 'any',    is_nullable = true },
            { name = 'status',       type = 'string' },  -- pending|taken|success|failed
            { name = 'user',         type = 'string', is_nullable = true },
            { name = 'coordinator',  type = 'string', is_nullable = true },
            { name = 'taken_at',     type = 'number', is_nullable = true },
            { name = 'completed_at', type = 'number', is_nullable = true },
            { name = 'error_reason', type = 'string', is_nullable = true },
        },
    })
    box.space[M.NAMES.FAILOVER_COMMANDS]:create_index('primary', {
        parts          = { 'id' },
        sequence       = true,
        if_not_exists  = true,
    })
    box.space[M.NAMES.FAILOVER_COMMANDS]:create_index('by_ts', {
        parts          = { 'ts' },
        unique         = false,
        if_not_exists  = true,
    })
    box.space[M.NAMES.FAILOVER_COMMANDS]:create_index('by_status', {
        parts          = { 'status', 'id' },
        unique         = false,
        if_not_exists  = true,
    })
    return true
end

-- SQL workbench library (Phase 3 Task 3.4). One row per saved
-- snippet: id (auto), name, sql, owner, created_at, shared,
-- tags. Visibility rules (enforced in the resolver): the owner
-- always sees; admins always see; shared = true means every
-- authenticated user with at least `operator` sees. Replicated +
-- sync so an operator's library survives a leader crash.
local function ensure_saved_queries()
    if box.space[M.NAMES.SAVED_QUERIES] ~= nil then return false end
    box.schema.space.create(M.NAMES.SAVED_QUERIES, {
        if_not_exists = true,
        is_sync       = true,
        format = {
            { name = 'id',         type = 'unsigned' },
            { name = 'name',       type = 'string' },
            { name = 'sql',        type = 'string' },
            { name = 'owner',      type = 'string' },
            { name = 'created_at', type = 'number' },
            { name = 'shared',     type = 'boolean' },
            { name = 'tags',       type = 'array', is_nullable = true },
        },
    })
    box.space[M.NAMES.SAVED_QUERIES]:create_index('primary', {
        parts          = { 'id' },
        sequence       = true,
        if_not_exists  = true,
    })
    box.space[M.NAMES.SAVED_QUERIES]:create_index('by_owner', {
        parts          = { 'owner', 'id' },
        unique         = false,
        if_not_exists  = true,
    })
    box.space[M.NAMES.SAVED_QUERIES]:create_index('by_shared', {
        parts          = { 'shared', 'id' },
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
    local created_webhook_queue       = ensure_webhook_queue()
    local created_webhook_dead_letter = ensure_webhook_dead_letter()
    local created_prepared            = ensure_prepared()
    local created_failover_commands   = ensure_failover_commands()
    local created_saved_queries       = ensure_saved_queries()

    local current = M.get_schema_version()
    local migrations_applied = 0
    if current == nil then
        -- Fresh install. Set baseline directly; the migration
        -- runner only kicks in when an existing deployment needs
        -- to roll forward.
        set_schema_version(M.CURRENT_SCHEMA_VERSION)
        current = M.CURRENT_SCHEMA_VERSION
        logger.info('storage schema initialised', { version = current })
    elseif current > M.CURRENT_SCHEMA_VERSION then
        return nil, string.format(
            'stored schema_version %d is newer than this build supports (%d)',
            current, M.CURRENT_SCHEMA_VERSION)
    elseif current < M.CURRENT_SCHEMA_VERSION then
        -- Roll forward via the migration catalog.
        local migrations = require('webui.storage.migrations')
        local result, err = migrations.run({
            meta_space      = box.space[M.NAMES.META],
            current_version = current,
            target_version  = M.CURRENT_SCHEMA_VERSION,
        })
        if result == nil then return nil, err end
        migrations_applied = #result.applied
        current = M.CURRENT_SCHEMA_VERSION
    end

    logger.info('storage spaces ready', {
        version             = current,
        created_meta        = created_meta,
        created_sessions    = created_sessions,
        created_audit       = created_audit,
        created_webhook_queue       = created_webhook_queue,
        created_webhook_dead_letter = created_webhook_dead_letter,
        created_prepared    = created_prepared,
        created_failover_commands   = created_failover_commands,
        created_saved_queries       = created_saved_queries,
        migrations_applied  = migrations_applied,
    })

    return {
        schema_version    = current,
        created_meta      = created_meta,
        created_sessions  = created_sessions,
        created_audit     = created_audit,
        created_prepared  = created_prepared,
        created_webhook_queue       = created_webhook_queue,
        created_webhook_dead_letter = created_webhook_dead_letter,
        created_failover_commands   = created_failover_commands,
        created_saved_queries       = created_saved_queries,
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

function M.meta()         return box.space[M.NAMES.META]         end
function M.sessions()     return box.space[M.NAMES.SESSIONS]     end
function M.audit()        return box.space[M.NAMES.AUDIT]        end
function M.prepared()     return box.space[M.NAMES.PREPARED]     end
function M.webhook_queue()       return box.space[M.NAMES.WEBHOOK_QUEUE]       end
function M.webhook_dead_letter() return box.space[M.NAMES.WEBHOOK_DEAD_LETTER] end
function M.failover_commands()   return box.space[M.NAMES.FAILOVER_COMMANDS]   end
function M.saved_queries()       return box.space[M.NAMES.SAVED_QUERIES]       end

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
