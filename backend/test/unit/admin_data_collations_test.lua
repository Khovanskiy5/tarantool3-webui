-- Unit tests for the read-only `query_collations` resolver.
--
-- The resolver reads `_collation` and returns every built-in plus
-- any operator-added rows except id=0 (the "none" default). Tests
-- cover:
--   * `box` not initialised → empty payload (defensive boot path)
--   * default id=0 row is filtered out
--   * payload is sorted by `name` and projects exactly the fields
--     the GraphQL type advertises
--   * a freshly created custom collation appears
--   * RBAC: viewer role passes, unknown role rejected
--   * sensitive masking: no `owner` / no `auth` keys leak through

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local admin_data = require('webui.graphql.resolvers.admin_data')

local g = t.group('admin_data.collations')

g.before_all(function()
    if box.info.status == 'unconfigured' then
        local tmp = fio.tempdir()
        box.cfg({
            memtx_dir   = tmp,
            wal_dir     = tmp,
            wal_mode    = 'none',
            listen      = box.NULL,
            log_level   = 0,
            background  = false,
        })
    end
end)

-- ── happy path ─────────────────────────────────────────────────────

g.test_returns_payload_with_collations_field = function()
    -- Tarantool ships with ~270 ICU collations out of the box, so we
    -- can assert non-empty without seeding anything ourselves.
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_collations(root)
    t.assert_type(res, 'table')
    t.assert_type(res.collations, 'table')
    t.assert(#res.collations > 0,
        'expected at least one built-in collation')
end

g.test_filters_out_default_id_zero = function()
    -- The "none" collation lives at id=0 and is the implicit default
    -- for every string index. Hiding it from the dropdown is half
    -- the value of this resolver — make sure that contract holds.
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_collations(root)
    for _, c in ipairs(res.collations) do
        t.assert_not_equals(c.id, 0,
            'id=0 ("none") must be filtered out')
        t.assert_not_equals(c.name, 'none',
            'the implicit-default row must not leak through')
    end
end

g.test_payload_is_sorted_by_name = function()
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_collations(root)
    for i = 2, #res.collations do
        t.assert(res.collations[i - 1].name <= res.collations[i].name,
            'collations must be sorted by name (operator-friendly)')
    end
end

g.test_projects_only_advertised_fields = function()
    -- Snapshot the projection shape against the GraphQL type so a
    -- future leak (e.g. accidentally surfacing `owner` or raw `opts`
    -- under a different key) breaks here and not in production.
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_collations(root)
    local first = res.collations[1]
    t.assert_type(first, 'table')
    local allowed = {
        id = true, name = true, type = true,
        locale = true, icu_opts = true,
    }
    for k in pairs(first) do
        t.assert(allowed[k],
            'unexpected field leaked into Collation: ' .. tostring(k))
    end
    -- Owner / auth.* must never appear — even though `_collation`
    -- has an `owner` column, the resolver intentionally drops it.
    t.assert_equals(first.owner, nil,
        'owner must be stripped from the projection')
    t.assert_equals(first.auth, nil,
        'no auth-shaped key must appear in any read response')
end

-- ── custom row roundtrip ──────────────────────────────────────────

g.test_custom_collation_appears = function()
    -- Create a user collation, verify it reaches the resolver
    -- output with the exact shape clients will consume.
    local name = 'webui_test_collation_' .. tostring(box.info.id) .. '_de1_4a'
    pcall(function() box.space._collation.index.name:delete{name} end)
    box.space._collation:auto_increment{
        name, box.session.uid(), 'ICU', 'en_US',
        { strength = 'tertiary' },
    }
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_collations(root)
    local found
    for _, c in ipairs(res.collations) do
        if c.name == name then found = c; break end
    end
    t.assert_not_equals(found, nil, 'custom collation must appear')
    t.assert_equals(found.type, 'ICU')
    t.assert_equals(found.locale, 'en_US')
    t.assert_type(found.icu_opts, 'table')
    t.assert_equals(found.icu_opts.strength, 'tertiary')
    -- cleanup so reruns are idempotent
    pcall(function() box.space._collation.index.name:delete{name} end)
end

-- ── RBAC ───────────────────────────────────────────────────────────

g.test_rbac_viewer_passes = function()
    -- Plan policy: read-only browsing is `viewer`+. The resolver
    -- must not require admin.
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local ok = pcall(admin_data.query_collations, root)
    t.assert_equals(ok, true)
end

g.test_rbac_unknown_role_rejected = function()
    -- Anything below viewer (or a typo) must hit the FORBIDDEN guard.
    local root = { user = 'nobody', roles = { 'guest' } }
    local ok, err = pcall(admin_data.query_collations, root)
    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'FORBIDDEN')
    t.assert_str_contains(tostring(err), 'collations')
end

-- ── defensive boot path ───────────────────────────────────────────

g.test_returns_empty_when_collation_space_absent = function()
    -- Defensive: during early boot `box.space._collation` can be nil
    -- — the resolver must not blow up. We hide the space via rawset
    -- so luacheck does not flag the temporary monkey-patch as a
    -- write to a read-only field.
    local saved = box.space._collation
    rawset(box.space, '_collation', nil)
    local root = { user = 'viewer_dev', roles = { 'viewer' } }
    local res = admin_data.query_collations(root)
    rawset(box.space, '_collation', saved)
    t.assert_equals(res.collations, {})
end
