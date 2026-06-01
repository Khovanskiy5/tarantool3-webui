--
-- Audit forwarder (Phase 4 Task 4.5 — minimal subset).
--
-- Opt-in side channels that mirror every audit row to an
-- external destination. Two backends ship in the open-source
-- baseline:
--
--   * `syslog`  — RFC 5424 UDP / TCP. Fire-and-forget with a
--                 best-effort send; SIEMs are the consumer and
--                 they own the retention story.
--   * `file`    — JSONL append to a path inside the container.
--                 Size-based rotation (`max_size_mb`) renames
--                 the live file to `<name>.1`, with at most
--                 `max_backups` historical files kept.
--
-- Configuration comes from cluster config:
--
--   roles_cfg.webui.audit.forwarders:
--     - { kind = 'syslog', host = 'syslog.example.com',
--         port = 514, protocol = 'udp',
--         tag = 'webui-audit', facility = 'local0',
--         severity = 'info', min_severity = 'info',
--         action_prefix = nil }
--     - { kind = 'file', path = '/opt/webui/var/log/audit.jsonl',
--         max_size_mb = 100, max_backups = 5,
--         min_severity = 'info', action_prefix = nil }
--
-- Forwarders are best-effort: a failed send logs a WARN and
-- moves on. `_webui_audit` is still the system of record; the
-- forwarder NEVER replaces it.
--

local fio    = require('fio')
local json   = require('json')
local socket = require('socket')

local log_util = require('webui.log_util')
local logger   = log_util.with_tag('audit.forwarder')

local M = {}

-- ── per-event filter ──────────────────────────────────────────────

-- Severity rank for the `min_severity` filter. Defaults to `info`
-- since most audit rows carry no explicit severity — they ARE
-- the security event. Higher entries override the default.
M.SEVERITY_RANK = {
    debug   = 1,
    info    = 2,
    notice  = 3,
    warning = 4,
    error   = 5,
    critical = 6,
    alert    = 7,
    emergency = 8,
}

local function row_severity(row)
    if row.severity and M.SEVERITY_RANK[row.severity] then
        return row.severity
    end
    -- Default: most audit rows are informational. RBAC-denied
    -- and login failures carry an explicit `severity` set by
    -- the writer; until that wiring lands the prefix heuristic
    -- below covers the obvious negative cases.
    local action = row.action or ''
    if action:find('rbac.denied', 1, true)
        or action:find('login_failed', 1, true)
        or action:find('error', 1, true) then
        return 'warning'
    end
    return 'info'
end
M._row_severity = row_severity

function M.passes_filter(forwarder, row)
    local min = forwarder.min_severity
    if min ~= nil then
        local min_rank = M.SEVERITY_RANK[min] or 0
        local row_rank = M.SEVERITY_RANK[row_severity(row)] or 0
        if row_rank < min_rank then return false end
    end
    local prefix = forwarder.action_prefix
    if prefix ~= nil and prefix ~= '' then
        if (row.action or ''):sub(1, #prefix) ~= prefix then return false end
    end
    return true
end

-- ── RFC 5424 framing ──────────────────────────────────────────────
--
-- <PRI>1 timestamp host app-name procid msgid - msg
-- PRI = facility * 8 + severity (numeric).

M.FACILITY_NUM = {
    kern = 0, user = 1, mail = 2, daemon = 3, auth = 4, syslog = 5,
    lpr = 6, news = 7, uucp = 8, cron = 9, authpriv = 10, ftp = 11,
    local0 = 16, local1 = 17, local2 = 18, local3 = 19,
    local4 = 20, local5 = 21, local6 = 22, local7 = 23,
}
M.SEVERITY_NUM = {
    emergency = 0, alert = 1, critical = 2, error = 3,
    warning = 4, notice = 5, info = 6, debug = 7,
}

local function rfc5424_line(forwarder, row)
    local facility = M.FACILITY_NUM[forwarder.facility or 'local0'] or 16
    local severity_num = M.SEVERITY_NUM[row_severity(row)] or 6
    local pri = facility * 8 + severity_num
    local ts = os.date('!%Y-%m-%dT%H:%M:%S.000Z',
        math.floor((row.ts or 0) / 1e6))
    local host = (rawget(_G, 'box') and box.info and box.info.name) or '-'
    local app  = forwarder.tag or 'webui-audit'
    local proc = '-'
    local msgid = row.action or '-'
    local msg = json.encode({
        user       = row.user,
        action     = row.action,
        scope      = row.scope,
        payload    = row.payload,
        request_id = row.request_id,
        id         = row.id,
        prev_hash  = row.prev_hash,
        current_hash = row.current_hash,
    })
    return string.format('<%d>1 %s %s %s %s %s - %s',
        pri, ts, host, app, proc, msgid, msg)
end
M._rfc5424_line = rfc5424_line

-- ── transports ────────────────────────────────────────────────────

local function send_syslog(forwarder, line)
    local host = forwarder.host or '127.0.0.1'
    local port = tonumber(forwarder.port) or 514
    local protocol = forwarder.protocol or 'udp'
    if protocol == 'udp' then
        local s = socket('AF_INET', 'SOCK_DGRAM', 'udp')
        if s == nil then return nil, 'udp socket() failed' end
        local ok = s:sendto(host, port, line)
        s:close()
        if not ok then return nil, 'sendto failed' end
        return true
    end
    if protocol == 'tcp' then
        local s = socket.tcp_connect(host, port, 1)
        if s == nil then return nil, 'tcp_connect failed' end
        s:send(line .. '\n')
        s:close()
        return true
    end
    return nil, 'unsupported protocol ' .. tostring(protocol)
end
M._send_syslog = send_syslog

-- Append-to-file with size-based rotation. Cheaper than a
-- background rotator fiber because the only writer is
-- record_local, which runs once per audit insert.
local function append_file(forwarder, row)
    local path = forwarder.path
    if type(path) ~= 'string' or path == '' then
        return nil, 'file forwarder: path is required'
    end
    -- Best-effort directory create. Tarantool's fio is forgiving;
    -- a missing dir is the most common operator misstep here.
    pcall(function() fio.mktree(fio.dirname(path)) end)

    local line = json.encode({
        ts            = row.ts,
        id            = row.id,
        user          = row.user,
        action        = row.action,
        scope         = row.scope,
        payload       = row.payload,
        request_id    = row.request_id,
        prev_hash     = row.prev_hash,
        current_hash  = row.current_hash,
        chain_seal    = row.chain_seal == true,
    })

    -- Rotation: size check first so the file we write to is
    -- always the live one.
    local max_bytes = (tonumber(forwarder.max_size_mb) or 100) * 1024 * 1024
    local st = fio.stat(path)
    if st ~= nil and st.size >= max_bytes then
        local max_backups = tonumber(forwarder.max_backups) or 5
        -- Shift .N → .N+1 from the tail.
        for i = max_backups - 1, 1, -1 do
            local from = path .. '.' .. i
            local to   = path .. '.' .. (i + 1)
            pcall(function() fio.rename(from, to) end)
        end
        pcall(function() fio.rename(path, path .. '.1') end)
    end

    local fd, err = fio.open(path,
        { 'O_WRONLY', 'O_CREAT', 'O_APPEND' },
        tonumber('644', 8))
    if fd == nil then return nil, tostring(err) end
    local ok_write = fd:write(line .. '\n')
    fd:fsync()
    fd:close()
    if not ok_write then return nil, 'write failed' end
    return true
end
M._append_file = append_file

-- ── public entry ─────────────────────────────────────────────────

local STATE = {
    forwarders = {},   -- normalised list from configure()
    enabled    = false,
}

function M.configure(opts)
    opts = opts or {}
    STATE.forwarders = {}
    for _, f in ipairs(opts.forwarders or {}) do
        if type(f) == 'table' and type(f.kind) == 'string' then
            table.insert(STATE.forwarders, f)
        end
    end
    STATE.enabled = #STATE.forwarders > 0
    if STATE.enabled then
        logger.info('audit forwarders configured', {
            count = #STATE.forwarders,
        })
    end
end

function M.handle(row)
    if not STATE.enabled then return end
    if type(row) ~= 'table' and type(row) ~= 'cdata' then return end
    for _, fwd in ipairs(STATE.forwarders) do
        if M.passes_filter(fwd, row) then
            if fwd.kind == 'syslog' then
                local line = rfc5424_line(fwd, row)
                local ok, err = send_syslog(fwd, line)
                if not ok then
                    logger.warn('syslog send dropped', {
                        host = fwd.host, err = err,
                    })
                end
            elseif fwd.kind == 'file' then
                local ok, err = append_file(fwd, row)
                if not ok then
                    logger.warn('file append dropped', {
                        path = fwd.path, err = err,
                    })
                end
            end
        end
    end
end

return M
