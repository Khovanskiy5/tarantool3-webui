-- DE-1.6 — `tuples(with_msgpack: true)` returns the base64 of the
-- tuple's raw msgpack, and it is off by default.

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local msgpack    = require('msgpack')
local digest     = require('digest')
local admin_data = require('webui.graphql.resolvers.admin_data')

local g = t.group('admin_data.tuples_msgpack')

local SPACE_NAME = 'admin_data_msgpack_test'

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

g.before_each(function()
    pcall(function()
        if box.space[SPACE_NAME] then box.space[SPACE_NAME]:drop() end
    end)
    local s = box.schema.space.create(SPACE_NAME)
    s:format({
        { name = 'id',  type = 'unsigned' },
        { name = 'tag', type = 'string'   },
    })
    s:create_index('primary', { parts = { 'id' } })
    s:insert({ 7, 'lucky' })
end)

g.after_all(function()
    pcall(function()
        if box.space[SPACE_NAME] then box.space[SPACE_NAME]:drop() end
    end)
end)

local root = { user = 'admin_dev', roles = { 'admin' } }

g.test_msgpack_absent_by_default = function()
    local r = admin_data.query_tuples(root, { space = SPACE_NAME, limit = 10 })
    t.assert_equals(#r.items, 1)
    -- No `with_msgpack` arg → the field must stay nil so the common
    -- browse path pays nothing.
    t.assert_equals(r.items[1].msgpack, nil)
end

g.test_msgpack_present_and_decodes_to_tuple = function()
    local r = admin_data.query_tuples(root,
        { space = SPACE_NAME, limit = 10, with_msgpack = true })
    t.assert_equals(#r.items, 1)
    local b64 = r.items[1].msgpack
    t.assert_type(b64, 'string')
    t.assert(b64 ~= '')
    -- Decode base64 → msgpack → the exact tuple Tarantool stores.
    local decoded = msgpack.decode(digest.base64_decode(b64))
    t.assert_equals(decoded, { 7, 'lucky' })
end
