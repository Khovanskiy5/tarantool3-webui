--
-- Replication topology fix (Phase 6 Task DR-7).
--
-- Symptom: someone edited the cluster YAML and the URI for one
-- of the instances now points at a host:port nothing answers
-- (typo, container rename, port conflict). The applier on every
-- peer is stuck waiting for the dead URI, the suggestions panel
-- shows "replication ... is stopped: connect, called on fd ...".
--
-- Two phases:
--
--   * `diagnose(yaml)` — parse the live cluster YAML, walk every
--     declared instance, return a list of {alias, declared_uri,
--     observed_uri, reachable} plus a `suggestion` field with
--     the correct URI when we know it (taken from the peer pool
--     which sees the real connect target).
--
--   * `apply(yaml, fixes)` — replace declared URIs with the
--     suggested ones and feed the patched YAML through the
--     existing twophase pipeline. Audit row + revert path live
--     in the resolver layer (config/twophase already audits).
--

local yaml = require('yaml')

local assess   = require('webui.recovery.assess')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('recovery.topology')

local M = {}

-- assess(payload, root) → Assessment (read-only). Fixing replication URIs
-- never touches tuple data, so it is `caution` (a config reload / restart
-- is the only effect), not `dangerous`.
function M.assess(payload, _root, snap)
    payload = payload or {}
    local fixes = payload.fixes or {}
    local aliases = {}
    for alias in pairs(type(fixes) == 'table' and fixes or {}) do
        aliases[#aliases + 1] = tostring(alias)
    end
    table.sort(aliases)
    snap = snap or require('webui.recovery.snapshot').build()
    local fp = assess.fingerprint(snap, aliases)
    local b = assess.new('topology_fix')
        .risk(assess.CAUTION)
        .summary('Fix replication URIs for ' .. tostring(#aliases) .. ' instance(s)')
        .with_docs('runbooks/topology-fix.md')
        .effect('Rewrites declared URIs in the cluster config via the '
            .. 'two-phase commit; no tuple data is changed.')
        .effect('Triggers a config reload / instance restart to take effect.')
        .precondition(#aliases > 0, 'At least one URI fix supplied')
    for _, alias in ipairs(aliases) do
        b.effect(alias .. ' -> ' .. tostring(fixes[alias]))
    end
    logger.debug('topology_fix.assess', { count = #aliases })
    return b.build(fp)
end

-- Walk `cfg.groups.<g>.replicasets.<rs>.instances.<alias>.iproto
-- .advertise.peer.uri` for every instance. Returns a flat list
-- of { alias, group, replicaset, declared_uri }.
function M.walk_declared(cfg)
    local out = {}
    if type(cfg) ~= 'table' then return out end
    local groups = cfg.groups or {}
    for gname, group in pairs(groups) do
        for rsname, rs in pairs(group.replicasets or {}) do
            for alias, inst in pairs(rs.instances or {}) do
                local uri
                if type(inst) == 'table' and type(inst.iproto) == 'table'
                    and type(inst.iproto.advertise) == 'table'
                    and type(inst.iproto.advertise.peer) == 'table' then
                    uri = inst.iproto.advertise.peer.uri
                end
                table.insert(out, {
                    alias        = alias,
                    group        = gname,
                    replicaset   = rsname,
                    declared_uri = uri,
                })
            end
        end
    end
    table.sort(out, function(a, b) return a.alias < b.alias end)
    return out
end

-- Cross-reference declared instances against the live peer pool.
-- `observed_uri` comes from cluster.state's box.info.replication
-- ids — the address the applier actually connects to. When the
-- two differ we have a fix candidate.
function M.cross_check(declared, observed_by_alias)
    observed_by_alias = observed_by_alias or {}
    local out = {}
    for _, decl in ipairs(declared) do
        local obs = observed_by_alias[decl.alias] or {}
        local entry = {
            alias        = decl.alias,
            group        = decl.group,
            replicaset   = decl.replicaset,
            declared_uri = decl.declared_uri,
            observed_uri = obs.uri,
            reachable    = obs.reachable == true,
            suggestion   = nil,
        }
        -- We only suggest a fix when the observed URI is
        -- different from the declared one AND the observed one
        -- is reachable. Suggesting an unreachable URI would
        -- replace one dead pointer with another.
        if obs.reachable and obs.uri ~= nil
            and obs.uri ~= decl.declared_uri then
            entry.suggestion = obs.uri
        end
        table.insert(out, entry)
    end
    return out
end

-- Walk the live cluster snapshot and project the per-alias
-- observed URI + reachability. cluster/state servers track the
-- pool member's `uri` after the first successful poll.
local function observed_from_state()
    local ok, state = pcall(require, 'webui.cluster.state')
    if not ok then return {} end
    local snap = state.snapshot()
    local out = {}
    for alias, srv in pairs(snap.servers or {}) do
        out[alias] = {
            uri       = srv.uri,
            reachable = srv.reachable == true,
        }
    end
    return out
end

-- Pull the current cluster YAML through the config module —
-- production calls already use the file-mirror fallback so we
-- always get the same bytes the runtime is configured from.
local function fetch_current_yaml()
    local ok, cfg = pcall(require, 'webui.config_store.config')
    if not ok then return nil, 'config module unavailable' end
    -- Prefer the in-band read; fall back to local mirror on
    -- fresh-cluster boot when etcd has no key yet.
    if type(cfg.query_current_raw) == 'function' then
        local raw, err = cfg.query_current_raw()
        if raw ~= nil then return raw end
        if type(cfg._read_local_yaml) == 'function' then
            local mirror, mirror_err = cfg._read_local_yaml()
            if mirror ~= nil then return mirror end
            return nil, err or mirror_err
        end
        return nil, err
    end
    return nil, 'no current YAML reader available'
end

-- diagnose() → { current_yaml, peers: [...], has_fixes }
function M.diagnose()
    local raw, err = fetch_current_yaml()
    if raw == nil then
        return { error = tostring(err or 'no current YAML') }
    end
    local ok_yaml, parsed = pcall(yaml.decode, raw)
    if not ok_yaml or type(parsed) ~= 'table' then
        return { error = 'cluster YAML invalid: ' .. tostring(parsed) }
    end
    local declared = M.walk_declared(parsed)
    local observed = observed_from_state()
    local peers = M.cross_check(declared, observed)
    local has_fixes = false
    for _, p in ipairs(peers) do
        if p.suggestion ~= nil then has_fixes = true; break end
    end
    return {
        current_yaml = raw,
        peers        = peers,
        has_fixes    = has_fixes,
    }
end

-- apply(fixes) → { ok, action, results }
-- `fixes` is { [alias] = new_uri }.
function M.apply(payload, root)
    payload = payload or {}
    local fixes = payload.fixes or {}
    if type(fixes) ~= 'table' or next(fixes) == nil then
        return { ok = false, action = 'topology_fix', results = {},
            error = 'fixes is required (map alias → uri)' }
    end

    local raw, err = fetch_current_yaml()
    if raw == nil then
        return { ok = false, action = 'topology_fix', results = {},
            error = tostring(err or 'no current YAML') }
    end
    local parsed = yaml.decode(raw)
    if type(parsed) ~= 'table' then
        return { ok = false, action = 'topology_fix', results = {},
            error = 'YAML decode failed' }
    end

    -- Mutate in place. The cluster YAML is dict-of-dicts so the
    -- update is a straight key reach-down per alias; we do NOT
    -- touch any other field. The audit chain captures the
    -- before/after through the twophase commit downstream.
    local changed = {}
    for _, group in pairs(parsed.groups or {}) do
        for _, rs in pairs(group.replicasets or {}) do
            for alias, inst in pairs(rs.instances or {}) do
                local new_uri = fixes[alias]
                if new_uri ~= nil and type(inst) == 'table' then
                    inst.iproto = inst.iproto or {}
                    inst.iproto.advertise = inst.iproto.advertise or {}
                    inst.iproto.advertise.peer = inst.iproto.advertise.peer or {}
                    local old_uri = inst.iproto.advertise.peer.uri
                    inst.iproto.advertise.peer.uri = new_uri
                    table.insert(changed,
                        { alias = alias, from = old_uri, to = new_uri })
                end
            end
        end
    end

    local new_yaml = yaml.encode(parsed)

    -- Route through the existing twophase commit. The config
    -- module owns validation + etcd write + audit row + reload
    -- fanout; we just hand it the patched YAML.
    local ok_cfg, config_resolver = pcall(require,
        'webui.graphql.resolvers.config')
    if not ok_cfg or type(config_resolver.commit_config) ~= 'function' then
        return { ok = false, action = 'topology_fix', results = {},
            error = 'config resolver unavailable' }
    end

    local commit_ok, commit_res = pcall(config_resolver.commit_config,
        root or {}, {
            yaml          = new_yaml,
            confirm_text  = payload.confirm_text or 'topology_fix',
            reason        = 'recovery.topology_fix: '
                .. tostring(#changed) .. ' URI fix(es)',
        })
    if not commit_ok then
        return {
            ok = false, action = 'topology_fix', results = changed,
            error = tostring(commit_res),
        }
    end
    logger.info('topology_fix applied', { count = #changed })
    return {
        ok = true, action = 'topology_fix',
        results = changed,
        commit  = commit_res,
    }
end

return M
