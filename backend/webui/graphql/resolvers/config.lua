--
-- Resolvers for the config-editor GraphQL surface.
--
-- Until etcd is fully provisioned (operators wire `roles_cfg.webui.etcd`
-- into their cluster config), these resolvers run in "local" mode:
-- everything happens in-memory on the responding instance. The contract
-- on the wire stays stable so the SPA can already render the editor.
--

local fio = require('fio')

local twophase     = require('webui.config_store.twophase')
local schema       = require('webui.config_store.schema')
local diff_module  = require('webui.config_store.diff')
local history      = require('webui.config_store.history')
local etcd_client  = require('webui.config_store.client')
local rbac         = require('webui.auth.rbac')
local audit        = require('webui.audit.log')
local log_util     = require('webui.log_util')
local logger       = log_util.with_tag('graphql.config')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

-- The local config source path is taken from the env (set by the
-- entrypoint script that boots Tarantool 3.x). Used as a fallback
-- when etcd is unwired or empty — operators get a starting point
-- for the editor on a fresh cluster. Exposed on the module table
-- so other resolvers (cluster_ops) can reuse the same env-var
-- precedence without duplicating the candidate list.
local function read_local_yaml()
    -- ipairs stops at the first nil, so we can't put env getters
    -- straight into the table literal. Build the list defensively.
    local candidates = {}
    local function push(p) if p and #p > 0 then table.insert(candidates, p) end end
    push(os.getenv('TT_CONFIG_PATH'))
    push(os.getenv('TT_CONFIG'))
    push('/opt/webui/etc/cluster.yaml')
    push('docker/configs/cluster.yaml')
    for _, path in ipairs(candidates) do
        local f = fio.open(path)
        if f ~= nil then
            local body = f:read()
            f:close()
            if body then return body, 'file' end
        end
    end
    return '', 'memory'
end
M._read_local_yaml = read_local_yaml

-- Source-of-truth precedence: etcd > file > empty.
--
-- etcd is the SoT once commitConfig populates `<prefix>/config`. We
-- read from there so the editor reflects what the cluster is actually
-- running on, not the boot-time file (which is immutable in the
-- container and would always reset the editor on reload).
--
-- The fallback file read covers two cases:
--   1. Fresh cluster, etcd empty — give operators the bootstrap YAML.
--   2. etcd unreachable — surface the file at least, with `source=file`
--      so the operator knows the dataset is stale.
function M.query_current(root)
    require_role(root, 'config')

    local client, client_err = etcd_client.get_client()
    if client ~= nil then
        local kv, e = client:get('config')
        if kv ~= nil and kv.value ~= nil and #kv.value > 0 then
            logger.debug('config read from etcd', {
                revision = kv.revision, size = #kv.value,
            })
            return {
                yaml     = kv.value,
                revision = kv.revision or 0,
                source   = 'etcd',
            }
        end
        if e ~= nil then
            -- Don't fail the query — surface the etcd error path
            -- through `source` and fall back to the file so the
            -- editor still renders something useful.
            logger.warn('config etcd read failed', { err = e.message })
        end
    elseif client_err then
        logger.debug('config etcd unavailable', { reason = client_err })
    end

    local yaml, source = read_local_yaml()
    return { yaml = yaml, revision = 0, source = source }
end

-- configHistory(limit, after): revisions[] + oldest_available_revision.
-- Backed by our own history.lua storage (etcd /history/ keys, NOT
-- etcd mod_revision history) so the timeline is deterministic and
-- survives etcd auto-compaction.
function M.query_history(root, args)
    require_role(root, 'configHistory')
    local client, client_err = etcd_client.get_client()
    if client == nil then
        logger.info('configHistory: etcd unavailable', { err = client_err })
        return {
            revisions = {},
            oldest_available_revision = nil,
            more = false,
        }
    end
    local list, err = history.list(client, {
        limit = args and args.limit or nil,
        after = args and args.after or nil,
    })
    if err then
        logger.warn('configHistory: list failed', { err = err })
        error('HISTORY_LIST_FAILED: ' .. tostring(err))
    end
    logger.info('configHistory ok', {
        user  = root and root.user,
        count = #(list.revisions or {}),
        more  = list.more,
    })
    return list
end

-- configRevision(revision): full YAML body for a single revision.
-- Returns REVISION_NOT_FOUND when the key has aged out beyond
-- MAX_HISTORY or never existed.
function M.query_revision(root, args)
    require_role(root, 'configRevision')
    if args == nil or args.revision == nil then
        error('VALIDATION_ERROR: revision is required')
    end
    local client, client_err = etcd_client.get_client()
    if client == nil then
        error('REVISION_NOT_FOUND: etcd unavailable (' ..
            tostring(client_err) .. ')')
    end
    local kv, err = history.get(client, args.revision)
    if err then
        logger.warn('configRevision: get failed', { rev = args.revision, err = err })
        error('REVISION_LOOKUP_FAILED: ' .. tostring(err))
    end
    if kv == nil then
        error('REVISION_NOT_FOUND: ' .. tostring(args.revision))
    end
    local meta = select(1, history.get_metadata(client, args.revision))
    logger.info('configRevision ok', {
        user = root and root.user, revision = args.revision,
    })
    return {
        revision = args.revision,
        yaml     = kv.value,
        ts       = meta and meta.ts or nil,
        user     = meta and meta.user or nil,
        action   = meta and meta.action or nil,
    }
end

function M.mutation_validate(root, args)
    require_role(root, 'validateConfig')
    local _, errs = schema.validate(args.yaml or '')
    if errs == nil then return { issues = {} } end
    return { issues = errs }
end

function M.mutation_prepare(root, args)
    require_role(root, 'proposeConfig')
    -- Diff against the LIVE etcd YAML (etcd is the source of truth
    -- after the SoT switch). Falling back to the disk file would let
    -- a no-op edit slip through whenever the file and etcd disagree
    -- (which they shouldn't, but defensive — etcd wins).
    local current_yaml
    do
        local client = etcd_client.get_client()
        if client ~= nil then
            local kv = select(1, client:get('config'))
            if kv ~= nil and kv.value ~= nil then current_yaml = kv.value end
        end
        if current_yaml == nil then current_yaml = read_local_yaml() end
    end
    local res, errs = twophase.prepare({
        yaml = args.yaml or '',
        user = root and root.user,
        current_yaml = current_yaml,
    })
    if res == nil then
        -- Distinct error class for no-op submissions so the SPA can
        -- render an inline info banner instead of a red validation
        -- error. Anything else stays under VALIDATION_FAILED.
        local first = errs and errs[1] or {}
        if first.code == 'NO_CHANGES' then
            error('NO_CHANGES: ' .. tostring(first.message
                or 'nothing to commit'))
        end
        error('VALIDATION_FAILED: ' .. tostring(first.message or '?'))
    end
    -- The plain Lua table comes through verbatim; the rock turns
    -- the `diff` list into GraphQL DiffOp records.
    return {
        prepared_id = res.prepared_id,
        expires_at  = res.expires_at,
        diff        = res.diff or {},
        warnings    = {},
    }
end

function M.mutation_commit(root, args)
    require_role(root, 'commitConfig')
    local entry = twophase.get_prepared(args.prepared_id)
    if entry == nil then
        error('PREPARED_NOT_FOUND: ' .. tostring(args.prepared_id))
    end

    -- etcd is the source of truth for cluster-wide config. Build a
    -- client from `config.etcd.*` and write the YAML there. If the
    -- block is missing or etcd is unreachable, fall back to the
    -- legacy dry-run path so the operator still gets a clear
    -- "validated but not persisted" outcome instead of an error.
    local client, client_err = etcd_client.get_client()
    local commit_opts = {}
    if client ~= nil then commit_opts.etcd = client end

    local result, err = twophase.commit(args.prepared_id, commit_opts)
    if err then error('COMMIT_FAILED: ' .. tostring(err)) end

    if commit_opts.etcd == nil then
        logger.info('config commit dry-run (no etcd)', {
            prepared_id = args.prepared_id, reason = client_err,
        })
        return {
            revision = 0,
            applied  = true,
            message  = 'validated and prepared, but not persisted: '
                .. (client_err or 'etcd unavailable')
                .. '. Configure config.etcd.endpoints in cluster.yaml '
                .. 'so commits land in the cluster-wide source of truth.',
        }
    end

    local revision = (result and result.revision) or 0

    -- Tarantool's etcd source does NOT poll automatically — it only
    -- re-reads on `config:reload()`. Fan-out a reload to every peer
    -- so the new YAML becomes effective immediately instead of
    -- waiting for the next manual `forceReapplyConfig`. Best-effort;
    -- partial failures land in the response message so the operator
    -- can re-run the reload on stragglers.
    local reload_outcome = ''
    do
        local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
        local peers_ok, peers = pcall(require, 'webui.cluster.peers')
        if rpc_ok and peers_ok then
            local all = {}
            for name in pairs(peers.list() or {}) do table.insert(all, name) end
            if #all > 0 then
                -- 15s budget per peer. `config:reload()` re-runs role
                -- start, which can coincide with a raft re-election
                -- (credentials/replicaset/iproto changes all force one).
                -- 5s was too tight: the peer that wins the election
                -- always reported as a timeout even though it
                -- recovered seconds later. 15s comfortably covers a
                -- re-election plus role re-init on the local hardware
                -- the dev cluster runs on.
                local ok_call, res_each = pcall(rpc.map_eval,
                    'require("config"):reload(); return true',
                    {}, { timeout = 15, peers = all })
                if ok_call then
                    local failed = {}
                    for name, r in pairs(res_each) do
                        if not (r and r.ok) then
                            table.insert(failed, name .. '=' ..
                                tostring(r and r.err or 'unknown'))
                        end
                    end
                    if #failed == 0 then
                        reload_outcome = ' Reloaded on '
                            .. tostring(#all) .. ' peer(s).'
                    else
                        reload_outcome = ' Reload partial: failed on '
                            .. table.concat(failed, ', ') .. '.'
                    end
                else
                    reload_outcome = ' Reload fan-out errored: '
                        .. tostring(res_each) .. '.'
                end
            end
        end
    end

    local mirror_outcome = ''
    if result and result.file_mirror then
        local m = result.file_mirror
        if #m.failed == 0 and #m.ok > 0 then
            mirror_outcome = ' cluster.yaml mirrored on ' ..
                tostring(#m.ok) .. ' instance(s).'
        elseif #m.failed > 0 then
            mirror_outcome = ' cluster.yaml mirror partial: ok=' ..
                tostring(#m.ok) .. ', failed=' ..
                table.concat(m.failed, '; ') .. '.'
        end
    end

    logger.info('config commit ok', {
        prepared_id = args.prepared_id, revision = revision,
    })
    return {
        revision = revision,
        applied  = true,
        message  = 'committed to etcd (revision ' .. tostring(revision)
            .. ').' .. reload_outcome .. mirror_outcome,
    }
end

-- rollbackConfig(revision): roll the cluster YAML back to a previous
-- revision from the /history/ timeline. Atomic shape: validate-target
-- → propose → commit (which fan-outs reload) → audit.
--
-- Pre-check: validateConfig on the target YAML. If the target
-- references roles/users/keys that were since removed from the live
-- environment, raise ROLLBACK_INCOMPATIBLE so the operator edits
-- current config first instead of producing a commit that would
-- pass schema-validation-at-commit-time-N but fail now.
function M.mutation_rollback(root, args)
    require_role(root, 'rollbackConfig')
    if args == nil or args.revision == nil then
        error('VALIDATION_ERROR: revision is required')
    end

    local client, client_err = etcd_client.get_client()
    if client == nil then
        error('ROLLBACK_INCOMPATIBLE: etcd unavailable (' ..
            tostring(client_err) .. ')')
    end

    local kv, get_err = history.get(client, args.revision)
    if get_err then
        error('ROLLBACK_LOOKUP_FAILED: ' .. tostring(get_err))
    end
    if kv == nil then
        error('REVISION_NOT_FOUND: ' .. tostring(args.revision))
    end
    local target_yaml = kv.value

    -- Schema compat pre-check: if the snapshot references things now
    -- gone, surface unresolved refs in the error details so the SPA
    -- can render a useful banner ("references removed roles: ...").
    local _, validation_errs = schema.validate(target_yaml)
    if validation_errs ~= nil and #validation_errs > 0 then
        local first = validation_errs[1] or {}
        error('ROLLBACK_INCOMPATIBLE: target revision references '
            .. 'config that is no longer valid: '
            .. tostring(first.message or 'unknown'))
    end

    -- For audit's diff_summary we need before/after; pull current
    -- YAML via the same channel propose uses.
    local current_kv = select(1, client:get('config'))
    local current_yaml = current_kv and current_kv.value or ''
    local diff_result = diff_module.diff_revisions(current_yaml, target_yaml)
    local diff_summary = {}
    for _, op in ipairs(diff_result.ops or {}) do
        table.insert(diff_summary, op.op .. ' ' .. op.path)
    end
    -- Cap to keep the audit payload bounded (large rollbacks can
    -- generate hundreds of ops; the full diff is recoverable from
    -- the timeline keys, audit only needs a quick eyeball summary).
    if #diff_summary > 50 then
        local truncated = {}
        for i = 1, 50 do truncated[i] = diff_summary[i] end
        table.insert(truncated, string.format('… (+%d more)',
            #diff_summary - 50))
        diff_summary = truncated
    end

    local prepared, prepare_errs = twophase.prepare({
        yaml         = target_yaml,
        user         = root and root.user,
        current_yaml = current_yaml,
    })
    if prepared == nil then
        local msg = (prepare_errs and prepare_errs[1]
            and prepare_errs[1].message) or '?'
        error('ROLLBACK_PROPOSE_FAILED: ' .. msg)
    end

    local commit_result, commit_err = twophase.commit(prepared.prepared_id, {
        etcd   = client,
        action = 'rollback',
    })
    if commit_err then
        error('ROLLBACK_COMMIT_FAILED: ' .. tostring(commit_err))
    end

    local new_revision = (commit_result and commit_result.revision) or 0

    -- Fire-and-forget audit + fan-out reload (mirrors mutation_commit).
    pcall(function()
        audit.record({
            user       = root and root.user,
            action     = 'config.rollback',
            scope      = 'cluster',
            payload    = {
                from_revision = current_kv and current_kv.revision,
                to_revision   = args.revision,
                new_revision  = new_revision,
                diff_summary  = diff_summary,
            },
            request_id = root and root.request_id,
        })
    end)

    local reload_outcome = ''
    do
        local rpc_ok, rpc = pcall(require, 'webui.cluster.rpc')
        local peers_ok, peers = pcall(require, 'webui.cluster.peers')
        if rpc_ok and peers_ok then
            local all = {}
            for name in pairs(peers.list() or {}) do
                table.insert(all, name)
            end
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

    logger.info('config rollback ok', {
        user          = root and root.user,
        from_revision = current_kv and current_kv.revision,
        to_revision   = args.revision,
        new_revision  = new_revision,
        ops           = #diff_summary,
    })

    return {
        revision = new_revision,
        applied  = true,
        message  = 'rolled back to revision ' .. tostring(args.revision)
            .. ' (new etcd revision ' .. tostring(new_revision) .. ').'
            .. reload_outcome,
    }
end

function M.mutation_abort(root, args)
    require_role(root, 'abortConfig')
    local _, err = twophase.abort(args.prepared_id)
    if err then error('ABORT_FAILED: ' .. tostring(err)) end
    return { revision = 0, applied = false, message = 'aborted' }
end

return M
