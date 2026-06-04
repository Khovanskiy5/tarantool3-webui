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
local yaml_patch    = require('webui.config_store.yaml_patch')
local etcd_client   = require('webui.config_store.client')
local audit         = require('webui.audit.log')
local commands      = require('webui.failover.commands')

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
-- Read the YAML the operator is editing against. Precedence:
--   1. etcd `<prefix>/config` — the cluster-wide source of truth
--      after the first commit.
--   2. On-disk file mirror — covers the fresh-bootstrap case where
--      etcd is empty (`down -v`, first cluster boot, freshly
--      provisioned WebUI on top of a running Tarantool). The
--      operator gets a working preview/apply cycle without first
--      having to navigate to /config-editor and dummy-commit.
--   3. Hard error only when BOTH sources are unavailable.
--
-- The downstream twophase.commit always writes to etcd, so the
-- file fallback is read-only here — the next round-trip reads
-- back from etcd as usual.
local function read_current_yaml()
    local client, client_err = etcd_client.get_client()
    local etcd_unavailable_reason
    if client ~= nil then
        local kv, get_err = client:read_cluster_config()
        if get_err ~= nil then
            etcd_unavailable_reason = 'etcd read failed: '
                .. tostring(get_err.message or get_err)
        elseif kv ~= nil and kv.value ~= nil and #kv.value > 0 then
            return kv.value, nil, kv.revision
        end
        -- etcd reachable but the `config` key is empty — fall through
        -- to the file mirror.
    else
        etcd_unavailable_reason = 'etcd unavailable: ' .. tostring(client_err)
    end

    -- File fallback. Imports config resolver lazily so we re-use
    -- the same env-var precedence (TT_CONFIG_PATH → TT_CONFIG →
    -- /opt/webui/etc/cluster.yaml).
    local ok_cfg, config_resolver = pcall(require, 'webui.graphql.resolvers.config')
    if ok_cfg and type(config_resolver._read_local_yaml) == 'function' then
        local yaml_text = config_resolver._read_local_yaml()
        if yaml_text and #yaml_text > 0 then
            return yaml_text, nil, 0
        end
    end

    if etcd_unavailable_reason ~= nil then
        return nil, etcd_unavailable_reason
    end
    return nil, 'no cluster YAML available — commit an initial config '
        .. 'via /config-editor first'
end

-- Reload fan-out helper. Tarantool's etcd source does NOT poll —
-- it only re-reads on `config:reload()`. Every mutation that
-- writes new etcd content must therefore run a reload on each
-- peer so the change becomes effective immediately.
--
-- Two layers:
--   * self-reload — `peers.list()` returns foreign peers only,
--     so the instance handling the GraphQL call would otherwise
--     keep serving the pre-commit `cfg:get(...)` until the next
--     manual reload. Operator-visible bug: setFailoverMode
--     returns success, but the page on the same peer still
--     shows the old mode.
--   * fan-out — every other peer through the existing net.box
--     RPC pool.
local function fan_out_reload()
    local self_outcome = ''
    do
        local ok_cfg, cfg = pcall(require, 'config')
        if ok_cfg then
            local ok, err = pcall(function() cfg:reload() end)
            if not ok then
                -- "already in progress" is a Tarantool 3.x race
                -- between our explicit reload and the etcd
                -- source's own poll cycle. Both will see the new
                -- key — silencing the noise keeps the operator-
                -- visible message focused on real failures.
                local msg = tostring(err)
                if not msg:find('already in progress', 1, true) then
                    self_outcome = ' Self-reload failed: ' .. msg .. '.'
                end
            end
        end
    end

    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    local peers_ok, peers = pcall(require, 'webui.cluster.peers')
    if not (rpc_ok and peers_ok) then return self_outcome end
    local all = {}
    for name in pairs(peers.list() or {}) do
        table.insert(all, name)
    end
    if #all == 0 then
        return self_outcome ~= '' and self_outcome or ' Reloaded locally.'
    end

    -- The local cfg:reload() above may have rotated iproto
    -- credentials / advertise URIs, which closes every existing
    -- net.box socket in the peer pool. If we fire the fan-out
    -- immediately, every call comes back "not connected" — the
    -- pool's reconnect_after hasn't fired yet. Best-effort retry
    -- with a brief sleep gives the pool time to rebuild the
    -- connections. The retry budget is bounded (3 attempts at
    -- 1s spacing) so a genuinely dead peer still surfaces.
    local function fan_out_attempt()
        local ok_call, res_each = pcall(rpc.map_eval,
            'require("config"):reload(); return true',
            {}, { timeout = 15, peers = all })
        if not ok_call then return nil, tostring(res_each) end
        local failed = {}
        for name, r in pairs(res_each or {}) do
            if not (r and r.ok) then
                table.insert(failed, name .. '=' ..
                    tostring(r and r.err or 'unknown'))
            end
        end
        return failed
    end

    local failed, call_err
    local fiber = require('fiber')
    for attempt = 1, 3 do
        failed, call_err = fan_out_attempt()
        if call_err ~= nil then break end
        if #failed == 0 then break end
        -- Only retry on transient "not connected" — anything else
        -- is a real failure we should surface immediately.
        local all_transient = true
        for _, f in ipairs(failed) do
            if not f:find('not connected', 1, true) then
                all_transient = false; break
            end
        end
        if not all_transient or attempt == 3 then break end
        fiber.sleep(1)
    end

    if call_err ~= nil then
        return self_outcome .. ' Reload fan-out errored: '
            .. tostring(call_err) .. '.'
    end
    if #failed == 0 then
        return self_outcome .. ' Reloaded on '
            .. tostring(#all + 1) .. ' peer(s) (self + ' .. #all .. ').'
    end
    return self_outcome .. ' Reload partial: failed on '
        .. table.concat(failed, ', ') .. '.'
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

    -- Patch the raw text against the old / new trees so operator comments
    -- and key order survive the structural edit; falls back to a plain
    -- re-encode if a clean merge is not possible (always valid YAML).
    local new_yaml = yaml_patch.render(current_yaml, current_parsed, new_cfg)

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
        commands.record(audit_action, {
            from_revision = current_revision,
            new_revision  = new_revision,
            ops_count     = #ops,
        }, { user = root and root.user, status = 'success' })
    end)
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

-- ── addInstance (alias) ───────────────────────────────────────────

-- `addInstance({alias, group, replicaset, uri, listen?, roles?})`
-- composes a ReplicasetEdit with a single `join_instances` entry.
-- Pre-flight URI reachability is best-effort: net.box.connect on
-- a brand-new peer often fails the first probe until the cluster
-- joins it, so a probe miss WARN's but does NOT block the edit.
function M.mutation_add_instance(root, args)
    require_role(root, 'addInstance')
    args = args or {}
    local payload = decode_json_input('input', args.input)
    if type(payload.alias) ~= 'string' or payload.alias == '' then
        error('VALIDATION_ERROR: alias is required')
    end
    if type(payload.group) ~= 'string' or payload.group == '' then
        error('VALIDATION_ERROR: group is required')
    end
    if type(payload.replicaset) ~= 'string' or payload.replicaset == '' then
        error('VALIDATION_ERROR: replicaset is required')
    end
    if type(payload.uri) ~= 'string' or payload.uri == '' then
        error('VALIDATION_ERROR: uri is required')
    end

    -- Build the per-instance spec from the convenience args.
    local instance_spec = {
        iproto = {
            advertise = { peer = { uri = payload.uri } },
        },
    }
    if payload.listen ~= nil then
        if type(payload.listen) == 'string' then
            instance_spec.iproto.listen = { { uri = payload.listen } }
        elseif type(payload.listen) == 'table' then
            local listen = {}
            for _, v in ipairs(payload.listen) do
                if type(v) == 'string' then
                    table.insert(listen, { uri = v })
                elseif type(v) == 'table' and v.uri ~= nil then
                    table.insert(listen, { uri = v.uri })
                end
            end
            instance_spec.iproto.listen = listen
        end
    end
    if payload.mode == 'rw' or payload.mode == 'ro' then
        instance_spec.database = { mode = payload.mode }
    end

    -- Best-effort URI probe — warn-only, never blocking. A fresh peer
    -- typically doesn't answer net.box until after replication joins
    -- it, so a failed probe is normal at this stage.
    local probe_warning
    do
        local lifecycle = require('webui.graphql.resolvers.lifecycle')
        local ok, probe = pcall(lifecycle.mutation_probe_uri, root, {
            uri = payload.uri,
        })
        if ok and probe and probe.reachable == false then
            probe_warning = string.format(
                'URI %s did not respond to probe (this is normal for a '
                .. 'brand-new peer that has not yet joined the cluster); '
                .. 'check connectivity if it stays unreachable after join.',
                payload.uri)
        end
    end

    local result = edit_topology_core(root, {
        replicasets = { {
            name           = payload.replicaset,
            group          = payload.group,
            roles          = payload.roles,
            join_instances = { [payload.alias] = instance_spec },
        } },
    }, payload.apply ~= false, 'cluster.add_instance')

    if probe_warning ~= nil then
        result.message = (result.message or '') .. ' ' .. probe_warning
    end
    return result
end

-- ── expelInstance ─────────────────────────────────────────────────

-- Two-step destructive operation:
--   1. editTopology removes the alias from cluster YAML — leaders
--      and followers stop accepting iproto from it after
--      config:reload(). The peer pool diff in cluster/peers.lua
--      closes the net.box connection on its next refresh tick.
--   2. Post-commit cleanup: the orphan `_cluster` row for the
--      target's UUID is deleted on every reachable peer so the
--      slot frees up immediately.
--
-- We refuse to expel the last instance of a replicaset (would
-- leave it with no live members). `force=true` skips the safety
-- check; the operator is then responsible for the consequences.
function M.mutation_expel_instance(root, args)
    require_role(root, 'expelInstance')
    args = args or {}
    if type(args.alias) ~= 'string' or args.alias == '' then
        error('VALIDATION_ERROR: alias is required')
    end
    local force = args.force == true

    -- Locate the alias in current YAML so we can build the right edit
    -- without forcing the caller to remember group / replicaset.
    local current_yaml, read_err, current_revision = read_current_yaml()
    if current_yaml == nil then
        error('UNAVAILABLE: ' .. read_err)
    end
    local ok, parsed = pcall(yaml.decode, current_yaml)
    if not ok or type(parsed) ~= 'table' then
        error('INVALID_CURRENT_CONFIG: failed to parse live YAML')
    end
    local gname, rsname
    do
        local groups = parsed.groups or {}
        for g, group in pairs(groups) do
            for rs, replicaset in pairs(group.replicasets or {}) do
                if replicaset.instances ~= nil
                    and replicaset.instances[args.alias] ~= nil then
                    gname = g
                    rsname = rs
                    break
                end
            end
            if rsname ~= nil then break end
        end
    end
    if rsname == nil then
        error('NOT_FOUND: alias ' .. args.alias .. ' is not in cluster YAML')
    end

    -- Safety: refuse to leave a replicaset with zero instances.
    if not force then
        local rs = parsed.groups[gname].replicasets[rsname]
        local remaining = 0
        for alias in pairs(rs.instances or {}) do
            if alias ~= args.alias then remaining = remaining + 1 end
        end
        if remaining == 0 then
            error('FORBIDDEN: refusing to expel the only instance of ' ..
                rsname .. '; pass force=true to override')
        end
    end

    -- Step 1: drop the entry from cluster YAML via the same atomic
    -- path the alias mutations use.
    local result = edit_topology_core(root, {
        replicasets = { {
            name            = rsname,
            group           = gname,
            expel_instances = { args.alias },
        } },
    }, true, 'cluster.expel_instance')

    -- Step 2: post-commit `_cluster` cleanup on every reachable
    -- peer. Best-effort: we never roll the YAML edit back when this
    -- fails — config:reload() already closed the peer pool to the
    -- expelled URI, and an orphan _cluster row only blocks a slot
    -- (operator can clean it via box.space._cluster:delete on a
    -- leader if it lingers).
    local cleanup_outcome = ''
    do
        local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
        local peers_ok, peers = pcall(require, 'webui.cluster.peers')
        if rpc_ok and peers_ok then
            local all = {}
            for name in pairs(peers.list() or {}) do
                if name ~= args.alias then table.insert(all, name) end
            end
            if #all > 0 then
                local expr = string.format([[
                    local target_uuid
                    for _, t in pairs(box.space._cluster:select()) do
                        if t and t[2] and t[3] and t[3].name == %q then
                            target_uuid = t[2]; break
                        end
                    end
                    if target_uuid == nil then
                        for _, t in pairs(box.space._cluster:select()) do
                            local sp = box.space._cluster:get({t[1]})
                            if sp and sp[2] == %q then
                                target_uuid = sp[2]; break
                            end
                        end
                    end
                    if target_uuid == nil then return { ok = true, deleted = 0 } end
                    local row = box.space._cluster.index.uuid:get({target_uuid})
                    if row == nil then return { ok = true, deleted = 0 } end
                    if box.info.ro then return { ok = false, ro = true, deleted = 0 } end
                    box.space._cluster:delete({row[1]})
                    return { ok = true, deleted = 1, replica_id = row[1] }
                ]], args.alias, args.alias)
                local call_ok, per_peer = pcall(rpc.map_eval, expr,
                    {}, { timeout = 5, peers = all })
                if call_ok and type(per_peer) == 'table' then
                    local deleted_on, ro_on = {}, {}
                    for name, r in pairs(per_peer) do
                        if r and r.ok and r.value and r.value.deleted == 1 then
                            table.insert(deleted_on, name)
                        elseif r and r.value and r.value.ro then
                            table.insert(ro_on, name)
                        end
                    end
                    if #deleted_on > 0 then
                        cleanup_outcome = string.format(
                            ' _cluster row deleted on %s.',
                            table.concat(deleted_on, ', '))
                    elseif #ro_on == #all then
                        cleanup_outcome = ' _cluster cleanup skipped '
                            .. '(no writable peer answered).'
                    end
                end
            end
        end
    end

    pcall(function()
        commands.record('cluster.expel_instance', {
            alias = args.alias, replicaset = rsname, force = force,
        }, { user = root and root.user, status = 'success' })
    end)
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'cluster.expel_instance',
            scope      = 'cluster',
            payload    = {
                alias         = args.alias,
                group         = gname,
                replicaset    = rsname,
                from_revision = current_revision,
                new_revision  = result.revision,
                force         = force,
            },
            request_id = root and root.request_id,
        })
    end)

    result.message = (result.message or '') .. cleanup_outcome
    return result
end

-- ── promoteInstance / demoteInstance ─────────────────────────────

local promote_module = require('webui.cluster_ops.promote')

-- Build the `apply_edit_topology` callback the promote module
-- needs. Captures the resolver-local `root` so audit + RBAC stay
-- consistent with the rest of cluster_ops.
local function make_apply_edit_topology(root)
    return function(edits, audit_action)
        return edit_topology_core(root, {
            servers     = edits.servers,
            replicasets = edits.replicasets,
        }, true, audit_action)
    end
end

function M.mutation_promote_instance(root, args)
    require_role(root, 'promoteInstance')
    args = args or {}
    if type(args.alias) ~= 'string' or args.alias == '' then
        error('VALIDATION_ERROR: alias is required')
    end
    local current_yaml, read_err = read_current_yaml()
    if current_yaml == nil then
        error('UNAVAILABLE: ' .. read_err)
    end
    local ok, parsed = pcall(yaml.decode, current_yaml)
    if not ok or type(parsed) ~= 'table' then
        error('INVALID_CURRENT_CONFIG: failed to parse live YAML')
    end
    local opts = {
        force_inconsistency  = args.force_inconsistency,
        skip_error_on_change = args.skip_error_on_change,
        timeout              = args.timeout,
        ttl_sec              = args.ttl_sec,
        by_user              = root and root.user,
    }
    local result = promote_module.promote({
        parsed              = parsed,
        current_yaml        = current_yaml,
        alias               = args.alias,
        opts                = opts,
        apply_edit_topology = make_apply_edit_topology(root),
    })
    pcall(function()
        commands.record('cluster.promote', {
            alias = args.alias, mode = result.mode,
        }, { user = root and root.user, status = 'success' })
    end)
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'cluster.promote',
            scope      = 'cluster',
            payload    = {
                alias = args.alias, mode = result.mode,
                opts = opts,
            },
            request_id = root and root.request_id,
        })
    end)
    return {
        prepared_id  = nil,
        diff_summary = { string.format('promote %s in %s mode',
            args.alias, tostring(result.mode)) },
        applied      = result.applied,
        revision     = result.revision or 0,
        message      = result.message,
    }
end

function M.mutation_demote_instance(root, args)
    require_role(root, 'demoteInstance')
    args = args or {}
    if type(args.alias) ~= 'string' or args.alias == '' then
        error('VALIDATION_ERROR: alias is required')
    end
    local current_yaml, read_err = read_current_yaml()
    if current_yaml == nil then
        error('UNAVAILABLE: ' .. read_err)
    end
    local ok, parsed = pcall(yaml.decode, current_yaml)
    if not ok or type(parsed) ~= 'table' then
        error('INVALID_CURRENT_CONFIG: failed to parse live YAML')
    end
    local result = promote_module.demote({
        parsed              = parsed,
        current_yaml        = current_yaml,
        alias               = args.alias,
        apply_edit_topology = make_apply_edit_topology(root),
    })
    pcall(function()
        commands.record('cluster.demote', {
            alias = args.alias, mode = result.mode,
        }, { user = root and root.user, status = 'success' })
    end)
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'cluster.demote',
            scope      = 'cluster',
            payload    = { alias = args.alias, mode = result.mode },
            request_id = root and root.request_id,
        })
    end)
    return {
        prepared_id  = nil,
        diff_summary = { 'demote ' .. args.alias },
        applied      = result.applied,
        revision     = result.revision or 0,
        message      = result.message,
    }
end

-- ── setFailoverMode ──────────────────────────────────────────────

-- Validate operator-supplied params before mutating cluster YAML.
-- Returns nil on success, error{code, message} on failure.
local function validate_failover_params(mode, params, instance_count)
    if mode ~= 'off' and mode ~= 'manual' and mode ~= 'election'
        and mode ~= 'supervised' then
        return { code = 'VALIDATION_ERROR',
            message = 'mode must be off|manual|election|supervised' }
    end
    if params == nil then return nil end

    -- synchro_quorum: accept either the string formula or an int.
    -- Reject ints below N/2+1 — they explicitly allow split-brain.
    if params.synchro_quorum ~= nil
        and type(params.synchro_quorum) == 'number' then
        local floor = math.floor(instance_count / 2) + 1
        if params.synchro_quorum < floor then
            return { code = 'VALIDATION_ERROR',
                message = string.format(
                    'synchro_quorum %d < N/2+1=%d would allow split-brain',
                    params.synchro_quorum, floor) }
        end
    end

    if params.synchro_timeout ~= nil
        and (type(params.synchro_timeout) ~= 'number'
             or params.synchro_timeout <= 0) then
        return { code = 'VALIDATION_ERROR',
            message = 'synchro_timeout must be a positive number' }
    end
    if params.election_timeout ~= nil
        and (type(params.election_timeout) ~= 'number'
             or params.election_timeout <= 0) then
        return { code = 'VALIDATION_ERROR',
            message = 'election_timeout must be a positive number' }
    end
    if params.election_fencing_mode ~= nil then
        local ok_em = {
            off    = true,
            soft   = true,
            strict = true,
        }
        if not ok_em[params.election_fencing_mode] then
            return { code = 'VALIDATION_ERROR',
                message = 'election_fencing_mode must be off|soft|strict' }
        end
    end
    return nil
end

-- Count total instances across all groups/replicasets for the
-- N/2+1 quorum check.
local function count_instances(parsed)
    local n = 0
    for _, group in pairs(parsed.groups or {}) do
        for _, rs in pairs(group.replicasets or {}) do
            for _ in pairs(rs.instances or {}) do n = n + 1 end
        end
    end
    return n
end

-- Snapshot the current leader per replicaset so failover-mode
-- transitions can carry the intent across the strip blocks.
-- Resolution order matches how each source-mode encodes
-- leadership: `database.mode: rw` (off), then `rs.leader` (manual).
-- election and supervised leave no static marker (raft / the agent's
-- etcd appointment drive leadership) — pick_manual_leader falls back
-- to the agent's last appointment for those.
local function snapshot_prior_leader(parsed)
    local out = {}
    for _, group in pairs(parsed.groups or {}) do
        for rs_name, rs in pairs(group.replicasets or {}) do
            local picked
            for alias, inst in pairs(rs.instances or {}) do
                if type(inst.database) == 'table'
                    and inst.database.mode == 'rw' then
                    picked = alias
                    break
                end
            end
            out[rs_name] = picked or rs.leader
        end
    end
    return out
end

-- Re-materialise the prior leader as `database.mode: rw` so the
-- writer survives a transition OUT of manual (where `database.mode`
-- was stripped on entry). No-op if the replicaset already has a
-- RW instance — operator edits during the same mutation win.
local function restore_prior_leader_rw(new_parsed, prior_leader)
    for _, group in pairs(new_parsed.groups or {}) do
        for rs_name, rs in pairs(group.replicasets or {}) do
            local has_rw = false
            for _, inst in pairs(rs.instances or {}) do
                if type(inst.database) == 'table'
                    and inst.database.mode == 'rw' then
                    has_rw = true
                    break
                end
            end
            if not has_rw and prior_leader[rs_name]
                and rs.instances
                and rs.instances[prior_leader[rs_name]] ~= nil then
                local inst = rs.instances[prior_leader[rs_name]]
                inst.database = inst.database or {}
                inst.database.mode = 'rw'
            end
        end
    end
end

-- Pick the leader for `rs` when entering manual mode and no
-- explicit leader was supplied. Sources in priority order:
--   1. prior_leader (operator's leader from the previous mode)
--   2. agent's last appointment for this replicaset
--   3. self if currently RW
--   4. first alphabetical alias — deterministic placeholder
local function pick_manual_leader(rs, rs_name, prior_leader,
                                  agent_last, self_alias, self_is_writer)
    if prior_leader[rs_name]
        and rs.instances
        and rs.instances[prior_leader[rs_name]] ~= nil then
        return prior_leader[rs_name]
    end
    if agent_last and agent_last[rs_name]
        and rs.instances
        and rs.instances[agent_last[rs_name]] ~= nil then
        return agent_last[rs_name]
    end
    if self_is_writer and self_alias
        and rs.instances
        and rs.instances[self_alias] ~= nil then
        return self_alias
    end
    local aliases = {}
    for alias in pairs(rs.instances or {}) do
        table.insert(aliases, alias)
    end
    table.sort(aliases)
    return aliases[1]
end

-- Read the live cluster YAML and decode it. Raises on an unreachable
-- store or unparseable YAML. Returns (parsed, current_yaml, revision).
-- Shared by setFailoverMode and setInstanceState.
local function load_parsed_yaml()
    local current_yaml, read_err, current_revision = read_current_yaml()
    if current_yaml == nil then
        error('UNAVAILABLE: ' .. read_err)
    end
    local ok, parsed = pcall(yaml.decode, current_yaml)
    if not ok or type(parsed) ~= 'table' then
        error('INVALID_CURRENT_CONFIG: failed to parse live YAML')
    end
    return parsed, current_yaml, current_revision
end

-- Write `replication.failover` and the community-agent toggle for the
-- target mode. `supervised` is the native failover mode (applier starts
-- RO; our agent assigns the writer) and keeps agent: true plus
-- bootstrap_strategy auto + MVCC. election/manual force the agent OFF
-- (Tarantool drives leadership); off defaults the agent ON unless the
-- operator passes agent: false.
local function build_failover_repl_config(new_parsed, mode, params)
    if mode == 'supervised' then
        new_parsed.replication.failover = 'supervised'
        new_parsed.replication.bootstrap_strategy =
            new_parsed.replication.bootstrap_strategy or 'auto'
        new_parsed.database = new_parsed.database or {}
        if new_parsed.database.use_mvcc_engine == nil then
            new_parsed.database.use_mvcc_engine = true
        end
        new_parsed.roles_cfg = new_parsed.roles_cfg or {}
        new_parsed.roles_cfg.webui = new_parsed.roles_cfg.webui or {}
        new_parsed.roles_cfg.webui.failover =
            new_parsed.roles_cfg.webui.failover or {}
        new_parsed.roles_cfg.webui.failover.agent = true
        if type(params.agent_params) == 'table' then
            for k, val in pairs(params.agent_params) do
                new_parsed.roles_cfg.webui.failover[k] = val
            end
        end
    else
        new_parsed.replication.failover = mode
        new_parsed.roles_cfg = new_parsed.roles_cfg or {}
        new_parsed.roles_cfg.webui = new_parsed.roles_cfg.webui or {}
        new_parsed.roles_cfg.webui.failover =
            new_parsed.roles_cfg.webui.failover or {}
        if mode == 'election' or mode == 'manual' then
            new_parsed.roles_cfg.webui.failover.agent = false
        elseif mode == 'off' then
            if params.agent == false then
                new_parsed.roles_cfg.webui.failover.agent = false
            else
                -- Default ON: plain `failover: off` with no explicit
                -- database.mode leaves the cluster with no RW peer; the
                -- agent is the OSS primary-electing driver.
                new_parsed.roles_cfg.webui.failover.agent = true
            end
        end
    end
end

-- Native `replication.failover: election | manual | supervised` is
-- mutually exclusive with per-instance `database.mode`; strip it
-- cluster-wide so the commit lands. The stripped intent is preserved in
-- `prior_leader` and re-materialised as rs.leader / database.mode later.
local function strip_instance_database_mode(new_parsed, mode)
    if mode ~= 'election' and mode ~= 'manual' and mode ~= 'supervised' then
        return
    end
    for _, group in pairs(new_parsed.groups or {}) do
        for _, rs in pairs(group.replicasets or {}) do
            for _, inst in pairs(rs.instances or {}) do
                if type(inst.database) == 'table'
                    and inst.database.mode ~= nil then
                    inst.database.mode = nil
                    -- Drop an empty `database` husk so the YAML stays clean.
                    if next(inst.database) == nil then
                        inst.database = nil
                    end
                end
            end
        end
    end
end

-- Schema rule: `replicasets.<rs>.leader` MUST NOT be set under
-- election | off | supervised (leadership is driven by raft / the
-- agent / per-instance database.mode). Strip it like database.mode.
local function strip_replicaset_leaders(new_parsed, mode)
    if mode ~= 'election' and mode ~= 'off' and mode ~= 'supervised' then
        return
    end
    for _, group in pairs(new_parsed.groups or {}) do
        for _, rs in pairs(group.replicasets or {}) do
            if rs.leader ~= nil then rs.leader = nil end
        end
    end
end

-- Manual mode requires `replicasets.<rs>.leader` to be set — otherwise
-- no instance becomes RW and the next sync write deadlocks on a queue
-- without an owner. When entering manual without an explicit leader,
-- pre-populate each replicaset's leader (prior_leader → agent
-- appointment → self-if-writer → first alphabetical alias).
local function assign_manual_leaders(new_parsed, prior_leader, mode)
    if mode ~= 'manual' then return end
    local self_alias
    if box.info and box.info.name then self_alias = box.info.name end
    local self_is_writer = box.info ~= nil and box.info.ro == false
    local agent_last
    do
        local ok_agent, agent = pcall(require, 'webui.failover.agent')
        if ok_agent then
            local s = ok_agent and agent.status() or nil
            if type(s) == 'table' and type(s.appointments) == 'table' then
                agent_last = {}
                for _, a in ipairs(s.appointments) do
                    if a.leader ~= nil then
                        agent_last[a.replicaset] = a.leader
                    end
                end
            end
        end
    end
    for _, group in pairs(new_parsed.groups or {}) do
        for rs_name, rs in pairs(group.replicasets or {}) do
            if rs.leader == nil then
                rs.leader = pick_manual_leader(rs, rs_name,
                    prior_leader, agent_last,
                    self_alias, self_is_writer)
            end
        end
    end
end

-- Apply the optional replication knobs only when explicitly supplied —
-- unset fields keep their current cluster values.
local function apply_replication_params(new_parsed, params)
    if params.synchro_quorum ~= nil then
        new_parsed.replication.synchro_quorum = params.synchro_quorum
    end
    if params.synchro_timeout ~= nil then
        new_parsed.replication.synchro_timeout = params.synchro_timeout
    end
    if params.election_timeout ~= nil then
        new_parsed.replication.election_timeout = params.election_timeout
    end
    if params.election_fencing_mode ~= nil then
        new_parsed.replication.election_fencing_mode = params.election_fencing_mode
    end
end

-- Off/election: cfg:reload() flips read_only on the demoted peer but
-- leaves the synchro queue owned by the old primary, so any new write
-- hangs. Drive box.ctl.demote() on whichever peer still owns its own
-- queue (self first, then foreign peers). Best-effort + bounded.
local function demote_old_queue_owner(mode)
    if mode ~= 'off' and mode ~= 'election' then return end
    local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
    local self_alias
    if box.info and box.info.name then self_alias = box.info.name end
    local demote_expr = [[
        if box.info.synchro.queue.owner == box.info.id then
            pcall(function() box.ctl.demote() end)
            return { demoted = true }
        end
        return { demoted = false }
    ]]
    do
        local ok_info = rawget(_G, 'box') ~= nil and box.info ~= nil
        if ok_info and box.info.synchro
            and box.info.synchro.queue.owner == box.info.id then
            pcall(function() box.ctl.demote() end)
        end
    end
    if rpc_ok then
        local ok_peers, peers = pcall(require, 'webui.cluster.peers')
        if ok_peers then
            local foreign = {}
            for name in pairs(peers.list() or {}) do
                if name ~= self_alias then table.insert(foreign, name) end
            end
            if #foreign > 0 then
                pcall(rpc.map_eval, demote_expr, {},
                    { timeout = 5, peers = foreign })
            end
        end
    end
end

-- Drive the queue handoff (cfg{read_only=false} + box.ctl.promote) on
-- the new leader, which cfg:reload() does NOT do for non-election modes
-- (see box_cfg.lua:1208-1212). manual → each rs.leader; off/supervised
-- → the re-emitted prior_leader; election → raft owns the term (no-op).
local function promote_new_queue_owner(mode, new_parsed, prior_leader)
    if mode == 'manual' then
        for _, group in pairs(new_parsed.groups or {}) do
            for _, rs in pairs(group.replicasets or {}) do
                if type(rs.leader) == 'string' and rs.leader ~= '' then
                    promote_module.take_queue_on(rs.leader)
                end
            end
        end
    elseif mode == 'off' or mode == 'supervised' then
        for _, group in pairs(new_parsed.groups or {}) do
            for rs_name, rs in pairs(group.replicasets or {}) do
                local leader_alias = prior_leader[rs_name]
                if leader_alias and rs.instances
                    and rs.instances[leader_alias] ~= nil then
                    promote_module.take_queue_on(leader_alias)
                end
            end
        end
    end
end

-- Wait (bounded 8s, 250ms poll) for the cluster to converge on a leader
-- so the SPA doesn't see a transient "no leader" right after Apply.
local function wait_for_leader_convergence()
    local ok_state, cluster_state = pcall(require, 'webui.cluster.state')
    if ok_state then
        local fiber = require('fiber')
        local deadline = fiber.time() + 8
        while fiber.time() < deadline do
            local leader = cluster_state.find_leader()
            if leader ~= nil then break end
            fiber.sleep(0.25)
        end
    end
end

-- Re-exported for unit testing of the pure YAML transformation.
M._build_failover_repl_config = build_failover_repl_config
M._strip_instance_database_mode = strip_instance_database_mode
M._strip_replicaset_leaders = strip_replicaset_leaders
M._apply_replication_params = apply_replication_params

function M.mutation_set_failover_mode(root, args)
    require_role(root, 'setFailoverMode')
    args = args or {}
    if type(args.mode) ~= 'string' or args.mode == '' then
        error('VALIDATION_ERROR: mode is required')
    end

    local params = {}
    if args.params ~= nil then
        params = decode_json_input('params', args.params)
    end

    local parsed, current_yaml, current_revision = load_parsed_yaml()

    local v = validate_failover_params(args.mode, params, count_instances(parsed))
    if v ~= nil then error(v.code .. ': ' .. v.message) end

    -- Compose the new YAML by deep-copying parsed and patching the
    -- relevant keys. topology_edit does not model these top-level
    -- knobs yet — handle them directly here. The byte-equality
    -- guard inside twophase.prepare still catches no-ops.
    local new_parsed = topology_edit._deep_copy(parsed)
    new_parsed.replication = new_parsed.replication or {}

    build_failover_repl_config(new_parsed, args.mode, params)

    -- Capture the operator's current leader BEFORE the strip blocks
    -- wipe per-instance `database.mode` / per-replicaset `rs.leader`.
    -- Read from `parsed`, not `new_parsed`, so the agent toggle above
    -- cannot perturb the snapshot. Reused to carry leadership intent
    -- across the manual / off / supervised transitions.
    local prior_leader = snapshot_prior_leader(parsed)

    strip_instance_database_mode(new_parsed, args.mode)
    strip_replicaset_leaders(new_parsed, args.mode)
    assign_manual_leaders(new_parsed, prior_leader, args.mode)

    -- Off / supervised re-materialise the prior leader as
    -- `database.mode: rw` so the writer survives the transition OUT of
    -- manual (where `database.mode` was stripped on entry).
    if args.mode == 'off' or args.mode == 'supervised' then
        restore_prior_leader_rw(new_parsed, prior_leader)
    end

    apply_replication_params(new_parsed, params)

    -- Preserve comments / key order across the failover-mode rewrite;
    -- falls back to a re-encode when a clean text merge is impossible.
    local new_yaml = yaml_patch.render(current_yaml, parsed, new_parsed)

    -- Schema cross-validation: if the new mode/params combination
    -- breaks election/leader exclusivity etc., fail before commit.
    local _, schema_errs = config_schema.validate(new_yaml)
    if schema_errs ~= nil and #schema_errs > 0 then
        local first = schema_errs[1] or {}
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
                or 'submitted mode change is a no-op'))
        end
        error('PREPARE_FAILED: ' .. tostring(first.message or '?'))
    end

    if args.apply == false then
        return {
            prepared_id  = prepared.prepared_id,
            expires_at   = prepared.expires_at,
            diff_summary = { 'set_failover_mode → ' .. args.mode },
            applied      = false,
            revision     = 0,
            message      = 'prepared; review and commit via commitConfig',
        }
    end

    local client = etcd_client.get_client()
    if client == nil then
        twophase.abort(prepared.prepared_id)
        error('UNAVAILABLE: etcd unavailable for commit')
    end
    local commit_result, commit_err = twophase.commit(prepared.prepared_id, {
        etcd   = client,
        action = 'cluster.set_failover_mode',
    })
    if commit_err then
        error('COMMIT_FAILED: ' .. tostring(commit_err))
    end
    pcall(function()
        commands.record('cluster.set_failover_mode', {
            mode = args.mode, params = params,
        }, { user = root and root.user, status = 'success' })
    end)
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'cluster.set_failover_mode',
            scope      = 'cluster',
            payload    = {
                mode          = args.mode,
                params        = params,
                from_revision = current_revision,
                new_revision  = commit_result and commit_result.revision,
            },
            request_id = root and root.request_id,
        })
    end)
    local reload_outcome = fan_out_reload()

    -- Cartridge-style synchro-queue handoff: cfg:reload() flips
    -- read_only per the new YAML but does NOT move queue ownership
    -- (box_cfg.lua:1208-1212 leaves it to the orchestrator for every
    -- mode except election). Demote the old owner (off/election) and
    -- promote the new one (manual/off/supervised); election leaves the
    -- fresh term to raft. Both are best-effort + bounded.
    demote_old_queue_owner(args.mode)
    promote_new_queue_owner(args.mode, new_parsed, prior_leader)

    -- A mode change often demotes the current writer transiently and
    -- the new leader takes a couple of agent/watcher ticks to appear;
    -- wait so the SPA doesn't see a misleading "no leader" right after
    -- a successful Apply.
    wait_for_leader_convergence()

    return {
        prepared_id  = nil,
        diff_summary = { 'set_failover_mode → ' .. args.mode },
        applied      = true,
        revision     = (commit_result and commit_result.revision) or 0,
        message      = string.format(
            'failover mode changed to %s (revision %d).%s',
            args.mode, (commit_result and commit_result.revision) or 0,
            reload_outcome),
    }
end

-- ── setInstanceState ──────────────────────────────────────────────

-- Determine failover mode + agent state from live YAML. Returns
-- one of: 'off_with_agent' | 'off' | 'manual' | 'election' |
-- 'supervised' | 'unknown'.
local function classify_failover_mode(parsed)
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
    if mode == 'manual' or mode == 'election'
        or mode == 'supervised' then
        return mode
    end
    return 'unknown'
end

-- Locate (group, replicaset) of an alias inside parsed cluster YAML.
local function locate_alias(parsed, alias)
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

-- setInstanceState(alias, enabled?, electable?) — per-mode action
-- matrix described in plan/Task 5.7.
-- Map the (enabled, electable) flags to a raft election_mode:
-- voter (cannot win), candidate (eligible), or nil when neither flag
-- was supplied.
local function compute_new_election_mode(args)
    if args.enabled == false or args.electable == false then
        return 'voter'
    elseif args.enabled == true or args.electable == true then
        return 'candidate'
    end
    return nil
end

-- Set the instance's `replication.election_mode` in the RAW cluster
-- YAML, returning the patched text. Patches the raw text rather than
-- re-encoding a decoded tree so operator comments, key order and
-- indentation survive (topology_edit does not model election_mode, so
-- we patch this single scalar directly).
local function patch_instance_election_mode(raw, gname, rsname, alias, em)
    local path = { 'groups', gname, 'replicasets', rsname,
                   'instances', alias, 'replication', 'election_mode' }
    local new_yaml, status = yaml_patch.set_field(raw, path, em)
    if new_yaml == nil then
        error('PATCH_FAILED: ' .. tostring(status))
    end
    return new_yaml
end

-- supervised / off-with-agent: toggle the etcd-backed disabled set so
-- the agent picks the change up on its next coordinator tick (< 1s).
-- electable is a no-op here (all healthy non-disabled candidates are
-- electable). Returns the resolver result.
local function apply_agent_disabled_state(root, args, rs, rsname, mode)
    local action_taken = {}
    if args.enabled ~= nil then
        local client = etcd_client.get_client()
        if client == nil then
            error('UNAVAILABLE: etcd unavailable for disabled-set update')
        end
        local disabled_mod = require('webui.failover.disabled')
        if args.enabled == false then
            local _, derr = disabled_mod.set(client, args.alias,
                root and root.user)
            if derr ~= nil then
                error('UNAVAILABLE: disabled.set failed: ' .. tostring(derr))
            end
            table.insert(action_taken, 'disabled in agent score map')
            -- If the disabled alias is the current synchro-queue owner,
            -- the operator must promote someone else separately.
            if rs.leader == args.alias then
                table.insert(action_taken,
                    'NOTE: alias is the configured leader — promote '
                    .. 'another instance to clear the queue owner')
            end
        else
            local _, derr = disabled_mod.clear(client, args.alias)
            if derr ~= nil then
                error('UNAVAILABLE: disabled.clear failed: ' .. tostring(derr))
            end
            table.insert(action_taken, 'enabled in agent score map')
        end
    end
    if args.electable ~= nil then
        table.insert(action_taken,
            'NOTE: electable flag is a no-op in supervised mode '
            .. '(all healthy non-disabled candidates are electable)')
    end
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'cluster.set_instance_state',
            scope      = 'replicaset:' .. tostring(rsname),
            payload    = {
                alias = args.alias, mode = mode,
                enabled = args.enabled, electable = args.electable,
                action_taken = action_taken,
            },
            request_id = root and root.request_id,
        })
    end)
    return {
        prepared_id  = nil,
        diff_summary = action_taken,
        applied      = true,
        revision     = 0,
        message      = string.format(
            'set_instance_state on %s: %s',
            args.alias, table.concat(action_taken, '; ')),
    }
end

-- `off` without an agent: enable/disable maps to database.mode rw/ro
-- via the shared editTopology core (audit + reload behave identically).
local function apply_off_no_agent(root, args)
    if args.enabled == false then
        return edit_topology_core(root, {
            servers = { { alias = args.alias, mode = 'ro' } },
        }, true, 'cluster.set_instance_state')
    end
    if args.enabled == true then
        return edit_topology_core(root, {
            servers = { { alias = args.alias, mode = 'rw' } },
        }, true, 'cluster.set_instance_state')
    end
    error('VALIDATION_ERROR: electable does not apply in off+no-agent mode')
end

-- `manual`: there is no per-instance disable; refuse to disable the
-- current leader and otherwise point the operator at promote/demote.
local function apply_manual_state(args, rs)
    if rs.leader == args.alias and args.enabled == false then
        error('FORBIDDEN: refusing to disable manual-mode leader; '
            .. 'promote another instance first')
    end
    return {
        prepared_id  = nil,
        diff_summary = {},
        applied      = false,
        revision     = 0,
        message      = 'manual mode has no per-instance disable; '
            .. 'use promote/demote to move the leader instead.',
    }
end

-- `election` (raft): toggle the instance's election_mode through a 2PC
-- prepare/commit on the patched YAML, then fan out a reload.
local function apply_election_mode_change(root, args, parsed,
                                          current_yaml, gname, rsname, mode)
    local new_election_mode = compute_new_election_mode(args)
    if new_election_mode == nil then
        error('VALIDATION_ERROR: pass enabled or electable for election mode')
    end
    local inst = parsed.groups[gname].replicasets[rsname].instances[args.alias]
    local current_em
    if type(inst) == 'table' and type(inst.replication) == 'table' then
        current_em = inst.replication.election_mode
    end
    if current_em == new_election_mode then
        return {
            prepared_id  = nil,
            diff_summary = {},
            applied      = false,
            revision     = 0,
            message      = 'election_mode already set to ' .. new_election_mode,
        }
    end
    local new_yaml = patch_instance_election_mode(current_yaml, gname, rsname,
        args.alias, new_election_mode)
    local prepared, prepare_errs = twophase.prepare({
        yaml         = new_yaml,
        user         = root and root.user,
        current_yaml = current_yaml,
    })
    if prepared == nil then
        local first = prepare_errs and prepare_errs[1] or {}
        error('PREPARE_FAILED: ' .. tostring(first.message or '?'))
    end
    local client = etcd_client.get_client()
    if client == nil then
        twophase.abort(prepared.prepared_id)
        error('UNAVAILABLE: etcd unavailable')
    end
    local commit_result, commit_err = twophase.commit(prepared.prepared_id, {
        etcd   = client,
        action = 'cluster.set_instance_state',
    })
    if commit_err then
        error('COMMIT_FAILED: ' .. tostring(commit_err))
    end
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'cluster.set_instance_state',
            scope      = 'replicaset:' .. tostring(rsname),
            payload    = {
                alias = args.alias, mode = mode,
                election_mode = new_election_mode,
            },
            request_id = root and root.request_id,
        })
    end)
    local reload_outcome = fan_out_reload()
    return {
        prepared_id  = nil,
        diff_summary = { 'change /election_mode → ' .. new_election_mode },
        applied      = true,
        revision     = (commit_result and commit_result.revision) or 0,
        message      = 'election_mode set to ' .. new_election_mode
            .. reload_outcome,
    }
end

-- Re-exported for unit testing of the pure election-mode transforms.
M._compute_new_election_mode = compute_new_election_mode
M._patch_instance_election_mode = patch_instance_election_mode

function M.mutation_set_instance_state(root, args)
    require_role(root, 'setInstanceState')
    args = args or {}
    if type(args.alias) ~= 'string' or args.alias == '' then
        error('VALIDATION_ERROR: alias is required')
    end
    if args.enabled == nil and args.electable == nil then
        error('VALIDATION_ERROR: at least one of enabled/electable required')
    end

    local parsed, current_yaml = load_parsed_yaml()
    local gname, rsname, rs = locate_alias(parsed, args.alias)
    if rsname == nil then
        error('NOT_FOUND: alias ' .. args.alias .. ' is not in cluster YAML')
    end
    local mode = classify_failover_mode(parsed)

    -- The supervised-OS path is the most common one in our setup:
    -- failover off + agent on.
    if mode == 'off_with_agent' or mode == 'supervised' then
        return apply_agent_disabled_state(root, args, rs, rsname, mode)
    elseif mode == 'off' then
        return apply_off_no_agent(root, args)
    elseif mode == 'manual' then
        return apply_manual_state(args, rs)
    elseif mode == 'election' then
        return apply_election_mode_change(root, args, parsed,
            current_yaml, gname, rsname, mode)
    end

    error('VALIDATION_ERROR: unsupported failover mode: ' .. tostring(mode))
end

-- ── pauseFailover / resumeFailover ────────────────────────────────

function M.mutation_pause_failover(root, args)
    require_role(root, 'pauseFailover')
    args = args or {}
    local client, client_err = etcd_client.get_client()
    if client == nil then
        error('UNAVAILABLE: etcd unavailable: ' .. tostring(client_err))
    end
    local pause_mod = require('webui.failover.pause')
    local res, err = pause_mod.set(client, args.ttl_sec,
        root and root.user)
    if res == nil then
        if err == 'PAUSE_TTL_TOO_LONG' then
            error('PAUSE_TTL_TOO_LONG: pause TTL cannot exceed '
                .. tostring(pause_mod.MAX_PAUSE_TTL_SEC)
                .. 's; for longer disable run setFailoverMode "off" '
                .. 'without our agent.')
        end
        error('UNAVAILABLE: pause write failed: ' .. tostring(err))
    end
    pcall(function()
        commands.record('cluster.pause_failover', {
            until_ts = res.until_ts,
            ttl_sec = args.ttl_sec or pause_mod.DEFAULT_TTL_SEC,
        }, { user = root and root.user, status = 'success' })
    end)
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'cluster.pause_failover',
            scope      = 'cluster',
            payload    = { until_ts = res.until_ts,
                ttl_sec = args.ttl_sec or pause_mod.DEFAULT_TTL_SEC },
            request_id = root and root.request_id,
        })
    end)
    return {
        prepared_id  = nil,
        diff_summary = { 'pause until ' .. tostring(math.floor(res.until_ts)) },
        applied      = true,
        revision     = 0,
        message      = string.format(
            'failover paused until epoch %d (%.0fs from now).',
            math.floor(res.until_ts), res.until_ts - require('fiber').time()),
    }
end

function M.mutation_resume_failover(root, _args)
    require_role(root, 'resumeFailover')
    local client, client_err = etcd_client.get_client()
    if client == nil then
        error('UNAVAILABLE: etcd unavailable: ' .. tostring(client_err))
    end
    local pause_mod = require('webui.failover.pause')
    local _, err = pause_mod.clear(client)
    if err ~= nil then
        error('UNAVAILABLE: pause clear failed: ' .. tostring(err))
    end
    pcall(function()
        commands.record('cluster.resume_failover', {},
            { user = root and root.user, status = 'success' })
    end)
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'cluster.resume_failover',
            scope      = 'cluster',
            payload    = {},
            request_id = root and root.request_id,
        })
    end)
    return {
        prepared_id  = nil,
        diff_summary = { 'resume' },
        applied      = true,
        revision     = 0,
        message      = 'failover resumed; agent will appoint on next tick.',
    }
end

return M
