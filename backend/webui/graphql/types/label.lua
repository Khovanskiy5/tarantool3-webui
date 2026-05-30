-- GraphQL Label type — one key/value pair attached to a server.
--
-- Labels are arbitrary, user-defined strings; they ride through the
-- cluster config and reach the UI via the cluster.state snapshot.
-- The type intentionally has no resolvers — fields are projected
-- directly from `{ name, value }` tables produced by the resolver.

local types = require('graphql.types')

local M = {}

M.Label = types.object {
    name = 'Label',
    description = 'Arbitrary key/value tag attached to a cluster instance.',
    fields = {
        name = {
            kind = types.string.nonNull,
            description = 'Label key.',
        },
        value = {
            kind = types.string.nonNull,
            description = 'Label value.',
        },
    },
}

return M
