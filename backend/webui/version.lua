-- Version information and Tarantool compatibility check.
--
-- Pure module: no side effects in require, no globals, no fibers.
-- All consumers obtain compatibility verdict through check_tarantool().

local M = {}

-- SemVer of the WebUI rock itself. Bumped by the release pipeline.
M.SEMVER = '0.1.0'

-- Supported Tarantool range. Inclusive minimum, exclusive maximum.
-- Bumping the maximum requires explicit CI verification on the new branch.
M.MIN_TARANTOOL = '3.7.0'
M.MAX_TARANTOOL_EXCLUSIVE = '4.0.0'

-- Protocol versions for stable APIs (see API stability contract).
M.WS_PROTOCOL_VERSION = 1
M.GRAPHQL_SCHEMA_GENERATION = 1

local function parse(s)
    if type(s) ~= 'string' then
        return nil
    end
    local major, minor, patch = string.match(s, '^(%d+)%.(%d+)%.(%d+)')
    if major == nil then
        return nil
    end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function compare(a, b)
    for i = 1, 3 do
        if a[i] ~= b[i] then
            return a[i] < b[i] and -1 or 1
        end
    end
    return 0
end

M.parse = parse
M.compare = compare

-- Check the current running Tarantool against the supported range.
-- Returns true on success, (nil, err_string) on incompatibility.
function M.check_tarantool()
    local current_raw = _TARANTOOL
    local current = parse(current_raw)
    local min_v = parse(M.MIN_TARANTOOL)
    local max_v = parse(M.MAX_TARANTOOL_EXCLUSIVE)

    if current == nil then
        return nil, string.format(
            'cannot parse current Tarantool version %q',
            tostring(current_raw)
        )
    end

    if compare(current, min_v) < 0 then
        return nil, string.format(
            'Tarantool %s is older than required minimum %s',
            current_raw, M.MIN_TARANTOOL
        )
    end

    if compare(current, max_v) >= 0 then
        return nil, string.format(
            'Tarantool %s is at or beyond the unsupported boundary %s',
            current_raw, M.MAX_TARANTOOL_EXCLUSIVE
        )
    end

    return true
end

return M
