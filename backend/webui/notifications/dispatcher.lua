--
-- Outbound webhooks dispatcher (Task 53a).
--
-- One fiber per role lifecycle. Polls `_webui_webhook_queue` by the
-- `by_next_attempt` index, attempts delivery, on failure schedules
-- a retry with exponential backoff. Exhausted entries move to
-- `_webui_webhook_dead_letter`.
--
-- The queue is replicated, but only the leader does the work — the
-- dispatcher fiber checks `box.info.ro` each loop iteration and
-- idles on followers. A failover handover is therefore graceful:
-- the new leader picks up where the old left off (rows already in
-- the queue), and any in-flight delivery on the old leader either
-- completes (and the row gets deleted via replication) or its
-- absence of a delete remains pending for the new leader.
--

local fiber       = require('fiber')
local http_client = require('http.client')
local json        = require('json')

local storage   = require('webui.storage.spaces')
local templates = require('webui.notifications.templates')
local signature = require('webui.notifications.signature')
local logger    = require('webui.log_util').with_tag('webhooks')

local M = {}

-- ── tunables ────────────────────────────────────────────────────────

local BACKOFF_SEC = { 1, 5, 30, 300 } -- last entry capped before dead-letter.
local MAX_ATTEMPTS = 5
local IDLE_POLL_SEC = 2
local HTTP_TIMEOUT_SEC = 5

-- ── retry math (pure, unit-testable) ────────────────────────────────

-- Returns the seconds to wait before attempt #N. Attempt 1 is the
-- first delivery; on failure we schedule attempt 2 with BACKOFF[1].
function M.backoff_seconds(attempt)
    if attempt < 1 then return 0 end
    local i = math.min(attempt, #BACKOFF_SEC)
    return BACKOFF_SEC[i]
end

function M.max_attempts() return MAX_ATTEMPTS end

-- ── state ────────────────────────────────────────────────────────────

local STATE = {
    fiber          = nil,
    stop_requested = false,
    -- Cluster-config webhook list, lazily refreshed each tick.
    webhooks       = {},
    -- Stats counters surfaced via /api/metrics/webui and
    -- `notifications.stats()`.
    stats = {
        delivered    = {},  -- [name] = count
        failed       = {},
        retried      = {},
        dead_lettered = {},
        last_error   = {},  -- [name] = string
        last_ok_at   = {},  -- [name] = unix
    },
    -- HTTP client; one instance is enough — the rock pools
    -- connections per host.
    http = nil,
}

local function bump(map, key)
    map[key] = (map[key] or 0) + 1
end

function M.stats()
    return {
        delivered    = STATE.stats.delivered,
        failed       = STATE.stats.failed,
        retried      = STATE.stats.retried,
        dead_lettered = STATE.stats.dead_lettered,
        last_error   = STATE.stats.last_error,
        last_ok_at   = STATE.stats.last_ok_at,
    }
end

function M.configure(opts)
    opts = opts or {}
    STATE.webhooks = opts.webhooks or {}
    logger.info('notifications configured',
        { webhook_count = #STATE.webhooks })
end

-- ── delivery (single attempt) ───────────────────────────────────────

local function envelope_for_type(webhook, event)
    local builder = templates.for_type(webhook.type or 'generic')
    return builder(event)
end

local function deliver_http(webhook, event)
    if STATE.http == nil then
        STATE.http = http_client.new({ max_connections = 8 })
    end
    local payload_obj = envelope_for_type(webhook, event)
    local body = json.encode(payload_obj)
    local hdr = { ['content-type'] = 'application/json' }
    local sig = signature.sign(webhook.secret, body)
    if sig ~= nil then hdr[signature.header_name()] = sig end
    local started = fiber.time()
    local ok, response = pcall(STATE.http.post, STATE.http, webhook.url, body, {
        headers = hdr,
        timeout = webhook.timeout or HTTP_TIMEOUT_SEC,
    })
    local latency_ms = (fiber.time() - started) * 1000
    if not ok then
        return nil, tostring(response), latency_ms
    end
    if response.status >= 200 and response.status < 300 then
        return true, nil, latency_ms
    end
    return nil, 'HTTP ' .. tostring(response.status) ..
        ' ' .. (response.body or ''):sub(1, 200), latency_ms
end

local function deliver_email(webhook, event)
    local smtp = require('webui.notifications.smtp')
    local payload = templates.for_type('email')(event)
    local started = fiber.time()
    local ok, err = smtp.send({
        host       = webhook.smtp_host,
        port       = webhook.smtp_port,
        username   = webhook.smtp_username,
        password   = webhook.smtp_password,
        starttls   = webhook.smtp_starttls == true,
        timeout    = webhook.timeout or HTTP_TIMEOUT_SEC,
        from       = webhook.from,
        to         = webhook.to or {},
        subject    = payload.subject,
        body       = payload.body,
    })
    local latency_ms = (fiber.time() - started) * 1000
    if not ok then return nil, tostring(err), latency_ms end
    return true, nil, latency_ms
end

local function deliver(webhook, event)
    local kind = webhook.type or 'generic'
    if kind == 'email' then return deliver_email(webhook, event) end
    return deliver_http(webhook, event)
end

-- Exposed so /testWebhook can fire a synthetic event without
-- touching the queue. Returns `{ok, latency_ms, error}`.
function M.deliver_now(webhook, event)
    local ok, err, latency_ms = deliver(webhook, event)
    if not ok then
        return { ok = false, latency_ms = latency_ms, error = err }
    end
    return { ok = true, latency_ms = latency_ms }
end

-- ── queue interaction (leader-only) ─────────────────────────────────

local function find_webhook(name)
    for _, w in ipairs(STATE.webhooks) do
        if w.name == name then return w end
    end
    return nil
end

local function matches(webhook, event)
    if webhook.enabled == false then return false end
    local subs = webhook.events
    if type(subs) ~= 'table' or #subs == 0 then return false end
    for _, sub in ipairs(subs) do
        if sub == event.type or sub == '*' then
            -- Optional filters
            local f = webhook.filters or {}
            if f.severity ~= nil and type(f.severity) == 'table' then
                local ok_sev = false
                for _, s in ipairs(f.severity) do
                    if s == event.severity then ok_sev = true; break end
                end
                if not ok_sev then return false end
            end
            if f.scope ~= nil and f.scope ~= '*' and f.scope ~= event.scope then
                return false
            end
            return true
        end
    end
    return false
end

local function enqueue(webhook_name, event)
    local space = storage.webhook_queue()
    if space == nil then return end
    local now = math.floor(fiber.time())
    space:insert({ box.NULL, now, now, 0, webhook_name, event, box.NULL })
end

-- Public entry point. Called from the in-process `emit()` API.
-- Walks the configured webhooks and enqueues a row per match.
function M.fanout(event)
    if type(event) ~= 'table' then return end
    for _, webhook in ipairs(STATE.webhooks) do
        if matches(webhook, event) then
            local ok = pcall(enqueue, webhook.name, event)
            if not ok then
                logger.warn('failed to enqueue webhook delivery',
                    { webhook = webhook.name, event_type = event.type })
            end
        end
    end
end

local function dead_letter(row, last_err)
    local dlq = storage.webhook_dead_letter()
    if dlq == nil then return end
    pcall(function()
        dlq:insert({
            box.NULL,
            math.floor(fiber.time()),
            row.webhook,
            row.event,
            row.attempt,
            last_err,
        })
    end)
    bump(STATE.stats.dead_lettered, row.webhook)
end

-- Process up to `budget` due rows in one tick. Returns the number
-- of rows touched so the caller can decide whether to keep working
-- or yield.
local function drain_due(budget)
    local space = storage.webhook_queue()
    if space == nil then return 0 end
    local idx = space.index.by_next_attempt
    if idx == nil then return 0 end
    local now = math.floor(fiber.time())
    local touched = 0
    local processed = {}
    for _, row in idx:pairs({ now }, { iterator = 'LE' }) do
        if row.next_attempt_at > now then break end
        table.insert(processed, row)
        touched = touched + 1
        if touched >= budget then break end
    end
    for _, row in ipairs(processed) do
        local webhook = find_webhook(row.webhook)
        if webhook == nil then
            -- Configuration removed the webhook while a row was
            -- queued. Drop it and dead-letter the event so an
            -- operator can review.
            pcall(function() space:delete({ row.id }) end)
            dead_letter(row, 'WEBHOOK_REMOVED_FROM_CONFIG')
            logger.warn('webhook removed from config; row dead-lettered', {
                webhook = row.webhook,
            })
        else
            local ok, err, latency_ms = deliver(webhook, row.event)
            if ok then
                pcall(function() space:delete({ row.id }) end)
                bump(STATE.stats.delivered, row.webhook)
                STATE.stats.last_ok_at[row.webhook] = math.floor(fiber.time())
                STATE.stats.last_error[row.webhook] = nil
                logger.info('webhook delivered', {
                    webhook = row.webhook,
                    event_type = row.event.type,
                    latency_ms = latency_ms,
                    attempt = row.attempt + 1,
                })
            else
                bump(STATE.stats.failed, row.webhook)
                STATE.stats.last_error[row.webhook] = err
                local new_attempt = row.attempt + 1
                if new_attempt >= MAX_ATTEMPTS then
                    pcall(function() space:delete({ row.id }) end)
                    dead_letter(row, err)
                    logger.error('webhook dead-lettered', {
                        webhook = row.webhook,
                        attempts = new_attempt, err = err,
                    })
                else
                    local delay = M.backoff_seconds(new_attempt)
                    bump(STATE.stats.retried, row.webhook)
                    pcall(function()
                        space:update({ row.id }, {
                            { '=', 'next_attempt_at', math.floor(fiber.time()) + delay },
                            { '=', 'attempt', new_attempt },
                            { '=', 'last_error', err },
                        })
                    end)
                    logger.warn('webhook delivery failed; will retry', {
                        webhook = row.webhook,
                        attempt = new_attempt, delay_sec = delay, err = err,
                    })
                end
            end
        end
    end
    return touched
end

-- ── fiber loop ──────────────────────────────────────────────────────

local function dispatcher_loop()
    fiber.name('webui_notifications_dispatcher', { truncate = true })
    while not STATE.stop_requested do
        local can_run = rawget(_G, 'box') ~= nil
            and box.info ~= nil
            and box.info.ro ~= true
        if can_run then
            local ok, err = pcall(drain_due, 50)
            if not ok then
                logger.warn('drain_due raised', { err = tostring(err) })
            end
        end
        for _ = 1, IDLE_POLL_SEC * 10 do
            if STATE.stop_requested then break end
            fiber.sleep(0.1)
        end
    end
    logger.info('notifications dispatcher stopped')
end

function M.start()
    if STATE.fiber ~= nil then return end
    STATE.stop_requested = false
    STATE.fiber = fiber.create(dispatcher_loop)
end

function M.stop()
    STATE.stop_requested = true
    STATE.fiber = nil
    -- We intentionally do not fiber.cancel() — letting the loop
    -- finish its current iteration avoids interrupting an in-flight
    -- HTTP delivery and double-counting failures.
end

function M.is_running()
    return STATE.fiber ~= nil and not STATE.stop_requested
end

-- ── test hook ──────────────────────────────────────────────────────

function M._reset_state_for_test()
    STATE.stop_requested = false
    STATE.fiber          = nil
    STATE.webhooks       = {}
    STATE.stats = {
        delivered = {}, failed = {}, retried = {},
        dead_lettered = {}, last_error = {}, last_ok_at = {},
    }
end

return M
