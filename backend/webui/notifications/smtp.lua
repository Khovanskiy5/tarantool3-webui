--
-- Minimal SMTP client for outbound email webhooks (Task 53a).
--
-- Supports the common dev/ops topology: STARTTLS on port 587 with
-- AUTH LOGIN/PLAIN, or plain port 25 to a local mail relay. The
-- implementation is intentionally small — production setups should
-- point this at a sidecar like Postfix / sendmail and let that
-- handle DKIM, SPF, retry-with-DNS, etc.
--
-- Public surface: `M.send({ host, port, from, to, subject, body,
-- username?, password?, starttls?, timeout? })` returns true on
-- success or `nil, err` with a stable error code.
--

local socket = require('socket')
local digest = require('digest')

local M = {}

local CRLF = '\r\n'

local function open(host, port, timeout)
    local s = socket.tcp_connect(host, port, timeout)
    if s == nil then
        return nil, 'CONNECT_FAILED: ' .. tostring(host) .. ':' .. tostring(port)
    end
    return s
end

local function readline(s, timeout)
    -- SMTP responses may span multiple lines (e.g. EHLO). The last
    -- line uses `<code><SP>` instead of `<code>-`; we return the
    -- final line's code and the accumulated text so the caller can
    -- inspect both.
    local lines = {}
    while true do
        local line = s:read({ delimiter = CRLF }, timeout)
        if line == nil or #line == 0 then
            return nil, 'READ_FAILED'
        end
        line = line:gsub('\r?\n$', '')
        table.insert(lines, line)
        local sep = line:sub(4, 4)
        if sep == ' ' or sep == '' then
            local code = tonumber(line:sub(1, 3))
            if code == nil then
                return nil, 'BAD_RESPONSE: ' .. line
            end
            return { code = code, lines = lines }
        end
        if #lines > 64 then
            return nil, 'TOO_MANY_LINES'
        end
    end
end

local function expect(s, want_codes, timeout, label)
    local resp, err = readline(s, timeout)
    if resp == nil then return nil, label .. ': ' .. tostring(err) end
    for _, c in ipairs(want_codes) do
        if resp.code == c then return resp end
    end
    return nil, string.format('%s: unexpected %d (%s)',
        label, resp.code, table.concat(resp.lines, ' / '))
end

local function send_line(s, line, timeout)
    local ok = s:write(line .. CRLF, timeout)
    if ok == nil then return nil, 'WRITE_FAILED' end
    return true
end

local function rfc822_date()
    -- "Thu, 14 Sep 2023 12:34:56 +0000"; we use UTC and skip
    -- locale-dependent day-of-week names by computing them.
    local days = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }
    local months = {
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    }
    local t = os.date('!*t')
    return string.format('%s, %02d %s %d %02d:%02d:%02d +0000',
        days[t.wday], t.day, months[t.month], t.year,
        t.hour, t.min, t.sec)
end

local function message_id(domain)
    return string.format('<%s@%s>',
        digest.urandom(12):gsub('.', function(c)
            return string.format('%02x', string.byte(c))
        end),
        domain or 'webui.local')
end

local function build_envelope(opts)
    local headers = {
        'From: ' .. opts.from,
        'To: ' .. table.concat(opts.to, ', '),
        'Subject: ' .. opts.subject,
        'Date: ' .. rfc822_date(),
        'Message-ID: ' .. message_id(opts.from:match('@(.+)$')),
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=UTF-8',
        'Content-Transfer-Encoding: 8bit',
        'X-Mailer: tarantool-webui',
    }
    local body = opts.body or ''
    -- SMTP `<CRLF>.<CRLF>` terminates DATA. Lines starting with `.`
    -- must be dot-stuffed (RFC 5321 §4.5.2).
    body = body:gsub('\r?\n', '\r\n'):gsub('\r\n%.', '\r\n..')
    return table.concat(headers, CRLF) .. CRLF .. CRLF .. body
end

-- Each protocol step sends one (or a few) commands, checks the
-- response codes, and returns `true` on success or `(nil, label,
-- detail)` on failure. The caller (`M.send`) owns the socket lifecycle
-- and turns a failure into a `fail(label, detail)` (QUIT + close).

local function smtp_ehlo(s, timeout)
    if not send_line(s, 'EHLO webui.local', timeout) then
        return nil, 'SMTP_EHLO', 'write failed'
    end
    local _, err = expect(s, { 250 }, timeout, 'EHLO')
    if err then return nil, 'SMTP_EHLO', err end
    return true
end

local function smtp_starttls(s, timeout)
    if not send_line(s, 'STARTTLS', timeout) then
        return nil, 'SMTP_STARTTLS', 'write failed'
    end
    local _, err = expect(s, { 220 }, timeout, 'STARTTLS')
    if err then return nil, 'SMTP_STARTTLS', err end
    if type(s.sslconnect) ~= 'function' then
        return nil, 'SMTP_STARTTLS',
            'sslconnect unavailable in this Tarantool build'
    end
    local ok_tls = s:sslconnect()
    if not ok_tls then
        return nil, 'SMTP_STARTTLS', 'TLS handshake failed'
    end
    if not send_line(s, 'EHLO webui.local', timeout) then
        return nil, 'SMTP_EHLO_TLS', 'write failed'
    end
    _, err = expect(s, { 250 }, timeout, 'EHLO/TLS')
    if err then return nil, 'SMTP_EHLO_TLS', err end
    return true
end

local function smtp_auth(s, timeout, username, password)
    if not send_line(s, 'AUTH LOGIN', timeout) then
        return nil, 'SMTP_AUTH', 'write failed'
    end
    local _, err = expect(s, { 334 }, timeout, 'AUTH start')
    if err then return nil, 'SMTP_AUTH', err end
    send_line(s, digest.base64_encode(username, { nowrap = true }), timeout)
    _, err = expect(s, { 334 }, timeout, 'AUTH user')
    if err then return nil, 'SMTP_AUTH', err end
    send_line(s, digest.base64_encode(password, { nowrap = true }), timeout)
    _, err = expect(s, { 235 }, timeout, 'AUTH password')
    if err then return nil, 'SMTP_AUTH', err end
    return true
end

local function smtp_mail_from(s, timeout, from)
    if not send_line(s, 'MAIL FROM:<' .. from .. '>', timeout) then
        return nil, 'SMTP_MAIL', 'write failed'
    end
    local _, err = expect(s, { 250 }, timeout, 'MAIL FROM')
    if err then return nil, 'SMTP_MAIL', err end
    return true
end

local function smtp_rcpt_to(s, timeout, to_list)
    for _, rcpt in ipairs(to_list) do
        if not send_line(s, 'RCPT TO:<' .. rcpt .. '>', timeout) then
            return nil, 'SMTP_RCPT', 'write failed'
        end
        local _, err = expect(s, { 250, 251 }, timeout, 'RCPT TO ' .. rcpt)
        if err then return nil, 'SMTP_RCPT', err end
    end
    return true
end

local function smtp_data(s, timeout, opts)
    if not send_line(s, 'DATA', timeout) then
        return nil, 'SMTP_DATA', 'write failed'
    end
    local _, err = expect(s, { 354 }, timeout, 'DATA start')
    if err then return nil, 'SMTP_DATA', err end
    local envelope = build_envelope(opts)
    if not send_line(s, envelope .. CRLF .. '.', timeout) then
        return nil, 'SMTP_DATA', 'envelope write failed'
    end
    _, err = expect(s, { 250 }, timeout, 'DATA end')
    if err then return nil, 'SMTP_DATA', err end
    return true
end

function M.send(opts)
    opts = opts or {}
    if type(opts.host) ~= 'string' or #opts.host == 0 then
        return nil, 'BAD_OPTS: host is required'
    end
    if type(opts.from) ~= 'string' or #opts.from == 0 then
        return nil, 'BAD_OPTS: from is required'
    end
    if type(opts.to) ~= 'table' or #opts.to == 0 then
        return nil, 'BAD_OPTS: to is required'
    end
    local port = opts.port or 25
    local timeout = opts.timeout or 5

    local s, conn_err = open(opts.host, port, timeout)
    if s == nil then return nil, conn_err end

    local function fail(label, err)
        pcall(function() send_line(s, 'QUIT', timeout); s:close() end)
        return nil, label .. ': ' .. tostring(err)
    end

    local _, err = expect(s, { 220 }, timeout, 'BANNER')
    if err then return fail('SMTP_BANNER', err) end

    local label, detail
    _, label, detail = smtp_ehlo(s, timeout)
    if label then return fail(label, detail) end

    if opts.starttls == true then
        _, label, detail = smtp_starttls(s, timeout)
        if label then return fail(label, detail) end
    end

    if opts.username and opts.password then
        _, label, detail = smtp_auth(s, timeout, opts.username, opts.password)
        if label then return fail(label, detail) end
    end

    _, label, detail = smtp_mail_from(s, timeout, opts.from)
    if label then return fail(label, detail) end

    _, label, detail = smtp_rcpt_to(s, timeout, opts.to)
    if label then return fail(label, detail) end

    _, label, detail = smtp_data(s, timeout, opts)
    if label then return fail(label, detail) end

    send_line(s, 'QUIT', timeout)
    s:close()
    return true
end

-- Internal helpers re-exported for unit testing.
M._build_envelope = build_envelope
M._smtp_ehlo = smtp_ehlo
M._smtp_starttls = smtp_starttls
M._smtp_auth = smtp_auth
M._smtp_mail_from = smtp_mail_from
M._smtp_rcpt_to = smtp_rcpt_to
M._smtp_data = smtp_data

return M
