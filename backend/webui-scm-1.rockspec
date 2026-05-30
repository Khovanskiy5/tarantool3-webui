package = 'webui'
version = 'scm-1'

source = {
    url = 'git+https://example.com/tarantool-webui.git',
    branch = 'main',
}

description = {
    summary  = 'Tarantool 3.7 cluster administration UI (Cartridge UI equivalent)',
    detailed = [[
        Backend Lua role embedded into every Tarantool 3.7 instance.
        Serves the embedded Vue 3 SPA, exposes a GraphQL admin API at
        /admin/api, REST endpoints for auth and operational commands,
        and a WebSocket endpoint for live cluster state. Talks to peer
        instances over net.box and to etcd for cluster-wide config.
    ]],
    license  = 'BSD-2-Clause',
    homepage = 'https://example.com/tarantool-webui',
    maintainer = 'Tarantool WebUI contributors',
}

dependencies = {
    'lua >= 5.1',
    'checks',
    'errors',
    'http >= 1.6',
    'graphql',
    -- Subsequent tasks pin additional dependencies as their code lands:
    --   Task 10 (compose configs): 'lyaml'
    --   Task 30 (etcd):          'etcd-client'
    --   Task 42a (self-metrics): 'metrics'
    --   Task 47 (vshard runtime, optional): 'vshard >= 0.1.27'
}

build = {
    type = 'builtin',
    modules = {
        ['webui']                    = 'backend/webui/init.lua',
        ['webui.version']            = 'backend/webui/version.lua',
        ['webui.log_util']           = 'backend/webui/log_util.lua',
        ['webui.errors']             = 'backend/webui/errors.lua',
        ['webui.http.server']        = 'backend/webui/http/server.lua',
        ['webui.http.middleware']    = 'backend/webui/http/middleware.lua',
        ['webui.http.error_envelope']= 'backend/webui/http/error_envelope.lua',
        ['webui.http.static']        = 'backend/webui/http/static.lua',
        ['webui.api.health']         = 'backend/webui/api/health.lua',
        ['webui.graphql.server']     = 'backend/webui/graphql/server.lua',
        ['webui.graphql.schema']     = 'backend/webui/graphql/schema.lua',
        ['webui.graphql.error_envelope'] = 'backend/webui/graphql/error_envelope.lua',
        ['webui.graphql.types.health']   = 'backend/webui/graphql/types/health.lua',
        ['webui.config_source.etcd_source'] = 'backend/webui/config_source/etcd_source.lua',
        ['webui.cluster.peer_cookie']    = 'backend/webui/cluster/peer_cookie.lua',
        ['webui.cluster.peers']          = 'backend/webui/cluster/peers.lua',
        ['webui.cluster.rpc']            = 'backend/webui/cluster/rpc.lua',
        ['webui.cluster.state']          = 'backend/webui/cluster/state.lua',
        ['webui.cluster.poller']         = 'backend/webui/cluster/poller.lua',
        ['internal.config.extras']       = 'backend/internal/config/extras.lua',
    },
}
