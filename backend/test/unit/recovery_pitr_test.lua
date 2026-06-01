local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local pitr = require('webui.recovery.pitr')

local g = t.group('recovery.pitr')

g.test_lsn_from_filename_snap = function()
    t.assert_equals(
        pitr.lsn_from_filename('var/lib/tt-1/00000000000000000178.snap'),
        178)
end

g.test_lsn_from_filename_xlog = function()
    t.assert_equals(
        pitr.lsn_from_filename('/tmp/00000000000000123456.xlog'),
        123456)
end

g.test_lsn_from_filename_returns_nil_for_other = function()
    t.assert_equals(pitr.lsn_from_filename('something.txt'), nil)
    t.assert_equals(pitr.lsn_from_filename('not-a-number.snap'), nil)
end

g.test_lsn_from_filename_strips_directory = function()
    -- Verifies the basename split works even with awkward
    -- relative paths.
    t.assert_equals(pitr.lsn_from_filename('./a/b/00000000000000000042.snap'),
        42)
end
