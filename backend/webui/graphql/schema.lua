-- WebUI GraphQL schema composition.
--
-- The schema is rebuilt once per role start (graphql.server.init) and
-- held in module-level state. Resolvers are deliberately thin: they
-- read from already-prepared state (role status, config:jsonschema()),
-- never block on net.box or etcd. Heavier resolvers land in later
-- tasks (cluster, config, schema, etc.) and follow the same pattern:
-- read from cluster/state.lua, return immediately.
--
-- Naming follows the contract in plan/Iter 18:
--   * Object types and scalars   PascalCase
--   * Fields and arguments        camelCase
--   * Enum values                 UPPER_SNAKE_CASE
--   * Mutations                   verbObject (configCommit, expelInstance, …)
--
-- Resolver-level error policy: each resolver may return (nil, err)
-- where err is an errors-rock object. graphql.server.handler() catches
-- exec failures via pcall and maps them to the standard envelope.

local json = require('json')
local fiber = require('fiber')

local types = require('graphql.types')
local schema_mod = require('graphql.schema')

local version = require('webui.version')
local health_types = require('webui.graphql.types.health')

local M = {}

-- ── ISO 8601 helper ────────────────────────────────────────────────────
local function iso8601_now()
    local t64 = fiber.time64()
    local seconds = tonumber(t64 / 1000000ULL)
    local micros  = tonumber(t64 % 1000000ULL)
    return string.format('%s.%06dZ',
        os.date('!%Y-%m-%dT%H:%M:%S', seconds), micros)
end

-- ── Resolvers ──────────────────────────────────────────────────────────

local function resolve_role_status()
    -- Lazy require avoids a hard cycle: webui.init → graphql.server.init
    -- → graphql.schema (this file) → webui. The require returns the
    -- already-loaded module table, so cycle detection succeeds.
    local webui = require('webui')
    return webui.status()
end

local function resolve_config_jsonschema()
    -- Tarantool 3.x exposes the cluster config JSON Schema natively.
    -- The schema is the single source of truth for backend validation
    -- and Monaco autocomplete, so we serialise it as a JSON string for
    -- clients to parse with their preferred JSON library.
    local ok, cfg = pcall(require, 'config')
    if not ok or cfg == nil or cfg.jsonschema == nil then
        return nil
    end
    local jsok, js = pcall(cfg.jsonschema, cfg)
    if not jsok or js == nil then
        return nil
    end
    return json.encode(js)
end

-- ── Query root ────────────────────────────────────────────────────────

local Query = types.object {
    name = 'Query',
    description = 'Read-only entry point of the WebUI admin API.',
    fields = {
        ping = {
            kind = types.string.nonNull,
            description = 'Liveness check; returns "pong".',
            resolve = function() return 'pong' end,
        },
        serverTime = {
            kind = types.string.nonNull,
            description = 'ISO 8601 UTC current time on the responding instance, microsecond precision.',
            resolve = function() return iso8601_now() end,
        },
        webuiVersion = {
            kind = types.string.nonNull,
            description = 'WebUI rock SemVer.',
            resolve = function() return version.SEMVER end,
        },
        roleStatus = {
            kind = health_types.RoleStatus.nonNull,
            description = 'Lifecycle status of this instance\'s webui role.',
            resolve = resolve_role_status,
        },
        configJsonSchema = {
            kind = types.string,
            description = 'JSON-encoded JSON Schema of the Tarantool cluster ' ..
                'config, taken from `config:jsonschema()`. Null when the ' ..
                'config module is unavailable.',
            resolve = resolve_config_jsonschema,
        },
    },
}

-- Mutations land in subsequent tasks (auth, config commit, …). The
-- placeholder is required because the rock validates that schemas with
-- queries also expose a Mutation type when introspection is used.
local Mutation = types.object {
    name = 'Mutation',
    description = 'Write operations. Populated by subsequent tasks.',
    fields = {
        _noop = {
            kind = types.boolean.nonNull,
            description = 'Placeholder mutation; always returns true. Will be removed once concrete mutations land.',
            resolve = function() return true end,
        },
    },
}

function M.build()
    return schema_mod.create({
        query = Query,
        mutation = Mutation,
    })
end

return M
