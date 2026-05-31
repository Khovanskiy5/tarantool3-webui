-- Unit tests for the pure helpers introduced for /config-history:
-- key formatters, revision parsers, prune planner.
--
-- The etcd-bound `list/record/get` paths are covered by integration
-- tests against a real etcd container (see backend/test/integration/);
-- this file only checks helpers that have no box / no network deps.

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local history = require('webui.config_store.history')

local g = t.group('config_history')

g.test_history_key_uses_zero_padded_revision = function()
    t.assert_equals(history.history_key('/wb', 1),
        '/wb/history/0000000001')
    t.assert_equals(history.history_key('/wb', 1234567890),
        '/wb/history/1234567890')
end

g.test_metadata_key_uses_separate_prefix = function()
    -- Snapshots and metadata MUST live under different prefixes so a
    -- range_prefix() over history/ never returns metadata rows.
    t.assert_equals(history.metadata_key('/wb', 42),
        '/wb/history-meta/0000000042')
    local snap = history.history_key('/wb', 42)
    local meta = history.metadata_key('/wb', 42)
    -- Plain `find` (4th arg `true`) — `-` in Lua patterns is a
    -- quantifier so the default mode would not match this substring.
    t.assert(not snap:find('history-meta', 1, true),
        'snapshot key must not match meta prefix')
    t.assert(meta:find('history-meta', 1, true),
        'meta key must match meta prefix')
end

g.test_parse_revision_extracts_integer = function()
    t.assert_equals(history.parse_revision('/wb/history/0000000001'), 1)
    t.assert_equals(history.parse_revision('/wb/history/1234567890'), 1234567890)
end

g.test_parse_revision_returns_nil_for_metadata_keys = function()
    -- range_prefix('/history/') will not match meta keys, but if a
    -- malformed `<prefix>/history/foo-meta/...` ever shows up we
    -- want it skipped, not crashed on.
    t.assert_equals(history.parse_revision('/wb/history-meta/0000000001'), nil)
    t.assert_equals(history.parse_revision('/wb/history/'), nil)
    t.assert_equals(history.parse_revision('/wb/history/abc'), nil)
    t.assert_equals(history.parse_revision(''), nil)
    t.assert_equals(history.parse_revision(nil), nil)
end

g.test_parse_revision_rejects_zero_and_negatives = function()
    -- etcd revisions are 1-indexed; 0 means "no record" in the
    -- v3 API and should not appear in our history keys.
    t.assert_equals(history.parse_revision('/wb/history/0000000000'), nil)
end

g.test_prune_plan_keeps_under_cap = function()
    local keys = { '/wb/history/0000000001', '/wb/history/0000000002' }
    t.assert_equals(history.prune_plan(keys, 5), {})
end

g.test_prune_plan_drops_oldest = function()
    local keys = {}
    for i = 1, 7 do
        table.insert(keys, string.format('/wb/history/%010d', i))
    end
    local drop = history.prune_plan(keys, 5)
    t.assert_equals(#drop, 2)
    t.assert_equals(drop[1], '/wb/history/0000000001')
    t.assert_equals(drop[2], '/wb/history/0000000002')
end

g.test_prune_plan_handles_empty_list = function()
    t.assert_equals(history.prune_plan({}, 10), {})
end
