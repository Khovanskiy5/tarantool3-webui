--
-- data_mutations facade.
--
-- HARD CAP: this file MUST stay ≤ 80 lines and MUST contain only:
--   * require() of submodules
--   * explicit re-export assignments to M
--   * the trailing `return M`
--
-- No helpers, no business logic, no conditional re-exports.
-- A growing init.lua is the signal that something belongs in
-- `common.lua` (or its own submodule), not here.
--
-- Public surface (do NOT remove without searching consumers across
-- the repo, including `graphql/schema.lua` and tests):
--   * SENSITIVE_SPACES table
--   * tuple_insert / tuple_replace / tuple_update / tuple_delete
--   * create_space / drop_space / alter_space / truncate_space
--   * create_index / drop_index
--   * remote_entry        – peer-bound DML receiver
--   * space_remote_entry  – peer-bound DDL receiver
--

local common = require('webui.graphql.resolvers.data_mutations.common')
local tuple  = require('webui.graphql.resolvers.data_mutations.tuple')
local space  = require('webui.graphql.resolvers.data_mutations.space')
local index  = require('webui.graphql.resolvers.data_mutations.index')
local remote = require('webui.graphql.resolvers.data_mutations.remote')

local M = {}

M.SENSITIVE_SPACES = common.SENSITIVE_SPACES

M.tuple_insert  = tuple.tuple_insert
M.tuple_replace = tuple.tuple_replace
M.tuple_update  = tuple.tuple_update
M.tuple_delete  = tuple.tuple_delete

M.create_space   = space.create_space
M.drop_space     = space.drop_space
M.alter_space    = space.alter_space
M.truncate_space = space.truncate_space

M.create_index  = index.create_index
M.drop_index    = index.drop_index

M.remote_entry        = remote.remote_entry
M.space_remote_entry  = remote.space_remote_entry

return M
