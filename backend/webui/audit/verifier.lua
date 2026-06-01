--
-- Audit chain verifier (Phase 4 Task 4.3, hash part).
--
-- Walks the `_webui_audit` space in id-order, recomputes each
-- row's `current_hash` from its canonical form + the previous
-- link, and reports the first row whose recorded hash differs
-- from the recomputed one — that's the corruption point.
--
-- A row with `chain_seal = true` is treated as a legitimate
-- restart (see audit/retention.lua): the verifier resets `prev`
-- to nil at that boundary instead of complaining that the
-- previous row vanished. Rows with no `current_hash` at all
-- (pre-chain rows that the migration could not back-fill, or
-- newly-inserted rows in some failure window) are also accepted
-- but they bypass the hash check for that link.
--
-- The Ed25519 signature half lives in audit/signer.lua + future
-- audit/verifier.lua extension (Task 4.2 / 4.3 part 2). This file
-- only deals with the hash chain.
--

local storage = require('webui.storage.spaces')
local chain   = require('webui.audit.chain')

local M = {}

-- verify(opts) → result table
-- opts.from_id (number, optional): start at this id (inclusive).
-- opts.to_id   (number, optional): stop after this id (inclusive).
--
-- Returns:
--   { ok: true, scanned, seals }                — chain intact
--   { ok: false, broken_at, expected_hash,
--     actual_hash, scanned, seals }             — first break
function M.verify(opts)
    opts = opts or {}
    local space = storage.audit()
    if space == nil then
        return { ok = false, reason = 'audit storage not bootstrapped' }
    end
    local from_id = tonumber(opts.from_id) or 0
    local to_id   = tonumber(opts.to_id)
    local primary = space.index.primary
    local prev = nil
    local scanned = 0
    local seals = 0
    for _, tuple in primary:pairs({ from_id }, { iterator = 'GE' }) do
        if to_id ~= nil and tuple.id > to_id then break end

        if tuple.chain_seal == true then
            -- Legitimate restart. Reset `prev` so the next row
            -- is verified against nil (matches what record_local
            -- did at the time of writing the sealed row).
            prev = tuple.current_hash
            seals = seals + 1
            scanned = scanned + 1
            -- Continue: the sealed row itself ALSO carries a
            -- hash that we already considered correct (it was
            -- written with `prev_hash = null` after the seal).
            -- We do not re-verify it because the writer set it,
            -- not derived from a previous link.
        else
            local recorded_prev = tuple.prev_hash
            local recorded_curr = tuple.current_hash
            if recorded_curr == nil or recorded_curr == '' then
                -- Pre-chain row (migration tail) — accept and
                -- carry an empty `prev` so the next link is
                -- judged from nil. Verifier never alarms on a
                -- missing hash; that's a deployment state, not
                -- corruption.
                prev = nil
            else
                if (recorded_prev or '') ~= (prev or '') then
                    return {
                        ok        = false,
                        broken_at = tuple.id,
                        expected_hash = prev,
                        actual_hash   = recorded_prev,
                        reason    = 'prev_hash does not match previous row',
                        scanned   = scanned,
                        seals     = seals,
                    }
                end
                local recomputed = chain.row_hash(prev, tuple)
                if recomputed ~= recorded_curr then
                    return {
                        ok        = false,
                        broken_at = tuple.id,
                        expected_hash = recomputed,
                        actual_hash   = recorded_curr,
                        reason    = 'current_hash does not match canonical form',
                        scanned   = scanned,
                        seals     = seals,
                    }
                end
                prev = recorded_curr
            end
            scanned = scanned + 1
        end
    end
    return { ok = true, scanned = scanned, seals = seals }
end

return M
