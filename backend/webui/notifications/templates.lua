--
-- Webhook payload templates (Task 53a).
--
-- Two transports supported in this MVP:
--
--   * generic — the event itself, JSON-encoded. The receiver
--     consumes a stable shape regardless of webhook type, useful
--     for in-house integrations and Prometheus alertmanager
--     receivers.
--   * slack   — Slack-incoming-webhook payload with a color-coded
--     attachment. The same template doubles as a Discord webhook
--     because Discord's webhook endpoint accepts Slack-style
--     payloads.
--
-- Adding a new type (email, pagerduty, …) means dropping in another
-- builder function and registering it in BUILDERS. The dispatcher
-- consults `for_type(name)` and falls back to `generic` when the
-- type is unknown so a typo in cluster config does not silently
-- drop deliveries.
--

local M = {}

local SEVERITY_COLORS = {
    critical = 'danger',
    error    = 'danger',
    warning  = 'warning',
    info     = '#4ea8de',
    debug    = '#888888',
}

local function build_generic(event)
    return event
end

local function build_slack(event)
    local color = SEVERITY_COLORS[event.severity or 'info'] or '#4ea8de'
    local text = string.format('[%s] %s',
        (event.severity or 'info'):upper(),
        event.message or event.type or 'webui event')
    local fields = {}
    if event.scope and event.scope ~= '' then
        table.insert(fields, {
            title = 'Scope', value = event.scope, short = true,
        })
    end
    if event.category and event.category ~= '' then
        table.insert(fields, {
            title = 'Category', value = event.category, short = true,
        })
    end
    if event.instance and event.instance ~= '' then
        table.insert(fields, {
            title = 'Instance', value = event.instance, short = true,
        })
    end
    if event.user and event.user ~= '' then
        table.insert(fields, {
            title = 'User', value = event.user, short = true,
        })
    end
    return {
        text = text,
        attachments = {{
            color  = color,
            fields = fields,
            footer = 'tarantool webui',
            ts     = event.ts,
        }},
    }
end

-- Email payloads carry (subject, body) instead of a raw JSON
-- structure — the SMTP client formats them into RFC 5322 message
-- envelopes downstream.
local function build_email(event)
    local subject = string.format('[%s] %s',
        (event.severity or 'info'):upper(),
        event.message or event.type or 'webui event')
    local lines = {
        'Tarantool WebUI notification',
        '',
        'Type:     ' .. tostring(event.type or '?'),
        'Severity: ' .. tostring(event.severity or 'info'),
    }
    if event.scope and event.scope ~= '' then
        table.insert(lines, 'Scope:    ' .. tostring(event.scope))
    end
    if event.instance and event.instance ~= '' then
        table.insert(lines, 'Instance: ' .. tostring(event.instance))
    end
    if event.category and event.category ~= '' then
        table.insert(lines, 'Category: ' .. tostring(event.category))
    end
    if event.user and event.user ~= '' then
        table.insert(lines, 'User:     ' .. tostring(event.user))
    end
    table.insert(lines, '')
    table.insert(lines, event.message or '')
    return {
        kind    = 'email',
        subject = subject,
        body    = table.concat(lines, '\r\n'),
    }
end

local BUILDERS = {
    generic = build_generic,
    slack   = build_slack,
    discord = build_slack,  -- Discord accepts Slack-style payloads.
    email   = build_email,
}

function M.for_type(name)
    return BUILDERS[name] or build_generic
end

function M.list_types()
    local out = {}
    for k in pairs(BUILDERS) do table.insert(out, k) end
    table.sort(out)
    return out
end

return M
