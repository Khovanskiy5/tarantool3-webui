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
