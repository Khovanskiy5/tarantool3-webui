local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local sql = require('webui.api.sql')

local g = t.group('api.sql')

-- ── statement split ────────────────────────────────────────────────

g.test_split_single = function()
    t.assert_equals(sql._split_statements('SELECT 1'), { 'SELECT 1' })
end

g.test_split_multi = function()
    local out = sql._split_statements('SELECT 1;;\nINSERT INTO x VALUES (1)')
    t.assert_equals(#out, 2)
    t.assert_equals(out[1], 'SELECT 1')
    t.assert_equals(out[2], 'INSERT INTO x VALUES (1)')
end

g.test_split_trailing_separator_dropped = function()
    local out = sql._split_statements('SELECT 1 ;; ')
    t.assert_equals(out, { 'SELECT 1' })
end

g.test_split_keeps_single_semicolons_inside_statement = function()
    -- Single `;` inside a literal is preserved — only the explicit
    -- `;;` boundary splits.
    local out = sql._split_statements("INSERT INTO x VALUES ('a;b;c')")
    t.assert_equals(#out, 1)
    t.assert_equals(out[1], "INSERT INTO x VALUES ('a;b;c')")
end

g.test_split_empty_input = function()
    t.assert_equals(sql._split_statements(''), {})
    t.assert_equals(sql._split_statements(' ;; ;; '), {})
end

-- ── first_keyword + RBAC sniff ─────────────────────────────────────

g.test_first_keyword_select = function()
    t.assert_equals(sql._first_keyword('SELECT * FROM x'), 'SELECT')
    t.assert_equals(sql._first_keyword('  select 1'), 'SELECT')
end

g.test_first_keyword_skips_leading_comment = function()
    t.assert_equals(sql._first_keyword('-- log line\nSELECT 1'), 'SELECT')
    t.assert_equals(sql._first_keyword('-- one\n-- two\nINSERT'), 'INSERT')
end

g.test_check_role_admin_only_for_writes = function()
    local viewer = { 'viewer' }
    local operator = { 'operator' }
    local admin = { 'admin' }
    -- SELECT — operator suffices
    local ok = sql._check_role(operator, 'SELECT 1')
    t.assert_equals(ok, true)
    -- INSERT — viewer rejected, operator rejected, admin OK
    local ok2, needed = sql._check_role(viewer, 'INSERT INTO x VALUES (1)')
    t.assert_equals(ok2, false)
    t.assert_equals(needed, 'admin')
    local ok3 = sql._check_role(operator, 'INSERT INTO x VALUES (1)')
    t.assert_equals(ok3, false)
    local ok4 = sql._check_role(admin, 'INSERT INTO x VALUES (1)')
    t.assert_equals(ok4, true)
end

g.test_check_role_viewer_cannot_select = function()
    -- viewer rank < operator → SELECT also rejected (the SQL surface
    -- always requires at least operator).
    local ok, needed = sql._check_role({ 'viewer' }, 'SELECT 1')
    t.assert_equals(ok, false)
    t.assert_equals(needed, 'operator')
end

-- ── shape_result projection ────────────────────────────────────────

g.test_shape_result_select = function()
    local out = sql._shape_result({
        metadata = { { name = 'id', type = 'integer' } },
        rows = { { 1 }, { 2 } },
    })
    t.assert_equals(out.metadata, { { name = 'id', type = 'integer' } })
    t.assert_equals(out.rows, { { 1 }, { 2 } })
    t.assert_equals(out.truncated, false)
end

g.test_shape_result_dml = function()
    local out = sql._shape_result({ row_count = 3 })
    t.assert_equals(out.row_count, 3)
end

g.test_shape_result_unknown_returns_ok = function()
    local out = sql._shape_result({})
    t.assert_equals(out.ok, true)
end

g.test_shape_result_caps_rows = function()
    local huge = {}
    for i = 1, 10500 do huge[i] = { i } end
    local out = sql._shape_result({
        metadata = { { name = 'id' } },
        rows = huge,
    })
    t.assert_equals(#out.rows, sql.MAX_ROWS)
    t.assert_equals(out.truncated, true)
end

-- ── seqscan detection ──────────────────────────────────────────────

g.test_seqscan_detection_matches_typical_message = function()
    t.assert_equals(sql._is_seqscan_error(
        'Scanning is not allowed for &quot;x&quot;'), true)
    t.assert_equals(sql._is_seqscan_error(
        'SEQSCAN is required'), true)
    t.assert_equals(sql._is_seqscan_error(
        'enable sql_seq_scan setting'), true)
end

g.test_seqscan_detection_ignores_unrelated_errors = function()
    t.assert_equals(sql._is_seqscan_error('Syntax error near "SELECT"'), false)
    t.assert_equals(sql._is_seqscan_error(nil), false)
end
