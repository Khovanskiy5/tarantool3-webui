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
    -- Subsequent tasks pin additional dependencies as their code lands:
    --   Task 3  (HTTP server):   'http >= 1.5'
    --   Task 7  (GraphQL):       'graphql'
    --   Task 10 (compose configs): 'lyaml'
    --   Task 19 (issues):        'errors'
    --   Task 30 (etcd):          'etcd-client'
    --   Task 42a (self-metrics): 'metrics'
    --   Task 47 (vshard runtime, optional): 'vshard >= 0.1.27'
}

build = {
    type = 'builtin',
    modules = {
        ['webui']          = 'backend/webui/init.lua',
        ['webui.version']  = 'backend/webui/version.lua',
        ['webui.log_util'] = 'backend/webui/log_util.lua',
    },
}
