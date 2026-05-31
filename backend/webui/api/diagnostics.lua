--
-- Diagnostic bundle (Task 55): GET /api/diagnostics/bundle
--
-- Packs a JSON payload with the role status, cluster snapshot,
-- active issues, suggestions, recent audit-log rows, role config
-- echo, and runtime versions. The bundle is meant for support —
-- operators attach it to a ticket without having to manually
-- gather state from each instance.
--
-- Admin only. No PII beyond what's already in the WebUI (no
-- passwords, no full cluster YAML by default — operators can opt
-- in via `?include_config=1`).
--

local json = require('json')
local fiber = require('fiber')

local state    = require('webui.cluster.state')
local storage  = require('webui.storage.spaces')
local issues   = require('webui.cluster.issues')
local suggestions = require('webui.cluster.suggestions')
local version  = require('webui.version')

local M = {}

local function audit_tail(n)
    local space = storage.audit()
    if space == nil then return {} end
    local out = {}
    local count = 0
    for _, tuple in space:pairs({}, { iterator = 'REQ' }) do
        table.insert(out, {
            id = tuple.id, ts = tuple.ts, user = tuple.user,
            action = tuple.action, scope = tuple.scope,
        })
        count = count + 1
        if count >= n then break end
    end
    return out
end

function M.handler(req)
    local include_config = (req.query and req.query['include_config']) == '1'
    local payload = {
        generated_at = fiber.time(),
        webui = {
            version = version.SEMVER,
            tarantool = _TARANTOOL,
        },
        instance = (rawget(_G, 'box') and box.info and box.info.name) or nil,
        cluster_snapshot = state.snapshot(),
        issues      = issues.current(),
        suggestions = suggestions.current(),
        audit_tail  = audit_tail(50),
    }
    if include_config then
        local fio_ok, fio = pcall(require, 'fio')
        if fio_ok then
            for _, p in ipairs({
                os.getenv('TT_CONFIG_PATH'),
                '/opt/webui/etc/cluster.yaml',
            }) do
                if p and #p > 0 then
                    local f = fio.open(p)
                    if f ~= nil then
                        payload.cluster_yaml = f:read()
                        f:close()
                        break
                    end
                end
            end
        end
    end
    pcall(function()
        require('webui.notifications').emit({
            type     = 'bundle.downloaded',
            severity = 'info',
            user     = req.user,
            scope    = include_config and 'with-config' or 'metadata-only',
            category = 'audit',
            message  = 'diagnostic bundle downloaded',
        })
    end)
    return {
        status = 200,
        headers = {
            ['content-type'] = 'application/json; charset=utf-8',
            ['content-disposition'] = 'attachment; filename="webui-diagnostics.json"',
        },
        body = json.encode(payload),
    }
end

return M
