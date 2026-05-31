--
-- Audit log writer (Task 26a fills in retention + query helpers).
--
-- Every security-relevant action — login, logout, config commit,
-- mutation dispatch, RBAC denial — appends a row to
-- `_webui_audit`. The space is replicated so an audit query
-- against any peer sees the full history.
--
-- Replication implication: the insert below is leader-only. With
-- HAProxy round-robin in front of the cluster, ~2/3 of audit calls
-- land on a follower. `M.record` detects that and forwards the
-- write through the `webui_peer` net.box pool — the leader does
-- the insert and replication pushes the row back so a later read
-- from any peer sees it. Forwarding is best-effort: on a network
-- partition the audit entry is dropped (with a WARN log) rather
-- than blocking the originating user request.
--

local checks = require('checks')

local storage  = require('webui.storage.spaces')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('audit')

local M = {}

local function now()
    -- Microsecond precision so close-in-time events keep a
    -- deterministic order even if the autoincrement id is gapped
    -- by another writer.
    return math.floor(require('fiber').time() * 1e6)
end

-- Direct insert into the local `_webui_audit` space. Only valid on
-- the leader; followers raise READONLY. Exposed for the net.box
-- shim in `init.lua` so a follower can hop here over the peer pool.
function M.record_local(entry)
    checks({
        user       = '?string',
        action     = 'string',
        scope      = '?string',
        payload    = '?',
        request_id = '?string',
    })
    local space = storage.audit()
    if space == nil then
        return nil, 'audit storage is not bootstrapped'
    end
    -- box.NULL drives the primary key's sequence.
    local tuple = space:insert({
        box.NULL,
        now(),
        entry.user,
        entry.action,
        entry.scope,
        entry.payload,
        entry.request_id,
    })
    logger.debug('audit entry recorded', {
        id = tuple.id, action = entry.action, user = entry.user,
    })
    return tuple
end

local function is_read_only()
    if rawget(_G, 'box') == nil or box.info == nil then return false end
    return box.info.ro == true
end

local function forward_to_leader(entry)
    local ok_state, cluster_state = pcall(require, 'webui.cluster.state')
    local ok_peers, peers         = pcall(require, 'webui.cluster.peers')
    if not (ok_state and ok_peers) then
        return nil, 'forward unavailable: cluster modules not loaded'
    end
    local leader_alias = cluster_state.find_leader()
    if leader_alias == nil then
        return nil, 'no leader'
    end
    local peer = peers.get(leader_alias)
    if peer == nil or peer.conn == nil then
        return nil, 'leader connection unavailable'
    end
    -- Fire-and-forget: audit is best-effort and must not stall the
    -- user request. is_async returns a future we deliberately do
    -- not await — the dispatcher loop will surface its outcome
    -- through the connection's error counters.
    local ok, err = pcall(function()
        peer.conn:call('webui_audit_record_remote',
            { entry }, { is_async = true })
    end)
    if not ok then
        return nil, tostring(err)
    end
    return { forwarded = true, leader = leader_alias }
end

-- Append a row. Returns the new tuple (local fast path) or a
-- forwarded marker. On every error path returns `nil, err` so
-- existing `pcall(audit.record, ...)` call sites keep working.
function M.record(entry)
    if is_read_only() then
        local ok, err = forward_to_leader(entry)
        if ok == nil then
            logger.warn('audit forward dropped', {
                action = entry.action, user = entry.user, err = err,
            })
        end
        return ok, err
    end
    return M.record_local(entry)
end

return M
