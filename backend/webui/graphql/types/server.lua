-- GraphQL Server / BoxInfo / Statistics / ServerPage types.
--
-- A Server represents a single Tarantool instance from the
-- perspective of the responding role. Every field is read from
-- `cluster.state.snapshot()` — the resolver does no live RPC and
-- never blocks.
--
-- BoxInfo carries the subset of `box.info` the UI actually shows
-- (version, uptime, raft, vclock as JSON). It is nested rather
-- than flattened so the cluster query can request only the cheap
-- fields when rendering tables.
--
-- Statistics is a nested object that will fill out in Task 19
-- (issues scanner pulls slab data). It is exposed now so the
-- frontend schema is stable across the M1 series.
--
-- ServerPage is a tiny cursor-based pagination envelope: callers
-- pass an `after` cursor (a UUID string) and a `limit` (default
-- 50, max 500). The next cursor is null when the page is the
-- last one.

local types = require('graphql.types')

local label_types = require('webui.graphql.types.label')

local M = {}

M.BoxInfo = types.object {
    name = 'BoxInfo',
    description = 'Subset of box.info exposed to the UI.',
    fields = {
        uuid = {
            kind = types.string,
            description = 'Instance UUID from box.info.uuid.',
        },
        version = {
            kind = types.string,
            description = 'Tarantool runtime version.',
        },
        uptime = {
            kind = types.float,
            description = 'Seconds since box bootstrap.',
            resolve = function(root) return root.uptime end,
        },
        status = {
            kind = types.string,
            description = 'box.info.status (running, orphan, recovery, ...).',
        },
        ro = {
            kind = types.boolean,
            description = 'box.info.ro — true when writes are rejected.',
            -- cluster.state stores the field as `is_ro` to avoid
            -- colliding with `ro_reason` when the merge runs over a
            -- table; remap it back on the way out.
            resolve = function(root) return root.is_ro end,
        },
        roReason = {
            kind = types.string,
            description = 'Reason for read-only state (election, config, ...)',
            resolve = function(root) return root.ro_reason end,
        },
        vclock = {
            kind = types.string,
            description = 'box.info.vclock as compact JSON.',
            resolve = function(root)
                if root.vclock == nil then return nil end
                local ok, encoded = pcall(require('json').encode, root.vclock)
                if not ok then return nil end
                return encoded
            end,
        },
        replicasetUuid = {
            kind = types.string,
            description = 'box.info.replicaset.uuid when available.',
            resolve = function(root)
                if type(root.replicaset) == 'table' then
                    return root.replicaset.uuid
                end
                return nil
            end,
        },
    },
}

M.Statistics = types.object {
    name = 'Statistics',
    description = 'Memory and slab counters from box.slab.info(). Fields '
        .. 'are nullable because the issues scanner (Task 19) is the '
        .. 'source of truth and may not yet have populated them.',
    fields = {
        arenaUsedRatio = {
            kind = types.float,
            description = 'box.slab.info().arena_used_ratio as a 0-1 fraction.',
            resolve = function(root) return root.arena_used_ratio end,
        },
        itemsUsedRatio = {
            kind = types.float,
            description = 'box.slab.info().items_used_ratio as a 0-1 fraction.',
            resolve = function(root) return root.items_used_ratio end,
        },
        quotaUsedRatio = {
            kind = types.float,
            description = 'box.slab.info().quota_used_ratio as a 0-1 fraction.',
            resolve = function(root) return root.quota_used_ratio end,
        },
    },
}

M.Server = types.object {
    name = 'Server',
    description = 'A single Tarantool instance as seen by the responding role.',
    fields = {
        alias = {
            kind = types.string.nonNull,
            description = 'Instance alias from `box.info.name` / cluster config.',
        },
        uri = {
            kind = types.string,
            description = 'iproto.advertise.peer URI used to reach the instance.',
        },
        uuid = {
            kind = types.string,
            description = 'Instance UUID. Null until the first successful probe.',
        },
        status = {
            kind = types.string.nonNull,
            description = 'Reported status: running, unreachable, unknown.',
        },
        message = {
            kind = types.string,
            description = 'Free-form status message from the last probe.',
            resolve = function(root) return root.message or root.last_error end,
        },
        electable = {
            kind = types.boolean.nonNull,
            description = 'True when this instance may be elected leader.',
        },
        replicasetName = {
            kind = types.string,
            description = 'Name of the replicaset this server belongs to.',
            resolve = function(root) return root.replicaset_name end,
        },
        groupName = {
            kind = types.string,
            description = 'Name of the cluster-config group this server belongs to.',
            resolve = function(root) return root.group_name end,
        },
        labels = {
            kind = types.list(label_types.Label.nonNull).nonNull,
            description = 'User-defined labels attached via cluster config.',
            resolve = function(root)
                local out = {}
                if type(root.labels) == 'table' then
                    for name, value in pairs(root.labels) do
                        table.insert(out, {
                            name  = tostring(name),
                            value = tostring(value),
                        })
                    end
                    table.sort(out, function(a, b) return a.name < b.name end)
                end
                return out
            end,
        },
        zone = {
            kind = types.string,
            description = 'Failover zone tag from cluster config.',
        },
        boxInfo = {
            kind = M.BoxInfo,
            description = 'Snapshot of the remote box.info — null when the '
                .. 'instance has not been probed yet.',
            resolve = function(root)
                if root.uuid == nil and root.version == nil then return nil end
                return root
            end,
        },
        statistics = {
            kind = M.Statistics,
            description = 'Memory counters from the last probe; populated by Task 19.',
            resolve = function(root)
                if root.arena_used_ratio == nil
                    and root.items_used_ratio == nil
                    and root.quota_used_ratio == nil then
                    return nil
                end
                return root
            end,
        },
        configStatus = {
            kind = types.string,
            description = 'Last reported config.info().status from the instance.',
            resolve = function(root) return root.config_status end,
        },
        reachable = {
            kind = types.boolean.nonNull,
            description = 'True when the last probe returned a value.',
        },
        lastSeen = {
            kind = types.float,
            description = 'fiber.clock() of the last successful probe; null when never.',
            resolve = function(root) return root.last_seen end,
        },
        lastError = {
            kind = types.string,
            description = 'Error from the most recent failed probe; null after recovery.',
            resolve = function(root) return root.last_error end,
        },
        nextRetryAt = {
            kind = types.float,
            description = 'fiber.clock() time when the poller will retry this peer; '
                .. 'null when the peer is reachable and out of backoff.',
            resolve = function(root) return root.next_retry_at end,
        },
    },
}

M.ServerPage = types.object {
    name = 'ServerPage',
    description = 'Cursor-paginated slice of Server entries.',
    fields = {
        items = {
            kind = types.list(M.Server.nonNull).nonNull,
            description = 'Page contents.',
        },
        nextCursor = {
            kind = types.string,
            description = 'Pass as `after` to fetch the next page; null when the page is last.',
            resolve = function(root) return root.next_cursor end,
        },
        totalCount = {
            kind = types.int.nonNull,
            description = 'Total number of servers across all pages.',
            resolve = function(root) return root.total_count end,
        },
    },
}

return M
