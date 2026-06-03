-- Unit tests for the pure timing validator / auto-corrector (Task FO-5).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('failover_timings')

local timings = require('webui.failover.timings')

-- Helper: assert no warning contains the given needle.
local function has_warning(warnings, needle)
    for _, w in ipairs(warnings) do
        if string.find(w, needle, 1, true) ~= nil then
            return true
        end
    end
    return false
end

g.test_valid_triple_passes_clean = function()
    local adj, warns, err = timings.validate_and_adjust({
        lease_ttl_sec = 20, keepalive_interval = 5, probe_timeout_sec = 3,
        safety_margin = 5,
    })
    t.assert_is(err, nil)
    t.assert_equals(adj.ttl, 20)
    t.assert_equals(adj.loop_wait, 5)
    t.assert_equals(adj.retry_timeout, 3)
    t.assert_equals(adj.safety_margin, 5)
    t.assert_equals(adj.renew_deadline, 15)
    t.assert_equals(#warns, 0, 'a fully valid triple emits no warnings')
end

g.test_defaults_when_opts_empty = function()
    local adj, _, err = timings.validate_and_adjust({})
    t.assert_is(err, nil)
    t.assert_equals(adj.ttl, timings.DEFAULTS.ttl)
    t.assert_equals(adj.loop_wait, timings.DEFAULTS.loop_wait)
    t.assert_equals(adj.retry_timeout, timings.DEFAULTS.retry_timeout)
end

g.test_retry_below_minimum_is_raised = function()
    local adj, warns, err = timings.validate_and_adjust({
        lease_ttl_sec = 20, keepalive_interval = 5, probe_timeout_sec = 1,
    })
    t.assert_is(err, nil)
    t.assert_equals(adj.retry_timeout, timings.MINS.retry_timeout)
    t.assert(has_warning(warns, 'probe_timeout_sec'), 'warns about raised probe')
end

g.test_loop_wait_below_minimum_is_raised = function()
    local adj, warns, err = timings.validate_and_adjust({
        lease_ttl_sec = 20, keepalive_interval = 0.5, probe_timeout_sec = 3,
    })
    -- 0.5 is non-positive-after-floor? no, positive but below min(1).
    t.assert_is(err, nil)
    t.assert_equals(adj.loop_wait, timings.MINS.loop_wait)
    t.assert(has_warning(warns, 'keepalive_interval'))
end

g.test_ttl_below_recommended_warns_but_passes = function()
    local adj, warns, err = timings.validate_and_adjust({
        lease_ttl_sec = 15, keepalive_interval = 5, probe_timeout_sec = 3,
    })
    t.assert_is(err, nil)
    t.assert_equals(adj.ttl, 15)
    t.assert(has_warning(warns, 'below recommended'),
        'soft floor warns, does not fail (keeps fast-LAN clusters running)')
end

g.test_loop_wait_too_large_for_ttl_is_shrunk = function()
    -- ttl=20, loop_wait=15 violates ttl >= 2*loop_wait (20 < 30).
    local adj, warns, err = timings.validate_and_adjust({
        lease_ttl_sec = 20, keepalive_interval = 15, probe_timeout_sec = 3,
    })
    t.assert_is(err, nil)
    t.assert(adj.loop_wait <= math.floor(20 / 2),
        'loop_wait shrunk to <= floor(ttl/2)')
    t.assert(adj.ttl >= 2 * adj.loop_wait, 'invariant 2 holds after correction')
    t.assert(has_warning(warns, 'too large for lease_ttl'))
end

g.test_inequality_shrinks_loop_wait_first = function()
    -- ttl=20, loop_wait=10, retry=6 -> 10 + 12 = 22 > 20. Invariant 2 also
    -- bites (20 < 2*10) and shrinks loop_wait to 10 first; then inequality
    -- shrinks it further. retry should remain untouched if loop_wait alone
    -- can make it fit.
    local adj, _, err = timings.validate_and_adjust({
        lease_ttl_sec = 20, keepalive_interval = 10, probe_timeout_sec = 6,
    })
    t.assert_is(err, nil)
    t.assert(adj.loop_wait + 2 * adj.retry_timeout <= adj.ttl,
        'invariant 1 holds after correction')
    t.assert_equals(adj.retry_timeout, 6,
        'retry untouched when shrinking loop_wait suffices (20 - 12 = 8)')
    t.assert_equals(adj.loop_wait, 8)
end

g.test_inequality_then_shrinks_retry = function()
    -- ttl=20, retry=10 -> even loop_wait at min(1): 1 + 20 = 21 > 20.
    -- retry must be shrunk to floor((20-1)/2) = 9.
    local adj, warns, err = timings.validate_and_adjust({
        lease_ttl_sec = 20, keepalive_interval = 1, probe_timeout_sec = 10,
    })
    t.assert_is(err, nil)
    t.assert(adj.loop_wait + 2 * adj.retry_timeout <= adj.ttl)
    t.assert(adj.retry_timeout < 10, 'retry was shrunk')
    t.assert(has_warning(warns, 'reduced probe_timeout_sec'))
end

g.test_unsatisfiable_tiny_ttl_errors = function()
    -- ttl=5 cannot fit min loop_wait(1) + 2*min retry(3) = 7.
    local adj, _, err = timings.validate_and_adjust({
        lease_ttl_sec = 5, keepalive_interval = 1, probe_timeout_sec = 3,
    })
    t.assert_is(adj, nil)
    t.assert_str_contains(err, 'unsatisfiable')
    t.assert_str_contains(err, 'raise lease_ttl_sec')
end

g.test_safety_margin_ge_ttl_is_reduced = function()
    local adj, warns, err = timings.validate_and_adjust({
        lease_ttl_sec = 20, keepalive_interval = 5, probe_timeout_sec = 3,
        safety_margin = 25,
    })
    t.assert_is(err, nil)
    t.assert(adj.safety_margin < adj.ttl)
    t.assert(adj.renew_deadline >= 1 and adj.renew_deadline < adj.ttl)
    t.assert(has_warning(warns, 'safety_margin'))
end

g.test_near_boundary_warns = function()
    -- ttl=21, loop_wait=5, retry=8 -> 5 + 16 = 21 == ttl, slack 0 < retry 8.
    local adj, warns, err = timings.validate_and_adjust({
        lease_ttl_sec = 21, keepalive_interval = 5, probe_timeout_sec = 8,
    })
    t.assert_is(err, nil)
    t.assert(adj.loop_wait + 2 * adj.retry_timeout <= adj.ttl)
    t.assert(has_warning(warns, 'near boundary'))
end

g.test_to_role_opts_maps_field_names = function()
    local adj = {
        ttl = 20, loop_wait = 5, retry_timeout = 3, safety_margin = 5,
        renew_deadline = 15,
    }
    local opts = timings.to_role_opts(adj)
    t.assert_equals(opts.lease_ttl_sec, 20)
    t.assert_equals(opts.keepalive_interval, 5)
    t.assert_equals(opts.probe_timeout_sec, 3)
    t.assert_equals(opts.safety_margin, 5)
end
