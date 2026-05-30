--
-- Resolvers for the `issues` and `issuesSummary` queries.
--
-- The resolver reads `cluster.issues.current()` once per call so
-- sub-fields and `issuesSummary` see the same scan output even if
-- the scanner runs between them.
--

local checks = require('checks')

local issues_module = require('webui.cluster.issues')
local log_util = require('webui.log_util')
local logger = log_util.with_tag('graphql.issues')

local M = {}

M.DEFAULT_PAGE_SIZE = 50
M.MAX_PAGE_SIZE     = 500

-- Pure: filter the issue list by optional severity / scope /
-- category. nil arguments mean "no filter on this dimension".
function M.filter(issues, opts)
    checks('?table', '?table')
    opts = opts or {}
    local out = {}
    for _, issue in ipairs(issues or {}) do
        local keep = true
        if opts.severity ~= nil and issue.severity ~= opts.severity then
            keep = false
        end
        if keep and opts.scope ~= nil and issue.scope ~= opts.scope then
            keep = false
        end
        if keep and opts.category ~= nil and issue.category ~= opts.category then
            keep = false
        end
        if keep and opts.instance ~= nil and issue.instance ~= opts.instance then
            keep = false
        end
        if keep and opts.replicaset ~= nil
            and issue.replicaset ~= opts.replicaset then
            keep = false
        end
        if keep then table.insert(out, issue) end
    end
    return out
end

-- Pure: slice a sorted issue list using cursor semantics over the
-- issue ID. `after` is the ID of the last item from the previous
-- page; nil starts from the beginning. limit caps at MAX_PAGE_SIZE,
-- defaults to DEFAULT_PAGE_SIZE.
function M.paginate(sorted, after, limit)
    checks('?table', '?string', '?number')
    sorted = sorted or {}
    local start_idx = 1
    if after ~= nil and after ~= '' then
        for i = 1, #sorted do
            if sorted[i].id == after then
                start_idx = i + 1
                break
            end
        end
    end
    local resolved = math.floor(tonumber(limit) or M.DEFAULT_PAGE_SIZE)
    if resolved <= 0 then resolved = M.DEFAULT_PAGE_SIZE end
    if resolved > M.MAX_PAGE_SIZE then resolved = M.MAX_PAGE_SIZE end
    local end_idx = math.min(#sorted, start_idx + resolved - 1)
    local items = {}
    for i = start_idx, end_idx do table.insert(items, sorted[i]) end
    local next_cursor = nil
    if end_idx < #sorted then
        local last = items[#items]
        next_cursor = last and last.id or nil
    end
    return {
        items       = items,
        next_cursor = next_cursor,
        total_count = #sorted,
    }
end

-- ─────────────────────────────────────────────────────────────────────
-- Resolvers
-- ─────────────────────────────────────────────────────────────────────

function M.issues(_, args)
    args = args or {}
    local snapshot = issues_module.current()
    local filtered = M.filter(snapshot, {
        severity   = args.severity,
        scope      = args.scope,
        category   = args.category,
        instance   = args.instance,
        replicaset = args.replicaset,
    })
    local page = M.paginate(filtered, args.after, args.limit)
    logger.debug('issues query', {
        total    = page.total_count,
        returned = #page.items,
    })
    return page
end

function M.issues_summary()
    local snapshot = issues_module.current()
    return issues_module.summarise(snapshot)
end

return M
