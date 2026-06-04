--
-- Unit test for `twophase.wait_prepared` and the replication-lag
-- tolerance it gives `commit()`.
--
-- Background: `_webui_prepared` is a replicated SYNC space. A prepare()
-- on a read-only follower forwards the write to the leader; a
-- back-to-back commit() on that same follower (rollback / force-apply,
-- or an interactive commit that the round-robin balancer routed
-- elsewhere) can read the row back LOCALLY before replication catches
-- up — historically returning a spurious PREPARED_NOT_FOUND.
--
-- A real follower cannot be reproduced in a single standalone box (you
-- cannot insert into a sync space while read_only=true). Instead we keep
-- the box WRITABLE and stub `twophase.is_read_only` — the seam exists
-- exactly for this. A background fiber inserts the prepared row after a
-- short delay to emulate replication arriving mid-wait.
--
-- Verifies:
--   * writable instance, local miss → nil immediately (no wait)
--   * read-only, row arrives late → wait_prepared returns the entry
--   * read-only, row never arrives → nil after the full budget
--   * commit() no longer fails PREPARED_NOT_FOUND when the row is
--     initially absent but replicates within the budget
--

local t = require('luatest')
local fio = require('fio')
local fiber = require('fiber')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' .. package.path

local twophase = require('webui.config_store.twophase')
local spaces   = require('webui.storage.spaces')

local g = t.group('twophase_prepared_replication')

local MIN_VALID_YAML = table.concat({
    'replication:',
    '  failover: off',
    'groups:',
    '  default:',
    '    replicasets:',
    '      rs-1:',
    '        instances:',
    '          tt-1:',
    '            iproto:',
    '              listen:',
    '              - uri: 0.0.0.0:3301',
    '              advertise:',
    '                peer:',
    '                  uri: tt-1:3301',
    '',
}, '\n')

local saved_is_read_only
local saved_state_mod
local saved_peers_mod

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
    pcall(spaces.bootstrap)
    pcall(box.ctl.promote)
end)

g.before_each(function()
    twophase._reset()
    saved_is_read_only = twophase.is_read_only
    saved_state_mod    = package.loaded['webui.cluster.state']
    saved_peers_mod    = package.loaded['webui.cluster.peers']
end)

g.after_each(function()
    twophase.is_read_only                  = saved_is_read_only
    package.loaded['webui.cluster.state']  = saved_state_mod
    package.loaded['webui.cluster.peers']  = saved_peers_mod
end)

-- Insert a prepared row directly (box is writable in the harness).
local function insert_prepared(id)
    local space = spaces.prepared()
    local now = fiber.time()
    space:replace({ id, MIN_VALID_YAML, '', now, now + 300 })
end

-- Insert the row after `delay` seconds to emulate replication arriving
-- while wait_prepared is polling.
local function insert_prepared_after(id, delay)
    fiber.create(function()
        fiber.sleep(delay)
        insert_prepared(id)
    end)
end

g.test_writable_miss_returns_nil_immediately = function()
    -- Box is promoted → is_read_only() is false. A local miss is a
    -- genuine absence, so we must NOT burn the budget waiting.
    local t0 = fiber.time()
    local entry = twophase.wait_prepared('prep-absent', 1)
    local elapsed = fiber.time() - t0
    t.assert_equals(entry, nil)
    t.assert(elapsed < 0.1,
        'writable instance must not wait on a missing row')
end

g.test_read_only_waits_for_late_replication = function()
    twophase.is_read_only = function() return true end
    local id = 'prep-late'
    insert_prepared_after(id, 0.04)

    local entry = twophase.wait_prepared(id, 2)
    t.assert_not_equals(entry, nil)
    t.assert_equals(entry.id, id)
    t.assert_equals(entry.yaml, MIN_VALID_YAML)
end

g.test_read_only_gives_up_after_budget = function()
    twophase.is_read_only = function() return true end
    local t0 = fiber.time()
    local entry = twophase.wait_prepared('prep-never', 0.2)
    local elapsed = fiber.time() - t0
    t.assert_equals(entry, nil)
    -- Proves the wait-loop ran to budget exhaustion (the branch that
    -- emits the WARN) rather than returning a fast nil.
    t.assert(elapsed >= 0.2,
        'must wait the full budget before declaring the row absent')
end

g.test_commit_tolerates_replication_lag = function()
    twophase.is_read_only = function() return true end
    -- delete_prepared() forwards to the leader on a read-only instance;
    -- stub the cluster lookup so the (ignored) forward stays quiet.
    package.loaded['webui.cluster.state'] = {
        find_leader = function() return nil end,
    }
    package.loaded['webui.cluster.peers'] = {
        get = function() return nil end,
    }

    local id = 'prep-commit-late'
    insert_prepared_after(id, 0.04)

    -- etcd = nil → dry-run path: the only thing that can fail here is the
    -- prepared lookup. Without wait_prepared this returned PREPARED_NOT_FOUND.
    local r, err = twophase.commit(id, { lookup_timeout = 2 })
    t.assert_equals(err, nil, 'commit must not fail with PREPARED_NOT_FOUND')
    t.assert_not_equals(r, nil)
    t.assert_equals(r.dry_run, true)
end
