--
-- Webhook surface (Task 53a) — read-only enumeration + synthetic
-- delivery probe. Editing is intentionally out-of-band (cluster
-- config): operators rotate secrets via the same two-phase commit
-- pipeline that controls every other roles_cfg.webui field.
--

local fiber = require('fiber')

local rbac     = require('webui.auth.rbac')
local storage  = require('webui.storage.spaces')
local notif    = require('webui.notifications')
local logger   = require('webui.log_util').with_tag('graphql.webhooks')

local M = {}

local function require_role(root, field)
    local required = rbac.GRAPHQL_FIELD[field] or 'admin'
    if not rbac.allowed((root and root.roles) or {}, required) then
        error('FORBIDDEN: ' .. field .. ' requires ' .. required)
    end
end

-- The configured webhook list lives in dispatcher state; expose a
-- snapshot here without leaking secrets. Stats (delivered / failed
-- / retried / dead-lettered) come from the dispatcher's in-memory
-- counters; depth fields read directly from the queue space.
local function describe(webhook, stats)
    local s = stats or {}
    return {
        name           = webhook.name,
        type           = webhook.type or 'generic',
        url            = webhook.url,
        events         = webhook.events or {},
        enabled        = webhook.enabled ~= false,
        has_secret     = type(webhook.secret) == 'string' and #webhook.secret > 0,
        delivered      = (s.delivered or {})[webhook.name] or 0,
        failed         = (s.failed or {})[webhook.name] or 0,
        retried        = (s.retried or {})[webhook.name] or 0,
        dead_lettered  = (s.dead_lettered or {})[webhook.name] or 0,
        last_error     = (s.last_error or {})[webhook.name],
        last_ok_at     = (s.last_ok_at or {})[webhook.name],
    }
end

local function read_webhook_config()
    local cfg_ok, cfg = pcall(require, 'config')
    if not cfg_ok then return {} end
    local role_cfg = cfg:get('roles_cfg.webui') or {}
    local list = role_cfg.webhooks
    if type(list) ~= 'table' then return {} end
    return list
end

function M.query_list(root)
    require_role(root, 'webhooks')
    local stats = notif.stats()
    local out = {}
    for _, w in ipairs(read_webhook_config()) do
        table.insert(out, describe(w, stats))
    end
    return { webhooks = out }
end

function M.query_queue_depth(root)
    require_role(root, 'webhooks')
    local q = storage.webhook_queue()
    local dlq = storage.webhook_dead_letter()
    return {
        queue       = q   and q:count()   or 0,
        dead_letter = dlq and dlq:count() or 0,
    }
end

function M.query_dead_letter(root, args)
    require_role(root, 'webhooks')
    local space = storage.webhook_dead_letter()
    if space == nil then return { entries = {} } end
    local limit = math.min(tonumber(args and args.limit) or 50, 200)
    local entries = {}
    local idx = space.index.primary
    local count = 0
    for _, tuple in idx:pairs({}, { iterator = 'REQ' }) do
        if count >= limit then break end
        table.insert(entries, {
            id         = tuple.id,
            failed_at  = tuple.failed_at,
            webhook    = tuple.webhook,
            event_type = tuple.event and tuple.event.type or nil,
            attempts   = tuple.attempts,
            last_error = tuple.last_error,
        })
        count = count + 1
    end
    return { entries = entries }
end

function M.mutation_test(root, args)
    require_role(root, 'testWebhook')
    local target_name = args.name
    if type(target_name) ~= 'string' or #target_name == 0 then
        error('INVALID_QUERY: name is required')
    end
    local webhook
    for _, w in ipairs(read_webhook_config()) do
        if w.name == target_name then webhook = w; break end
    end
    if webhook == nil then
        error('NOT_FOUND: webhook ' .. target_name .. ' is not configured')
    end
    local event = {
        type     = 'webhook.test',
        severity = 'info',
        scope    = 'manual',
        category = 'audit',
        user     = root and root.user,
        message  = 'synthetic event from /webhooks Test button',
        ts       = math.floor(fiber.time()),
    }
    local res = notif.deliver_now(webhook, event)
    logger.info('test webhook', {
        webhook = target_name,
        ok = res.ok, latency_ms = res.latency_ms, err = res.error,
    })
    return {
        ok         = res.ok,
        latency_ms = res.latency_ms,
        error      = res.error,
    }
end

function M.mutation_clear_dead_letter(root)
    require_role(root, 'clearDeadLetter')
    local space = storage.webhook_dead_letter()
    if space == nil then return { cleared = 0 } end
    local count = space:count() or 0
    pcall(function() space:truncate() end)
    logger.info('dead letter cleared', { rows = count })
    return { cleared = count }
end

return M
