--
-- Recovery preflight + execute glue (Task RC-2).
--
-- One place that maps a recovery `action` to the module that assesses it,
-- knows which actions are read-only diagnostics (and bypass the gate),
-- evaluates the live blocking precondition (failover paused), and keeps a
-- small idempotency store so a retried/double-clicked mutation does not run
-- twice. The pure enforcement decision lives in `assess.gate`.
--
-- Lua simple/reliable rules: plain control flow, locals, pcall around every
-- external touch, no metatables.
--

local fiber = require('fiber')

local assess   = require('webui.recovery.assess')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.preflight')

local M = {}

-- action -> { module, method }. Only MUTATING actions have an assess().
local DISPATCH = {
    leader_takeover    = { 'webui.recovery.leader_takeover', 'assess' },
    orphan_resolve     = { 'webui.recovery.orphan',         'assess' },
    quorum_loss_escape = { 'webui.recovery.quorum_loss',    'assess' },
    topology_fix       = { 'webui.recovery.topology_fix',   'assess' },
    wal_quarantine     = { 'webui.recovery.wal_repair',     'assess' },
    split_brain_resolve = { 'webui.recovery.split_brain',   'assess' },
}

-- Read-only diagnose pseudo-actions: no assess(), bypass the enforcement
-- gate entirely (invariant 9).
M.DIAGNOSE = {
    wal_diagnose          = true,
    topology_fix_diagnose = true,
}

M.is_diagnose = function(action) return M.DIAGNOSE[action] == true end
M.is_mutating = function(action) return DISPATCH[action] ~= nil end

-- Compute the assessment for an action. `snap` is an optional pre-built
-- snapshot (snapshot.build()); when nil the module fetches its own.
-- Returns the Assessment table, or nil for an unknown/diagnose action.
function M.assess(action, payload, snap)
    local d = DISPATCH[action]
    if d == nil then return nil end
    local ok, mod = pcall(require, d[1])
    if not ok or type(mod) ~= 'table' or type(mod[d[2]]) ~= 'function' then
        return nil
    end
    local ok_call, res = pcall(mod[d[2]], payload, nil, snap)
    if not ok_call then
        logger.warn('assess failed', { action = action, err = tostring(res) })
        return nil
    end
    return res
end

-- Live blocking precondition: is failover paused? Returns:
--   true  — paused (precondition satisfied);
--   false — definitively NOT paused (block dangerous action);
--   nil   — unknown (etcd unreachable) → do not block on it.
-- Best-effort: never raises.
function M.failover_paused()
    local ok_p, pause = pcall(require, 'webui.failover.pause')
    local ok_c, client_mod = pcall(require, 'webui.config_store.client')
    if not (ok_p and ok_c) then return nil end
    local client = nil
    pcall(function() client = client_mod.get_client() end)
    if client == nil then return nil end
    local active = nil
    local ok = pcall(function() active = pause.is_active(client) end)
    if not ok then return nil end
    return active == true
end

-- ── Idempotency store ────────────────────────────────────────────────
-- key -> { ts_mono, result }. Bounded by TTL; pruned lazily on access.

local IDEM_TTL = 600
local idem = {}

local function prune(now)
    for k, v in pairs(idem) do
        if (now - v.ts_mono) > IDEM_TTL then idem[k] = nil end
    end
end

-- Run `fn` at most once per idempotency key within the TTL window. A repeat
-- with the same fresh key returns the stored result without calling `fn`.
-- `now` is a monotonic timestamp (fiber.clock()); injectable for tests.
function M.idempotent(key, now, fn)
    if type(key) ~= 'string' or key == '' then
        return fn()  -- no key supplied → run normally, no dedup
    end
    now = now or fiber.clock()
    prune(now)
    local hit = idem[key]
    if hit ~= nil then
        logger.info('idempotent replay', { key = key })
        return hit.result
    end
    local result = fn()
    idem[key] = { ts_mono = now, result = result }
    return result
end

-- Test seam.
M._reset_idem = function() idem = {} end

-- ── Execute path ─────────────────────────────────────────────────────
-- action -> { module, method } for the REAL mutation (distinct from the
-- assess() method).

local EXEC = {
    leader_takeover    = { 'webui.recovery.leader_takeover', 'promote' },
    orphan_resolve     = { 'webui.recovery.orphan',         'resolve' },
    quorum_loss_escape = { 'webui.recovery.quorum_loss',    'escape' },
    topology_fix       = { 'webui.recovery.topology_fix',   'apply' },
    wal_quarantine     = { 'webui.recovery.wal_repair',     'quarantine' },
    split_brain_resolve = { 'webui.recovery.split_brain',   'resolve' },
}

-- Run the real mutation for a mutating action.
function M.dispatch(action, payload, root)
    local e = EXEC[action]
    if e == nil then
        return { ok = false, action = action, results = {},
            error = 'unsupported action ' .. tostring(action) }
    end
    return require(e[1])[e[2]](payload, root)
end

local function audit_refused(action, assessment, gate, root)
    pcall(function()
        require('webui.audit.log').record({
            user   = root and root.user,
            action = 'recovery.refused',
            scope  = 'cluster',
            payload = {
                recovery_action = action,
                code = gate.code,
                risk = assessment and assessment.risk,
                fingerprint = assessment and assessment.fingerprint,
            },
            request_id = root and root.request_id,
        })
    end)
end

-- Gate + idempotency wrapper around a MUTATING action. Re-assesses from a
-- fresh snapshot (server is the authority, not the preflight result),
-- enforces the gate for dangerous actions, refuses with a structured code,
-- and dedups by idempotency key. Returns the standard
-- { ok, action, error, results } shape.
function M.guarded(action, payload, args, root)
    args = args or {}
    return M.idempotent(args.idempotencyKey, nil, function()
        local a = M.assess(action, payload)
        if a == nil then
            return { ok = false, action = action, results = {},
                error = 'INTERNAL: assessment unavailable' }
        end
        local pc_ok = nil
        if a.risk == assess.DANGEROUS then pc_ok = M.failover_paused() end
        local gate = assess.gate(a, args, pc_ok)
        if not gate.allow then
            audit_refused(action, a, gate, root)
            logger.warn('recovery refused', {
                action = action, code = gate.code, risk = a.risk,
            })
            return { ok = false, action = action, results = {},
                error = (gate.code or 'REFUSED') .. ': ' .. (gate.message or '') }
        end
        logger.info('recovery apply', {
            action = action, risk = a.risk, fingerprint = a.fingerprint,
        })
        return M.dispatch(action, payload, root)
    end)
end

return M
