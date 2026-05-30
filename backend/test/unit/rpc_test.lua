-- Unit tests for backend/webui/cluster/rpc.lua
--
-- Covers the pure result interpreter. The map_call fan-out needs a
-- live net.box pool and is exercised by the integration suite.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local rpc = require('webui.cluster.rpc')

local g = t.group('rpc')

-- ── interpret_result ─────────────────────────────────────────────────

g.test_interpret_result_pcall_failure_is_err = function()
    local r = rpc.interpret_result(false, 'boom', nil)
    t.assert_equals(r.ok, false)
    t.assert_equals(r.err, 'boom')
end

g.test_interpret_result_pcall_failure_keeps_explicit_err = function()
    local r = rpc.interpret_result(false, nil, 'wait failed')
    t.assert_equals(r.ok, false)
    t.assert_equals(r.err, 'wait failed')
end

g.test_interpret_result_timeout_returns_err = function()
    -- net.box surfaces a wait timeout as (nil, err).
    local r = rpc.interpret_result(true, nil, 'Timeout exceeded')
    t.assert_equals(r.ok, false)
    t.assert_str_contains(r.err, 'Timeout')
end

g.test_interpret_result_single_return_value_is_unwrapped = function()
    -- conn:call returns an array. Single-return becomes value.
    local r = rpc.interpret_result(true, { 42 }, nil)
    t.assert_equals(r.ok, true)
    t.assert_equals(r.value, 42)
end

g.test_interpret_result_multi_return_keeps_array = function()
    local r = rpc.interpret_result(true, { 'a', 'b', 'c' }, nil)
    t.assert_equals(r.ok, true)
    t.assert_equals(r.value, { 'a', 'b', 'c' })
end

g.test_interpret_result_scalar_value_passes_through = function()
    -- Defensive: a non-array value (string, number) should not be
    -- mangled either; rpc passes whatever it received.
    local r = rpc.interpret_result(true, 'hi', nil)
    t.assert_equals(r.ok, true)
    t.assert_equals(r.value, 'hi')
end

g.test_interpret_result_table_with_first_nil_is_passed_through = function()
    -- {nil, 'x'} is not interpreted as a single-return; the unwrap
    -- only fires when `value[1]` is non-nil AND `value[2]` is nil.
    local payload = { [2] = 'x' }
    local r = rpc.interpret_result(true, payload, nil)
    t.assert_equals(r.ok, true)
    t.assert_equals(r.value, payload)
end

-- ── default timeout constant ─────────────────────────────────────────

g.test_default_timeout_is_reasonable = function()
    -- The poller (Task 17) ticks at 1.5s so the default per-call
    -- deadline must be smaller; pin the contract here so a careless
    -- bump shows up in code review.
    t.assert(rpc.DEFAULT_TIMEOUT_SEC > 0)
    t.assert(rpc.DEFAULT_TIMEOUT_SEC < 1.5)
end

-- ── map_call argument validation ────────────────────────────────────

g.test_map_call_rejects_non_string_fn_name = function()
    t.assert_error(function() rpc.map_call(nil) end)
    t.assert_error(function() rpc.map_call(42) end)
end

g.test_map_call_with_empty_pool_returns_empty_table = function()
    -- No peers configured -> map_call short-circuits with no
    -- entries. Bring the live peers module into a clean state so a
    -- previous test does not leak.
    local peers = require('webui.cluster.peers')
    peers._reset()
    local out = rpc.map_call('any_function', {})
    t.assert_equals(out, {})
end
