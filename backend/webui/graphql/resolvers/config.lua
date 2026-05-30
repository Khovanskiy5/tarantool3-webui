--
-- Resolvers for the config-editor GraphQL surface.
--
-- Until etcd is fully provisioned (operators wire `roles_cfg.webui.etcd`
-- into their cluster config), these resolvers run in "local" mode:
-- everything happens in-memory on the responding instance. The contract
-- on the wire stays stable so the SPA can already render the editor.
--

local fio = require('fio')

local twophase = require('webui.config_store.twophase')
local schema   = require('webui.config_store.schema')
local rbac     = require('webui.auth.rbac')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('graphql.config')

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
    local candidates = {
        os.getenv('TT_CONFIG_PATH'),
        '/opt/webui/etc/cluster.yaml',
        'docker/configs/cluster.yaml',
    }
    for _, path in ipairs(candidates) do
        if path and #path > 0 then
            local f = fio.open(path)
            if f ~= nil then
                local body = f:read()
                f:close()
                if body then return body, 'file' end
            end
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
    -- Local mode: pretend to apply and clear. Real etcd CAS will
    -- happen in the post-bootstrap commit task.
    local _, err = twophase.commit(args.prepared_id, {})
    if err then error('COMMIT_FAILED: ' .. tostring(err)) end
    logger.info('config commit local-only', { prepared_id = args.prepared_id })
    return { revision = 0, applied = true,
             message = 'committed in local mode (etcd not configured)' }
end

function M.mutation_abort(root, args)
    require_role(root, 'abortConfig')
    local _, err = twophase.abort(args.prepared_id)
    if err then error('ABORT_FAILED: ' .. tostring(err)) end
    return { revision = 0, applied = false, message = 'aborted' }
end

return M
