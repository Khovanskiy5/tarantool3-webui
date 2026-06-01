local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local fwd = require('webui.audit.forwarder')

local g = t.group('audit.forwarder')

-- ── severity heuristic ────────────────────────────────────────────

g.test_severity_defaults_to_info = function()
    t.assert_equals(fwd._row_severity({ action = 'config.commit' }), 'info')
end

g.test_severity_picks_warning_for_login_failed = function()
    t.assert_equals(fwd._row_severity({ action = 'auth.login_failed' }), 'warning')
end

g.test_severity_picks_warning_for_rbac_denied = function()
    t.assert_equals(fwd._row_severity({ action = 'rbac.denied' }), 'warning')
end

-- ── filter ────────────────────────────────────────────────────────

g.test_passes_filter_min_severity_blocks_lower = function()
    local f = { min_severity = 'warning' }
    t.assert_equals(fwd.passes_filter(f, { action = 'config.commit' }), false)
end

g.test_passes_filter_min_severity_allows_equal_or_higher = function()
    local f = { min_severity = 'info' }
    t.assert_equals(fwd.passes_filter(f, { action = 'config.commit' }), true)
    -- warning > info → passes.
    t.assert_equals(fwd.passes_filter(f, { action = 'rbac.denied' }), true)
end

g.test_passes_filter_action_prefix = function()
    local f = { action_prefix = 'cluster.' }
    t.assert_equals(fwd.passes_filter(f, { action = 'cluster.promote' }), true)
    t.assert_equals(fwd.passes_filter(f, { action = 'auth.login' }), false)
end

g.test_passes_filter_no_constraints_passes_anything = function()
    t.assert_equals(fwd.passes_filter({}, { action = 'whatever' }), true)
end

-- ── RFC 5424 line ─────────────────────────────────────────────────

g.test_rfc5424_priority_uses_facility_and_severity = function()
    local f = { facility = 'local3', tag = 'webui-audit' }
    local row = {
        id = 1, ts = 1700000000000000, action = 'auth.login',
    }
    local line = fwd._rfc5424_line(f, row)
    -- local3 (19) * 8 + info (6) = 158. `<158>1 ...`
    t.assert_str_contains(line, '<158>1 ')
end

g.test_rfc5424_severity_promotes_warning_for_login_failed = function()
    local f = { facility = 'local0', tag = 'webui-audit' }
    local row = {
        id = 1, ts = 1700000000000000, action = 'auth.login_failed',
    }
    local line = fwd._rfc5424_line(f, row)
    -- local0 (16) * 8 + warning (4) = 132.
    t.assert_str_contains(line, '<132>1 ')
end

g.test_rfc5424_includes_tag_and_action = function()
    local f = { facility = 'local0', tag = 'my-app' }
    local row = {
        id = 42, ts = 1700000000000000,
        action = 'cluster.promote',
        user = 'admin_dev',
    }
    local line = fwd._rfc5424_line(f, row)
    t.assert_str_contains(line, 'my-app')
    t.assert_str_contains(line, 'cluster.promote')
    t.assert_str_contains(line, 'admin_dev')
end

-- ── file append + rotation ────────────────────────────────────────

g.test_append_file_writes_jsonl_and_rotates = function()
    local tmp = fio.tempdir()
    local path = fio.pathjoin(tmp, 'audit.jsonl')
    local f = { kind = 'file', path = path, max_size_mb = 0, max_backups = 2 }
    -- max_size_mb = 0 → bytes threshold is 0 so every write
    -- rotates. That exercises the rename chain.
    fwd._append_file(f, { id = 1, action = 'first', ts = 1 })
    fwd._append_file(f, { id = 2, action = 'second', ts = 2 })
    fwd._append_file(f, { id = 3, action = 'third', ts = 3 })

    -- Live file holds the latest row. The .1 backup carries the
    -- second-latest, .2 the third-latest (oldest of the three).
    local live = fio.open(path, { 'O_RDONLY' }):read(4096)
    t.assert_str_contains(live, '"third"')
    local b1 = fio.open(path .. '.1', { 'O_RDONLY' }):read(4096)
    t.assert_str_contains(b1, '"second"')
    local b2 = fio.open(path .. '.2', { 'O_RDONLY' }):read(4096)
    t.assert_str_contains(b2, '"first"')
end
