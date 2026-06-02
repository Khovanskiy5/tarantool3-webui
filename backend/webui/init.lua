--
-- WebUI role facade.
--
-- HARD CAP: this file MUST stay ≤ 40 lines and MUST contain only:
--   * require() of submodules
--   * explicit re-export assignments to M
--   * the trailing `return M`
--
-- No helpers, no business logic, no conditional re-exports.
-- The lifecycle (validate / apply / start / stop / status) lives in
-- `webui.lifecycle.*`. A growing init.lua is the signal that
-- something leaked back into the wiring layer.
--
-- Public surface (do NOT remove without searching every consumer
-- across the repo, including the role registration in
-- docker/configs/cluster/50-roles.yaml and `graphql/schema.lua`):
--   * validate – declarative role interface, side-effect-free
--   * apply    – declarative role interface, idempotent
--   * start    – explicit boot, used by tests and standalone scripts
--   * stop     – declarative role interface + on_shutdown hook
--   * status   – read-only state snapshot
--

local validate = require('webui.lifecycle.validate')
local apply    = require('webui.lifecycle.apply')
local start    = require('webui.lifecycle.start')
local stop     = require('webui.lifecycle.stop')
local state    = require('webui.lifecycle.state')

local M = {}

M.validate = validate.validate
M.apply    = apply.apply
M.start    = start.start
M.stop     = stop.stop
M.status   = state.status

return M
