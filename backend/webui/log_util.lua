-- Structured JSON logging for the webui role.
--
-- Every log entry is a single JSON line with the mandatory fields:
--   ts       ISO 8601 UTC with microsecond precision
--   level    debug | info | warn | error
--   tag      subsystem label, e.g. "http", "cluster", "config"
--   instance current instance alias (when known)
--   msg      single line, no newlines
-- Optional fields are merged from the caller's `fields` table.
--
-- The module has no side effects on require. State lives in a single
-- local table updated through configure().
--
-- Lua simple/reliable rules applied:
--   * no globals, no metatables, no exceptions
--   * tagged loggers are plain tables of closures, not OOP
--   * level filtering is computed once per emit, no metric storms
--   * any encode failure falls back to a plain-text message

local json = require('json')
local fiber = require('fiber')
local log = require('log')

local LEVEL = { debug = 1, info = 2, warn = 3, error = 4 }
local DEFAULT_LEVEL = LEVEL.debug
local DEFAULT_TAG = 'general'

local M = {}

local state = {
    level = DEFAULT_LEVEL,
    instance = nil,
}

local function parse_level(value)
    if type(value) ~= 'string' then
        return nil
    end
    return LEVEL[string.lower(value)]
end

local function format_ts()
    -- fiber.time64 returns microseconds since epoch as 64-bit cdata number.
    -- Split into seconds + remainder to render ISO 8601 with microsecond fraction.
    local t64 = fiber.time64()
    local seconds = tonumber(t64 / 1000000ULL)
    local micros = tonumber(t64 % 1000000ULL)
    local d = os.date('!%Y-%m-%dT%H:%M:%S', seconds)
    return string.format('%s.%06dZ', d, micros)
end

local function build_entry(level, tag, msg, fields)
    local entry = {
        ts = format_ts(),
        level = level,
        tag = tag or DEFAULT_TAG,
        instance = state.instance,
        msg = msg,
    }
    if type(fields) == 'table' then
        for k, v in pairs(fields) do
            -- Reserved keys may not be overwritten by caller payload.
            if entry[k] == nil then
                entry[k] = v
            end
        end
    end
    return entry
end

local function serialize(entry)
    local ok, payload = pcall(json.encode, entry)
    if ok then
        return payload
    end
    -- Encoding failed (e.g. fields contain non-serialisable userdata).
    -- Emit a degraded but informative line instead of throwing.
    return string.format(
        '{"ts":%q,"level":%q,"tag":%q,"msg":%q,"_encode_error":true}',
        entry.ts, entry.level, entry.tag,
        tostring(entry.msg or '')
    )
end

local function dispatch(level, payload)
    -- log.* delegates to Tarantool's logger which honours box.cfg.log_level
    -- when running inside box.cfg; in test/standalone mode it prints to stderr.
    if level == 'error' then
        log.error('%s', payload)
    elseif level == 'warn' then
        log.warn('%s', payload)
    elseif level == 'info' then
        log.info('%s', payload)
    else
        log.debug('%s', payload)
    end
end

local function emit(level, tag, msg, fields)
    local numeric = LEVEL[level]
    if numeric == nil or numeric < state.level then
        return
    end
    local entry = build_entry(level, tag, msg, fields)
    dispatch(level, serialize(entry))
end

-- Reconfigure the logger. Idempotent. Safe to call repeatedly.
-- Accepts:
--   opts.level    string ('debug'|'info'|'warn'|'error')
--   opts.instance string (alias of the running instance)
function M.configure(opts)
    opts = opts or {}
    local lvl = parse_level(opts.level)
    if lvl ~= nil then
        state.level = lvl
    end
    if opts.instance ~= nil then
        state.instance = tostring(opts.instance)
    end
end

function M.current_level()
    -- Reverse lookup for diagnostics.
    for name, value in pairs(LEVEL) do
        if value == state.level then
            return name
        end
    end
    return 'unknown'
end

-- Build a tagged sub-logger. Plain table of closures, no metatable.
function M.with_tag(tag)
    if type(tag) ~= 'string' or tag == '' then
        tag = DEFAULT_TAG
    end
    return {
        debug = function(msg, fields) emit('debug', tag, msg, fields) end,
        info  = function(msg, fields) emit('info',  tag, msg, fields) end,
        warn  = function(msg, fields) emit('warn',  tag, msg, fields) end,
        error = function(msg, fields) emit('error', tag, msg, fields) end,
    }
end

-- Untagged convenience entry points.
function M.debug(msg, fields) emit('debug', DEFAULT_TAG, msg, fields) end
function M.info(msg, fields)  emit('info',  DEFAULT_TAG, msg, fields) end
function M.warn(msg, fields)  emit('warn',  DEFAULT_TAG, msg, fields) end
function M.error(msg, fields) emit('error', DEFAULT_TAG, msg, fields) end

return M
