local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local smtp = require('webui.notifications.smtp')

local g = t.group('notifications.smtp')

-- Drive the extracted SMTP protocol helpers against a fake socket that
-- replays a scripted sequence of server responses. Verifies the
-- happy-path command flow and that an unexpected response code on any
-- step surfaces the right error label. Live delivery stays covered by a
-- local SMTP catcher (manual, see plan).

-- responses: list of reply strings like '250 OK' served in order.
local function fake_socket(responses, opts)
    opts = opts or {}
    local i = 0
    local sock = { writes = {} }
    function sock:read(_, _)
        i = i + 1
        local r = responses[i]
        if r == nil then return nil end
        return r .. '\r\n'
    end
    function sock:write(data, _)
        table.insert(self.writes, data)
        return #data
    end
    function sock:close() self.closed = true end
    if opts.tls ~= false then
        function sock:sslconnect() return opts.tls_ok ~= false end
    end
    return sock
end

-- ── EHLO ─────────────────────────────────────────────────────────────

g.test_ehlo_ok = function()
    local s = fake_socket({ '250 hello' })
    t.assert_equals(smtp._smtp_ehlo(s, 1), true)
end

g.test_ehlo_unexpected_code = function()
    local s = fake_socket({ '500 nope' })
    local ok, label, detail = smtp._smtp_ehlo(s, 1)
    t.assert_equals(ok, nil)
    t.assert_equals(label, 'SMTP_EHLO')
    t.assert_str_contains(detail, 'unexpected 500')
end

-- ── STARTTLS ─────────────────────────────────────────────────────────

g.test_starttls_ok = function()
    local s = fake_socket({ '220 go', '250 ehlo-tls' })
    t.assert_equals(smtp._smtp_starttls(s, 1), true)
end

g.test_starttls_rejected = function()
    local s = fake_socket({ '454 tls unavailable' })
    local ok, label = smtp._smtp_starttls(s, 1)
    t.assert_equals(ok, nil)
    t.assert_equals(label, 'SMTP_STARTTLS')
end

g.test_starttls_no_sslconnect = function()
    local s = fake_socket({ '220 go' }, { tls = false })
    local ok, label, detail = smtp._smtp_starttls(s, 1)
    t.assert_equals(ok, nil)
    t.assert_equals(label, 'SMTP_STARTTLS')
    t.assert_str_contains(detail, 'sslconnect unavailable')
end

g.test_starttls_handshake_failure = function()
    local s = fake_socket({ '220 go' }, { tls_ok = false })
    local ok, label, detail = smtp._smtp_starttls(s, 1)
    t.assert_equals(ok, nil)
    t.assert_equals(label, 'SMTP_STARTTLS')
    t.assert_str_contains(detail, 'TLS handshake failed')
end

-- ── AUTH LOGIN ───────────────────────────────────────────────────────

g.test_auth_ok = function()
    local s = fake_socket({ '334 user', '334 pass', '235 ok' })
    t.assert_equals(smtp._smtp_auth(s, 1, 'u', 'p'), true)
end

g.test_auth_rejected = function()
    local s = fake_socket({ '334 user', '334 pass', '535 bad creds' })
    local ok, label = smtp._smtp_auth(s, 1, 'u', 'p')
    t.assert_equals(ok, nil)
    t.assert_equals(label, 'SMTP_AUTH')
end

-- ── MAIL FROM / RCPT TO ──────────────────────────────────────────────

g.test_mail_from_ok = function()
    local s = fake_socket({ '250 ok' })
    t.assert_equals(smtp._smtp_mail_from(s, 1, 'a@x'), true)
    t.assert_str_contains(s.writes[1], 'MAIL FROM:<a@x>')
end

g.test_rcpt_to_multiple = function()
    local s = fake_socket({ '250 ok', '251 forwarded' })
    t.assert_equals(smtp._smtp_rcpt_to(s, 1, { 'a@x', 'b@y' }), true)
    t.assert_str_contains(s.writes[1], 'RCPT TO:<a@x>')
    t.assert_str_contains(s.writes[2], 'RCPT TO:<b@y>')
end

g.test_rcpt_to_rejected = function()
    local s = fake_socket({ '550 no such user' })
    local ok, label = smtp._smtp_rcpt_to(s, 1, { 'a@x' })
    t.assert_equals(ok, nil)
    t.assert_equals(label, 'SMTP_RCPT')
end

-- ── DATA ─────────────────────────────────────────────────────────────

g.test_data_ok = function()
    local s = fake_socket({ '354 go ahead', '250 queued' })
    local opts = { from = 'a@x', to = { 'b@y' },
        subject = 'hi', body = 'line1\nline2' }
    t.assert_equals(smtp._smtp_data(s, 1, opts), true)
end

g.test_data_rejected_at_start = function()
    local s = fake_socket({ '503 bad sequence' })
    local opts = { from = 'a@x', to = { 'b@y' }, subject = 'hi', body = 'x' }
    local ok, label = smtp._smtp_data(s, 1, opts)
    t.assert_equals(ok, nil)
    t.assert_equals(label, 'SMTP_DATA')
end

-- ── envelope dot-stuffing (RFC 5321 §4.5.2) ──────────────────────────

g.test_envelope_dot_stuffs_leading_dots = function()
    local env = smtp._build_envelope({
        from = 'a@x', to = { 'b@y' }, subject = 'hi',
        body = 'normal\n.hidden',
    })
    t.assert_str_contains(env, '\r\n..hidden')
end
