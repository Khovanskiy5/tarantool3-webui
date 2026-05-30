--
-- Community-Edition `internal.config.extras` module.
--
-- Tarantool 3.x's config subsystem calls
-- `require('internal.config.extras')` at startup. On Enterprise this
-- module ships in the binary and registers the proprietary etcd /
-- config-storage sources. On Community Edition the module is absent
-- and any `config.etcd:` block in the YAML is rejected by the schema.
--
-- Installing this file at /usr/share/tarantool/internal/config/extras.lua
-- (see the rockspec) makes the same contract available on Community
-- Edition:
--
--   1. **Targeted** schema patch — every node in the instance schema
--      that carries `enterprise_edition = true` AND lives under
--      `config.etcd` / `config.storage` / iproto SSL has its `validate`
--      and `apply_default_if` replaced with no-op equivalents. This
--      relaxes the EE gate for the etcd source surface and the mTLS
--      knobs WITHOUT enabling other EE-only options whose defaults
--      would trip box.cfg on Community (`flightrec_*`, etc.) — those
--      nodes keep their EE checks and CE rejects them as before.
--   2. The `webui.config_source.etcd` source is registered before the
--      cluster_config is collected, so YAML payloads fetched from etcd
--      are merged into the effective configuration the same way an EE
--      build would do it.
--
-- Why a global `tarantool.package` override is NOT enough:
--   Setting `tarantool.package = 'Tarantool Enterprise'` unconditionally
--   passes EVERY EE check, including `flightrec_requests_size` and
--   friends whose defaults are applied to box.cfg even when the
--   user did not opt in. box.cfg then rejects those options because
--   the C subsystem is absent on Community. Targeted node patching
--   avoids that by only touching the subtree the user actually asked
--   for via this extras shim.
--
-- The module is loaded exactly once per process. The contract Tarantool
-- expects is documented at the top of
-- tarantool-3.7.0/src/box/lua/config/init.lua (`load_extras`).
--

local M = {}

local function noop_validate() end
local function always_true() return true end

-- ── 1. Targeted schema relaxation ────────────────────────────────────

-- Recursively walk a schema node, replacing the validate/apply_default_if
-- of every descendant marked `enterprise_edition = true` whose path
-- starts with one of the allowed prefixes.
--
-- `path` is the dotted breadcrumb from the schema root, used to decide
-- which EE nodes we are willing to relax. Anything outside the allow
-- list keeps its original validators and continues to reject on CE.
local function relax_ee_nodes(node, path, allow_prefixes)
    if type(node) ~= 'table' then return end

    if node.enterprise_edition == true then
        local allowed = false
        for _, prefix in ipairs(allow_prefixes) do
            if path == prefix or path:sub(1, #prefix + 1) == prefix .. '.' then
                allowed = true
                break
            end
        end
        if allowed then
            node.validate         = noop_validate
            node.apply_default_if = always_true
            -- Clear the marker so the schema reports as fully built
            -- once the patch lands.
            node.enterprise_edition = false
        end
    end

    -- Records have `.fields`; arrays/maps have `.items` / `.key` /
    -- `.value`. Recurse into every shape the schema framework uses.
    if type(node.fields) == 'table' then
        for fname, child in pairs(node.fields) do
            local child_path = path == '' and fname or (path .. '.' .. fname)
            relax_ee_nodes(child, child_path, allow_prefixes)
        end
    end
    if type(node.items) == 'table' then
        relax_ee_nodes(node.items, path .. '.*', allow_prefixes)
    end
    if type(node.key) == 'table' then
        relax_ee_nodes(node.key, path .. '.<key>', allow_prefixes)
    end
    if type(node.value) == 'table' then
        relax_ee_nodes(node.value, path .. '.<value>', allow_prefixes)
    end
end

-- Subtrees of the instance schema we are willing to relax. Everything
-- else keeps its EE-only gate and behaves as upstream CE expects.
local ALLOW_PREFIXES = {
    'config.etcd',     -- etcd config source (our source plugs in here)
    'config.storage',  -- centralized config storage (Task 30 backlog)
    -- The iproto SSL params live deep under iproto.listen.* and
    -- iproto.advertise.peer.*; including their parent paths is enough.
    'iproto.listen',
    'iproto.advertise.peer',
    'iproto.advertise.sharding',
    'iproto.advertise.client',
}

local function patch_instance_schema()
    local ok, ic = pcall(require, 'internal.config.instance_config')
    if not ok or type(ic) ~= 'table' or type(ic.schema) ~= 'table' then
        return
    end
    relax_ee_nodes(ic.schema, '', ALLOW_PREFIXES)
end

patch_instance_schema()

-- ── 2. Register the etcd source ──────────────────────────────────────
--
-- The source itself implements the standard register-source contract
-- (see backend/webui/config_source/etcd_source.lua). It is constructed
-- lazily inside `initialize(config)`: registering earlier would race
-- with the config-module's own bookkeeping.

local etcd_source_module = require('webui.config_source.etcd_source')

local function safe_log_info(msg, fields)
    -- Tarantool's `log` module may not be ready on some boot paths;
    -- pcall keeps the sequence linear in either case.
    local ok, log_mod = pcall(require, 'log')
    if ok then
        if type(fields) == 'table' then
            log_mod.info('[webui.config.extras] %s %s',
                msg, require('json').encode(fields))
        else
            log_mod.info('[webui.config.extras] %s', msg)
        end
    end
end

function M.initialize(config)
    local source = etcd_source_module.new({ name = 'etcd' })
    config:_register_source(source)
    safe_log_info('etcd source registered', {
        relaxed_prefixes = ALLOW_PREFIXES,
        note = 'community-edition extras active',
    })
end

function M.post_apply(_config)
    -- No-op for now. Future Task 30 expansion will hook here to:
    --   * arm an etcd watch fiber on the prefix
    --   * republish config.info on watch-event
    --   * surface etcd connectivity in /api/health
end

return M
