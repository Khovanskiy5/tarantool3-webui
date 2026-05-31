--
-- GraphQL resolvers for Cartridge-style operator controls.
--
-- The primary surface is `editTopology(servers, replicasets, apply)`
-- — one atomic mutation that builds a new cluster YAML, validates
-- it, optionally commits, and fans out a reload. All other Phase 5
-- mutations (setReplicasetRoles, createReplicaset, editReplicaset,
-- promoteInstance, ...) are convenience wrappers that compose
-- TopologyEdit inputs and delegate here.
--
-- Why this resolver lives separately from `config.lua`:
--   * `config.lua` is the editor surface (raw YAML in / YAML out).
--   * `cluster_ops.lua` is the operator surface (structured inputs).
-- The transport (twophase + etcd) is the same; only the shape of
-- the input differs.
--

local yaml = require('yaml')
local json = require('json')

local topology_edit = require('webui.cluster_ops.topology_edit')
local twophase      = require('webui.config_store.twophase')
local config_schema = require('webui.config_store.schema')
local etcd_client   = require('webui.config_store.client')
local audit         = require('webui.audit.log')
local rbac          = require('webui.auth.rbac')
local log_util      = require('webui.log_util')
local logger        = log_util.with_tag('graphql.cluster_ops')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

-- Inputs to editTopology and the alias mutations carry nested,
-- variable-shape data (an instance-spec is the entire Tarantool 3.x
-- instance config sub-schema). Modelling that in static GraphQL
-- types is fragile and would drift every time Tarantool ships a
-- new config knob. We instead accept a JSON-encoded `input` string,
-- decode it here, and feed the table straight into topology_edit.
-- The SPA builds the structure from TypeScript types it already
-- holds and serialises before sending.
local function decode_json_input(field, raw)
    if raw == nil then return {} end
    if type(raw) ~= 'string' or raw == '' then
        error('VALIDATION_ERROR: ' .. field
            .. ' must be a JSON-encoded string')
    end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        error('VALIDATION_ERROR: ' .. field
            .. ' is not valid JSON: ' .. tostring(decoded))
    end
    return decoded
end

-- Pull the live cluster YAML out of etcd. We deliberately do NOT
-- fall back to the on-disk file here: editTopology is always an
-- intentional operator action and should fail loudly when the
-- source of truth is unreachable — silently editing the boot YAML
-- behind etcd's back would create drift the operator cannot see.
local function read_current_yaml()
    local client, client_err = etcd_client.get_client()
    if client == nil then
        return nil, 'etcd unavailable: ' .. tostring(client_err)
    end
    local kv, get_err = client:get('config')
    if get_err ~= nil then
        return nil, 'etcd read failed: ' .. tostring(get_err.message or get_err)
    end
    if kv == nil or kv.value == nil or #kv.value == 0 then
        return nil, 'etcd has no `config` key yet — commit an initial config first'
    end
    return kv.value, nil, kv.revision
end

-- Flatten ops to a stable string list (op + path) — kept bounded
-- so the audit payload stays under the 64 KiB row cap on noisy
-- batch edits.
local function flatten_ops(ops)
    local flat = {}
    for _, op in ipairs(ops) do
        table.insert(flat, op.op .. ' ' .. op.path)
    end
    if #flat > 50 then
        local truncated = {}
        for i = 1, 50 do truncated[i] = flat[i] end
        table.insert(truncated, string.format('… (+%d more)', #flat - 50))
        return truncated
    end
    return flat
end

-- ── editTopology (primary mutation) ──────────────────────────────

-- Build a new cluster YAML from the current one + the operator's
-- structured edits, validate it, and either return a preview or
-- commit it through the existing 2PC pipeline.
--
-- args:
--   servers       — list of ServerEdit (alias-keyed, all fields optional)
--   replicasets   — list of ReplicasetEdit (name-keyed, all fields optional)
--   apply         — when true, commit straight after prepare; when
--                   false or unset, return prepared_id + diff for
--                   operator review (mirrors proposeConfig UX).
--
-- Returns: {
--   prepared_id   — for the apply=false branch
--   diff_ops      — structural ops describing what changed
--   diff_summary  — bounded flat list for the operator confirmation
--   revision      — etcd revision when apply=true succeeded
--   applied       — true once the commit landed
--   message       — human-readable outcome (reload fan-out included)
-- }
-- Internal entry point: takes already-decoded Lua tables and the
-- `root` carrying the session. Used by both the GraphQL resolver
-- (which decodes JSON first) and by the alias mutations
-- (setReplicasetRoles, createReplicaset, editReplicaset) which
-- assemble the edit structure programmatically.
local function edit_topology_core(root, edits, apply, audit_action)
    apply = apply == true
    audit_action = audit_action or 'cluster.edit_topology'

    local current_yaml, read_err, current_revision = read_current_yaml()
    if current_yaml == nil then
        error('UNAVAILABLE: ' .. read_err)
    end

    local ok, current_parsed = pcall(yaml.decode, current_yaml)
    if not ok or type(current_parsed) ~= 'table' then
        error('INVALID_CURRENT_CONFIG: failed to parse live YAML: '
            .. tostring(current_parsed))
    end

    local new_cfg, ops, edit_errs = topology_edit.apply(current_parsed, {
        servers     = edits.servers,
        replicasets = edits.replicasets,
    })
    if new_cfg == nil then
        local first = edit_errs[1] or {}
        error('TOPOLOGY_EDIT_FAILED: ' .. tostring(first.message or '?'))
    end

    if #ops == 0 then
        error('NO_CHANGES: the supplied edits leave the config unchanged')
    end

    local new_yaml = yaml.encode(new_cfg)

    -- Validate before letting it anywhere near etcd. schema.validate
    -- runs both `config:jsonschema()` and our cross-validators
    -- (leader-in-replicaset, unique peer URIs, etc.).
    local _, validation_errs = config_schema.validate(new_yaml)
    if validation_errs ~= nil and #validation_errs > 0 then
        local first = validation_errs[1] or {}
        error('VALIDATION_FAILED: ' .. tostring(first.message or '?'))
    end

    local prepared, prepare_errs = twophase.prepare({
        yaml         = new_yaml,
        user         = root and root.user,
        current_yaml = current_yaml,
    })
    if prepared == nil then
        local first = prepare_errs and prepare_errs[1] or {}
        if first.code == 'NO_CHANGES' then
            error('NO_CHANGES: ' .. tostring(first.message
                or 'nothing to commit'))
        end
        error('PREPARE_FAILED: ' .. tostring(first.message or '?'))
    end

    local diff_summary = flatten_ops(ops)

    if not apply then
        logger.info('editTopology preview', {
            user        = root and root.user,
            ops         = #ops,
            prepared_id = prepared.prepared_id,
        })
        return {
            prepared_id  = prepared.prepared_id,
            expires_at   = prepared.expires_at,
            diff_ops     = ops,
            diff_summary = diff_summary,
            applied      = false,
            revision     = 0,
            message      = string.format(
                'prepared %d op(s); review and commit via commitConfig.',
                #ops),
        }
    end

    -- apply=true → land the commit through the same path as
    -- mutation_commit (etcd CAS + fan-out reload + file mirror).
    local client = etcd_client.get_client()
    if client == nil then
        twophase.abort(prepared.prepared_id)
        error('UNAVAILABLE: etcd client disappeared between prepare and commit')
    end

    local commit_result, commit_err = twophase.commit(prepared.prepared_id, {
        etcd   = client,
        action = audit_action,
    })
    if commit_err then
        error('COMMIT_FAILED: ' .. tostring(commit_err))
    end

    local new_revision = (commit_result and commit_result.revision) or 0

    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = audit_action,
            scope      = 'cluster',
            payload    = {
                from_revision = current_revision,
                new_revision  = new_revision,
                ops           = #ops,
                diff_summary  = diff_summary,
                servers       = edits.servers,
                replicasets   = edits.replicasets,
            },
            request_id = root and root.request_id,
        })
    end)

    -- Same reload fan-out as mutation_commit. Best-effort — partial
    -- failures land in the message so the operator can re-run
    -- forceReapplyConfig on stragglers.
    local reload_outcome = ''
    do
        local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
        local peers_ok, peers = pcall(require, 'webui.cluster.peers')
        if rpc_ok and peers_ok then
            local all = {}
            for name in pairs(peers.list() or {}) do table.insert(all, name) end
            if #all > 0 then
                local ok_call, res_each = pcall(rpc.map_eval,
                    'require("config"):reload(); return true',
                    {}, { timeout = 15, peers = all })
                if ok_call then
                    local failed = {}
                    for name, r in pairs(res_each) do
                        if not (r and r.ok) then
                            table.insert(failed, name)
                        end
                    end
                    if #failed == 0 then
                        reload_outcome = ' Reloaded on '
                            .. tostring(#all) .. ' peer(s).'
                    else
                        reload_outcome = ' Reload partial: failed on '
                            .. table.concat(failed, ', ') .. '.'
                    end
                end
            end
        end
    end

    logger.info('editTopology commit ok', {
        user         = root and root.user,
        ops          = #ops,
        new_revision = new_revision,
    })

    return {
        prepared_id  = prepared.prepared_id,
        expires_at   = prepared.expires_at,
        diff_ops     = ops,
        diff_summary = diff_summary,
        applied      = true,
        revision     = new_revision,
        message      = string.format(
            '%s committed (revision %d, %d op(s)).%s',
            audit_action, new_revision, #ops, reload_outcome),
    }
end

-- Exported for unit tests that already hold pre-decoded edits.
M._edit_topology_core = edit_topology_core

-- editTopology(input: String!) — JSON-encoded `{servers, replicasets,
-- apply}` envelope. The SPA serialises its TopologyEdit types
-- directly. Validation happens both in the JSON shape (via
-- topology_edit.apply) and in the resulting YAML (via schema.validate)
-- before we touch etcd, so a malformed input can never partially
-- land.
function M.mutation_edit_topology(root, args)
    require_role(root, 'editTopology')
    args = args or {}
    local payload = decode_json_input('input', args.input)
    return edit_topology_core(root, {
        servers     = payload.servers,
        replicasets = payload.replicasets,
    }, payload.apply, 'cluster.edit_topology')
end

-- ── setReplicasetRoles (alias) ────────────────────────────────────

-- Thin wrapper over editTopology with a single ReplicasetEdit.
function M.mutation_set_replicaset_roles(root, args)
    require_role(root, 'setReplicasetRoles')
    args = args or {}
    if type(args.replicaset) ~= 'string' or args.replicaset == '' then
        error('VALIDATION_ERROR: replicaset is required')
    end
    if type(args.roles) ~= 'table' then
        error('VALIDATION_ERROR: roles must be a list of strings')
    end
    return edit_topology_core(root, {
        replicasets = { {
            name  = args.replicaset,
            roles = args.roles,
        } },
    }, args.apply ~= false, 'cluster.set_replicaset_roles')
end

-- ── createReplicaset (alias) ──────────────────────────────────────

-- Assembles a single ReplicasetEdit that creates a new rs with the
-- listed instances joined under it. `instances` is a map of
-- {alias = instance-spec}; the spec follows the standard Tarantool
-- 3.x instance schema (database, iproto, ...). The most common
-- case — joining unassigned instances that already exist as their
-- own per-replicaset entries elsewhere — is NOT covered here; that
-- is a multi-step migration (expel + create) handled by the
-- editReplicaset alias.
function M.mutation_create_replicaset(root, args)
    require_role(root, 'createReplicaset')
    args = args or {}
    local payload = decode_json_input('input', args.input)
    if type(payload.name) ~= 'string' or payload.name == '' then
        error('VALIDATION_ERROR: name is required')
    end
    if type(payload.group) ~= 'string' or payload.group == '' then
        error('VALIDATION_ERROR: group is required')
    end
    if payload.instances ~= nil and type(payload.instances) ~= 'table' then
        error('VALIDATION_ERROR: instances must be a map')
    end
    if payload.roles ~= nil and type(payload.roles) ~= 'table' then
        error('VALIDATION_ERROR: roles must be a list')
    end
    if payload.failover_priority ~= nil
        and type(payload.failover_priority) ~= 'table' then
        error('VALIDATION_ERROR: failover_priority must be a list')
    end
    if payload.weight ~= nil
        and (type(payload.weight) ~= 'number' or payload.weight < 0) then
        error('VALIDATION_ERROR: weight must be a non-negative number')
    end

    local replicaset = {
        name              = payload.name,
        group             = payload.group,
        roles             = payload.roles,
        leader            = payload.leader,
        failover_priority = payload.failover_priority,
        weight            = payload.weight,
        vshard_group      = payload.vshard_group,
        join_instances    = payload.instances,
    }

    if replicaset.leader ~= nil and replicaset.leader ~= '' then
        local found = false
        if replicaset.join_instances ~= nil then
            found = replicaset.join_instances[replicaset.leader] ~= nil
        end
        if not found then
            error('VALIDATION_ERROR: leader '
                .. tostring(replicaset.leader)
                .. ' is not in the joined instances')
        end
    end
    if replicaset.failover_priority ~= nil then
        local joined = {}
        if replicaset.join_instances ~= nil then
            for alias in pairs(replicaset.join_instances) do
                joined[alias] = true
            end
        end
        for _, alias in ipairs(replicaset.failover_priority) do
            if not joined[alias] then
                error('VALIDATION_ERROR: failover_priority alias '
                    .. tostring(alias) .. ' is not in the joined instances')
            end
        end
    end

    return edit_topology_core(root, {
        replicasets = { replicaset },
    }, payload.apply ~= false, 'cluster.create_replicaset')
end

-- ── editReplicaset (alias) ────────────────────────────────────────

-- Wraps a single ReplicasetEdit for partial updates: rename, roles,
-- leader, failover_priority, weight, add/remove instances. Useful
-- when the operator already opens a replicaset in the UI and wants
-- a focused edit instead of the full editTopology surface.
function M.mutation_edit_replicaset(root, args)
    require_role(root, 'editReplicaset')
    args = args or {}
    local payload = decode_json_input('input', args.input)
    if type(payload.name) ~= 'string' or payload.name == '' then
        error('VALIDATION_ERROR: name is required')
    end

    local replicaset = {
        name              = payload.name,
        group             = payload.group,
        roles             = payload.roles,
        leader            = payload.leader,
        failover_priority = payload.failover_priority,
        weight            = payload.weight,
        vshard_group      = payload.vshard_group,
        join_instances    = payload.join_instances,
        expel_instances   = payload.expel_instances,
        all_rw            = payload.all_rw,
    }

    local result = edit_topology_core(root, {
        replicasets = { replicaset },
    }, payload.apply ~= false, 'cluster.edit_replicaset')

    if payload.expel_instances ~= nil and #payload.expel_instances > 0 then
        local existing = result.message or ''
        result.message = existing
            .. ' WARNING: instance removal leaves data in place on the '
            .. 'expelled host — rebalance vshard buckets manually before '
            .. 'decommissioning the process.'
    end

    return result
end

return M
