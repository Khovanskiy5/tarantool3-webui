--
-- REST handlers for cluster-config import/export.
--
-- GET  /api/config/download  → admin; returns the current YAML as a
--                              file attachment.
-- POST /api/config/upload    → admin; takes a YAML body, runs the
--                              two-phase prepare, returns the
--                              prepared_id + diff so the SPA can
--                              show a preview.
--

local json = require('json')
local fio  = require('fio')

local twophase = require('webui.config_store.twophase')
local log_util = require('webui.log_util')
local logger   = log_util.with_tag('api.config_io')

local M = {}

local function read_current_yaml()
    local paths = {}
    local function push(p) if p and #p > 0 then table.insert(paths, p) end end
    push(os.getenv('TT_CONFIG_PATH'))
    push(os.getenv('TT_CONFIG'))
    push('/opt/webui/etc/cluster.yaml')
    for _, p in ipairs(paths) do
        local f = fio.open(p)
        if f ~= nil then
            local body = f:read()
            f:close()
            if body and #body > 0 then return body end
        end
    end
    return ''
end

function M.handler_download(req)
    -- Auth is enforced by the middleware (`auth='admin'`); the
    -- handler only owns the body shaping.
    local body = read_current_yaml()
    logger.info('config download', { user = req.user, size = #body })
    return {
        status = 200,
        headers = {
            ['content-type']        = 'application/yaml; charset=utf-8',
            ['content-disposition'] = 'attachment; filename="cluster.yaml"',
        },
        body = body,
    }
end

function M.handler_upload(req)
    local raw
    if type(req.read_cached) == 'function' then
        local ok, body = pcall(req.read_cached, req)
        if ok then raw = body end
    end
    if raw == nil or #raw == 0 then
        return {
            status = 400, body = json.encode({ error = {
                code = 'INVALID_QUERY', message = 'empty body' } }),
            headers = { ['content-type'] = 'application/json' },
        }
    end
    -- 4 MiB cap mirrors the plan's `LARGE_CONFIG` threshold.
    if #raw > 4 * 1024 * 1024 then
        return {
            status = 413, body = json.encode({ error = {
                code = 'LARGE_CONFIG', message = 'config exceeds 4 MiB' } }),
            headers = { ['content-type'] = 'application/json' },
        }
    end
    local res, errs = twophase.prepare({
        yaml = raw, user = req.user, current_yaml = read_current_yaml(),
    })
    if res == nil then
        return {
            status = 400, body = json.encode({ error = {
                code = 'VALIDATION_FAILED',
                message = errs and errs[1] and errs[1].message or 'invalid',
                details = { issues = errs } } }),
            headers = { ['content-type'] = 'application/json' },
        }
    end
    logger.info('config upload prepared', {
        user = req.user, prepared_id = res.prepared_id,
    })
    return {
        status = 200, body = json.encode({
            prepared_id = res.prepared_id,
            expires_at  = res.expires_at,
            diff        = res.diff,
        }),
        headers = { ['content-type'] = 'application/json' },
    }
end

return M
