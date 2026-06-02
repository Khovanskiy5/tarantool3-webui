--
-- Facade contract for data_mutations/.
--
-- Two invariants this file pins:
--
--   1. `init.lua` stays under the hard 80-line cap. A growing
--      facade is the signal that something leaked out of a
--      submodule into the wiring layer.
--   2. Every name documented in init.lua's header is actually
--      exported. Removing one of them silently is the kind of
--      change that breaks downstream consumers (`graphql/schema.lua`,
--      audit log replay, peer-bound remote functions) only at
--      runtime — we catch it here at unit-test time instead.
--

local t   = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('data_mutations_facade')

local FACADE_PATH = repo_root
    .. '/backend/webui/graphql/resolvers/data_mutations/init.lua'

g.test_init_lua_is_under_size_cap = function()
    local f = io.open(FACADE_PATH, 'r')
    t.assert(f ~= nil, 'init.lua must exist at ' .. FACADE_PATH)
    local lines = 0
    for _ in f:lines() do lines = lines + 1 end
    f:close()
    t.assert(lines <= 80,
        'init.lua grew to ' .. lines .. ' lines; the hard cap is 80. ' ..
        'Anything beyond require + re-export belongs in common.lua or ' ..
        'a dedicated submodule.')
end

g.test_facade_exports_full_public_surface = function()
    local mut = require('webui.graphql.resolvers.data_mutations')
    -- SENSITIVE_SPACES is a table; the rest are functions.
    t.assert_type(mut.SENSITIVE_SPACES, 'table')
    for _, name in ipairs({
        'tuple_insert', 'tuple_replace', 'tuple_update', 'tuple_delete',
        'create_space', 'drop_space', 'alter_space',
        'create_index', 'drop_index',
        'remote_entry', 'space_remote_entry',
    }) do
        t.assert_type(mut[name], 'function',
            'facade is missing export: ' .. name)
    end
end

g.test_shim_resolves_to_init = function()
    -- Sanity: `require('...data_mutations')` should reach the same
    -- table whether Lua's loader picks the .lua shim or the init.
    local shim = require('webui.graphql.resolvers.data_mutations')
    local init = require('webui.graphql.resolvers.data_mutations.init')
    t.assert_equals(shim, init)
end
