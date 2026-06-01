--
-- Integration test for the audit hash-chain migration (Phase 4
-- Task 4.1 + 4.1b).
--
-- Simulates the rolling-upgrade path: an existing deployment has a
-- pre-chain `_webui_audit` with rows already in it, then ships
-- schema_version 8 (adds prev_hash/current_hash/chain_seal) and 9
-- (re-backfills with the stable canonical form).
--
-- Steps verified end-to-end:
--   1. Old-schema rows are still readable.
--   2. Backfill reaches every row in id-order.
--   3. The verifier reports ok=true on the back-filled tail.
--   4. A subsequent insert via `record_local` continues the chain
--      and the verifier still says ok.
--   5. Retention seal does not look like corruption to the verifier.
--

local t = require('luatest')
local fio = require('fio')
local clock = require('clock')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('audit_upgrade')

local TMP = nil

g.before_all(function()
    TMP = fio.tempdir()
    box.cfg({
        memtx_dir   = TMP,
        wal_dir     = TMP,
        wal_mode    = 'none',
        listen      = box.NULL,
        log_level   = 0,
    })
    -- record_local writes through a sync space — solo instance
    -- has no synchro queue owner by default, so promote.
    pcall(box.ctl.promote)
end)

g.before_each(function()
    -- Fresh space per test so the chain starts from id=1 every
    -- time. Drop with pcall so the first run does not throw on
    -- "space does not exist".
    pcall(function() box.space._webui_audit:drop() end)
end)

local function create_pre_chain_space()
    -- Re-create the schema in its pre-Task-4.1 shape: the
    -- chain-related fields are absent. The migration step 8
    -- alters the format and back-fills.
    box.schema.space.create('_webui_audit', {
        is_sync = true,
        format = {
            { name = 'id',         type = 'unsigned' },
            { name = 'ts',         type = 'unsigned' },
            { name = 'user',       type = 'string', is_nullable = true },
            { name = 'action',     type = 'string' },
            { name = 'scope',      type = 'string', is_nullable = true },
            { name = 'payload',    type = 'any',    is_nullable = true },
            { name = 'request_id', type = 'string', is_nullable = true },
        },
    })
    box.space._webui_audit:create_index('primary', {
        parts = { 'id' }, sequence = true,
    })
    box.space._webui_audit:create_index('by_ts', {
        parts = { 'ts' }, unique = false,
    })
    box.space._webui_audit:create_index('by_user', {
        parts = { { field = 'user', is_nullable = true } },
        unique = false,
    })
end

g.test_migration_8_then_9_back_fills_existing_rows = function()
    create_pre_chain_space()
    -- Seed 25 rows in id-order. Mix payloads so the canonical
    -- serializer exercises both scalar and table fields.
    local audit = box.space._webui_audit
    local started_at = math.floor(clock.realtime() * 1e6)
    for i = 1, 25 do
        audit:insert({
            box.NULL,
            started_at + i,
            'user-' .. (i % 3),
            'test.action.' .. i,
            i % 2 == 0 and 'scope-A' or 'scope-B',
            { i = i, payload = { nested = i * 2 } },
            'req-' .. i,
        })
    end
    t.assert_equals(audit:count(), 25)

    -- Run migration 8 directly. The plan keeps each step pure
    -- (takes `box` only), so we can invoke them out of band.
    local migrations = require('webui.storage.migrations')
    migrations.migrations[8](box)
    -- Step 8 emits stable bytes only when run with the new
    -- canonical, which is what step 9 enforces. We run both.
    migrations.migrations[9](box)

    -- Every row must now have prev_hash + current_hash, and the
    -- verifier must walk the chain without complaining.
    for _, tuple in audit.index.primary:pairs() do
        t.assert_type(tuple.current_hash, 'string',
            'row ' .. tuple.id .. ' missing current_hash')
        t.assert(#tuple.current_hash == 64,
            'sha256-hex is 64 chars')
    end
    local verifier = require('webui.audit.verifier')
    local res = verifier.verify()
    t.assert_equals(res.ok, true, res.reason or '')
    t.assert_equals(res.scanned, 25)
end

g.test_record_local_continues_the_chain_after_backfill = function()
    create_pre_chain_space()
    local audit = box.space._webui_audit
    local ts0 = math.floor(clock.realtime() * 1e6)
    for i = 1, 5 do
        audit:insert({
            box.NULL, ts0 + i, 'pre-user', 'pre.action',
            'pre-scope', { i = i }, 'pre-req',
        })
    end
    local migrations = require('webui.storage.migrations')
    migrations.migrations[8](box)
    migrations.migrations[9](box)

    -- Insert one row through the production code path. It must
    -- read the latest chain link, derive prev_hash from it, and
    -- store a fresh current_hash that the verifier accepts.
    local log = require('webui.audit.log')
    local new_tuple = log.record_local({
        user   = 'post-user',
        action = 'post.action',
        scope  = 'post-scope',
        payload = { hello = 'world' },
        request_id = 'post-req',
    })
    t.assert_type(new_tuple, 'cdata', 'record_local returns a tuple')
    t.assert_equals(new_tuple.id, 6)
    t.assert_type(new_tuple.current_hash, 'string')

    local verifier = require('webui.audit.verifier')
    local res = verifier.verify()
    t.assert_equals(res.ok, true, res.reason or '')
    t.assert_equals(res.scanned, 6)
end

g.test_retention_seal_is_not_corruption = function()
    create_pre_chain_space()
    local audit = box.space._webui_audit
    local ts0 = math.floor(clock.realtime() * 1e6)
    for i = 1, 10 do
        audit:insert({
            box.NULL, ts0 + i, 'u', 'a',
            'scope', { i = i }, 'r',
        })
    end
    local migrations = require('webui.storage.migrations')
    migrations.migrations[8](box)
    migrations.migrations[9](box)

    -- Drop the 4 oldest rows manually, then SEAL the new oldest
    -- exactly the way retention.sweep_once would.
    for i = 1, 4 do audit:delete({ i }) end
    audit:update({ 5 }, {
        { '=', 'prev_hash',  box.NULL },
        { '=', 'chain_seal', true },
    })

    local verifier = require('webui.audit.verifier')
    local res = verifier.verify()
    t.assert_equals(res.ok, true, res.reason or '')
    t.assert(res.seals >= 1, 'verifier counts at least one seal')
end

g.test_verifier_flags_corruption_after_chain = function()
    create_pre_chain_space()
    local audit = box.space._webui_audit
    local ts0 = math.floor(clock.realtime() * 1e6)
    for i = 1, 5 do
        audit:insert({
            box.NULL, ts0 + i, 'u', 'a',
            'scope', { i = i }, 'r',
        })
    end
    local migrations = require('webui.storage.migrations')
    migrations.migrations[8](box)
    migrations.migrations[9](box)

    -- Mutate row 3 in place — bypass the production writer so
    -- current_hash stays at the original value. The verifier
    -- should detect that row 4's prev_hash no longer matches
    -- row 3's (now-stale) current_hash.
    audit:update({ 3 }, { { '=', 'action', 'TAMPERED' } })

    local verifier = require('webui.audit.verifier')
    local res = verifier.verify()
    t.assert_equals(res.ok, false)
    -- The detection point is row 3 itself (its recomputed hash
    -- no longer matches the stored current_hash).
    t.assert_equals(res.broken_at, 3)
end
