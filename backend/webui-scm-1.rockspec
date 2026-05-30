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
        ['webui.http.ws_frame']      = 'backend/webui/http/ws_frame.lua',
        ['webui.http.ws_registry']   = 'backend/webui/http/ws_registry.lua',
        ['webui.http.ws']            = 'backend/webui/http/ws.lua',
        ['webui.api.health']         = 'backend/webui/api/health.lua',
        ['webui.graphql.server']     = 'backend/webui/graphql/server.lua',
        ['webui.graphql.schema']     = 'backend/webui/graphql/schema.lua',
        ['webui.graphql.error_envelope'] = 'backend/webui/graphql/error_envelope.lua',
        ['webui.graphql.types.health']      = 'backend/webui/graphql/types/health.lua',
        ['webui.graphql.types.label']       = 'backend/webui/graphql/types/label.lua',
        ['webui.graphql.types.server']      = 'backend/webui/graphql/types/server.lua',
        ['webui.graphql.types.replicaset']  = 'backend/webui/graphql/types/replicaset.lua',
        ['webui.graphql.types.issue']       = 'backend/webui/graphql/types/issue.lua',
        ['webui.graphql.types.suggestion']  = 'backend/webui/graphql/types/suggestion.lua',
        ['webui.graphql.resolvers.cluster'] = 'backend/webui/graphql/resolvers/cluster.lua',
        ['webui.graphql.resolvers.issues']  = 'backend/webui/graphql/resolvers/issues.lua',
        ['webui.graphql.resolvers.suggestions'] = 'backend/webui/graphql/resolvers/suggestions.lua',
        ['webui.cluster.issues']            = 'backend/webui/cluster/issues.lua',
        ['webui.cluster.suggestions']       = 'backend/webui/cluster/suggestions.lua',
        ['webui.config_source.etcd_source'] = 'backend/webui/config_source/etcd_source.lua',
        ['webui.cluster.peer_cookie']    = 'backend/webui/cluster/peer_cookie.lua',
        ['webui.config_store.etcd']      = 'backend/webui/config_store/etcd.lua',
        ['webui.config_store.schema']    = 'backend/webui/config_store/schema.lua',
        ['webui.config_store.diff']      = 'backend/webui/config_store/diff.lua',
        ['webui.config_store.twophase']  = 'backend/webui/config_store/twophase.lua',
        ['webui.config_store.history']   = 'backend/webui/config_store/history.lua',
        ['webui.storage.spaces']         = 'backend/webui/storage/spaces.lua',
        ['webui.storage.migrations']     = 'backend/webui/storage/migrations.lua',
        ['webui.auth.session']           = 'backend/webui/auth/session.lua',
        ['webui.auth.rate_limit']        = 'backend/webui/auth/rate_limit.lua',
        ['webui.auth.rbac']              = 'backend/webui/auth/rbac.lua',
        ['webui.api.auth']               = 'backend/webui/api/auth.lua',
        ['webui.api.config_io']          = 'backend/webui/api/config_io.lua',
        ['webui.api.metrics']            = 'backend/webui/api/metrics.lua',
        ['webui.api.snapshots']          = 'backend/webui/api/snapshots.lua',
        ['webui.api.eval']               = 'backend/webui/api/eval.lua',
        ['webui.api.diagnostics']        = 'backend/webui/api/diagnostics.lua',
        ['webui.graphql.resolvers.lifecycle'] = 'backend/webui/graphql/resolvers/lifecycle.lua',
        ['webui.graphql.resolvers.failover']  = 'backend/webui/graphql/resolvers/failover.lua',
        ['webui.graphql.resolvers.vshard']    = 'backend/webui/graphql/resolvers/vshard.lua',
        ['webui.audit.log']              = 'backend/webui/audit/log.lua',
        ['webui.audit.retention']        = 'backend/webui/audit/retention.lua',
        ['webui.graphql.types.audit']    = 'backend/webui/graphql/types/audit.lua',
        ['webui.graphql.resolvers.audit'] = 'backend/webui/graphql/resolvers/audit.lua',
        ['webui.graphql.types.config']    = 'backend/webui/graphql/types/config.lua',
        ['webui.graphql.resolvers.config'] = 'backend/webui/graphql/resolvers/config.lua',
        ['webui.cluster.peers']          = 'backend/webui/cluster/peers.lua',
        ['webui.cluster.rpc']            = 'backend/webui/cluster/rpc.lua',
        ['webui.cluster.state']          = 'backend/webui/cluster/state.lua',
        ['webui.cluster.poller']         = 'backend/webui/cluster/poller.lua',
        ['internal.config.extras']       = 'backend/internal/config/extras.lua',
    },
}
