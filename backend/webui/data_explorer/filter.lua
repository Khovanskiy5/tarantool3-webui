--
-- Filter compilation and index selection for the `tuples` query.
--
-- The data-explorer accepts an AND-combined list of conditions
-- `{field, op, value}`. We translate that into:
--
--   1. A key prefix for `idx:pairs({key}, {iterator=...})` that the
--      chosen index covers (the "pushdown" part).
--   2. A post-filter applied in Lua to whatever leaks past the
--      index (the "residual" part). Anything we cannot push down
--      flips `partial_scan = true` in the GraphQL response so the
--      operator knows the query did extra work.
--
--   3. `pick_index(space, filter)` picks the index whose leading
--      parts cover the most equality conditions. Ties broken in
--      favor of unique indexes — they typically yield a single
--      tuple. Falls back to primary (index 0) when nothing matches.
--
-- The compiler is deliberately conservative: any unknown op falls
-- into post-filter, never into a wrong iterator hint. A wrong
-- iterator is worse than a missing one — it returns silently bogus
-- pages.
--

local M = {}

-- Allowed operators. The set mirrors what the SPA can render in the
-- filter chip UI; expand both sides together so the surface stays
-- in sync with the typed GraphQL enum.
local OPS = {
    eq = true, ne = true,
    gt = true, ge = true,
    lt = true, le = true,
    like = true, prefix = true,
}
M.OPS = OPS

-- pick_index(space, filter) → (index, covered_count, conditions_for_index)
--
-- Scans every index on the space, asks "if I started a key from this
-- index using only `eq` conditions on its leading parts, how many
-- parts would I cover?". The index with the highest covered count
-- wins; ties go to the unique index, then to the lowest id.
--
-- Returns the index handle plus the prefix length we matched so the
-- caller can `idx:pairs({key1, key2, ...})` without overshooting.
function M.pick_index(space, filter)
    if space == nil or space.index == nil then return nil, 0, {} end
    local conditions_by_field = {}
    for _, c in ipairs(filter or {}) do
        if c.op == 'eq' then
            conditions_by_field[c.field] = c
        end
    end

    local best_idx, best_cover, best_unique, best_id = nil, -1, false, nil
    for k, idx in pairs(space.index) do
        if type(k) == 'number' and type(idx) == 'table' and idx.parts then
            local cover = 0
            for _, part in ipairs(idx.parts) do
                local field_name = part.field_name or part.name
                if field_name == nil or conditions_by_field[field_name] == nil then
                    break
                end
                cover = cover + 1
            end
            -- ties: prefer unique, then lower id
            local replace = cover > best_cover
                or (cover == best_cover and not best_unique and idx.unique)
                or (cover == best_cover and best_unique == idx.unique
                    and (best_id == nil or idx.id < best_id))
            if replace then
                best_idx     = idx
                best_cover   = cover
                best_unique  = idx.unique == true
                best_id      = idx.id
            end
        end
    end

    if best_idx == nil then return nil, 0, {} end
    return best_idx, math.max(best_cover, 0)
end

-- Build the iterator key from the chosen prefix length and the
-- per-field eq conditions. Returns (key_list, iterator_type).
--
-- We default to 'GE' rather than 'EQ' when prefix length < #idx.parts
-- because the operator may have asked "field A eq X, field B gt 0"
-- against an index (A, B). EQ would only return tuples where B
-- exactly equals nil; GE returns everything starting from {X} that
-- the residual filter can then prune.
function M.build_key(idx, prefix_len, filter)
    if idx == nil or prefix_len == 0 then return {}, 'ALL' end
    local conds = {}
    for _, c in ipairs(filter or {}) do
        if c.op == 'eq' then conds[c.field] = c.value end
    end
    local key = {}
    for i = 1, prefix_len do
        local part = idx.parts[i]
        local field_name = part.field_name or part.name
        key[i] = conds[field_name]
    end
    -- All-eq → exact key, EQ iterator. Anything shorter than the
    -- full index covers a range, GE is the safe default.
    local iter = (prefix_len == #idx.parts) and 'EQ' or 'GE'
    return key, iter
end

-- Compile a filter into post-filter conditions: anything that did
-- NOT make it into the index key. Returns a list of `{field, op,
-- value}` to apply in Lua to each candidate tuple.
function M.residual(filter, idx, prefix_len)
    local pushed = {}
    if idx ~= nil and prefix_len > 0 then
        for i = 1, prefix_len do
            local part = idx.parts[i]
            pushed[part.field_name or part.name] = true
        end
    end
    local out = {}
    for _, c in ipairs(filter or {}) do
        if not pushed[c.field] or c.op ~= 'eq' then
            table.insert(out, c)
        end
    end
    return out
end

-- ── post-filter (applied in Lua, slow path) ─────────────────────────

-- Tarantool tuples behave like Lua arrays + indexable maps when the
-- space has a format. We resolve `field_name` through the format
-- once and cache the resulting fieldno per call.
local function build_field_lookup(format)
    local lookup = {}
    for i, f in ipairs(format or {}) do
        if type(f) == 'table' and f.name then
            lookup[f.name] = i
        end
    end
    return lookup
end
M._build_field_lookup = build_field_lookup

local function match_condition(value, op, target)
    if value == nil and op ~= 'ne' then return false end
    if op == 'eq'   then return value == target end
    if op == 'ne'   then return value ~= target end
    if op == 'gt'   then return value > target  end
    if op == 'ge'   then return value >= target end
    if op == 'lt'   then return value < target  end
    if op == 'le'   then return value <= target end
    if op == 'prefix' then
        return type(value) == 'string' and type(target) == 'string'
            and value:sub(1, #target) == target
    end
    if op == 'like' then
        -- SQL-style LIKE → Lua pattern. We anchor with ^ / $ so
        -- 'abc' does not match 'xabcy'. Steps:
        --   1. Escape every Lua-pattern special char (including %)
        --      so user input cannot smuggle a regex.
        --   2. Convert the SQL wildcards. After step 1 the literal
        --      SQL `%` is `%%` and the literal SQL `_` is still `_`
        --      (underscore is not special in Lua patterns).
        --   3. Replace `%%` → `.*` and `_` → `.`.
        if type(value) ~= 'string' or type(target) ~= 'string' then return false end
        local escaped = target:gsub('([%%%(%)%.%+%-%*%?%[%]%^%$])', '%%%1')
        local pat = '^' .. escaped:gsub('%%%%', '.*'):gsub('_', '.') .. '$'
        return value:match(pat) ~= nil
    end
    return false
end
M._match_condition = match_condition

-- apply_post_filter(tuple, conditions, lookup) → bool
function M.apply_post_filter(tuple, conditions, lookup)
    if conditions == nil or #conditions == 0 then return true end
    for _, c in ipairs(conditions) do
        local fieldno = lookup[c.field]
        local v = (fieldno ~= nil) and tuple[fieldno] or nil
        if not match_condition(v, c.op, c.value) then return false end
    end
    return true
end

-- ── full-scan guard ─────────────────────────────────────────────────

-- The data-explorer pages spaces with cursor + limit, but a user
-- can submit an empty filter and a "limit: 1000" against a 10M-row
-- space and lock up the tx-thread. We refuse that unless the caller
-- explicitly passes `allow_full_scan = true`.
M.HARD_LIMIT = 1000

function M.check_full_scan(space, filter, opts)
    if (opts or {}).allow_full_scan == true then return true end
    -- A filter that an index can cover at all is not a full scan.
    local _, covered = M.pick_index(space, filter)
    if covered > 0 then return true end
    -- No filter and no allow → only safe on small spaces.
    local count = 0
    pcall(function() count = space:count() end)
    if count <= M.HARD_LIMIT then return true end
    return false,
        ('FORBIDDEN: full-scan of %s (~%d rows) refused without ' ..
         'allow_full_scan=true'):format(space.name or '?', count)
end

return M
