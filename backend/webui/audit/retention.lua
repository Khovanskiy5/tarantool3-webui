--
-- Audit-log retention sweeper.
--
-- Once an hour (configurable) a fiber walks `_webui_audit` from
-- the oldest end of `by_ts` and drops every row older than the
-- retention horizon. Defaults follow the plan: 90 days, sweep
-- every hour. Sweeps only run on the cluster leader because the
-- space is replicated — running them on followers would attempt
-- writes against a read-only state.
--

local fiber = require('fiber')

local storage  = require('webui.storage.spaces')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('audit.retention')

local M = {}

M.DEFAULT_RETENTION_DAYS = 90
M.DEFAULT_TICK_SEC       = 3600
M.MAX_DELETIONS_PER_TICK = 5000  -- amortise long sweeps

local STATE = {
    fiber = nil,
    stop_flag = false,
    last_run_at = nil,
    last_deleted = 0,
    retention_sec = M.DEFAULT_RETENTION_DAYS * 86400,
    tick_sec = M.DEFAULT_TICK_SEC,
}

-- ─────────────────────────────────────────────────────────────────────
-- Pure helpers
-- ─────────────────────────────────────────────────────────────────────

-- The audit row stores microsecond timestamps (see
-- backend/webui/audit/log.lua), so the horizon is in the same unit
-- to keep comparisons trivial.
function M.horizon_us(now_sec, retention_sec)
    return math.floor((now_sec - retention_sec) * 1e6)
end

-- ─────────────────────────────────────────────────────────────────────
-- Sweep loop
-- ─────────────────────────────────────────────────────────────────────

local function leader_only()
    if rawget(_G, 'box') == nil then return false end
    local ok, info = pcall(function() return box.info end)
    if not ok or type(info) ~= 'table' then return false end
    return info.ro ~= true
end

-- Sweep one batch. Returns (deleted_count, more_to_do_flag).
--
-- Phase 4 Task 4.1c: after deletion, the oldest surviving row's
-- `prev_hash` points at a tuple that is no longer in storage —
-- a naive verifier would flag this as corruption. We resolve it
-- by SEALING the chain at the new boundary:
--   * the survivor's `chain_seal` is flipped to `true`
--   * its `prev_hash` is cleared to `box.NULL`
--   * an audit row `retention.chain_sealed` is appended so the
--     event is itself part of the chain (the next link uses the
--     survivor's existing `current_hash`).
--
-- The seal is the verifier's contract: a row with `chain_seal =
-- true` is a legitimate restart point. Distinguishing seal from
-- corruption is mandatory because retention runs forever and
-- otherwise every cluster would alarm hourly.
function M.sweep_once(opts)
    opts = opts or {}
    local space = storage.audit()
    if space == nil then return 0, false end
    if not leader_only() then return 0, false end
    local horizon = M.horizon_us(fiber.time(), STATE.retention_sec)
    local idx = space.index.by_ts
    if idx == nil then return 0, false end
    local budget = opts.budget or M.MAX_DELETIONS_PER_TICK
    local deleted = 0
    local deleted_max_id = 0
    for _, tuple in idx:pairs({}, { iterator = 'GE' }) do
        if tuple.ts >= horizon then break end
        if tuple.id > deleted_max_id then deleted_max_id = tuple.id end
        space:delete({ tuple.id })
        deleted = deleted + 1
        if deleted >= budget then
            -- Seal eagerly here too — partial sweep, but the
            -- survivor we just exposed is still the new oldest.
            M._seal_after_delete(space, deleted, deleted_max_id)
            return deleted, true
        end
    end
    if deleted > 0 then
        M._seal_after_delete(space, deleted, deleted_max_id)
    end
    return deleted, false
end

-- Seal the chain at the new oldest row. Idempotent — re-sealing
-- a row that is already sealed is a no-op (the update writes the
-- same values).
function M._seal_after_delete(space, deleted_count, deleted_max_id)
    local oldest
    pcall(function() oldest = space.index.primary:min() end)
    if oldest == nil then return end
    -- Already sealed by a prior sweep? Skip the update and the
    -- audit row to avoid spamming the chain.
    local was_sealed = oldest.chain_seal == true
        and (oldest.prev_hash == nil or oldest.prev_hash == '')
    if was_sealed then return end
    pcall(function()
        space:update({ oldest.id }, {
            { '=', 'prev_hash',  box.NULL },
            { '=', 'chain_seal', true },
        })
    end)
    -- Self-document the seal as a regular audit row so the event
    -- is searchable and itself part of the chain.
    pcall(function()
        local log = require('webui.audit.log')
        log.record_local({
            user   = 'system:retention',
            action = 'retention.chain_sealed',
            scope  = 'audit',
            payload = {
                deleted_count       = deleted_count,
                deleted_max_id      = deleted_max_id,
                new_chain_start_id  = oldest.id,
            },
        })
    end)
end

local function loop()
    fiber.self():name('webui_audit_retention', { truncate = true })
    while not STATE.stop_flag do
        if leader_only() then
            local ok, deleted, more = pcall(M.sweep_once)
            if ok then
                STATE.last_run_at = fiber.time()
                STATE.last_deleted = deleted
                if deleted > 0 then
                    logger.info('audit retention sweep', {
                        deleted = deleted, more = more,
                        retention_sec = STATE.retention_sec,
                    })
                end
            else
                logger.error('audit retention sweep raised', {
                    err = tostring(deleted),
                })
            end
        end
        -- Sleep in 1-second slices so M.stop() returns quickly.
        local remaining = STATE.tick_sec
        while remaining > 0 and not STATE.stop_flag do
            local slice = math.min(remaining, 1)
            fiber.sleep(slice)
            remaining = remaining - slice
        end
    end
    logger.debug('audit retention loop exited')
end

function M.start(opts)
    opts = opts or {}
    if opts.retention_days then
        STATE.retention_sec = math.max(1, opts.retention_days) * 86400
    end
    if opts.tick_sec then
        STATE.tick_sec = math.max(1, opts.tick_sec)
    end
    if STATE.fiber ~= nil and STATE.fiber:status() ~= 'dead' then
        logger.warn('audit retention already running')
        return true
    end
    STATE.stop_flag = false
    STATE.fiber = fiber.create(loop)
    logger.info('audit retention started', {
        retention_sec = STATE.retention_sec, tick_sec = STATE.tick_sec,
    })
    return true
end

function M.stop()
    if STATE.fiber == nil then return true end
    STATE.stop_flag = true
    local deadline = fiber.time() + 3
    while STATE.fiber:status() ~= 'dead' and fiber.time() < deadline do
        fiber.sleep(0.05)
    end
    STATE.fiber = nil
    logger.info('audit retention stopped')
    return true
end

function M.status()
    return {
        running       = STATE.fiber ~= nil and STATE.fiber:status() ~= 'dead',
        last_run_at   = STATE.last_run_at,
        last_deleted  = STATE.last_deleted,
        retention_sec = STATE.retention_sec,
        tick_sec      = STATE.tick_sec,
    }
end

-- Test hook.
function M._set_retention(sec)
    STATE.retention_sec = sec
end

return M
