--
-- Unit tests for the admin_credentials path in
-- `webui.config_store.bootstrap` (T4) and the matching gate in
-- `webui.graphql.resolvers.bootstrap` (T5).
--
-- The existing `bootstrap_test.lua` keeps covering the legacy
-- `render(name, cluster_name)` two-arg form, which still ships
-- the hardcoded `admin_dev` fixtures for backward-compat. This
-- file pins the new opt-in path:
--   * admin_credentials enables `keep_dev_users = false`;
--   * the resulting YAML contains the operator-chosen user and
--     drops every `*_dev` legacy fixture;
--   * login + password validators reject the shapes T4 promised
--     (length floor, charset, missing letters / digits).
--

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('bootstrap_credentials')

local bootstrap = require('webui.config_store.bootstrap')

local function good_admin()
    return { login = 'admin', password = 'OperatorChose2026' }
end

-- ── render with admin_credentials ───────────────────────────────────

g.test_admin_credentials_user_present_in_yaml = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', good_admin())
    t.assert_equals(err, nil)
    t.assert_str_contains(yaml, 'admin:')
    t.assert_str_contains(yaml, 'OperatorChose2026')
end

g.test_admin_credentials_drops_dev_fixtures = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', good_admin())
    t.assert_equals(err, nil)
    -- keep_dev_users defaults to false when admin_credentials is set
    -- (per render() contract). No `*_dev` users may leak through.
    for _, dev in ipairs({
        'admin_dev', 'operator_dev', 'viewer_dev', 'superuser_dev',
    }) do
        t.assert(yaml:find(dev) == nil,
            'dev fixture user `' .. dev .. '` must not appear in the YAML '
            .. 'when admin_credentials is supplied (keep_dev_users default '
            .. 'flipped to false)')
    end
end

g.test_admin_credentials_keeps_webui_peer = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', good_admin())
    t.assert_equals(err, nil)
    -- webui_peer is the system net.box account. It MUST stay with the
    -- legacy literal so the shared bootstrap-dev cluster.yaml and the
    -- rendered cluster YAML use the same password — otherwise peer pool
    -- auth would drop right after `config:reload()`.
    t.assert_str_contains(yaml, 'webui_peer:')
    t.assert_str_contains(yaml, 'webui-peer-password')
end

g.test_admin_credentials_keeps_replicator = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', good_admin())
    t.assert_equals(err, nil)
    -- replicator is the replication-bus account; same rationale as
    -- webui_peer above.
    t.assert_str_contains(yaml, 'replicator:')
end

g.test_keep_dev_users_explicit_true_grandfathers_legacy = function()
    local yaml, err = bootstrap.render(
        'single-instance', 'demo', good_admin(), { keep_dev_users = true })
    t.assert_equals(err, nil)
    -- Explicit opt-in restores the dev fixtures alongside the
    -- operator-chosen admin. Used in tests / niche scripts.
    t.assert_str_contains(yaml, 'admin_dev:')
    t.assert_str_contains(yaml, 'admin:')
end

-- ── validation: login ──────────────────────────────────────────────

g.test_rejects_empty_login = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = '', password = 'OperatorChose2026',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_LOGIN')
end

g.test_rejects_short_login = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = 'ab', password = 'OperatorChose2026',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_LOGIN')
end

g.test_rejects_login_starting_with_digit = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = '1admin', password = 'OperatorChose2026',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_LOGIN')
end

g.test_rejects_login_with_uppercase = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = 'Admin', password = 'OperatorChose2026',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_LOGIN')
end

g.test_rejects_login_with_dash = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = 'my-admin', password = 'OperatorChose2026',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_LOGIN')
end

g.test_accepts_login_with_underscore = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = 'my_admin', password = 'OperatorChose2026',
    })
    t.assert_equals(err, nil)
    t.assert_str_contains(yaml, 'my_admin:')
end

-- ── validation: password ───────────────────────────────────────────

g.test_rejects_short_password = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = 'admin', password = 'Short1',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_PASSWORD')
end

g.test_rejects_letters_only_password = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = 'admin', password = 'OnlyLettersHere',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_PASSWORD')
end

g.test_rejects_digits_only_password = function()
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        login = 'admin', password = '111122223333',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_PASSWORD')
end

g.test_admin_credentials_missing_login_or_password_rejected = function()
    -- Missing login (only password supplied) → INVALID_ADMIN_LOGIN,
    -- because the validator checks login first.
    local yaml, err = bootstrap.render('single-instance', 'demo', {
        password = 'OperatorChose2026',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_LOGIN')

    -- Missing password (login present and valid) → INVALID_ADMIN_PASSWORD.
    yaml, err = bootstrap.render('single-instance', 'demo', {
        login = 'admin',
    })
    t.assert_equals(yaml, nil)
    t.assert_equals(err, 'INVALID_ADMIN_PASSWORD')
end

-- ── nil admin_credentials stays legacy ─────────────────────────────

g.test_nil_admin_credentials_stays_legacy_with_dev_users = function()
    local yaml, err = bootstrap.render('single-instance', 'demo')
    t.assert_equals(err, nil)
    -- Legacy path still ships the dev fixtures so existing tests and
    -- dev-compose scripts don't break.
    t.assert_str_contains(yaml, 'admin_dev:')
    t.assert_str_contains(yaml, 'superuser_dev:')
end
