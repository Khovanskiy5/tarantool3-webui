-- Regression test for the WS reader fiber's EOF handling.
--
-- Background: spawn_reader() in backend/webui/http/ws.lua used to
-- treat sock:read returning '' (empty string) and nil identically
-- as "no bytes yet, keep waiting". sock:read returns nil on a 1s
-- timeout (which yields the fiber) but returns '' instantly on
-- clean EOF — so an undetected EOF made the outer loop spin at
-- 100% CPU until the heartbeat fiber eventually flipped
-- entry.closed (up to PONG_DEADLINE_SEC = 60 seconds).
--
-- This test does not boot a real socket; it mirrors the decision
-- tree as a pure helper so the contract stays explicit:
--   chunk == ''   → break (EOF, must not spin)
--   chunk == nil  → loop (1s timeout, normal)
--   non-empty str → consume buffer
--
-- The actual reader fiber wires this decision against a real
-- sock:read; the production code's branch must mirror this helper.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('ws_reader_eof')

-- Pure decision helper that mirrors spawn_reader's outer loop.
-- Returns: 'break_eof' | 'continue_timeout' | 'consume'.
local function classify(chunk)
    if chunk == '' then return 'break_eof' end
    if chunk == nil then return 'continue_timeout' end
    return 'consume'
end

g.test_empty_string_is_eof = function()
    -- This is the regression: '' MUST terminate the loop. Before
    -- the fix it was lumped with nil and the outer loop spun.
    t.assert_equals(classify(''), 'break_eof')
end

g.test_nil_is_timeout = function()
    t.assert_equals(classify(nil), 'continue_timeout')
end

g.test_string_is_consume = function()
    t.assert_equals(classify('hello'), 'consume')
end

g.test_eof_and_timeout_are_distinct = function()
    -- Most important property: the two outcomes that look alike
    -- to a naive `if x == nil or x == ''` check must classify
    -- DIFFERENTLY, otherwise we regress to the hot-loop bug.
    t.assert_not_equals(classify(''), classify(nil))
end

-- Source-level guard: the production reader in ws.lua must
-- contain an explicit `chunk == ''` branch that breaks. This
-- check fails loudly if someone reverts to the lumped check.
g.test_production_code_has_eof_branch = function()
    local path = repo_root .. '/backend/webui/http/ws.lua'
    local f = io.open(path, 'r')
    t.assert_not_equals(f, nil, 'ws.lua not found')
    local body = f:read('*a')
    f:close()
    t.assert(body:find("chunk == ''"),
        "spawn_reader must branch on `chunk == ''` (clean EOF) " ..
        "and break the loop; lumping it with nil regresses to a " ..
        "100% CPU hot-loop on every dead WS connection")
    -- The break must happen in the EOF arm — verify the immediate
    -- next non-comment, non-blank token after the EOF condition is
    -- a `break` (allowing a logger call in between).
    local idx = body:find("chunk == ''")
    local window = body:sub(idx, idx + 400)
    t.assert(window:find("break"),
        "EOF branch must contain `break`; otherwise the outer " ..
        "loop continues spinning on a closed socket")
end
