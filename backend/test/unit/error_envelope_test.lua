-- Unit test for the unified REST/GraphQL error envelope.

local t = require('luatest')

-- Source: /<repo>/backend/test/unit/foo_test.lua → four dirname'es
-- give the repo root.
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;' ..
               repo_root .. '/backend/?/init.lua;' ..
               package.path

local g = t.group('error_envelope')

local rest_envelope = require('webui.http.error_envelope')
local gql_envelope  = require('webui.graphql.error_envelope')

-- ── REST ──────────────────────────────────────────────────────────────

g.test_rest_envelope_includes_code_message_request_id = function()
    local body, code = rest_envelope.build({
        code = 'FORBIDDEN',
        message = 'role admin required',
    }, 'req-1')
    t.assert_equals(code, 'FORBIDDEN')
    t.assert_equals(body.error.code, 'FORBIDDEN')
    t.assert_equals(body.error.message, 'role admin required')
    t.assert_equals(body.error.request_id, 'req-1')
end

g.test_rest_envelope_masks_internal_message = function()
    local body, code = rest_envelope.build('something secret /etc/foo', 'req-2')
    t.assert_equals(code, 'INTERNAL')
    -- Internal-error messages must NEVER leak file paths or stack
    -- traces; the envelope replaces them with a generic phrase.
    t.assert_equals(body.error.message, 'internal error')
    t.assert_equals(body.error.request_id, 'req-2')
    t.assert_equals(body.error.details, nil)
end

g.test_rest_envelope_handles_errors_rock_object = function()
    local errors = require('errors')
    local Cls = errors.new_class('TEST_CLS', { capture_stack = false })
    local err = Cls:new('boom %s', 'param')
    local body, code = rest_envelope.build(err, 'req-3')
    t.assert_equals(code, 'TEST_CLS')
    t.assert_equals(body.error.code, 'TEST_CLS')
    t.assert_equals(body.error.message, 'boom param')
end

g.test_rest_envelope_handles_nil = function()
    local body, code = rest_envelope.build(nil, 'req-4')
    t.assert_equals(code, 'INTERNAL')
    t.assert_equals(body.error.message, 'internal error')
end

-- ── GraphQL ──────────────────────────────────────────────────────────

g.test_graphql_envelope_basic_shape = function()
    local err = gql_envelope.format_error({
        code = 'VALIDATION_ERROR',
        message = 'field foo missing',
        request_id = 'req-5',
    })
    t.assert_equals(err.message, 'field foo missing')
    t.assert_equals(err.extensions.code, 'VALIDATION_ERROR')
    t.assert_equals(err.extensions.request_id, 'req-5')
end

g.test_graphql_envelope_masks_internal = function()
    local err = gql_envelope.format_error({
        code = 'INTERNAL',
        message = 'segfault details we should not leak',
        request_id = 'req-6',
        details = { internal_path = '/etc/secret' },
    })
    -- INTERNAL: message replaced and details dropped — keeps stack and
    -- file paths out of the wire response.
    t.assert_equals(err.message, 'internal error')
    t.assert_equals(err.extensions.code, 'INTERNAL')
    t.assert_equals(err.extensions.details, nil)
end

g.test_graphql_envelope_keeps_details_on_business_errors = function()
    local err = gql_envelope.format_error({
        code = 'VALIDATION_ERROR',
        message = 'invalid field',
        request_id = 'req-7',
        details = { field = 'foo' },
    })
    t.assert_equals(err.extensions.details.field, 'foo')
end

g.test_graphql_envelope_http_status_maps_known_codes = function()
    t.assert_equals(gql_envelope.http_status('VALIDATION_ERROR'), 400)
    t.assert_equals(gql_envelope.http_status('UNAUTHORIZED'), 401)
    t.assert_equals(gql_envelope.http_status('FORBIDDEN'), 403)
    t.assert_equals(gql_envelope.http_status('INTERNAL'), 500)
    t.assert_equals(gql_envelope.http_status('UNAVAILABLE'), 503)
    -- Unknown codes default to 500.
    t.assert_equals(gql_envelope.http_status('NOPE_NOT_REAL'), 500)
end
