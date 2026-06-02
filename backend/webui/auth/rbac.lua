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
    clusterLiveness = 'viewer',
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
