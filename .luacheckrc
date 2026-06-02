-- luacheck configuration for the Tarantool 3.7 WebUI backend.
--
-- Rationale:
--   * Tarantool exposes a generous set of globals (box, fiber, ...) —
--     declare them so luacheck does not flag every usage.
--   * The cluster API surface uses `_TARANTOOL`, `_G.box.NULL` and a
--     few other private idioms; whitelist explicitly.
--   * Max line length aligns with the rules/base.md style note (120).

std = 'luajit'

read_globals = {
    -- Built-in Tarantool runtime exposed to every script.
    'box',
    'tonumber64',
    '_TARANTOOL',

    -- Standard library extensions Tarantool ships with.
    table = { fields = { 'copy', 'deepcopy', 'clear', 'unpack' } },
    string = { fields = {
        'startswith', 'endswith', 'split', 'strip',
        'lstrip', 'rstrip', 'hex', 'fromhex'
    } },
    math = { fields = { 'huge' } },
}

globals = {
    -- Modules sometimes export themselves through _G for tests.
}

ignore = {
    -- 211: unused local
    --   intentional in graceful cleanup paths
    '211/_.*',
    -- 212: unused argument
    --   common in resolver/handler signatures (req, args, info) and
    --   instance methods (`function M:foo(...)` may not need self
    --   today but stays an instance method for symmetry / future use).
    '212/_.*',
    '212/self',
    -- 213: unused loop variable
    '213/_.*',
    -- 214: used variable assigned with `_` placeholder
    '214/_.*',
}

max_line_length = 120
max_code_line_length = 120
-- Long string lines are acceptable for embedded HTML/SQL/JSON literals
-- such as the inline GraphiQL explorer page in graphql/server.lua.
max_string_line_length = 300
max_comment_line_length = 200
max_cyclomatic_complexity = 30

-- Exclude generated assets bundle (3+ MB of base64 strings).
exclude_files = {
    'backend/webui/assets/bundle.lua',
    '.rocks/',
    'cartridge-*/',
    'tarantool-*/',
    'tarantool-docs/',
}

files['backend/test/'] = {
    -- luatest test fixtures use `t = require('luatest')` and
    -- `g = luatest.group()` patterns that are not real globals
    -- but assigned upvalues — leave default config alone.
    std = '+busted',
}

files['tools/'] = {
    -- CLI scripts may use io.* and os.exit aggressively;
    -- ignore "non-standard global" warnings there. Per-file CLI
    -- scripts are inherently sequential and exceed the cyclomatic
    -- ceiling defined for library code.
    std = '+luajit',
    max_cyclomatic_complexity = 60,
}

-- lifecycle/start.lua orchestrates the role bootstrap end-to-end
-- (config read, session/audit init, HTTP routes, fiber pool spin-up,
-- graceful shutdown hook). lifecycle/validate.lua type-checks every
-- roles_cfg.webui field. Both grow linearly with the role's surface
-- area; splitting them further would scatter the boot order /
-- validation rules across helpers and obscure the single linear flow.
files['backend/webui/lifecycle/start.lua'] = {
    max_cyclomatic_complexity = 50,
}
files['backend/webui/lifecycle/validate.lua'] = {
    max_cyclomatic_complexity = 45,
}

-- M.send walks the SMTP protocol state machine (HELO/STARTTLS/AUTH/
-- MAIL/RCPT/DATA/QUIT, each with its own error branches). It is
-- inherently sequential and reads top-to-bottom; refactoring would
-- replace one readable function with several less readable ones.
files['backend/webui/notifications/smtp.lua'] = {
    max_cyclomatic_complexity = 40,
}

-- M.apply is a per-suggestion-type dispatcher. The branch count grows
-- 1:1 with the suggestion catalog (force_apply, restart_replication,
-- bootstrap_vshard, edit_topology, …); a registry/table-of-handlers
-- pattern would only hide the per-type contract that lives in the
-- adjacent branches.
files['backend/webui/cluster/suggestions.lua'] = {
    max_cyclomatic_complexity = 75,
}

-- apply_server_edit / apply_replicaset_edit walk every editable YAML
-- field of a server / replicaset and validate + mutate it inline.
-- The complexity follows the schema surface area, not control-flow
-- design — splitting per-field helpers would scatter validation
-- rules and obscure the single-source-of-truth ordering.
files['backend/webui/cluster_ops/topology_edit.lua'] = {
    max_cyclomatic_complexity = 65,
}

-- M.coerce_field converts user input to every supported Tarantool
-- type (unsigned/integer/number/string/boolean/uuid/decimal/array/map
-- /any). One linear branch per type is easier to audit than a
-- per-type helper registry.
files['backend/webui/data_explorer/types.lua'] = {
    max_cyclomatic_complexity = 40,
}

-- mutation_set_failover_mode validates + applies every failover-mode
-- parameter (mode, leader, synchro_quorum, timeouts, supervised
-- coordinator) against the current cluster shape. mutation_set_
-- instance_state mirrors that for per-instance state (mode/labels/
-- election_mode/zone). Both are gated through 2PC; pulling
-- helpers out would force callers to duplicate the validation
-- ordering the schema relies on.
files['backend/webui/graphql/resolvers/cluster_ops.lua'] = {
    max_cyclomatic_complexity = 115,
}

-- M.resolve dispatches on action ∈ {manual, rebootstrap_losing,
-- force_promote_winner}. Each branch needs its own validation
-- and audit envelope; the dispatcher keeps the wire contract in
-- one place.
files['backend/webui/recovery/split_brain.lua'] = {
    max_cyclomatic_complexity = 35,
}

-- M.commit orchestrates the linear etcd-put → file-mirror fan-out →
-- optional reload fan-out → history snapshot → notification chain.
-- Each phase has its own pcall guard with structured logging; pulling
-- a phase into a helper would only hide the ordering that this
-- function is built around (etcd authoritative, file cache, peer
-- reload, then bookkeeping).
files['backend/webui/config_store/twophase.lua'] = {
    max_cyclomatic_complexity = 45,
}
