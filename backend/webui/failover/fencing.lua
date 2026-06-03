--
-- Leader self-fencing decision (Task FO-1).
--
-- A leader that can no longer confirm — via a successful etcd
-- appointment read naming itself — that it is still the appointed
-- leader must voluntarily step down to read-only BEFORE the
-- coordinator lease can be regranted to someone else. Otherwise a
-- leader partitioned from etcd keeps accepting writes while a new
-- coordinator appoints (and promotes) a different instance — the
-- classic stale-leader split-brain (Patroni `demote('offline')`,
-- Kleppmann fencing, K8s "give up at the renew deadline").
--
-- This module holds ONLY the pure decision so it is unit-testable
-- without a running box. The wiring (tracking the last-confirm
-- timestamp on a monotonic clock, the probe fiber, the actual
-- demote) lives in `failover/watcher.lua`.
--
-- Timing: `renew_deadline = lease_ttl_sec - safety_margin`. It MUST
-- be strictly less than `lease_ttl_sec` so the old leader is already
-- read-only by the time the lease (and thus the right to appoint a
-- new leader) could change hands. `safety_margin` absorbs clock
-- skew. All time math uses a MONOTONIC clock (`fiber.clock()`), never
-- wall-clock, which can jump on NTP steps / VM time-warps.
--

local M = {}

-- Should the current instance self-fence (demote to read-only)?
--
-- `state` fields:
--   * is_leader          — do we currently own the synchro queue?
--   * now_mono           — monotonic now (fiber.clock()).
--   * last_confirm_mono  — monotonic time of our last successful
--                          self-as-leader confirmation via etcd.
--   * renew_deadline     — seconds; fence once the gap reaches it.
--
-- Returns a reason string when fencing is required, otherwise nil.
-- Defensive: missing/invalid inputs → nil (never fence on bad data).
function M.should_fence(state)
    if type(state) ~= 'table' then return nil end
    if not state.is_leader then return nil end
    local now = tonumber(state.now_mono)
    local last = tonumber(state.last_confirm_mono)
    local deadline = tonumber(state.renew_deadline)
    if now == nil or last == nil or deadline == nil then return nil end
    if deadline <= 0 then return nil end
    if (now - last) >= deadline then
        return 'lease_renew_timeout'
    end
    return nil
end

return M
