--
-- Lazy etcd client for the cluster-config commit path.
--
-- Both the bootstrap wizard and the config-editor commit mutation
-- need to obtain an etcd client built from the same cluster config
-- block (`config.etcd.*`). Centralising the lookup here keeps both
-- call sites honest about the failure mode: missing config block
-- vs unreachable endpoint vs auth failure all surface as
-- (nil, reason) and the caller decides whether to degrade to a
-- dry-run or hard-fail.
--
-- Returns (client, nil) when:
--   * `config.etcd.endpoints` is a non-empty list in cluster config
--   * the `webui.config_store.etcd` module loads
--   * `etcd.new(...)` succeeds (auth, dial)
--
-- Returns (nil, reason) otherwise; `reason` is short and operator-
-- facing, e.g. "config.etcd.endpoints not set".
--
-- The client is NOT cached: each call builds a fresh
-- `http_client`. The clients are cheap (single HTTP/1.1 keep-alive)
-- and the commit path is invoked rarely, so the simpler "build per
-- call" model avoids any TLS / token-refresh subtlety.
--

local M = {}

-- Look up the etcd endpoints block. Preference order:
--   1. `roles_cfg.webui.etcd_writer.*` — the WebUI-specific write
--      target; safe to set in file config because Tarantool itself
--      never reads it.
--   2. `config.etcd.*` — the Tarantool-level config source. If the
--      operator has already promoted the cluster to read its own
--      config from etcd, the same endpoints serve both reads and
--      WebUI writes.
local function read_etcd_block()
    local cfg_ok, cfg = pcall(require, 'config')
    if not cfg_ok then return nil, 'config module unavailable' end
    local role = (cfg:get('roles_cfg') or {}).webui or {}
    if type(role.etcd_writer) == 'table'
        and type(role.etcd_writer.endpoints) == 'table'
        and #role.etcd_writer.endpoints > 0 then
        return role.etcd_writer
    end
    local tt = (cfg:get('config') or {}).etcd
    if type(tt) == 'table'
        and type(tt.endpoints) == 'table'
        and #tt.endpoints > 0 then
        return tt
    end
    return nil, 'no etcd endpoints configured '
        .. '(roles_cfg.webui.etcd_writer.endpoints or config.etcd.endpoints)'
end

function M.get_client()
    local etcd_block, err = read_etcd_block()
    if etcd_block == nil then return nil, err end
    local etcd_ok, etcd = pcall(require, 'webui.config_store.etcd')
    if not etcd_ok then
        return nil, 'etcd module unavailable'
    end
    local client, new_err = etcd.new({
        endpoints = etcd_block.endpoints,
        prefix    = etcd_block.prefix or '/tarantool/webui',
        username  = etcd_block.username,
        password  = etcd_block.password,
        timeout   = 2,
    })
    if client == nil then
        return nil, (new_err and new_err.message) or tostring(new_err)
    end
    return client
end

return M
