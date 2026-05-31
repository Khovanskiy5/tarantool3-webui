--
-- Per-mode promote / demote helpers for the cluster operator
-- toolkit.
--
-- The four failover modes pick mechanically different code paths;
-- this module concentrates the dispatch logic so the GraphQL
-- resolver stays thin. Inputs:
--
--   * `parsed` — already-decoded cluster YAML (for read-only
--     lookups: locate alias → (group, rs), inspect leader and
--     election fields, learn `replication.failover`).
--   * `current_yaml` — raw bytes (passed through to twophase.prepare
--     so the byte-equality guard fires correctly).
--   * `alias` — instance to promote / demote.
--   * `opts` — {force_inconsistency, skip_error_on_change, timeout,
--     ttl_sec, by_user}.
--   * `apply_edit` — callback that runs editTopology with the
--     supplied edits; injected by the resolver so it does not
--     have to circular-import cluster_ops.
--
-- Returns {applied, revision?, mode, message} on success or
-- raises an error('CODE: message') string for the resolver to
-- relay as a typed GraphQL envelope.
--

local M = {}

-- locate(parsed, alias) → (gname, rsname, replicaset_table)
local function locate(parsed, alias)
    local groups = parsed and parsed.groups or {}
    for gname, group in pairs(groups) do
        for rsname, rs in pairs(group.replicasets or {}) do
            if rs.instances ~= nil
                and rs.instances[alias] ~= nil then
                return gname, rsname, rs
            end
        end
    end
    return nil
end

-- Classify the failover mode from the parsed YAML. Mirrors the
-- helper inside cluster_ops resolver — kept local so promote.lua
-- stays standalone-testable.
local function classify(parsed)
    local repl = parsed and parsed.replication or {}
    local mode = repl.failover
    if mode == nil or mode == 'off' then
        local agent_on = false
        local roles_cfg = parsed.roles_cfg or {}
        local webui_cfg = roles_cfg.webui or {}
        if type(webui_cfg.failover) == 'table' then
            agent_on = webui_cfg.failover.agent == true
        end
        return agent_on and 'off_with_agent' or 'off'
    end
    if mode == 'manual' or mode == 'election' or mode == 'supervised' then
        return mode
    end
    return 'unknown'
end

-- Issue `box.ctl.promote()` on a remote peer over net.box. The
-- supervised + election modes both end up calling this when the
-- operator wants the queue-owner side-effect immediately.
local function remote_promote(alias, opts)
    opts = opts or {}
    local timeout = tonumber(opts.timeout) or 5
    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    if not rpc_ok or type(rpc.map_eval) ~= 'function' then
        return nil, 'rpc module unavailable'
    end
    local expr
    if opts.force_inconsistency == true then
        expr = 'box.ctl.promote(); return { promoted = true, forced = true }'
    else
        expr = 'box.ctl.promote(); return { promoted = true }'
    end
    local ok_call, per_peer = pcall(rpc.map_eval, expr, {},
        { timeout = timeout, peers = { alias } })
    if not ok_call then return nil, tostring(per_peer) end
    if type(per_peer) ~= 'table' or per_peer[alias] == nil then
        return nil, 'no response from ' .. alias
    end
    local r = per_peer[alias]
    if not (r and r.ok) then
        return nil, (r and r.err) or 'unknown error'
    end
    return r.value or {}, nil
end

-- promote(ctx) → {applied, revision?, mode, message}
-- ctx = {parsed, current_yaml, alias, opts, apply_edit_topology}
function M.promote(ctx)
    if type(ctx) ~= 'table' or type(ctx.alias) ~= 'string'
        or ctx.alias == '' then
        error('VALIDATION_ERROR: alias is required')
    end
    if type(ctx.parsed) ~= 'table' then
        error('INVALID_CURRENT_CONFIG: parsed YAML missing')
    end
    local opts = ctx.opts or {}
    local gname, rsname, rs = locate(ctx.parsed, ctx.alias)
    if rsname == nil then
        error('NOT_FOUND: alias ' .. ctx.alias
            .. ' is not in cluster YAML')
    end
    local mode = classify(ctx.parsed)

    -- Idempotency shortcut shared by every mode.
    if opts.skip_error_on_change == true and rs.leader == ctx.alias then
        return {
            applied  = true,
            revision = 0,
            mode     = mode,
            message  = 'idempotent: ' .. ctx.alias
                .. ' already declared leader of ' .. rsname,
        }
    end

    -- off (no agent): RW only on target, RO on the rest.
    if mode == 'off' then
        local server_edits = {}
        table.insert(server_edits, { alias = ctx.alias, mode = 'rw' })
        for alias in pairs(rs.instances or {}) do
            if alias ~= ctx.alias then
                table.insert(server_edits, { alias = alias, mode = 'ro' })
            end
        end
        local res = ctx.apply_edit_topology({ servers = server_edits },
            'cluster.promote')
        res.mode = mode
        return res
    end

    -- manual: declare leader inside the replicaset.
    if mode == 'manual' then
        local res = ctx.apply_edit_topology({
            replicasets = { {
                name = rsname, group = gname, leader = ctx.alias,
            } },
        }, 'cluster.promote')
        res.mode = mode
        return res
    end

    -- election (raft): drive box.ctl.promote on the target. Tarantool
    -- routes the leadership change through a raft round; we do NOT
    -- mutate cluster YAML.
    if mode == 'election' then
        local res, err = remote_promote(ctx.alias, opts)
        if res == nil then
            error('PROMOTE_FAILED: election round failed: ' .. tostring(err))
        end
        return {
            applied  = true,
            revision = 0,
            mode     = mode,
            message  = 'box.ctl.promote() invoked on ' .. ctx.alias,
        }
    end

    -- supervised / off_with_agent: write a manual override
    -- appointment in etcd so the coordinator stops auto-electing
    -- somebody else for TTL seconds. We ALSO call box.ctl.promote
    -- on the target so the synchro queue ownership moves
    -- immediately (the watcher would do the same on its next
    -- tick, but the operator clicked "promote" — make it instant).
    if mode == 'supervised' or mode == 'off_with_agent' then
        local etcd_client = require('webui.config_store.client')
        local client, client_err = etcd_client.get_client()
        if client == nil then
            error('UNAVAILABLE: etcd unavailable: ' .. tostring(client_err))
        end
        local agent = require('webui.failover.agent')
        local ttl_sec = tonumber(opts.ttl_sec) or 300
        local app, app_err = agent.appoint_manually(
            client, rsname, ctx.alias, ttl_sec, opts.by_user)
        if app == nil then
            error('UNAVAILABLE: manual appointment failed: '
                .. tostring(app_err))
        end
        -- Best-effort immediate promote. Failure here is non-fatal:
        -- the watcher on the appointed target will see the etcd
        -- key on its next poll and run box.ctl.promote then.
        local promote_outcome = ''
        local r, rerr = remote_promote(ctx.alias, opts)
        if r ~= nil then
            promote_outcome = ' box.ctl.promote() ok.'
        elseif rerr ~= nil then
            promote_outcome = ' box.ctl.promote() warning: '
                .. tostring(rerr) .. '.'
        end
        return {
            applied  = true,
            revision = 0,
            mode     = mode,
            message  = string.format(
                'manual override appointment written for %s on %s '
                .. '(expires in %ds).%s',
                ctx.alias, rsname, ttl_sec, promote_outcome),
        }
    end

    error('VALIDATION_ERROR: unsupported failover mode: ' .. tostring(mode))
end

-- demote(ctx) → mirror of promote but for the inverse action.
-- Only `off` and `supervised`/`off_with_agent` are supported.
function M.demote(ctx)
    if type(ctx) ~= 'table' or type(ctx.alias) ~= 'string'
        or ctx.alias == '' then
        error('VALIDATION_ERROR: alias is required')
    end
    if type(ctx.parsed) ~= 'table' then
        error('INVALID_CURRENT_CONFIG: parsed YAML missing')
    end
    local gname, rsname, rs = locate(ctx.parsed, ctx.alias)
    if rsname == nil then
        error('NOT_FOUND: alias ' .. ctx.alias
            .. ' is not in cluster YAML')
    end
    local mode = classify(ctx.parsed)
    _ = gname

    if mode == 'off' then
        return ctx.apply_edit_topology({
            servers = { { alias = ctx.alias, mode = 'ro' } },
        }, 'cluster.demote')
    end

    if mode == 'supervised' or mode == 'off_with_agent' then
        -- Pick any other healthy alias and promote IT instead. The
        -- simplest "demote me" semantics: hand the queue off to a
        -- neighbour. We do not pick a specific target — the score
        -- map after the override expires will choose.
        local etcd_client = require('webui.config_store.client')
        local client = etcd_client.get_client()
        if client == nil then
            error('UNAVAILABLE: etcd unavailable for demote')
        end
        local rpc = require('webui.cluster.rpc')
        -- box.ctl.demote() on the target releases the synchro queue.
        local ok_call, per_peer = pcall(rpc.map_eval,
            'box.ctl.demote(); return { demoted = true }',
            {}, { timeout = 5, peers = { ctx.alias } })
        if not ok_call then
            error('DEMOTE_FAILED: ' .. tostring(per_peer))
        end
        return {
            applied  = true,
            revision = 0,
            mode     = mode,
            message  = 'box.ctl.demote() invoked on ' .. ctx.alias
                .. ' — agent will appoint a new leader on next tick.',
        }
    end

    if mode == 'manual' then
        error('FORBIDDEN: manual mode has no demote; promote another '
            .. 'instance instead (which moves leader away from ' .. ctx.alias .. ')')
    end

    if mode == 'election' then
        -- Temporarily flip election_mode to 'voter' on the target
        -- so it loses the next raft round.
        local res = ctx.apply_edit_topology({
            replicasets = { {
                name = rsname,
                -- election_mode is per-instance — handled by the
                -- resolver, not topology_edit. We expose the intent
                -- here; the resolver follows up by patching the
                -- instance spec the same way setInstanceState does.
            } },
        }, 'cluster.demote')
        _ = rs
        res.mode = mode
        return res
    end

    error('VALIDATION_ERROR: unsupported failover mode: ' .. tostring(mode))
end

M._locate = locate
M._classify = classify

return M
