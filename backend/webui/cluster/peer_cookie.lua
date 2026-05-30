--
-- Peer cookie / system user `webui_peer` bootstrap.
--
-- Every WebUI instance needs a uniform user that the other peers can
-- authenticate as when this instance pulls data over net.box. The
-- production-grade story is: declare the user inside the cluster-wide
-- config (`credentials.users.webui_peer`) and roll the password via
-- the two-phase commit pipeline. This module is the fallback path
-- when the config has not declared the user yet — typical for dev
-- compose, first-boot before the operator pushes a config, or for
-- CE deployments that bootstrap by env.
--
-- Resolution order (first non-empty wins):
--   1. Password injected through the cluster config (passed by the
--      caller as `opts.config_password`). This is the authoritative
--      source in prod and never reaches box.cfg.credentials.
--   2. Environment variable `TT_WEBUI_PEER_PASSWORD`. Used by docker
--      compose to share a secret across the three dev instances.
--   3. Persisted entry in the per-instance `_webui_meta` space.
--      Survives restarts even when env and config did not provide
--      one — this is what carries the next two paths.
--   4. Generated random 32-character base64. Persisted to
--      `_webui_meta` so the peer cookie is stable across restarts.
--      A WARN log makes the ad-hoc credential obvious in the log
--      stream so operators can replace it with a managed secret.
--
-- The public surface is intentionally narrow:
--   * `resolve_password(opts)` — pure function used by tests.
--   * `bootstrap(opts)` — touches `box`, creates the user, grants
--     the minimum privileges, returns `{ user, source }`.
--
-- Splitting the logic this way keeps the resolver unit-testable
-- without spinning up a box instance, while the box-side path is
-- covered by integration tests once Task 16's peer pool can talk
-- back over net.box.
--

local checks = require('checks')
local digest = require('digest')
local fiber  = require('fiber')

local log_util = require('webui.log_util')
local logger = log_util.with_tag('peer_cookie')

local M = {}

local USER_NAME      = 'webui_peer'
local META_SPACE     = '_webui_meta'
local META_KEY       = 'webui_peer_password'
local RANDOM_BYTES   = 24

M.USER_NAME = USER_NAME
M.META_SPACE = META_SPACE
M.META_KEY = META_KEY

-- ─────────────────────────────────────────────────────────────────────
-- Pure resolver
-- ─────────────────────────────────────────────────────────────────────

-- Returns (password, source) where source ∈ {config, env, meta, nil}.
-- A nil result means the caller must generate and persist a fresh
-- password. The function does not look at `os.getenv` or `box` so
-- tests can drive every branch by passing the inputs explicitly.
function M.resolve_password(opts)
    checks({
        config_password    = '?string',
        env_password       = '?string',
        persisted_password = '?string',
    })
    opts = opts or {}
    if type(opts.config_password) == 'string' and opts.config_password ~= '' then
        return opts.config_password, 'config'
    end
    if type(opts.env_password) == 'string' and opts.env_password ~= '' then
        return opts.env_password, 'env'
    end
    if type(opts.persisted_password) == 'string' and opts.persisted_password ~= '' then
        return opts.persisted_password, 'meta'
    end
    return nil, nil
end

function M.generate_password()
    -- url-safe base64 keeps the secret safe for environments that
    -- pass it through HTTP headers or YAML config (no '+', '/' or
    -- padding to escape).
    return digest.base64_encode(digest.urandom(RANDOM_BYTES),
        { nowrap = true, urlsafe = true })
end

-- ─────────────────────────────────────────────────────────────────────
-- box-side adapter
-- ─────────────────────────────────────────────────────────────────────

local function ensure_meta_space()
    if box.space[META_SPACE] ~= nil then return end
    -- `is_local = true` keeps each instance's peer-cookie state out
    -- of replication. The cluster-config path remains the authoritative
    -- way to share the same secret across peers; this space only
    -- carries an instance-local fallback.
    box.schema.space.create(META_SPACE, {
        if_not_exists = true,
        is_local      = true,
        format = {
            { name = 'key',   type = 'string' },
            { name = 'value', type = 'string' },
        },
    })
    box.space[META_SPACE]:create_index('primary', {
        parts          = { 'key' },
        if_not_exists  = true,
    })
end

local function read_persisted()
    ensure_meta_space()
    local tuple = box.space[META_SPACE]:get({ META_KEY })
    if tuple == nil then return nil end
    return tuple.value
end

local function persist(password)
    ensure_meta_space()
    box.space[META_SPACE]:replace({ META_KEY, password })
end

local function ensure_user(password)
    local existed = box.schema.user.exists(USER_NAME)
    if not existed then
        box.schema.user.create(USER_NAME, { if_not_exists = true })
        logger.info('created peer user', { user = USER_NAME })
    else
        logger.debug('peer user already exists', { user = USER_NAME })
    end
    -- box.schema.user.passwd is idempotent; calling it on every
    -- bootstrap is also what makes rotation through cluster-config
    -- work without an explicit reconcile step.
    box.schema.user.passwd(USER_NAME, password)
    return existed
end

local function grant_privileges()
    -- The peer pool (Task 16) needs the user to:
    --   * authenticate over iproto (read on universe)
    --   * call helper functions registered by later tasks
    --     (execute on universe)
    -- The grants are wrapped in pcall because Tarantool throws when
    -- a grant already exists; we cannot use `if_not_exists` for the
    -- old form without a target object.
    local ok, err = pcall(box.schema.user.grant,
        USER_NAME, 'read,execute', 'universe', nil, { if_not_exists = true })
    if not ok then
        logger.warn('grant universe failed', {
            user = USER_NAME,
            err  = tostring(err),
        })
    end
end

-- Detect whether this instance currently rejects writes. Raft
-- followers and explicit `read_only = true` configurations both
-- report `box.info.ro = true`; DDL aimed at the schema and the
-- `_user` system space must be performed on the leader and lets
-- replication carry the result to everyone else.
local function box_is_read_only()
    local ok, info = pcall(function() return box.info end)
    if not ok or type(info) ~= 'table' then return true end
    return info.ro == true
end

-- Pure leader path: do every DDL/DML on the assumption the caller
-- already verified box.info.ro == false. Pulled out of bootstrap()
-- so the background provisioner can re-use it once the instance
-- transitions to read-write.
local function provision_as_leader(opts, env_password)
    local password, source = M.resolve_password({
        config_password    = opts.config_password,
        env_password       = env_password,
        persisted_password = read_persisted(),
    })

    if password == nil then
        password = M.generate_password()
        persist(password)
        source = 'generated'
        logger.warn(
            'peer cookie auto-generated; declare credentials.users.webui_peer'
            .. ' in cluster config or set TT_WEBUI_PEER_PASSWORD to control rotation',
            { user = USER_NAME })
    elseif source == 'meta' then
        logger.debug('peer cookie loaded from meta space', {
            user = USER_NAME,
        })
    else
        logger.info('peer cookie loaded', {
            user   = USER_NAME,
            source = source,
        })
    end

    local existed = ensure_user(password)
    grant_privileges()

    if source ~= 'meta' and source ~= 'generated' then
        -- Persist the externally-supplied password so a later restart
        -- without env/config still finds the same cookie. A no-op if
        -- the value matches the current tuple.
        persist(password)
    end

    return source, not existed
end

-- Fork a daemon fiber that waits for this instance to transition
-- to read-write, then runs the leader path. The fiber is fire-and-
-- forget: if this instance never becomes leader (Raft follower for
-- its entire life), the fiber sits idle. There is exactly one
-- daemon per role lifecycle — bootstrap() flips the flag below so
-- repeated invocations do not pile up parallel watchers.
local provisioner_started = false
local function start_background_provisioner(opts, env_password)
    if provisioner_started then return end
    provisioner_started = true
    fiber.create(function()
        fiber.name('webui_peer_provisioner', { truncate = true })
        local wait_ok, wait_err = pcall(function()
            -- No timeout — we are happy to wait forever on a
            -- permanent replica; cluster-config + replication will
            -- still carry the user to us.
            box.ctl.wait_rw()
        end)
        if not wait_ok then
            logger.warn('wait_rw failed while waiting for leadership', {
                err = tostring(wait_err),
            })
            return
        end
        logger.info('instance became read-write; provisioning peer cookie', {
            user = USER_NAME,
        })
        local ok, err = pcall(provision_as_leader, opts, env_password)
        if not ok then
            logger.error('deferred peer cookie provisioning failed', {
                err = tostring(err),
            })
        end
    end)
end

-- Bootstrap the peer user. `opts.config_password` is what the caller
-- (init.lua) pulls out of the cluster config when present; the
-- env/meta/generated fallbacks are resolved here.
--
-- On a read-only instance (Raft follower / `read_only = true`) the
-- function does not touch the schema — the leader is responsible
-- for creating the `webui_peer` user and the `_webui_meta` space,
-- both of which replicate to every member of the replicaset. The
-- follower still resolves its outbound credential from env/config
-- so the peer pool (Task 16) can connect to peers.
--
-- Returns `{ user, source, created, deferred }` or `nil, err`.
function M.bootstrap(opts)
    checks('?table')
    opts = opts or {}

    -- Box must be alive — peer cookie runs after storage in the init
    -- order. We do not call box.cfg here; we just refuse to proceed
    -- if box hasn't been bootstrapped yet so a misconfiguration is
    -- loud instead of silent.
    if rawget(_G, 'box') == nil or type(box.schema) ~= 'table' then
        return nil, 'box is not initialised; peer_cookie.bootstrap called too early'
    end

    local env_password = os.getenv('TT_WEBUI_PEER_PASSWORD')

    if box_is_read_only() then
        -- The leader will provision the user; we only resolve the
        -- outbound credential so this instance can act as a client.
        -- The persisted-meta source is not consulted on followers
        -- because the meta space may not yet have been replicated.
        local pw, src = M.resolve_password({
            config_password = opts.config_password,
            env_password    = env_password,
        })
        if pw == nil then
            logger.info(
                'peer cookie DDL deferred; instance is read-only and no external credential is configured.'
                .. ' Leader will create the user, set TT_WEBUI_PEER_PASSWORD or cluster config to use it as a client',
                { user = USER_NAME })
        else
            logger.info('peer cookie DDL deferred; instance is read-only', {
                user   = USER_NAME,
                source = src,
            })
        end
        -- If this instance ever becomes the leader (Raft elections
        -- typically settle within a few seconds of role start), the
        -- daemon fiber below will run the full DDL path. On a
        -- permanent replica it stays idle.
        start_background_provisioner(opts, env_password)
        return {
            user     = USER_NAME,
            source   = src,
            created  = false,
            deferred = true,
        }
    end

    local source, created = provision_as_leader(opts, env_password)
    return {
        user     = USER_NAME,
        source   = source,
        created  = created,
        deferred = false,
    }
end

return M
