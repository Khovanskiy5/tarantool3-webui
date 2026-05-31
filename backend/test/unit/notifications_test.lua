-- Unit tests for the notifications subsystem (Task 53a).

local t = require('luatest')
local fio = require('fio')

local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local g = t.group('notifications')

local signature = require('webui.notifications.signature')
local templates = require('webui.notifications.templates')
local dispatcher = require('webui.notifications.dispatcher')
local notifications = require('webui.notifications')

-- ── signature ─────────────────────────────────────────────────────

g.test_signature_returns_nil_for_empty_secret = function()
    t.assert_equals(signature.sign(nil, 'body'), nil)
    t.assert_equals(signature.sign('', 'body'), nil)
end

g.test_signature_deterministic = function()
    local a = signature.sign('top-secret', 'hello')
    local b = signature.sign('top-secret', 'hello')
    t.assert_equals(a, b)
    t.assert(a:find('^sha256='), 'signature must carry sha256= prefix')
    t.assert_equals(#a, #'sha256=' + 64, 'hex digest must be 64 chars')
end

g.test_signature_differs_for_different_body = function()
    local a = signature.sign('top-secret', 'hello')
    local b = signature.sign('top-secret', 'world')
    t.assert_not_equals(a, b)
end

g.test_header_name_is_stable = function()
    t.assert_equals(signature.header_name(), 'X-Webui-Signature')
end

-- ── templates ─────────────────────────────────────────────────────

g.test_generic_template_returns_event_verbatim = function()
    local evt = { type = 'foo', severity = 'info', extra = 1 }
    local payload = templates.for_type('generic')(evt)
    t.assert_equals(payload, evt)
end

g.test_unknown_type_falls_back_to_generic = function()
    local evt = { type = 'foo' }
    local payload = templates.for_type('does-not-exist')(evt)
    t.assert_equals(payload, evt)
end

g.test_slack_template_has_attachments = function()
    local payload = templates.for_type('slack')({
        type = 'issue.appeared', severity = 'critical',
        scope = 'tt-1', category = 'replication',
        message = 'upstream stalled',
    })
    t.assert_str_contains(payload.text, '[CRITICAL]')
    t.assert_type(payload.attachments, 'table')
    t.assert_equals(payload.attachments[1].color, 'danger')
    local fields = payload.attachments[1].fields
    t.assert(#fields >= 2, 'expected at least scope + category fields')
end

g.test_discord_template_aliases_slack = function()
    local s = templates.for_type('slack')({
        type = 'foo', severity = 'warning', message = 'x',
    })
    local d = templates.for_type('discord')({
        type = 'foo', severity = 'warning', message = 'x',
    })
    t.assert_equals(s, d)
end

g.test_email_template_carries_subject_and_body = function()
    local payload = templates.for_type('email')({
        type = 'audit.security', severity = 'warning',
        scope = '127.0.0.1', message = 'rate limited',
    })
    t.assert_equals(payload.kind, 'email')
    t.assert_str_contains(payload.subject, '[WARNING]')
    t.assert_str_contains(payload.body, 'audit.security')
    t.assert_str_contains(payload.body, 'rate limited')
end

-- ── dispatcher backoff ────────────────────────────────────────────

g.test_backoff_progression = function()
    -- The shipped schedule grows 1 → 5 → 30 → 300 then caps.
    t.assert_equals(dispatcher.backoff_seconds(1), 1)
    t.assert_equals(dispatcher.backoff_seconds(2), 5)
    t.assert_equals(dispatcher.backoff_seconds(3), 30)
    t.assert_equals(dispatcher.backoff_seconds(4), 300)
    t.assert_equals(dispatcher.backoff_seconds(5), 300,
        'attempts beyond the schedule must clamp to the final delay')
end

g.test_backoff_zero_for_invalid = function()
    t.assert_equals(dispatcher.backoff_seconds(0), 0)
    t.assert_equals(dispatcher.backoff_seconds(-1), 0)
end

g.test_max_attempts_matches_plan = function()
    -- The plan budgets 5 attempts before dead-lettering.
    t.assert_equals(dispatcher.max_attempts(), 5)
end

-- ── cluster-config validator ──────────────────────────────────────

g.test_validate_accepts_nil = function()
    local ok = notifications.validate(nil)
    t.assert_equals(ok, true)
end

g.test_validate_accepts_missing_webhooks = function()
    local ok = notifications.validate({ listen = ':8081' })
    t.assert_equals(ok, true)
end

g.test_validate_rejects_non_list = function()
    local _, err = notifications.validate({ webhooks = 'not a list' })
    t.assert_str_contains(err, 'must be a list')
end

g.test_validate_rejects_unknown_type = function()
    local _, err = notifications.validate({ webhooks = {
        { name = 'x', type = 'pagerduty', events = { 'audit.security' } },
    } })
    t.assert_str_contains(err, 'type must be one of')
end

g.test_validate_rejects_missing_events = function()
    local _, err = notifications.validate({ webhooks = {
        { name = 'x', type = 'slack', url = 'https://hooks.slack.com/x' },
    } })
    t.assert_str_contains(err, 'events is required')
end

g.test_validate_rejects_bad_url = function()
    local _, err = notifications.validate({ webhooks = {
        { name = 'x', type = 'slack', url = 'ftp://nope', events = { '*' } },
    } })
    t.assert_str_contains(err, 'url must be http')
end

g.test_validate_requires_email_smtp_host = function()
    local _, err = notifications.validate({ webhooks = {
        { name = 'x', type = 'email', events = { '*' },
          from = 'a@b', to = { 'c@d' } },
    } })
    t.assert_str_contains(err, 'requires smtp_host')
end

g.test_validate_accepts_well_formed_entries = function()
    local ok = notifications.validate({ webhooks = {
        { name = 'slack', type = 'slack',
          url = 'https://hooks.slack.com/services/T/B/X',
          events = { 'issue.appeared', 'config.committed' },
          enabled = true },
        { name = 'mail', type = 'email',
          smtp_host = 'smtp.example.com', smtp_port = 587,
          from = 'a@example.com', to = { 'b@example.com' },
          events = { 'audit.security' } },
    } })
    t.assert_equals(ok, true)
end
