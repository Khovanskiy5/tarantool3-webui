-- Unit tests for backend/webui/cluster/peer_cookie.lua
--
-- Only the pure resolver path is covered here. The box-side branch
-- (user create + grant + meta-space persistence) needs a live
-- Tarantool instance and is exercised by the integration suite via
-- backend/test/helpers/server.lua once Task 16's peer pool can
-- authenticate using the cookie.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local peer_cookie = require('webui.cluster.peer_cookie')

local g = t.group('peer_cookie')

-- ── resolve_password — priority order ────────────────────────────────

g.test_resolve_config_wins_over_env_and_meta = function()
    local pw, src = peer_cookie.resolve_password({
        config_password    = 'from-config',
        env_password       = 'from-env',
        persisted_password = 'from-meta',
    })
    t.assert_equals(pw, 'from-config')
    t.assert_equals(src, 'config')
end

g.test_resolve_env_wins_when_no_config = function()
    local pw, src = peer_cookie.resolve_password({
        env_password       = 'from-env',
        persisted_password = 'from-meta',
    })
    t.assert_equals(pw, 'from-env')
    t.assert_equals(src, 'env')
end

g.test_resolve_meta_when_env_absent = function()
    local pw, src = peer_cookie.resolve_password({
        persisted_password = 'from-meta',
    })
    t.assert_equals(pw, 'from-meta')
    t.assert_equals(src, 'meta')
end

g.test_resolve_returns_nil_when_no_source = function()
    local pw, src = peer_cookie.resolve_password({})
    t.assert_equals(pw, nil)
    t.assert_equals(src, nil)
end

-- ── empty strings are equivalent to "not provided" ───────────────────

g.test_resolve_empty_config_falls_through = function()
    local pw, src = peer_cookie.resolve_password({
        config_password = '',
        env_password    = 'real',
    })
    t.assert_equals(pw, 'real')
    t.assert_equals(src, 'env')
end

g.test_resolve_empty_env_falls_through = function()
    local pw, src = peer_cookie.resolve_password({
        env_password       = '',
        persisted_password = 'real',
    })
    t.assert_equals(pw, 'real')
    t.assert_equals(src, 'meta')
end

g.test_resolve_empty_meta_falls_through = function()
    local pw, src = peer_cookie.resolve_password({
        persisted_password = '',
    })
    t.assert_equals(pw, nil)
    t.assert_equals(src, nil)
end

-- ── argument validation ──────────────────────────────────────────────

g.test_resolve_rejects_non_string_inputs = function()
    -- `checks` raises on type mismatch; callers must always pass
    -- strings (or nil), not booleans or numbers.
    t.assert_error(function()
        peer_cookie.resolve_password({ config_password = 123 })
    end)
end

-- ── generated password contract ──────────────────────────────────────

g.test_generate_password_returns_url_safe_base64 = function()
    local pw = peer_cookie.generate_password()
    t.assert_type(pw, 'string')
    -- url-safe base64 of 24 bytes is 32 chars (no padding because
    -- nowrap=true and the byte count is a multiple of 3).
    t.assert_equals(#pw, 32)
    -- url-safe alphabet excludes '+' and '/'. Padding '=' is also
    -- absent due to the byte length above.
    t.assert(not pw:find('[+/=]'), 'unexpected character in url-safe password: ' .. pw)
end

g.test_generate_password_is_high_entropy = function()
    -- Two consecutive draws must differ. The probability of collision
    -- with 24 random bytes (192 bits) is negligible; if this ever
    -- fails, the RNG is broken.
    local a = peer_cookie.generate_password()
    local b = peer_cookie.generate_password()
    t.assert_not_equals(a, b)
end

-- ── module constants are publicly exposed ────────────────────────────

g.test_module_exports_naming = function()
    t.assert_equals(peer_cookie.USER_NAME, 'webui_peer')
    t.assert_equals(peer_cookie.META_SPACE, '_webui_meta')
    t.assert_equals(peer_cookie.META_KEY, 'webui_peer_password')
end

-- ── bootstrap refuses to run before box.cfg ──────────────────────────

g.test_bootstrap_errors_when_box_missing = function()
    -- Save and clear the global box reference; restore on cleanup so
    -- subsequent tests in the same process are not affected.
    local saved_box = rawget(_G, 'box')
    rawset(_G, 'box', nil)
    local ok, err = peer_cookie.bootstrap({})
    rawset(_G, 'box', saved_box)
    t.assert_equals(ok, nil)
    t.assert_str_contains(err, 'box is not initialised')
end
