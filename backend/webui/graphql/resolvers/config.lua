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
local etcd_client  = require('webui.config_store.client')
local rbac         = require('webui.auth.rbac')
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
-- entrypoint script that boots Tarantool 3.x). Returning whatever
-- is on disk gives operators a starting point for the editor even
-- before etcd is wired.
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

function M.query_current(root)
    require_role(root, 'config')
    local yaml, source = read_local_yaml()
    return { yaml = yaml, revision = 0, source = source }
end

function M.mutation_validate(root, args)
    require_role(root, 'validateConfig')
    local _, errs = schema.validate(args.yaml or '')
    if errs == nil then return { issues = {} } end
    return { issues = errs }
end

function M.mutation_prepare(root, args)
    require_role(root, 'proposeConfig')
    local current_yaml = read_local_yaml()
    local res, errs = twophase.prepare({
        yaml = args.yaml or '',
        user = root and root.user,
        current_yaml = current_yaml,
    })
    if res == nil then
        error('VALIDATION_FAILED: ' .. (errs and errs[1] and errs[1].message or '?'))
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

    logger.info('config commit ok', {
        prepared_id = args.prepared_id, revision = revision,
    })
    return {
        revision = revision,
        applied  = true,
        message  = 'committed to etcd (revision ' .. tostring(revision)
            .. ').' .. reload_outcome,
    }
end

function M.mutation_abort(root, args)
    require_role(root, 'abortConfig')
    local _, err = twophase.abort(args.prepared_id)
    if err then error('ABORT_FAILED: ' .. tostring(err)) end
    return { revision = 0, applied = false, message = 'aborted' }
end

return M
