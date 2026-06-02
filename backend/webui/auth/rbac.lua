--
-- Declarative RBAC.
--
-- Four roles, ranked low → high: viewer < operator < admin < superuser.
-- A request is allowed when *any* role assigned to the user is at the
-- required rank or higher. The role rank is a plain integer so the
-- check is a single map lookup + numeric compare; it cannot fail open
-- because unknown roles map to nil and short-circuit to false.
--
-- User → roles mapping comes from cluster-wide config
-- (`roles_cfg.webui.rbac.users`). This module keeps the runtime map
-- separate from the dev fixture defaults so the wiring code in Task 30
-- can call `M.set_user_roles(map)` from the config applier without
-- touching the defaults shipped with the dev compose.
--

local M = {}

M.ROLES = {
    viewer    = 1,
    operator  = 2,
    admin     = 3,
    superuser = 4,
}

-- Dev-fixture mapping. Production deployments override via the
-- cluster-wide `roles_cfg.webui.rbac.users` block.
M.DEFAULT_USER_TO_ROLES = {
    admin_dev     = { 'admin' },
    operator_dev  = { 'operator' },
    viewer_dev    = { 'viewer' },
    superuser_dev = { 'superuser' },
}

local runtime_users = {}

function M.set_user_roles(map)
    if type(map) ~= 'table' then return end
    runtime_users = {}
    for user, roles in pairs(map) do
        if type(user) == 'string' and type(roles) == 'table' then
            runtime_users[user] = roles
        end
    end
end

function M.user_roles(user_name)
    if type(user_name) ~= 'string' then return {} end
    return runtime_users[user_name]
        or M.DEFAULT_USER_TO_ROLES[user_name]
        or {}
end

function M.role_rank(role)
    return M.ROLES[role] or 0
end

function M.user_rank(user_roles)
    local best = 0
    if type(user_roles) ~= 'table' then return best end
    for _, r in ipairs(user_roles) do
        local rank = M.role_rank(r)
        if rank > best then best = rank end
    end
    return best
end

function M.allowed(user_roles, required)
    local rank = M.role_rank(required)
    if rank == 0 then return false end
    return M.user_rank(user_roles) >= rank
end

-- ─────────────────────────────────────────────────────────────────────
-- Pre-bootstrap bypass.
--
-- A handful of GraphQL fields MUST be reachable before any admin
-- user exists — most importantly `bootstrapInitialize` itself, which
-- is what creates the first admin. Without a bypass the wizard is
-- a deadlock: mutation gates on admin, admin only appears after
-- mutation. We detect "etcd has no cluster config" via
-- `webui.config_store.bootstrap.status` (which already encapsulates
-- the etcd-vs-file check) and cache the result for 1s so the gate
-- does not amortise a network round-trip onto every resolver call.
--
-- The bypass is intentionally narrow: only the listed fields, only
-- while `<prefix>/config/all` is absent. As soon as `bootstrapInitialize`
-- writes a config to etcd, the next `is_pre_bootstrap()` call returns
-- false and the gate closes back on the normal admin rank check.
-- ─────────────────────────────────────────────────────────────────────

M.PRE_BOOTSTRAP_FIELDS = {
    bootstrapInitialize = true,
}

local PRE_BOOTSTRAP_TTL_SEC = 1

local pre_boot_cache = {
    value = nil,
    expires_at = 0,
}

local function lazy_probe()
    -- Lazy require to avoid a cycle: rbac is loaded very early,
    -- bootstrap pulls in lyaml + etcd helpers which we want kept
    -- off the hot path. pcall keeps the function honest when the
    -- probes themselves blow up (config:get can raise during reload).
    local ok_bs, bs = pcall(require, 'webui.config_store.bootstrap')
    if not ok_bs then return false end
    local ok_cl, client_mod = pcall(require, 'webui.config_store.client')
    local etcd = nil
    if ok_cl and type(client_mod.get_client) == 'function' then
        local c, _ = pcall(function() return client_mod.get_client() end)
        if type(c) == 'table' then etcd = c end
    end
    local local_yaml = ''
    local ok_st, st = pcall(bs.status, {
        etcd_client = etcd,
        local_yaml  = local_yaml,
    })
    if not ok_st or type(st) ~= 'table' then return false end
    return st.needed == true
end

function M.is_pre_bootstrap()
    local now = require('fiber').time()
    if pre_boot_cache.value ~= nil and now < pre_boot_cache.expires_at then
        return pre_boot_cache.value
    end
    local v = lazy_probe()
    pre_boot_cache.value = v
    pre_boot_cache.expires_at = now + PRE_BOOTSTRAP_TTL_SEC
    return v
end

function M._invalidate_pre_bootstrap_cache()
    pre_boot_cache.value = nil
    pre_boot_cache.expires_at = 0
end

function M.allowed_for_field(user_roles, field)
    if field == nil then return false end
    local required = M.GRAPHQL_FIELD[field] or 'admin'
    if M.PRE_BOOTSTRAP_FIELDS[field] and M.is_pre_bootstrap() then
        local ok_lu, lu = pcall(require, 'webui.log_util')
        if ok_lu then
            lu.with_tag('rbac').warn('pre_bootstrap_bypass', {
                field = field,
                required = required,
                reason = 'cluster has no config yet — gate bypassed',
            })
        end
        return true
    end
    return M.allowed(user_roles, required)
end

-- ─────────────────────────────────────────────────────────────────────
-- Route map. Routes not present here are treated as `session`
-- (login required, no role check). Mutations always require CSRF.
-- ─────────────────────────────────────────────────────────────────────

M.REST_AUTH = {
    -- Public surface: no session needed.
    ['GET  /api/health']       = 'public',
    ['POST /api/auth/login']   = 'public',
    ['POST /api/auth/logout']  = 'public',
    -- /me requires a valid session but no role above viewer.
    ['GET  /api/auth/me']      = 'session',
    -- The Lua/SQL console (Task 44) is restricted to superuser.
    ['POST /api/eval']         = 'superuser',
    -- WebSocket is gated by its own handshake (Task 26a).
    ['GET  /ws']               = 'public',
    -- GraphQL surface — session always; per-field RBAC enforced
    -- inside the resolvers because the field set varies per request.
    ['POST /admin/api']        = 'session',
    ['GET  /admin/api/explore']= 'admin',
}

-- GraphQL field → required role. Resolvers consult this map and
-- raise FORBIDDEN before doing any work. Unset fields default to
-- `viewer` for queries and `admin` for mutations (see resolver
-- helpers in Task 30+).
M.GRAPHQL_FIELD = {
    -- Queries
    cluster        = 'viewer',
    config         = 'viewer',
    configHistory  = 'viewer',
    configRevision = 'operator',
    schema         = 'viewer',
    tuples         = 'viewer',
    savedQueries   = 'operator',
    users        = 'admin',
    audit        = 'admin',
    verifyAuditChain = 'admin',
    recoverySnapshot = 'admin',
    recoveryAction   = 'admin',
    issues       = 'viewer',
    suggestions  = 'viewer',
    metrics      = 'viewer',
    health       = 'viewer',
    -- Mutations (operators can propose; only admin/superuser commit)
    proposeConfig = 'operator',
    validateConfig = 'operator',
    commitConfig  = 'admin',
    abortConfig   = 'operator',
    rollbackConfig = 'admin',
    forceTakeLock = 'admin',
    setFailover   = 'admin',
    promote       = 'admin',
    expel         = 'admin',
    joinInstance  = 'admin',
    rebootstrapInstance = 'admin',
    -- Phase 5 cluster operator controls (Cartridge-style).
    -- `editTopology` is the atomic primary mutation; the alias
    -- mutations compose `TopologyEdit` inputs and route through it.
    editTopology          = 'admin',
    setReplicasetRoles    = 'admin',
    createReplicaset      = 'admin',
    editReplicaset        = 'admin',
    addInstance           = 'admin',
    expelInstance         = 'admin',
    promoteInstance       = 'admin',
    demoteInstance        = 'admin',
    setInstanceState      = 'admin',
    setFailoverMode       = 'admin',
    pauseFailover         = 'admin',
    resumeFailover        = 'admin',
    -- Phase 2 Task 2.3 data-explorer tuple mutations.
    tupleInsert           = 'admin',
    tupleReplace          = 'admin',
    tupleUpdate           = 'admin',
    tupleDelete           = 'admin',
    createSpace           = 'admin',
    dropSpace             = 'admin',
    alterSpace            = 'admin',
    createIndex           = 'admin',
    dropIndex             = 'admin',
    -- Phase 3 Task 3.4 — SQL workbench snippet library.
    saveQuery             = 'operator',
    deleteSavedQuery      = 'operator',
    setUserRoles  = 'admin',
    setLabels     = 'operator',
    setVshardWeight = 'admin',
    setVshardGroup  = 'admin',
    bootstrapVshard = 'admin',
    bootstrapStatus     = 'admin',
    bootstrapTemplates  = 'admin',
    bootstrapRender     = 'admin',
    bootstrapInitialize = 'admin',
    webhooks            = 'admin',
    testWebhook         = 'admin',
    clearDeadLetter     = 'admin',
    exportAudit   = 'admin',
    runEval       = 'superuser',
    runSql        = 'superuser',
    hotReloadModule = 'superuser',
}

return M
