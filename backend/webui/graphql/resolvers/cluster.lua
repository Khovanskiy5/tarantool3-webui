--
-- Resolvers for the `cluster` query family.
--
-- The resolver reads from `cluster.state.snapshot()` once per query
-- and projects the immutable copy into GraphQL shapes. No live RPC,
-- no net.box, no blocking calls — the poller is the only writer and
-- the snapshot is a deep copy, so even a long-running resolver
-- (large cluster, expensive field selection) never starves the
-- HTTP fiber.
--
-- Pagination contract for `cluster.servers`:
--
--   * Sort order is by UUID (lexicographic, with nil-uuid entries
--     last so newly-added peers without a probe land at the tail).
--   * `after` is the UUID of the last item from the previous page.
--   * `limit` defaults to 50, caps at 500.
--   * `nextCursor` is the UUID of the last item in the returned
--     page, or null when the page contains the final item.
--

local checks = require('checks')

local state = require('webui.cluster.state')
local log_util = require('webui.log_util')
local logger = log_util.with_tag('graphql.cluster')

local M = {}

M.DEFAULT_PAGE_SIZE = 50
M.MAX_PAGE_SIZE     = 500

-- ── pure helpers ────────────────────────────────────────────────────

-- Stable sort key: primary by UUID, secondary by alias so peers
-- without a UUID still have deterministic order. A nil UUID sorts
-- after every real UUID so newly added instances appear at the
-- tail rather than the head of the list (UI-friendly).
local function server_sort_key(a, b)
    local au, bu = a.uuid, b.uuid
    if au == bu then
        return tostring(a.alias) < tostring(b.alias)
    end
    if au == nil then return false end
    if bu == nil then return true  end
    return au < bu
end

-- Pure: take the unpaginated server map and produce the ordered
-- list. Pulled out so unit tests can verify the contract without
-- spinning up box / poller.
function M.sort_servers(servers)
    checks('?table')
    local out = {}
    if type(servers) ~= 'table' then return out end
    for _, srv in pairs(servers) do
        table.insert(out, srv)
    end
    table.sort(out, server_sort_key)
    return out
end

-- Pure: slice an already-sorted list using cursor semantics.
-- `after` is the UUID of the last item from the previous page;
-- nil means "start from the beginning".
function M.paginate(sorted, after, limit)
    checks('?table', '?string', '?number')
    sorted = sorted or {}

    -- Skip until we are past the cursor. The pure function does
    -- not assume a particular iteration order over input so the
    -- cursor lookup is O(n); for the typical cluster size this is
    -- cheaper than maintaining a separate index.
    local start_idx = 1
    if after ~= nil and after ~= '' then
        for i = 1, #sorted do
            if sorted[i].uuid == after then
                start_idx = i + 1
                break
            end
        end
    end

    local resolved_limit = math.floor(tonumber(limit) or M.DEFAULT_PAGE_SIZE)
    if resolved_limit <= 0 then resolved_limit = M.DEFAULT_PAGE_SIZE end
    if resolved_limit > M.MAX_PAGE_SIZE then resolved_limit = M.MAX_PAGE_SIZE end

    local end_idx = math.min(#sorted, start_idx + resolved_limit - 1)
    local items = {}
    for i = start_idx, end_idx do
        table.insert(items, sorted[i])
    end

    local next_cursor = nil
    if end_idx < #sorted then
        local last = items[#items]
        next_cursor = last and last.uuid or nil
    end

    return {
        items        = items,
        next_cursor  = next_cursor,
        total_count  = #sorted,
    }
end

-- Pure: derive the aggregate replicaset health from per-server
-- reachability. The mapping is intentionally simple at M1 — the
-- detailed health rollup lands with the issues scanner (Task 19).
local function rollup_status(servers)
    local total, reachable = 0, 0
    for _, s in ipairs(servers) do
        total = total + 1
        if s.reachable then reachable = reachable + 1 end
    end
    if total == 0 then return 'unknown' end
    if reachable == total then return 'healthy' end
    if reachable == 0 then return 'unhealthy' end
    return 'degraded'
end

-- Pure: convert the snapshot's replicasets table into the
-- GraphQL Replicaset shape. The input contains alias-only
-- members; the output includes the resolved Server records.
function M.build_replicasets(snapshot)
    checks('?table')
    snapshot = snapshot or { replicasets = {}, servers = {} }
    local out = {}
    for name, rs in pairs(snapshot.replicasets or {}) do
        local members = {}
        for _, alias in ipairs(rs.instances or {}) do
            local srv = snapshot.servers and snapshot.servers[alias]
            if srv ~= nil then table.insert(members, srv) end
        end
        table.sort(members, function(a, b)
            return tostring(a.alias) < tostring(b.alias)
        end)
        -- The active leader is whichever member reports `ro = false`.
        -- Until the poller fills this field for every peer, the
        -- value can be nil.
        local active_leader
        for _, s in ipairs(members) do
            if s.is_ro == false then
                active_leader = s.alias
                break
            end
        end
        local first = members[1]
        table.insert(out, {
            name          = name,
            alias         = name,
            uuid          = first
                and (first.replicaset and first.replicaset.uuid or nil)
                or nil,
            group_name    = rs.group_name,
            status        = rollup_status(members),
            roles         = {},
            weight        = nil,
            leader        = rs.leader,
            active_leader = active_leader,
            all_rw        = false,
            vshard_group  = nil,
            servers       = members,
        })
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ── public resolvers ────────────────────────────────────────────────

-- Single object returned for the top-level `cluster` field. The
-- per-field resolvers below close over the same snapshot so the
-- query sees a consistent state even if a tick runs in between.
function M.cluster(_, args, _info, _ctx)
    local snap = state.snapshot()
    logger.debug('cluster query', {
        generation   = snap.generation,
        servers      = (function()
            local n = 0
            for _ in pairs(snap.servers or {}) do n = n + 1 end
            return n
        end)(),
    })
    return {
        snapshot = snap,
        args     = args or {},
    }
end

function M.cluster_self(root)
    local snap = root.snapshot
    if snap == nil or snap.self_alias == nil then return nil end
    return snap.servers and snap.servers[snap.self_alias] or nil
end

function M.cluster_servers(root, args)
    args = args or {}
    local snap = root.snapshot
    local sorted = M.sort_servers(snap and snap.servers or nil)
    return M.paginate(sorted, args.after, args.limit)
end

function M.cluster_replicasets(root)
    return M.build_replicasets(root.snapshot)
end

function M.cluster_known_roles()
    -- Roles awareness ships in M2 when the role registry lands.
    -- Returning an empty list keeps the schema stable.
    return {}
end

function M.cluster_vshard_groups()
    -- Sharding groups are populated by Task 47. Until then this
    -- field returns an empty list rather than nil so consumers do
    -- not need a separate null guard.
    return {}
end

return M
