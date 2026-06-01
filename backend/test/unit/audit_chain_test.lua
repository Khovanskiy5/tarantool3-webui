local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local chain = require('webui.audit.chain')

local g = t.group('audit.chain')

g.test_canonical_is_deterministic = function()
    local row = {
        id = 1, ts = 1700000000,
        user = 'alice', action = 'login', scope = 'auth',
        payload = { ip = '127.0.0.1' }, request_id = 'r-1',
    }
    local a = chain.canonical(row)
    local b = chain.canonical(row)
    t.assert_equals(a, b)
end

g.test_canonical_ignores_chain_fields = function()
    -- prev_hash / current_hash / chain_seal MUST NOT enter the
    -- canonical projection — otherwise the chain would be
    -- circular (current_hash includes itself).
    local row_a = {
        id = 1, ts = 1, action = 'x',
        prev_hash = 'aa', current_hash = 'bb', chain_seal = true,
    }
    local row_b = {
        id = 1, ts = 1, action = 'x',
        prev_hash = 'zz', current_hash = 'yy', chain_seal = false,
    }
    t.assert_equals(chain.canonical(row_a), chain.canonical(row_b))
end

g.test_row_hash_with_nil_prev = function()
    local row = { id = 1, ts = 1, action = 'x' }
    local h = chain.row_hash(nil, row)
    t.assert_type(h, 'string')
    t.assert(#h == 64, 'sha256 hex is 64 chars')
end

g.test_row_hash_differs_per_payload = function()
    local r1 = { id = 1, ts = 1, action = 'x' }
    local r2 = { id = 1, ts = 1, action = 'y' }
    t.assert_not_equals(chain.row_hash(nil, r1), chain.row_hash(nil, r2))
end

g.test_row_hash_differs_per_prev = function()
    local r = { id = 1, ts = 1, action = 'x' }
    t.assert_not_equals(
        chain.row_hash('aa', r),
        chain.row_hash('bb', r))
end

g.test_chain_links_3_rows = function()
    -- Manual 3-row chain. Each row's prev_hash is the previous
    -- row's current_hash; verifier should be able to walk it.
    local rows = {
        { id = 1, ts = 1, action = 'a' },
        { id = 2, ts = 2, action = 'b' },
        { id = 3, ts = 3, action = 'c' },
    }
    local h1 = chain.row_hash(nil, rows[1])
    local h2 = chain.row_hash(h1, rows[2])
    local h3 = chain.row_hash(h2, rows[3])
    -- Independent recomputation must reproduce the same hashes.
    t.assert_equals(chain.row_hash(nil, rows[1]), h1)
    t.assert_equals(chain.row_hash(h1, rows[2]), h2)
    t.assert_equals(chain.row_hash(h2, rows[3]), h3)
    -- And the trio is distinct.
    t.assert_not_equals(h1, h2)
    t.assert_not_equals(h2, h3)
    t.assert_not_equals(h1, h3)
end

g.test_next_link_handles_seal = function()
    -- A sealed row breaks the chain on purpose. next_link must
    -- return nil so the next row starts a new root.
    local sealed = { current_hash = 'abc', chain_seal = true }
    t.assert_equals(chain.next_link(sealed), nil)
    -- An unsealed row passes its current_hash through.
    local normal = { current_hash = 'def', chain_seal = false }
    t.assert_equals(chain.next_link(normal), 'def')
    -- A row with no hash yet (pre-chain / partial migration)
    -- also returns nil so the new row is judged as a root.
    local pre = { current_hash = nil, chain_seal = false }
    t.assert_equals(chain.next_link(pre), nil)
end
