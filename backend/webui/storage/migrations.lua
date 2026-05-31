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
