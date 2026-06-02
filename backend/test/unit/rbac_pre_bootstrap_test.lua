--
-- Unit test for the pre-bootstrap RBAC bypass (T0).
--
-- Without it, `bootstrapInitialize` would require an admin session,
-- but no admin user exists yet on a fresh cluster — bootstrap creates
-- the first admin. The bypass narrowly opens `bootstrapInitialize`
-- (and any future field listed in `PRE_BOOTSTRAP_FIELDS`) while
-- `webui.config_store.bootstrap.status` reports `needed = true`.
--
-- We monkeypatch `package.loaded` for `webui.config_store.bootstrap`
-- and `webui.config_store.client` so the probe is deterministic — no
-- real etcd dependency, no file I/O.
--

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local rbac = require('webui.auth.rbac')

local g = t.group('rbac_pre_bootstrap')

local saved_bs_mod
local saved_cl_mod

g.before_each(function()
    saved_bs_mod = package.loaded['webui.config_store.bootstrap']
    saved_cl_mod = package.loaded['webui.config_store.client']
    rbac._invalidate_pre_bootstrap_cache()
end)

g.after_each(function()
    package.loaded['webui.config_store.bootstrap'] = saved_bs_mod
    package.loaded['webui.config_store.client']    = saved_cl_mod
    rbac._invalidate_pre_bootstrap_cache()
end)

local function set_status_needed(needed)
    package.loaded['webui.config_store.bootstrap'] = {
        status = function(_opts) return { needed = needed } end,
    }
    package.loaded['webui.config_store.client'] = {
        get_client = function() return nil end,
    }
end

-- ── is_pre_bootstrap ────────────────────────────────────────────────

g.test_pre_bootstrap_true_when_bootstrap_needed = function()
    set_status_needed(true)
    t.assert_equals(rbac.is_pre_bootstrap(), true)
end

g.test_pre_bootstrap_false_when_already_bootstrapped = function()
    set_status_needed(false)
    t.assert_equals(rbac.is_pre_bootstrap(), false)
end

g.test_pre_bootstrap_caches_within_ttl = function()
    local calls = 0
    package.loaded['webui.config_store.bootstrap'] = {
        status = function() calls = calls + 1
            return { needed = true } end,
    }
    package.loaded['webui.config_store.client'] = {
        get_client = function() return nil end,
    }
    rbac.is_pre_bootstrap()
    rbac.is_pre_bootstrap()
    rbac.is_pre_bootstrap()
    t.assert_equals(calls, 1, 'second/third call must hit cache')
end

-- ── allowed_for_field ───────────────────────────────────────────────

g.test_bypass_opens_bootstrap_initialize = function()
    set_status_needed(true)
    -- Empty user roles, no session whatsoever.
    t.assert_equals(rbac.allowed_for_field({}, 'bootstrapInitialize'), true)
end

g.test_bypass_does_not_open_other_fields = function()
    set_status_needed(true)
    -- Even when pre-bootstrap, non-listed fields stay locked.
    t.assert_equals(rbac.allowed_for_field({}, 'cluster'), false)
    t.assert_equals(rbac.allowed_for_field({}, 'editTopology'), false)
end

g.test_bypass_closes_after_bootstrap = function()
    set_status_needed(false)
    t.assert_equals(rbac.allowed_for_field({}, 'bootstrapInitialize'), false,
        'after etcd has config/all, the gate must be back to admin-only')
end

g.test_admin_user_still_allowed = function()
    set_status_needed(false)
    t.assert_equals(
        rbac.allowed_for_field({ 'admin' }, 'bootstrapInitialize'), true)
end

g.test_viewer_user_blocked_for_bootstrap = function()
    set_status_needed(false)
    t.assert_equals(
        rbac.allowed_for_field({ 'viewer' }, 'bootstrapInitialize'), false)
end

g.test_unknown_field_returns_false = function()
    set_status_needed(true)
    t.assert_equals(rbac.allowed_for_field({}, nil), false)
end

g.test_pre_bootstrap_fields_table_is_narrow = function()
    -- A growing PRE_BOOTSTRAP_FIELDS is a foot-gun: every extra entry
    -- weakens the auth surface. Pin the list explicitly.
    local count = 0
    for _ in pairs(rbac.PRE_BOOTSTRAP_FIELDS) do count = count + 1 end
    t.assert_equals(count, 1,
        'PRE_BOOTSTRAP_FIELDS should hold only bootstrapInitialize. '
        .. 'Anything else needs a security review.')
    t.assert(rbac.PRE_BOOTSTRAP_FIELDS.bootstrapInitialize)
end
