--
-- Cluster-config validation via the live `require('config'):jsonschema()`.
--
-- The runtime owns the canonical schema, so we delegate to it
-- rather than hand-maintain a copy. On top of the schema check
-- we run a few cross-validations (referenced replicaset exists,
-- leader is in its replicaset, peer URIs unique) that JSON
-- Schema cannot express.
--

local json = require('json')
local yaml = require('yaml')

local M = {}

-- Pure helper exposed for tests.
function M.collect_replicaset_uris(cfg)
    local seen = {}
    local groups = cfg and cfg.groups or {}
    for _, group in pairs(groups) do
        local rss = group and group.replicasets or {}
        for _, rs in pairs(rss) do
            local instances = rs and rs.instances or {}
            for inst_name, inst in pairs(instances) do
                local advertise = inst and inst.iproto and inst.iproto.advertise
                local uri = advertise and advertise.peer and advertise.peer.uri
                if uri then
                    seen[uri] = seen[uri] or {}
                    table.insert(seen[uri], inst_name)
                end
            end
        end
    end
    return seen
end

-- Effective `replication.X` for a scope, walking instance → replicaset
-- → group → global (the inner-most set wins), like Tarantool's config.
local function effective_repl(cfg, group, rs, inst, key)
    local function v(t) return t and t.replication and t.replication[key] end
    local x = v(inst); if x ~= nil then return x end
    x = v(rs);    if x ~= nil then return x end
    x = v(group); if x ~= nil then return x end
    return v(cfg)
end

-- Count the voting (non-anonymous) instances of a replicaset.
local function count_voters(cfg, group, rs)
    local n = 0
    for _, inst in pairs(rs.instances or {}) do
        if effective_repl(cfg, group, rs, inst, 'anon') ~= true then
            n = n + 1
        end
    end
    return n
end

-- Pure helper: returns a list of {path, message} for cross-cluster
-- constraints. Pure so it can be unit-tested without a live
-- `config` rock.
function M.cross_validate(cfg)
    if type(cfg) ~= 'table' then
        return { { path = '/', message = 'config root must be a table' } }
    end
    local issues = {}
    -- 1. peer URI uniqueness
    for uri, instances in pairs(M.collect_replicaset_uris(cfg)) do
        if #instances > 1 then
            table.insert(issues, {
                path = '/groups/*/replicasets/*/instances',
                message = string.format(
                    'peer URI %q used by multiple instances: %s',
                    uri, table.concat(instances, ', ')),
            })
        end
    end
    -- 2. failover mode + leader exclusivity
    local global_failover = cfg.replication and cfg.replication.failover
    local groups = cfg.groups or {}
    for gname, group in pairs(groups) do
        for rsname, rs in pairs(group.replicasets or {}) do
            if global_failover == 'election' and rs.leader ~= nil then
                table.insert(issues, {
                    path = string.format('/groups/%s/replicasets/%s/leader',
                                         gname, rsname),
                    message = 'leader: cannot be set when ' ..
                        'replication.failover = election',
                })
            end
            -- leader must be one of this replicaset's instances
            if rs.leader ~= nil then
                local instances = rs.instances or {}
                if instances[rs.leader] == nil then
                    table.insert(issues, {
                        path = string.format('/groups/%s/replicasets/%s/leader',
                                             gname, rsname),
                        message = string.format(
                            'leader %q is not an instance of the replicaset',
                            tostring(rs.leader)),
                    })
                end
            end
            -- 3. synchro_quorum below N/2+1 (FO-11). A numeric quorum
            -- under the majority of voting members permits split-brain
            -- on a leader change. The formula string ('N/2+1') is safe
            -- and auto-adjusts, so only flag explicit numbers.
            local voters = count_voters(cfg, group, rs)
            local q = effective_repl(cfg, group, rs, nil, 'synchro_quorum')
            if type(q) == 'number' and voters >= 2 then
                local need = math.floor(voters / 2) + 1
                if q < need then
                    table.insert(issues, {
                        path = string.format(
                            '/groups/%s/replicasets/%s synchro_quorum',
                            gname, rsname),
                        message = string.format(
                            'synchro_quorum=%d is below N/2+1=%d for %d voting '
                            .. 'members — permits split-brain; use the formula '
                            .. "'N/2+1' or a value >= %d",
                            q, need, voters, need),
                    })
                end
            end
        end
    end
    -- 4. EE synchro_mode while the WebUI agent is active (FO-11).
    -- failover.replicasets.<rs>.synchro_mode forces election_mode=manual,
    -- which fights our agent over the synchro queue.
    local agent_on = cfg.roles_cfg and cfg.roles_cfg.webui
        and cfg.roles_cfg.webui.failover
        and cfg.roles_cfg.webui.failover.agent == true
    local fo = cfg.failover
    if agent_on and type(fo) == 'table' and type(fo.replicasets) == 'table' then
        for rsn, r in pairs(fo.replicasets) do
            if type(r) == 'table' and r.synchro_mode then
                table.insert(issues, {
                    path = string.format('/failover/replicasets/%s/synchro_mode',
                                         tostring(rsn)),
                    message = 'synchro_mode forces election_mode=manual, which '
                        .. 'conflicts with the WebUI failover agent; remove it '
                        .. 'or disable the agent',
                })
            end
        end
    end
    return issues
end

-- Advisory (non-blocking) guardrails — surfaced to the operator but do
-- NOT reject the commit. Pure; returns a list of {path, message}.
function M.guardrail_warnings(cfg)
    local warnings = {}
    if type(cfg) ~= 'table' then return warnings end
    local repl = cfg.replication or {}
    if repl.bootstrap_strategy == 'legacy' then
        table.insert(warnings, {
            path = '/replication/bootstrap_strategy',
            message = 'bootstrap_strategy: legacy uses the old re-bootstrap '
                .. 'behaviour (split-brain footgun); prefer auto',
        })
    end
    local mvcc = cfg.database and cfg.database.use_mvcc_engine
    if mvcc ~= true then
        table.insert(warnings, {
            path = '/database/use_mvcc_engine',
            message = 'memtx MVCC is not enabled; required for correct '
                .. 'isolation of synchronous transactions',
        })
    end
    for gname, group in pairs(cfg.groups or {}) do
        for rsname, rs in pairs(group.replicasets or {}) do
            local voters = count_voters(cfg, group, rs)
            if voters >= 2 and voters % 2 == 0 then
                table.insert(warnings, {
                    path = string.format('/groups/%s/replicasets/%s',
                                         gname, rsname),
                    message = string.format(
                        'replicaset has %d voting members (even) — no extra '
                        .. 'fault tolerance over %d and risks split votes; '
                        .. 'prefer an odd count', voters, voters - 1),
                })
            end
        end
    end
    return warnings
end

-- Parse + JSON-schema validate + cross-validate.
-- Returns (parsed_table, nil) on success, (nil, errors[]) otherwise.
--
-- The JSON-Schema step uses Tarantool's own `cluster_config:validate()`
-- — the same validator the runtime invokes inside `cfg:reload()`
-- (`src/box/lua/config/init.lua:241`). Earlier this function only
-- "touched" `config:jsonschema()` without actually validating the
-- parsed payload, so values that the runtime rejects on reload
-- (e.g. `config.etcd.endpoints[1]` as a table instead of a string,
-- or `config.etcd.prefix: ""`) sailed through precommit, landed in
-- etcd + the on-disk mirror, and only blew up on the follow-up
-- `cfg:reload()` — leaving the cluster with an unloadable YAML and
-- a stuck synchro queue. Running the same validator in precommit
-- prevents that class of incident.
function M.validate(yaml_text)
    if type(yaml_text) ~= 'string' or yaml_text == '' then
        return nil, { { path = '/', message = 'empty config' } }
    end
    local ok, parsed = pcall(yaml.decode, yaml_text)
    if not ok or type(parsed) ~= 'table' then
        return nil, { { path = '/', message = 'invalid YAML: ' .. tostring(parsed) } }
    end
    -- JSON-Schema check via Tarantool's own validator. The module
    -- lives under `internal.config.*`, which is available whenever
    -- this code runs inside Tarantool 3.x (production, integration
    -- tests, luatest). When it is absent (pure-Lua sandboxes) we
    -- fall through to cross-validation as a safety net.
    local cc_ok, cluster_config = pcall(require, 'internal.config.cluster_config')
    if cc_ok and type(cluster_config) == 'table'
        and type(cluster_config.validate) == 'function' then
        local vok, verr = pcall(cluster_config.validate, cluster_config, parsed)
        if not vok then
            return nil, { { path = '/', message = tostring(verr) } }
        end
    end
    local cross_issues = M.cross_validate(parsed)
    if #cross_issues > 0 then
        return nil, cross_issues
    end
    return parsed
end

-- JSON-encode the schema for the GraphQL `configJsonSchema` field.
function M.jsonschema_text()
    local config_ok, config = pcall(require, 'config')
    if not config_ok then return nil end
    local ok, schema = pcall(function() return config:jsonschema() end)
    if not ok or schema == nil then return nil end
    local enc_ok, encoded = pcall(json.encode, schema)
    if not enc_ok then return nil end
    return encoded
end

return M
