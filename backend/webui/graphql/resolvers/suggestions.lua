--
-- Resolvers for the suggestions query and the applySuggestion
-- mutation family.
--

local suggestions = require('webui.cluster.suggestions')
local log_util = require('webui.log_util')
local logger = log_util.with_tag('graphql.suggestions')

local M = {}

function M.suggestions(_, _args)
    local current = suggestions.current()
    local total = 0
    for _, list in pairs(current) do total = total + #list end
    logger.debug('suggestions query', { total = total })
    return current
end

local function apply(type_, args)
    args = args or {}
    local result, err = suggestions.apply(type_, {
        instance_uuids = args.instanceUuids or args.uuids,
    })
    if result == nil then
        -- "Not implemented yet" is a semantic outcome, not a
        -- transport error. Surface it on the ApplyResult so the
        -- UI can render the action button as disabled with a
        -- tooltip without parsing GraphQL `errors[]`.
        return {
            ok      = false,
            message = err,
            unknown = {},
            results = {},
        }
    end
    return result
end

function M.apply_force_apply(_, args)
    return apply(suggestions.TYPES.FORCE_APPLY, args)
end

function M.apply_restart_replication(_, args)
    return apply(suggestions.TYPES.RESTART_REPLICATION, args)
end

-- The remaining mutations are stubs that delegate to
-- suggestions.apply, which itself returns "not implemented" for
-- types whose subsystems have not landed. Exposing the mutations
-- now keeps the GraphQL schema stable for the frontend.
function M.apply_refresh_vshard(_, args)
    return apply(suggestions.TYPES.REFRESH_VSHARD, args)
end

function M.apply_disable_server(_, args)
    return apply(suggestions.TYPES.DISABLE_SERVER, args)
end

function M.apply_refine_uri(_, args)
    return apply(suggestions.TYPES.REFINE_URI, args)
end

function M.apply_restart_failover(_, args)
    return apply(suggestions.TYPES.RESTART_FAILOVER, args)
end

function M.apply_bootstrap_vshard(_, args)
    return apply(suggestions.TYPES.BOOTSTRAP_VSHARD, args)
end

return M
