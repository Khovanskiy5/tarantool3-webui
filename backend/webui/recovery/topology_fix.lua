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

-- Replace every verbatim occurrence of `old` with `new` in `s`,
-- treating both as plain strings (no Lua-pattern magic). Returns the
-- patched string and the replacement count. Used to rewrite a single
-- URI in the raw cluster YAML without parsing it, so comments,
-- ordering and formatting survive untouched.
local function literal_replace(s, old, new)
    local pat = old:gsub('%W', '%%%0')      -- escape every non-word char
    local rep = new:gsub('%%', '%%%%')      -- escape % in the replacement
    return s:gsub(pat, rep)
end

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
            needs_fix    = false,
        }
        -- Auto-suggest a fix when a REACHABLE peer answers on a
        -- different address than the config declares — the pool
        -- already worked around a stale/typo'd URI, so we know the
        -- right value and can offer one-click correction.
        if obs.reachable and obs.uri ~= nil
            and obs.uri ~= decl.declared_uri then
            entry.suggestion = obs.uri
            entry.needs_fix = true
        end
        -- Also flag an UNREACHABLE declared peer: a wrong host:port
        -- means nothing answers, so the pool can't tell us the right
        -- address (no auto-suggestion) — the operator edits the
        -- pre-filled declared URI. A genuinely-stopped instance also
        -- lands here; the panel labels it so the operator can tell a
        -- typo apart from a down process.
        if not entry.reachable and type(decl.declared_uri) == 'string'
            and decl.declared_uri ~= '' then
            entry.needs_fix = true
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

-- Pull the current cluster YAML straight from etcd (the source of
-- truth) the same way the config resolver does. Falls back to the
-- on-disk mirror the resolver maintains for the fresh-boot window
-- when etcd has no key yet.
local function fetch_current_yaml()
    local ok_client, etcd_client = pcall(require, 'webui.config_store.client')
    if ok_client and etcd_client ~= nil
        and type(etcd_client.get_client) == 'function' then
        local client = etcd_client.get_client()
        if client ~= nil then
            local kv = select(1, client:read_cluster_config())
            if kv ~= nil and kv.value ~= nil then
                return kv.value
            end
        end
    end
    -- Fresh-cluster boot: etcd has no key yet. The config resolver
    -- exports the same on-disk mirror reader it uses for diffs.
    local ok_cfg, resolver = pcall(require, 'webui.graphql.resolvers.config')
    if ok_cfg and type(resolver._read_local_yaml) == 'function' then
        local mirror = resolver._read_local_yaml()
        if mirror ~= nil then return mirror end
    end
    return nil, 'current cluster YAML unavailable'
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
        if p.needs_fix then has_fixes = true; break end
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

    -- Discover the currently-declared URI per alias from the parsed
    -- view — read-only. We then rewrite each URI with a literal string
    -- replacement on the RAW YAML instead of re-encoding the parsed
    -- tree, so comments, key ordering and formatting all survive (a
    -- re-encode would strip every operator comment from the config).
    local declared_by_alias = {}
    for _, d in ipairs(M.walk_declared(parsed)) do
        declared_by_alias[d.alias] = d.declared_uri
    end

    local new_yaml = raw
    local changed = {}
    local skipped = {}
    for alias, new_uri in pairs(fixes) do
        local old_uri = declared_by_alias[alias]
        if type(new_uri) ~= 'string' or new_uri == '' then
            table.insert(skipped,
                { alias = alias, reason = 'new URI is empty' })
        elseif old_uri == new_uri then
            -- already correct — nothing to do for this alias
            table.insert(skipped,
                { alias = alias, reason = 'declared URI already matches' })
        elseif type(old_uri) ~= 'string' or old_uri == '' then
            -- No declared URI to anchor the replacement on; a literal
            -- edit can't safely insert a nested key. Surface it.
            table.insert(skipped,
                { alias = alias, reason = 'no declared URI to replace' })
        else
            local patched, n = literal_replace(new_yaml, old_uri, new_uri)
            if n == 0 then
                table.insert(skipped, { alias = alias,
                    reason = 'declared URI not found in config text' })
            else
                new_yaml = patched
                table.insert(changed,
                    { alias = alias, from = old_uri, to = new_uri })
            end
        end
    end

    -- The recoveryAction GraphQL contract wants result rows shaped
    -- { peer, ok, msg }. Map our internal change / skip records onto it
    -- (a non-conforming row crashes serialization on non-null `peer`).
    local function skipped_rows()
        local rows = {}
        for _, s in ipairs(skipped) do
            rows[#rows + 1] = { peer = s.alias, ok = false, msg = s.reason }
        end
        return rows
    end
    local function applied_rows()
        local rows = {}
        for _, ch in ipairs(changed) do
            rows[#rows + 1] = { peer = ch.alias, ok = true,
                msg = tostring(ch.from) .. ' -> ' .. tostring(ch.to) }
        end
        for _, row in ipairs(skipped_rows()) do
            rows[#rows + 1] = row
        end
        return rows
    end

    if #changed == 0 then
        return { ok = false, action = 'topology_fix', results = skipped_rows(),
            error = 'no applicable URI fix — nothing changed' }
    end

    -- Route through the existing two-phase config pipeline. The
    -- config resolver owns validation + etcd write + audit row +
    -- reload fan-out; we drive its prepare → commit pair exactly
    -- like the config editor does, so the URI fix lands in the
    -- source of truth and every instance reloads. `root` carries the
    -- admin roles the recovery dispatcher already verified, so the
    -- proposeConfig / commitConfig role checks pass through.
    local ok_cfg, config_resolver = pcall(require,
        'webui.graphql.resolvers.config')
    if not ok_cfg
        or type(config_resolver.mutation_prepare) ~= 'function'
        or type(config_resolver.mutation_commit) ~= 'function' then
        return { ok = false, action = 'topology_fix', results = {},
            error = 'config resolver unavailable' }
    end

    -- prepare: diff the patched YAML against the live etcd config and
    -- validate it on every peer. Raises on NO_CHANGES / VALIDATION_FAILED.
    local prep_ok, prep = pcall(config_resolver.mutation_prepare,
        root or {}, { yaml = new_yaml })
    if not prep_ok then
        return { ok = false, action = 'topology_fix', results = applied_rows(),
            error = tostring(prep) }
    end

    -- The prepared bundle lives in a replicated sync space. When apply()
    -- runs on a read-only follower, prepare() forwarded the write to the
    -- leader; the back-to-back commit() below reads it back LOCALLY and
    -- can race ahead of replication, hitting PREPARED_NOT_FOUND. Wait for
    -- the row to replicate via the shared helper (no-op on the leader and
    -- when the row is already present). Observed lag is a few ms.
    local ok_tp, twophase = pcall(require, 'webui.config_store.twophase')
    if ok_tp and type(twophase.wait_prepared) == 'function' then
        twophase.wait_prepared(prep.prepared_id)
    end

    -- commit: write to etcd, append the audit row, fan out the reload.
    local commit_ok, commit_res = pcall(config_resolver.mutation_commit,
        root or {}, { prepared_id = prep.prepared_id })
    if not commit_ok then
        return { ok = false, action = 'topology_fix', results = applied_rows(),
            error = tostring(commit_res) }
    end
    logger.info('topology_fix applied', { count = #changed })
    return {
        ok = true, action = 'topology_fix',
        results = applied_rows(),
        commit  = commit_res,
    }
end

return M
