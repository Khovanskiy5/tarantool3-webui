--
-- Schema migration runner.
--
-- Storage uses a single integer `schema_version` stored in
-- `_webui_meta`. Migrations are numbered: `migrations[N]` upgrades
-- the schema from version N-1 to N. They run on the leader in
-- ascending order, each inside its own transaction, with the new
-- version committed at the end of every step. Replication then
-- carries the DDL/DML to the followers.
--
-- Roll-forward only. A downgrade is an explicit operational
-- decision and forces a manual rollback; this module refuses to
-- start if the stored version is newer than the build's
-- CURRENT_VERSION.
--
-- Each migration step must be rolling-safe with the previous
-- version: the new schema is readable by the N-1 code so a peer
-- that has not yet applied the migration keeps working until
-- replication catches up. The N/N+1 compatibility window matches
-- what the plan documents.
--

local clock = require('clock')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('migrations')

local M = {}

-- Catalog. Add a new entry when a schema change ships. The function
-- signature is intentionally narrow: the runner passes only the
-- `box` namespace so a migration cannot reach into other modules.
M.migrations = {
    -- Baseline step. Existing deployments that wrote a 0 marker
    -- before this catalog landed get a clean forward path. The
    -- step is intentionally empty because storage.bootstrap
    -- itself creates the M2 spaces; this entry exists so the
    -- runner has something to advance.
    [1] = function(_box) end,

    -- Secondary index `by_user` on `_webui_audit`.
    --
    -- The audit-page filter accepts `user`. Until this step landed
    -- the resolver had to walk the by_ts index and discard rows
    -- inline; on a clean install the new index is created by
    -- `ensure_audit`, but pre-existing deployments need a
    -- migration to pick it up. The index part is nullable because
    -- `_webui_audit.user` is nullable (system actions like
    -- retention sweeps leave it empty), and the index is
    -- non-unique because the same operator emits many rows.
    [2] = function(box)
        local audit = box.space._webui_audit
        if audit == nil then
            -- Defensive: the space is created by storage.bootstrap
            -- before migrations run. If it is missing we are in a
            -- broken installation; the catch-all pcall in the
            -- runner will surface the error.
            error('migration 2: _webui_audit space is missing', 0)
        end
        if audit.index.by_user ~= nil then return end
        audit:create_index('by_user', {
            parts = { { field = 'user', is_nullable = true } },
            unique = false,
            if_not_exists = true,
        })
    end,

    -- Outbound notifications queue + dead-letter spaces (Task 53a).
    -- Both spaces are replicated; only the leader's dispatcher
    -- writes to them. Idempotent: a follower that already saw the
    -- replicated DDL hits the early-return branch when it later
    -- becomes leader.
    [3] = function(box)
        if box.space._webui_webhook_queue == nil then
            box.schema.space.create('_webui_webhook_queue', {
                if_not_exists = true,
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
            box.space._webui_webhook_queue:create_index('primary', {
                parts = { 'id' }, sequence = true, if_not_exists = true,
            })
            box.space._webui_webhook_queue:create_index('by_next_attempt', {
                parts = { 'next_attempt_at', 'id' },
                unique = false, if_not_exists = true,
            })
        end
        if box.space._webui_webhook_dead_letter == nil then
            box.schema.space.create('_webui_webhook_dead_letter', {
                if_not_exists = true,
                format = {
                    { name = 'id',         type = 'unsigned' },
                    { name = 'failed_at',  type = 'unsigned' },
                    { name = 'webhook',    type = 'string' },
                    { name = 'event',      type = 'any' },
                    { name = 'attempts',   type = 'unsigned' },
                    { name = 'last_error', type = 'string', is_nullable = true },
                },
            })
            box.space._webui_webhook_dead_letter:create_index('primary', {
                parts = { 'id' }, sequence = true, if_not_exists = true,
            })
        end
    end,

    -- _webui_prepared for the two-phase commit pipeline. The
    -- previous in-memory cache in twophase.lua broke under round-
    -- robin: prepare() on tt-1 made the prepared_id invisible to
    -- a commit() that landed on tt-2. Promoting the cache to a
    -- replicated space removes the affinity requirement.
    [4] = function(box)
        if box.space._webui_prepared == nil then
            box.schema.space.create('_webui_prepared', {
                if_not_exists = true,
                format = {
                    { name = 'id',          type = 'string' },
                    { name = 'yaml',        type = 'string' },
                    { name = 'user',        type = 'string',   is_nullable = true },
                    { name = 'ts',          type = 'number' },
                    { name = 'expires_at',  type = 'number' },
                },
            })
            box.space._webui_prepared:create_index('primary', {
                parts = { 'id' }, if_not_exists = true,
            })
            box.space._webui_prepared:create_index('by_expires_at', {
                parts = { 'expires_at' }, unique = false, if_not_exists = true,
            })
        end
    end,

    -- Make every replicated WebUI space synchronous. Required by
    -- the open-source supervised-failover agent: writes that the
    -- API acknowledged to the caller must survive an immediate
    -- leader crash, otherwise the new leader returns 404 / 401 /
    -- PREPARED_NOT_FOUND for state the caller already saw
    -- confirmed. `_webui_meta` is local (is_local=true, never
    -- replicates) and stays async.
    [5] = function(box)
        local sync_spaces = {
            '_webui_sessions',
            '_webui_audit',
            '_webui_webhook_queue',
            '_webui_webhook_dead_letter',
            '_webui_prepared',
        }
        for _, name in ipairs(sync_spaces) do
            local s = box.space[name]
            -- Idempotent: only ALTER if not already sync. The
            -- fresh-install path in storage/spaces.lua creates
            -- the space with is_sync=true so the alter() here is
            -- a no-op for new deployments.
            if s ~= nil and s.is_sync ~= true then
                s:alter({ is_sync = true })
            end
        end
    end,

    -- `_webui_failover_commands`: TCM-style commands journal for
    -- every operator-issued cluster mutation. Replicated + sync so
    -- the row the API just returned is durable across an immediate
    -- leader crash; without sync the operator would see "promote
    -- success" but find no audit-trail row on the new leader.
    [6] = function(box)
        if box.space._webui_failover_commands == nil then
            box.schema.space.create('_webui_failover_commands', {
                if_not_exists = true,
                is_sync       = true,
                format = {
                    { name = 'id',           type = 'unsigned' },
                    { name = 'ts',           type = 'number' },
                    { name = 'command_type', type = 'string' },
                    { name = 'params',       type = 'any',    is_nullable = true },
                    { name = 'status',       type = 'string' },
                    { name = 'user',         type = 'string', is_nullable = true },
                    { name = 'coordinator',  type = 'string', is_nullable = true },
                    { name = 'taken_at',     type = 'number', is_nullable = true },
                    { name = 'completed_at', type = 'number', is_nullable = true },
                    { name = 'error_reason', type = 'string', is_nullable = true },
                },
            })
            box.space._webui_failover_commands:create_index('primary', {
                parts = { 'id' }, sequence = true, if_not_exists = true,
            })
            box.space._webui_failover_commands:create_index('by_ts', {
                parts = { 'ts' }, unique = false, if_not_exists = true,
            })
            box.space._webui_failover_commands:create_index('by_status', {
                parts = { 'status', 'id' },
                unique = false, if_not_exists = true,
            })
        end
    end,

    -- SQL workbench library: `_webui_saved_queries` (Phase 3
    -- Task 3.4). Idempotent on existing deployments — the
    -- bootstrap path also creates the space on a fresh install;
    -- this step covers the rolling upgrade case where an
    -- existing cluster jumps from schema_version 6 to 7.
    [7] = function(box)
        if box.space._webui_saved_queries == nil then
            box.schema.space.create('_webui_saved_queries', {
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
            box.space._webui_saved_queries:create_index('primary', {
                parts = { 'id' }, sequence = true, if_not_exists = true,
            })
            box.space._webui_saved_queries:create_index('by_owner', {
                parts = { 'owner', 'id' }, unique = false, if_not_exists = true,
            })
            box.space._webui_saved_queries:create_index('by_shared', {
                parts = { 'shared', 'id' }, unique = false, if_not_exists = true,
            })
        end
    end,

    -- Tamper-evident audit hash chain (Phase 4 Task 4.1).
    -- Adds prev_hash / current_hash / chain_seal to the
    -- `_webui_audit` format and back-fills the chain over the
    -- existing tail in id-order. After this step every row links
    -- to the canonical hash of the previous one; verifier walks
    -- the chain in either direction.
    [8] = function(box)
        local audit = box.space._webui_audit
        if audit == nil then
            error('migration 8: _webui_audit space is missing', 0)
        end
        -- Extend format if not already at the new shape. format()
        -- on an existing space rewrites the layout; we only
        -- rewrite when the new fields are absent so a re-run is
        -- idempotent.
        local current_format = audit:format()
        local has_prev_hash = false
        for _, f in ipairs(current_format) do
            if f.name == 'prev_hash' then has_prev_hash = true; break end
        end
        if not has_prev_hash then
            local new_format = {}
            for _, f in ipairs(current_format) do table.insert(new_format, f) end
            table.insert(new_format, { name = 'prev_hash',
                type = 'string',  is_nullable = true })
            table.insert(new_format, { name = 'current_hash',
                type = 'string',  is_nullable = true })
            table.insert(new_format, { name = 'chain_seal',
                type = 'boolean', is_nullable = true })
            audit:format(new_format)
        end
        -- Backfill the chain over the existing tail. We re-derive
        -- the hash for every row in id-order. Skipping the
        -- backfill is technically rolling-safe (new code tolerates
        -- nil hashes, verifier treats the first non-nil row as
        -- the chain root), but compliance frameworks prefer a
        -- fully-sealed history from day one.
        local chain  = require('webui.audit.chain')
        local prev   = nil
        local count  = 0
        for _, tuple in audit:pairs() do
            -- Skip rows that already have a current_hash (re-run
            -- after a partial migration), but use them as the
            -- previous link for the next backfill.
            local existing = tuple.current_hash
            if existing ~= nil and existing ~= '' then
                prev = existing
            else
                local digest = chain.row_hash(prev, tuple)
                audit:update({ tuple.id }, {
                    { '=', 'prev_hash',    prev or box.NULL },
                    { '=', 'current_hash', digest },
                })
                prev = digest
                count = count + 1
            end
        end
        require('log').info(
            string.format('migration 8: hash chain backfilled for %d audit row(s)',
                count))
    end,

    -- Re-backfill the audit chain with the stable canonical
    -- form (Phase 4 Task 4.1 follow-up). Step 8 was correct in
    -- shape but used `json.encode` directly, whose key order is
    -- implementation-defined in LuaJIT and therefore
    -- non-reproducible. The verifier could not match recorded
    -- hashes to recomputed ones, so the chain looked broken on
    -- every cluster that ran step 8 against existing data.
    --
    -- This step forcibly recomputes prev_hash / current_hash for
    -- every row in id-order using the sorted-keys serializer
    -- from `webui.audit.chain`. Idempotent: a fresh install has
    -- no rows yet and skips immediately.
    [9] = function(box)
        local audit = box.space._webui_audit
        if audit == nil then
            error('migration 9: _webui_audit space is missing', 0)
        end
        local chain = require('webui.audit.chain')
        local prev = nil
        local count = 0
        for _, tuple in audit:pairs() do
            -- A pre-existing chain_seal still resets the link —
            -- retention may have already sealed mid-history.
            local sealed = tuple.chain_seal == true
            local digest = chain.row_hash(sealed and nil or prev, tuple)
            audit:update({ tuple.id }, {
                { '=', 'prev_hash',    (sealed and box.NULL) or (prev or box.NULL) },
                { '=', 'current_hash', digest },
            })
            prev = digest
            count = count + 1
        end
        require('log').info(
            string.format('migration 9: hash chain re-backfilled for %d audit row(s)',
                count))
    end,
    [10] = function(box)
        -- Local fallback session store, writable even under read_only so
        -- an operator can log in to drive recovery on a broken cluster.
        -- is_local DDL replicates (like _webui_meta) so every instance
        -- gets the space; the data stays per-instance.
        if box.space._webui_sessions_local ~= nil then return end
        box.schema.space.create('_webui_sessions_local', {
            if_not_exists = true,
            is_local      = true,
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
        box.space._webui_sessions_local:create_index('primary',
            { parts = { 'id' }, if_not_exists = true })
        box.space._webui_sessions_local:create_index('by_expires_at',
            { parts = { 'expires_at' }, unique = false, if_not_exists = true })
        require('log').info('migration 10: created _webui_sessions_local')
    end,
}

-- ─────────────────────────────────────────────────────────────────────
-- Pure planning helpers (unit-testable)
-- ─────────────────────────────────────────────────────────────────────

-- Build the ordered list of migration step numbers that move the
-- schema from `from_version` to `to_version`. Returns the list and
-- an error message when a required step is missing.
function M.plan(from_version, to_version, migrations)
    if type(from_version) ~= 'number' or type(to_version) ~= 'number' then
        return nil, 'plan: from/to must be numbers'
    end
    if to_version < from_version then
        return nil, string.format(
            'plan: refuse downgrade %d -> %d', from_version, to_version)
    end
    if to_version == from_version then return {} end
    migrations = migrations or {}
    local steps = {}
    for v = from_version + 1, to_version do
        if migrations[v] == nil then
            return nil, string.format(
                'plan: missing migration step %d', v)
        end
        table.insert(steps, v)
    end
    return steps
end

-- ─────────────────────────────────────────────────────────────────────
-- Runner
-- ─────────────────────────────────────────────────────────────────────

local SCHEMA_VERSION_KEY = 'schema_version'

local function persist_version(meta_space, version)
    meta_space:replace({ SCHEMA_VERSION_KEY, tostring(version) })
end

-- Apply every pending step. `opts.meta_space` is the _webui_meta
-- box.space handle, `opts.current_version` is the stored value,
-- `opts.target_version` is the build's CURRENT_SCHEMA_VERSION.
-- Returns `{from, to, applied = [N, ...], elapsed_ms}` or nil/err.
function M.run(opts)
    local from   = tonumber(opts.current_version) or 0
    local to     = tonumber(opts.target_version)
    local space  = opts.meta_space
    local steps_table = opts.migrations or M.migrations

    if space == nil then
        return nil, 'migrations.run: meta_space is required'
    end
    if to == nil then
        return nil, 'migrations.run: target_version is required'
    end
    if from > to then
        return nil, string.format(
            'stored schema_version %d is newer than CURRENT_SCHEMA_VERSION %d;'
            .. ' refusing to start (downgrade is unsafe)',
            from, to)
    end

    local steps, plan_err = M.plan(from, to, steps_table)
    if steps == nil then return nil, plan_err end
    if #steps == 0 then
        return { from = from, to = to, applied = {}, elapsed_ms = 0 }
    end

    logger.info('starting migrations', {
        from = from, to = to, step_count = #steps,
    })
    local applied = {}
    local started = clock.monotonic()
    for _, step in ipairs(steps) do
        local step_started = clock.monotonic()
        local ok, err = pcall(function()
            box.begin()
            local fn = steps_table[step]
            fn(box)
            persist_version(space, step)
            box.commit()
        end)
        if not ok then
            pcall(box.rollback)
            logger.error('migration failed; role start aborted', {
                step = step, err = tostring(err),
            })
            return nil, string.format(
                'migration to %d failed: %s', step, tostring(err))
        end
        table.insert(applied, step)
        logger.info('migration applied', {
            from = step - 1, to = step,
            elapsed_ms = (clock.monotonic() - step_started) * 1000,
        })
    end
    return {
        from = from,
        to = to,
        applied = applied,
        elapsed_ms = (clock.monotonic() - started) * 1000,
    }
end

return M
