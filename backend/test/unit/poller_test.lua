-- Unit tests for backend/webui/cluster/poller.lua
--
-- Covers the pure backoff math and the skip-set computation. The
-- fiber lifecycle (start / stop / config.info watcher) needs a live
-- Tarantool instance and lands in the integration suite.

local t = require('luatest')

local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local poller = require('webui.cluster.poller')

local g = t.group('poller')

-- ── compute_backoff_delay ───────────────────────────────────────────

g.test_backoff_first_failure = function()
    -- attempt=1 → INITIAL_BACKOFF_SEC (no exponential growth yet).
    t.assert_equals(poller.compute_backoff_delay(1), poller.INITIAL_BACKOFF_SEC)
end

g.test_backoff_doubles_on_each_failure = function()
    local d1 = poller.compute_backoff_delay(1)
    local d2 = poller.compute_backoff_delay(2)
    local d3 = poller.compute_backoff_delay(3)
    t.assert_equals(d2, d1 * 2)
    t.assert_equals(d3, d1 * 4)
end

g.test_backoff_caps_at_max = function()
    -- A very large attempt count must not produce a delay above
    -- MAX_BACKOFF_SEC. Otherwise the poller would silently skip a
    -- dead peer for hours.
    local d = poller.compute_backoff_delay(100)
    t.assert_equals(d, poller.MAX_BACKOFF_SEC)
end

g.test_backoff_capped_exp_keeps_within_max = function()
    -- The implementation caps the exponent at MAX_BACKOFF_EXP; any
    -- attempt at or beyond MAX_BACKOFF_EXP + 1 produces the same
    -- ceiling delay.
    local a = poller.compute_backoff_delay(poller.MAX_BACKOFF_EXP + 1)
    local b = poller.compute_backoff_delay(poller.MAX_BACKOFF_EXP + 10)
    t.assert_equals(a, b)
end

-- ── peers_to_skip ──────────────────────────────────────────────────

g.test_peers_to_skip_returns_only_window_active = function()
    local skip = poller.peers_to_skip({
        ['tt-1'] = { next_retry_at = 200 },  -- not yet
        ['tt-2'] = { next_retry_at = 50 },   -- already due
        ['tt-3'] = { next_retry_at = 100 },  -- right at the boundary; not skipped
    }, 100)
    t.assert_equals(skip['tt-1'], true)
    t.assert_equals(skip['tt-2'], nil)
    t.assert_equals(skip['tt-3'], nil)
end

g.test_peers_to_skip_handles_nil_backoff = function()
    t.assert_equals(poller.peers_to_skip(nil, 100), {})
end

g.test_peers_to_skip_entry_without_next_retry_is_not_skipped = function()
    -- Backoff entry with no next_retry_at means "we have not seen
    -- this peer fail yet" — keep polling.
    local skip = poller.peers_to_skip({
        ['tt-1'] = { attempt = 0 },
    }, 100)
    t.assert_equals(skip['tt-1'], nil)
end

-- ── update_backoff ──────────────────────────────────────────────────

g.test_update_backoff_clears_on_recovery = function()
    local next_state = poller.update_backoff(
        { ['tt-2'] = { attempt = 3, next_retry_at = 200 } },
        { ['tt-2'] = { ok = true, value = {} } },
        100
    )
    t.assert_equals(next_state['tt-2'], nil)
end

g.test_update_backoff_extends_on_failure = function()
    local next_state = poller.update_backoff(
        { ['tt-2'] = { attempt = 1, next_retry_at = 50 } },
        { ['tt-2'] = { ok = false, err = 'down' } },
        100
    )
    t.assert_equals(next_state['tt-2'].attempt, 2)
    t.assert(next_state['tt-2'].next_retry_at > 100,
        'next_retry_at must be in the future after a failure')
end

g.test_update_backoff_initialises_new_failure = function()
    local next_state = poller.update_backoff(
        {},
        { ['tt-new'] = { ok = false, err = 'unknown host' } },
        50
    )
    t.assert_equals(next_state['tt-new'].attempt, 1)
    t.assert_equals(next_state['tt-new'].next_retry_at,
        50 + poller.INITIAL_BACKOFF_SEC)
end

g.test_update_backoff_does_not_mutate_input = function()
    local input = {
        ['tt-1'] = { attempt = 1, next_retry_at = 10 },
    }
    poller.update_backoff(input, { ['tt-1'] = { ok = false } }, 100)
    -- input must still hold its original values.
    t.assert_equals(input['tt-1'].attempt, 1)
    t.assert_equals(input['tt-1'].next_retry_at, 10)
end

g.test_update_backoff_passes_through_unrelated_peers = function()
    local input = {
        ['tt-1'] = { attempt = 1, next_retry_at = 50 },
        ['tt-2'] = { attempt = 2, next_retry_at = 80 },
    }
    -- Only tt-1 has a fresh result; tt-2 must keep its backoff.
    local next_state = poller.update_backoff(input,
        { ['tt-1'] = { ok = true, value = {} } }, 100)
    t.assert_equals(next_state['tt-1'], nil)
    t.assert_equals(next_state['tt-2'].attempt, 2)
    t.assert_equals(next_state['tt-2'].next_retry_at, 80)
end

-- ── module constants are publicly visible ───────────────────────────

g.test_constants_publicly_exposed = function()
    t.assert_equals(poller.POLL_INTERVAL_SEC, 1.5)
    -- Probe timeout must stay below the cadence so a stuck peer
    -- cannot push the next tick past its deadline.
    t.assert(poller.PROBE_TIMEOUT_SEC < poller.POLL_INTERVAL_SEC)
    t.assert(poller.MAX_BACKOFF_SEC > poller.INITIAL_BACKOFF_SEC)
end

g.test_probe_src_is_a_string_payload = function()
    -- Lifelines for future refactors: the probe must remain a string
    -- (conn:eval signature) and must not be empty.
    t.assert_type(poller.PROBE_SRC, 'string')
    t.assert(#poller.PROBE_SRC > 100, 'probe source looks suspiciously short')
end

g.test_status_returns_running_false_before_start = function()
    poller._reset()
    local s = poller.status()
    t.assert_equals(s.running, false)
    t.assert_equals(s.backoff_count, 0)
end
