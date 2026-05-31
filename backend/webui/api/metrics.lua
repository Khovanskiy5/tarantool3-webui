--
-- Prometheus-style metrics endpoints.
--
-- /api/metrics       → proxies the application metrics produced by
--                      the `metrics` rock when present; otherwise a
--                      minimal payload from the role state.
-- /api/metrics/webui → self-metrics about the WebUI internals
--                      (HTTP requests, WS connections, audit-log size,
--                      poller tick latency).
--

local json   = require('json')
local fiber  = require('fiber')

local registry = require('webui.http.ws_registry')
local state    = require('webui.cluster.state')
local storage  = require('webui.storage.spaces')

local M = {}

-- Pure helper exposed for tests.
function M.format_prom(family, labels, value, help)
    local label_str = ''
    if labels and next(labels) ~= nil then
        local parts = {}
        for k, v in pairs(labels) do
            table.insert(parts, string.format('%s="%s"', k, tostring(v)))
        end
        label_str = '{' .. table.concat(parts, ',') .. '}'
    end
    local out = {}
    if help then table.insert(out, '# HELP ' .. family .. ' ' .. help) end
    table.insert(out, '# TYPE ' .. family .. ' gauge')
    table.insert(out, family .. label_str .. ' ' .. tostring(value))
    return table.concat(out, '\n')
end

function M.handler_app(_req)
    local ok, metrics = pcall(require, 'metrics')
    if ok and type(metrics.invoke_callbacks) == 'function' then
        pcall(function() metrics.invoke_callbacks() end)
    end
    -- The `metrics` rock ships a Prometheus exporter; if it's wired
    -- the caller should hit it directly. Here we return the minimal
    -- contract so that monitoring can probe a constant endpoint.
    local body = M.format_prom('webui_up', {}, 1, 'webui role health, 1=alive')
    return {
        status = 200, headers = {
            ['content-type'] = 'text/plain; version=0.0.4'
        }, body = body,
    }
end

local function audit_row_count()
    local space = storage.audit()
    if space == nil then return 0 end
    return space:count() or 0
end

local function webhook_queue_depth()
    local space = storage.webhook_queue()
    if space == nil then return 0 end
    return space:count() or 0
end

local function webhook_dead_letter_depth()
    local space = storage.webhook_dead_letter()
    if space == nil then return 0 end
    return space:count() or 0
end

-- Notification dispatcher counters (Task 53a). Per-webhook
-- delivered / failed / retried / dead-lettered. Labels keep the
-- webhook name on the metric so a single Prometheus query can
-- alert on per-receiver failure ratios.
local function format_webhook_counters()
    local notif_ok, notif = pcall(require, 'webui.notifications')
    if not notif_ok then return {} end
    local s = notif.stats()
    local lines = {}
    local function emit_family(family, help, map)
        table.insert(lines, '# HELP ' .. family .. ' ' .. help)
        table.insert(lines, '# TYPE ' .. family .. ' counter')
        for name, count in pairs(map or {}) do
            table.insert(lines,
                string.format('%s{name="%s"} %s',
                    family, name, tostring(count)))
        end
    end
    emit_family('webui_webhook_deliveries_total',
        'successful webhook deliveries', s.delivered)
    emit_family('webui_webhook_failures_total',
        'failed webhook delivery attempts', s.failed)
    emit_family('webui_webhook_retry_count_total',
        'webhook deliveries that needed at least one retry', s.retried)
    emit_family('webui_webhook_dead_letter_total',
        'events that exhausted their retry budget', s.dead_lettered)
    return lines
end

function M.handler_self(_req)
    local snap = state.snapshot() or {}
    local servers = snap.servers or {}
    local server_count = 0
    for _ in pairs(servers) do server_count = server_count + 1 end
    local parts = {
        M.format_prom('webui_ws_connections',       {}, registry.count(),
            'open WebSocket connections'),
        M.format_prom('webui_audit_rows',           {}, audit_row_count(),
            'rows currently in _webui_audit'),
        M.format_prom('webui_servers_seen',         {}, server_count,
            'peers known to cluster.state'),
        M.format_prom('webui_webhook_queue_depth',  {}, webhook_queue_depth(),
            'pending webhook deliveries'),
        M.format_prom('webui_webhook_dead_letter_depth', {}, webhook_dead_letter_depth(),
            'events parked in the dead-letter space'),
        M.format_prom('webui_self_time',            {}, math.floor(fiber.time()),
            'wall-clock seconds since epoch on the responding instance'),
    }
    for _, line in ipairs(format_webhook_counters()) do
        table.insert(parts, line)
    end
    local body = table.concat(parts, '\n') .. '\n'
    return {
        status = 200,
        headers = { ['content-type'] = 'text/plain; version=0.0.4' },
        body = body,
    }
end

function M.handler_health_json(_req)
    -- Convenience JSON variant used by tests that don't want to
    -- parse the Prom text format.
    local snap = state.snapshot() or {}
    local server_count = 0
    for _ in pairs(snap.servers or {}) do server_count = server_count + 1 end
    return {
        status = 200, headers = { ['content-type'] = 'application/json' },
        body = json.encode({
            ws_connections = registry.count(),
            audit_rows     = audit_row_count(),
            servers_seen   = server_count,
        }),
    }
end

return M
