-- See data_mutations/ for the actual implementation.
-- This shim exists so `require('webui.graphql.resolvers.data_mutations')`
-- keeps resolving (Lua's loader prefers `<name>.lua` over `<name>/init.lua`).
return require('webui.graphql.resolvers.data_mutations.init')
