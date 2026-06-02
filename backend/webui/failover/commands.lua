--
-- TCM-style commands journal for operator-issued cluster mutations.
--
-- Every promote / pause / resume / force_apply / expel / set_failover
-- call lands a row in `_webui_failover_commands` so operators see a
-- single audit-grade timeline of "what changed when and by whom".
-- The space is replicated + sync, so the row is durable the moment
-- the API returns.
--
-- Rows walk: pending → taken → success / failed. For the simple
-- one-shot mutations we collapse pending+taken+success into a single
-- write (start_command() returns the id, complete_command(id, status,
-- err?) flips it to terminal). For the supervised promote path we
-- emit two rows so the operator sees both the manual override write
-- and the agent's downstream box.ctl.promote effects.
--
-- Retention: a leader-only fiber sweeps rows older than 30 days,
-- 1000 per tick. Pruning by time avoids the per-coordinator-term
-- complexity Cartridge ran into.
--

local fiber   = require('fiber')
local json    = require('json')
local storage = require('webui.storage.spaces')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('failover.commands')

local M = {}

-- Knobs (overridable from roles_cfg.webui.failover.* in init.lua).
M.RETENTION_DAYS_DEFAULT = 30
M.RETENTION_TICK_BUDGET  = 1000  -- rows deleted per sweep
M.RETENTION_INTERVAL_SEC = 3600  -- 1 hour

local FIBER_NAME = 'webui_failover_commands_retention'

local function is_read_only()
    if rawget(_G, 'box') == nil or box.info == nil then return false end
    return box.info.ro == true
end

local function space_or_nil()
    return storage.failover_commands()
end

-- forward(client, args) → result, err. Routes writes through the
-- leader via the existing webui_peer pool when this peer is RO. The
-- shim that lives at the other end is registered in init.lua as
-- `webui_failover_commands_write_remote`.
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
    if type(res) == 'table' and res.err ~= nil then return nil, res.err end
    return res
end

-- record(command_type, params, status?, user?, error_reason?) → (id, nil) | (nil, err)
-- The default status is `success`; use `start` first for two-phase
-- semantics on long-running commands.
function M.record(command_type, params, opts)
    opts = opts or {}
    local now = fiber.time()
    local row = {
        nil,                                          -- auto id
        now,                                          -- ts
        tostring(command_type or 'unknown'),          -- command_type
        params,                                       -- params (any)
        opts.status or 'success',                     -- status
        opts.user,                                    -- user
        opts.coordinator,                             -- coordinator
        opts.taken_at,                                -- taken_at
        (opts.status == 'success' or opts.status == 'failed') and now or nil,
        opts.error_reason,                            -- error_reason
    }
    if is_read_only() then
        local res, err = forward_to_leader(
            'webui_failover_commands_write_remote', { row })
        if res == nil then return nil, err end
        return res.id, nil
    end
    local space = space_or_nil()
    if space == nil then return nil, 'space not bootstrapped' end
    local ok, tuple = pcall(function() return space:insert(row) end)
    if not ok then return nil, tostring(tuple) end
    return tuple[1], nil
end

-- start(command_type, params, user, coordinator) → (id, nil) | (nil, err)
-- Use for long-running mutations: call .start() first, do the work,
-- then .complete(id, 'success' | 'failed', err?).
function M.start(command_type, params, user, coordinator)
    return M.record(command_type, params, {
        status      = 'pending',
        user        = user,
        coordinator = coordinator,
    })
end

function M.complete(id, status, error_reason)
    if id == nil then return nil, 'id is required' end
    local now = fiber.time()
    if is_read_only() then
        local res, err = forward_to_leader(
            'webui_failover_commands_complete_remote', {
                id, status, error_reason, now,
            })
        if res == nil then return nil, err end
        return true
    end
    local space = space_or_nil()
    if space == nil then return nil, 'space not bootstrapped' end
    local ok, err = pcall(function()
        space:update({ id }, {
            { '=', 'status',       status or 'success' },
            { '=', 'completed_at', now },
            { '=', 'error_reason', error_reason },
        })
    end)
    if not ok then return nil, tostring(err) end
    return true
end

-- Cluster read helpers used by the GraphQL resolver.
function M.list(opts)
    opts = opts or {}
    local space = space_or_nil()
    if space == nil then return {} end
    local limit = tonumber(opts.limit) or 100
    if limit > 1000 then limit = 1000 end
    local out = {}
    -- The by_ts index is sorted ascending; iterate in reverse so
    -- the most recent commands surface first (typical UI need).
    for _, t in space.index.primary:pairs({}, { iterator = 'REQ' }) do
        local skip = (opts.status ~= nil and t.status ~= opts.status)
            or (opts.command_type ~= nil and t.command_type ~= opts.command_type)
        if not skip then
            -- params is `any` in the space (Lua table); GraphQL
            -- exposes it as a JSON string so the SPA can pick
            -- through nested shapes without us having to model
            -- every command type separately.
            local params_str
            if t.params ~= nil then
                local enc_ok, enc = pcall(json.encode, t.params)
                params_str = enc_ok and enc or tostring(t.params)
            end
            table.insert(out, {
                id           = t.id,
                ts           = t.ts,
                command_type = t.command_type,
                params       = params_str,
                status       = t.status,
                user         = t.user,
                coordinator  = t.coordinator,
                taken_at     = t.taken_at,
                completed_at = t.completed_at,
                error_reason = t.error_reason,
            })
            if #out >= limit then break end
        end
    end
    return out
end

-- ── Retention sweep ──────────────────────────────────────────────

local retention_started = false

local function sweep_once(retention_days)
    if is_read_only() then return 0 end
    local space = space_or_nil()
    if space == nil then return 0 end
    local cutoff = fiber.time() - retention_days * 86400
    local deleted = 0
    for _, t in space.index.by_ts:pairs({ 0 }, { iterator = 'GE' }) do
        if t.ts >= cutoff then break end
        local ok = pcall(function() space:delete({ t.id }) end)
        if ok then
            deleted = deleted + 1
            if deleted >= M.RETENTION_TICK_BUDGET then break end
        end
    end
    if deleted > 0 then
        logger.info('failover_commands retention sweep', {
            deleted = deleted, retention_days = retention_days,
        })
    end
    return deleted
end

function M.start_retention(opts)
    if retention_started then return end
    retention_started = true
    opts = opts or {}
    local retention_days = tonumber(opts.retention_days)
        or M.RETENTION_DAYS_DEFAULT
    local interval = tonumber(opts.interval_sec)
        or M.RETENTION_INTERVAL_SEC
    fiber.create(function()
        fiber.name(FIBER_NAME, { truncate = true })
        while true do
            pcall(sweep_once, retention_days)
            fiber.sleep(interval)
        end
    end)
    logger.info('failover_commands retention fiber started', {
        retention_days = retention_days, interval_sec = interval,
    })
end

-- Pure helper exposed for tests.
M._sweep_once = sweep_once

return M
