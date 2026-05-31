--
-- Public surface for the outbound notifications subsystem (Task 53a).
--
-- The role's start path calls `configure(opts)` with the webhook
-- list from cluster config + `start()` to spawn the dispatcher
-- fiber. Application code emits events through `emit(evt)`; the
-- fanout step is synchronous (matches against the in-memory
-- webhook list + inserts into `_webui_webhook_queue`), the actual
-- HTTP/SMTP I/O is owned by the dispatcher fiber.
--

local fiber = require('fiber')

local dispatcher = require('webui.notifications.dispatcher')
local logger     = require('webui.log_util').with_tag('notifications')

local M = {}

local STATE = {
    configured = false,
}

-- ── config validation ──────────────────────────────────────────────

local SUPPORTED_TYPES = { generic = true, slack = true, discord = true, email = true }

local function validate_webhook(entry, idx)
    if type(entry) ~= 'table' then
        return ('roles_cfg.webui.webhooks[%d] must be a table'):format(idx)
    end
    if type(entry.name) ~= 'string' or #entry.name == 0 then
        return ('roles_cfg.webui.webhooks[%d].name is required'):format(idx)
    end
    if type(entry.type) ~= 'string' or not SUPPORTED_TYPES[entry.type] then
        return ('roles_cfg.webui.webhooks[%d].type must be one of generic/slack/discord/email')
            :format(idx)
    end
    if type(entry.events) ~= 'table' or #entry.events == 0 then
        return ('roles_cfg.webui.webhooks[%d].events is required'):format(idx)
    end
    if entry.type == 'email' then
        if type(entry.smtp_host) ~= 'string' or #entry.smtp_host == 0 then
            return ('roles_cfg.webui.webhooks[%d]: email requires smtp_host'):format(idx)
        end
        if type(entry.from) ~= 'string' or #entry.from == 0 then
            return ('roles_cfg.webui.webhooks[%d]: email requires from'):format(idx)
        end
        if type(entry.to) ~= 'table' or #entry.to == 0 then
            return ('roles_cfg.webui.webhooks[%d]: email requires non-empty to'):format(idx)
        end
    else
        if type(entry.url) ~= 'string' or #entry.url == 0 then
            return ('roles_cfg.webui.webhooks[%d]: %s requires url'):format(idx, entry.type)
        end
        if not entry.url:match('^https?://') then
            return ('roles_cfg.webui.webhooks[%d]: url must be http(s)://'):format(idx)
        end
    end
    return nil
end

function M.validate(cfg)
    if cfg == nil or cfg.webhooks == nil then return true end
    if type(cfg.webhooks) ~= 'table' then
        return nil, 'roles_cfg.webui.webhooks must be a list'
    end
    for i, entry in ipairs(cfg.webhooks) do
        local err = validate_webhook(entry, i)
        if err ~= nil then return nil, err end
    end
    return true
end

-- ── public API ─────────────────────────────────────────────────────

function M.configure(opts)
    opts = opts or {}
    local webhooks = opts.webhooks or {}
    -- Defensive copy so cluster config reloads don't tear out the
    -- table the dispatcher is iterating over.
    local copy = {}
    for _, w in ipairs(webhooks) do table.insert(copy, w) end
    dispatcher.configure({ webhooks = copy })
    STATE.configured = true
end

function M.start()
    if not STATE.configured then
        logger.debug('notifications not configured; dispatcher not started')
        return
    end
    dispatcher.start()
    logger.info('notifications dispatcher started')
end

function M.stop()
    dispatcher.stop()
end

function M.is_running() return dispatcher.is_running() end
function M.stats()      return dispatcher.stats()      end
function M.fanout(event) return dispatcher.fanout(event) end
function M.deliver_now(webhook, event)
    return dispatcher.deliver_now(webhook, event)
end

-- ── high-level emit ────────────────────────────────────────────────

-- One-stop call used by application code. Stamps ts/instance and
-- delegates to fanout(). Safe to call from anywhere: a missing
-- dispatcher (e.g. during early init) silently drops the event so
-- the caller does not need to feature-check.
function M.emit(evt)
    if type(evt) ~= 'table' then return end
    evt.ts = evt.ts or math.floor(fiber.time())
    if evt.instance == nil and rawget(_G, 'box') ~= nil then
        local ok, info = pcall(function() return box.info end)
        if ok and type(info) == 'table' then
            evt.instance = info.name
        end
    end
    pcall(M.fanout, evt)
end

return M
