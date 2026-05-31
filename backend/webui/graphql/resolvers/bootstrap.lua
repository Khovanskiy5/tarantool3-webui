--
-- Resolvers for the initial bootstrap wizard (Task 36).
--
-- The wizard runs against a fresh etcd prefix and walks the operator
-- through name + template selection. The mutation renders YAML,
-- validates it with the existing schema validator, prepares it
-- through the two-phase pipeline, and immediately commits — there
-- is nothing prior to overwrite so the dry-run / staged-commit
-- ceremony does not apply at first boot.
--
-- Etcd integration is best-effort: when the role config carries
-- `config.etcd.endpoints`, status uses it to probe; otherwise the
-- check falls back to the file source. Initialize() writes through
-- twophase.commit which will land in etcd if configured, or no-op
-- (dry-run) if not.
--

local fio = require('fio')

local rbac     = require('webui.auth.rbac')
local bootstrap = require('webui.config_store.bootstrap')
local twophase  = require('webui.config_store.twophase')
local schema    = require('webui.config_store.schema')
local log_util  = require('webui.log_util')
local logger    = log_util.with_tag('graphql.bootstrap')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

local function read_local_yaml()
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
            if body then return body end
        end
    end
    return ''
end

-- Locate an etcd client from the live `config:get('config.etcd')`
-- block. Returns (client, nil) when configured + reachable,
-- (nil, reason) otherwise. The mutation only treats a reachable
-- etcd as authoritative; without one it commits in dry-run mode
-- and lets the operator copy the rendered YAML by hand.
local etcd_client_mod = require('webui.config_store.client')
local lazy_etcd_client = etcd_client_mod.get_client

-- ── queries ─────────────────────────────────────────────────────────

function M.query_status(root)
    require_role(root, 'bootstrapStatus')
    local etcd, etcd_err = lazy_etcd_client()
    local res = bootstrap.status({
        local_yaml  = read_local_yaml(),
        etcd_client = etcd,
    })
    res.etcd_available = etcd ~= nil
    res.etcd_error     = (etcd == nil) and etcd_err or nil
    return res
end

function M.query_templates(root)
    require_role(root, 'bootstrapStatus')
    return { templates = bootstrap.list_templates() }
end

function M.query_render(root, args)
    require_role(root, 'bootstrapStatus')
    local yaml, err = bootstrap.render(
        args.template or '', args.cluster_name)
    if yaml == nil then
        return { yaml = nil, error = err }
    end
    return { yaml = yaml, error = box.NULL }
end

-- ── mutation ────────────────────────────────────────────────────────

-- Builds a uniform { ok = false, message = ... } envelope so the
-- mutation can surface expected operational errors (NOT_NEEDED,
-- TEMPLATE_NOT_FOUND, …) without bouncing through GraphQL's
-- INTERNAL masking. Only truly unexpected failures still raise.
local function fail(message, code, extras)
    extras = extras or {}
    return {
        ok          = false,
        yaml        = box.NULL,
        revision    = 0,
        dry_run     = false,
        etcd_used   = extras.etcd_used == true,
        etcd_error  = extras.etcd_error,
        error_code  = code,
        message     = message,
    }
end

function M.mutation_initialize(root, args)
    require_role(root, 'bootstrapInitialize')
    local template_name = args.template or ''
    local cluster_name  = args.cluster_name or 'tarantool-cluster'

    -- Refuse to initialize over an existing config. The status
    -- query is the friendly upstream check; the mutation does the
    -- same guard so a stale SPA cannot stomp a live deployment.
    local etcd, etcd_err = lazy_etcd_client()
    local status = bootstrap.status({
        local_yaml  = read_local_yaml(),
        etcd_client = etcd,
    })
    if not status.needed then
        logger.warn('bootstrap initialize refused', {
            reason = status.reason, source = status.source,
        })
        return fail(
            status.reason or 'already configured',
            'BOOTSTRAP_NOT_NEEDED',
            { etcd_used = etcd ~= nil, etcd_error = etcd_err })
    end

    local yaml, render_err = bootstrap.render(template_name, cluster_name)
    if yaml == nil then
        return fail(
            'cannot render template ' .. template_name,
            render_err or 'TEMPLATE_NOT_FOUND',
            { etcd_used = etcd ~= nil, etcd_error = etcd_err })
    end

    -- Validate against the live JSON Schema. A failed schema check
    -- means the template ships an invalid baseline — that's a code
    -- bug in this module, but it surfaces as a structured response
    -- rather than a 500 so the operator can copy the YAML and
    -- file an issue.
    local _, errs = schema.validate(yaml)
    if errs ~= nil and #errs > 0 then
        logger.error('bootstrap template failed validation',
            { template = template_name, issues = errs })
        return fail(
            errs[1].message or 'schema error',
            'TEMPLATE_INVALID',
            { etcd_used = etcd ~= nil, etcd_error = etcd_err })
    end

    local prepare_res, prep_errs = twophase.prepare({
        yaml         = yaml,
        user         = root and root.user,
        current_yaml = '',
    })
    if prepare_res == nil then
        return fail(
            tostring(prep_errs and prep_errs[1] and prep_errs[1].message
                or 'prepare failed'),
            'PREPARE_FAILED',
            { etcd_used = etcd ~= nil, etcd_error = etcd_err })
    end

    local commit_res, commit_err = twophase.commit(
        prepare_res.prepared_id, { etcd = etcd })
    if commit_res == nil then
        return fail(
            tostring(commit_err) or 'commit failed',
            'COMMIT_FAILED',
            { etcd_used = etcd ~= nil, etcd_error = etcd_err })
    end

    logger.info('bootstrap initialize ok', {
        template = template_name,
        cluster_name = cluster_name,
        revision = commit_res.revision,
        dry_run  = commit_res.dry_run == true,
        etcd_available = etcd ~= nil,
        etcd_error     = etcd_err,
    })

    return {
        ok          = true,
        yaml        = yaml,
        revision    = commit_res.revision or 0,
        dry_run     = commit_res.dry_run == true,
        etcd_used   = etcd ~= nil,
        etcd_error  = (etcd == nil) and etcd_err or nil,
        error_code  = box.NULL,
        message     = box.NULL,
    }
end

return M
