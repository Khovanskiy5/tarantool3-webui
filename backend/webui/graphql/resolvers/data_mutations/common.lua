--
-- Shared helpers for data_mutations sub-modules.
--
-- Lives at the bottom of the dependency graph: tuple / space /
-- index / remote all `require` this module; nothing here may
-- `require` back into them or a cycle would form.
--
-- Contents:
--
--   * SENSITIVE_SPACES   – deny-list shared by every resolver and
--                          re-enforced by the remote receivers so
--                          a misbehaving follower cannot smuggle a
--                          write.
--   * require_role       – RBAC gate keyed by the GraphQL field
--                          name; falls back to 'admin'.
--   * assert_safe_space  – tuple-level deny-list check.
--   * assert_safe_ddl    – DDL-level guard: same deny-list plus a
--                          ban on creating/altering anything in
--                          the `_` namespace.
--   * space_format /
--     space_pk_parts     – introspection helpers used by every
--                          tuple op.
--   * is_read_only       – leader detection (true on followers).
--   * forward_dml /
--     forward_ddl        – forward to the cluster leader via
--                          net.box. Two flavours because DML and
--                          DDL register different remote entry
--                          points (`webui_data_mutation_remote`
--                          vs `webui_space_mutation_remote`).
--   * tuple_to_wire      – encode a tuple for the GraphQL response.
--   * audit_record       – tolerant pcall wrapper around the audit
--                          sink; never raises into the resolver.
--   * UPDATE_OPS         – alias table mapping user-facing op names
--                          to Tarantool's single-char codes; shared
--                          between tuple.lua and any future module
--                          that wants to validate op codes.
--

local rbac     = require('webui.auth.rbac')
local audit    = require('webui.audit.log')
local de_types = require('webui.data_explorer.types')

local M = {}

-- Spaces the GraphQL surface refuses to mutate at the tuple level.
-- Read access stays open under admin (with masked credential fields
-- — see `admin_data.lua`).
M.SENSITIVE_SPACES = {
    _user             = true,
    _priv             = true,
    _func             = true,
    _schema           = true,
    _cluster          = true,
    _session_settings = true,
}

function M.require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

function M.assert_safe_space(space_name, op)
    if M.SENSITIVE_SPACES[space_name] then
        error('FORBIDDEN: ' .. op .. ' on system space ' .. space_name ..
            ' is blocked. Use dedicated mutations (setUserRoles, ' ..
            'grantPrivilege, hotReloadModule, ...) so the change ' ..
            'goes through validation + audit + the matching ' ..
            'forward-to-leader path.')
    end
end

-- DDL guard: tuple deny-list plus the wider `_` namespace, since
-- Tarantool reserves it for system spaces and dedicated mutations
-- own those flows (createUser, hotReloadModule, ...).
function M.assert_safe_ddl(name, op)
    if M.SENSITIVE_SPACES[name] or name:sub(1, 1) == '_' then
        error('FORBIDDEN: ' .. op .. ' on system space ' .. name ..
            ' is blocked. The `_`-prefix namespace belongs to Tarantool ' ..
            'and dedicated mutations (createUser, hotReloadModule, …).')
    end
end

function M.space_format(space)
    local raw = type(space.format) == 'function' and space:format() or {}
    return de_types.normalize_format(raw)
end

function M.space_pk_parts(space)
    local idx = space.index[0]
    if idx == nil then return {} end
    return idx.parts or {}
end

function M.is_read_only()
    if rawget(_G, 'box') == nil or box.info == nil then return false end
    return box.info.ro == true
end

-- ── leader forwarding ──────────────────────────────────────────────
--
-- Both flavours look up the same leader and reuse the same peer
-- connection pool; only the remote function name differs.

local function resolve_leader_peer()
    local ok_state, cluster_state = pcall(require, 'webui.cluster.state')
    local ok_peers, peers         = pcall(require, 'webui.cluster.peers')
    if not (ok_state and ok_peers) then
        return nil, nil, 'UNAVAILABLE: cluster modules not loaded'
    end
    local leader_alias = cluster_state.find_leader()
    if leader_alias == nil then
        return nil, nil, 'UNAVAILABLE: no cluster leader reachable'
    end
    local peer = peers.get(leader_alias)
    if peer == nil or peer.conn == nil then
        return nil, nil, 'UNAVAILABLE: leader ' .. leader_alias .. ' not reachable'
    end
    return leader_alias, peer, nil
end

local FORWARD_TIMEOUT_SEC = 5

function M.forward_dml(op, space, payload, root)
    local leader_alias, peer, err = resolve_leader_peer()
    if err ~= nil then return nil, err end
    local ok, res, call_err = pcall(function()
        return peer.conn:call('webui_data_mutation_remote',
            { op, space, payload, {
                user       = root and root.user,
                request_id = root and root.request_id,
                roles      = root and root.roles,
            } }, { timeout = FORWARD_TIMEOUT_SEC })
    end)
    if not ok then
        return nil, 'forward to leader ' .. leader_alias .. ' failed: ' .. tostring(res)
    end
    if type(res) == 'table' and res._error ~= nil then
        return nil, res._error
    end
    if call_err ~= nil then
        return nil, tostring(call_err)
    end
    res.forwarded = true
    res.leader = leader_alias
    return res
end

function M.forward_ddl(op, payload, root)
    local leader_alias, peer, err = resolve_leader_peer()
    if err ~= nil then return nil, err end
    local ok, res, call_err = pcall(function()
        return peer.conn:call('webui_space_mutation_remote',
            { op, payload, {
                user       = root and root.user,
                request_id = root and root.request_id,
            } }, { timeout = FORWARD_TIMEOUT_SEC })
    end)
    if not ok then
        return nil, 'forward to leader ' .. leader_alias .. ' failed: ' .. tostring(res)
    end
    if type(res) == 'table' and res._error ~= nil then
        return nil, res._error
    end
    if call_err ~= nil then
        return nil, tostring(call_err)
    end
    res.forwarded = true
    res.leader = leader_alias
    return res
end

-- ── encoding ───────────────────────────────────────────────────────

function M.tuple_to_wire(tuple)
    if tuple == nil then return nil end
    local fields = {}
    -- `encode_field` maps a stored NULL to Lua nil. Writing nil into
    -- the middle of `fields` would punch a hole and truncate the
    -- list (Lua `#` stops at the first nil), so we substitute the
    -- box.NULL sentinel — it occupies the slot AND json.encode
    -- renders it as JSON `null` on the wire.
    for i = 1, #tuple do
        local enc = de_types.encode_field(tuple[i])
        if enc == nil then enc = box.NULL end
        fields[i] = enc
    end
    return fields
end

-- ── audit ──────────────────────────────────────────────────────────
--
-- Audit is best-effort: a failure to record must not break the
-- user's operation. Caller passes a fully built entry; we only
-- pcall it through.

function M.audit_record(entry)
    pcall(audit.record, entry)
end

-- ── shared op-alias table ──────────────────────────────────────────

M.UPDATE_OPS = {
    set = '=', SET = '=', ['='] = '=',
    add = '+', ADD = '+', ['+'] = '+',
    sub = '-', SUB = '-', ['-'] = '-',
    band = '&', BAND = '&', ['&'] = '&',
    bor  = '|', BOR  = '|', ['|'] = '|',
    bxor = '^', BXOR = '^', ['^'] = '^',
    splice = ':', SPLICE = ':', [':'] = ':',
    insert = '!', INSERT = '!', ['!'] = '!',
    delete = '#', DELETE = '#', ['#'] = '#',
}

return M
