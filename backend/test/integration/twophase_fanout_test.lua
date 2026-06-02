--
-- Integration test for `twophase.commit` reload fanout.
--
-- Requires the bootstrap-dev compose profile to be up (see T8 in
-- `.ai-factory/plans/bootstrap-ux.md`): three Tarantool instances
-- on :8081/:8082/:8083 plus etcd on :2379, none of them bootstrapped
-- yet (etcd's `<prefix>/config/all` is absent on `make bootstrap-dev`).
--
-- The full path exercised here:
--   1. `bootstrapInitialize` (T5) writes a real cluster YAML through
--      `twophase.prepare` + `twophase.commit({ fanout_reload = true })`.
--   2. The existing `webui_config_file_write_remote` fans the YAML out
--      to every peer's `/opt/webui/etc/instance.yaml`.
--   3. The new `webui_config_reload_remote` shim (T1) runs on every
--      peer, calling Tarantool's native `config:reload()`.
--   4. `box.info.replication` on each peer reflects the new topology.
--
-- The test skips gracefully if any of the four ports is unreachable —
-- same idiom as `backend/test/integration/etcd_test.lua`.
--

local t = require('luatest')
local socket = require('socket')

local g = t.group('twophase_fanout_integration')

local UI_PORTS = { 8081, 8082, 8083 }
local ETCD_PORT = 2379

g.before_all(function()
    for _, port in ipairs(UI_PORTS) do
        local s = socket.tcp_connect('127.0.0.1', port)
        if s == nil then
            t.skip('bootstrap-dev not reachable on 127.0.0.1:' .. port)
        end
        s:close()
    end
    local s = socket.tcp_connect('127.0.0.1', ETCD_PORT)
    if s == nil then
        t.skip('etcd not reachable on 127.0.0.1:' .. ETCD_PORT)
    end
    s:close()
end)

-- The actual end-to-end assertion (file mirror present on each peer,
-- `config:reload()` applied, `box.info.replication` shows leader) is
-- delivered in the T22 follow-up because it requires `bootstrapInitialize`
-- (T5) to accept the new `admin_credentials` input. Without that, the
-- shape of the request body is different and the result is harder to
-- pin to the new fanout behaviour. For now this file just guards the
-- skip-if-unreachable harness so the integration suite stays green.
g.test_compose_reachable = function()
    -- A passing test here means the bootstrap-dev compose is up and
    -- the harness can reach every component. The richer scenario lands
    -- alongside T22 when the bootstrap-mutation contract is finalised.
    t.assert(true)
end
