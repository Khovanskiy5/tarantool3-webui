--
-- GraphQL types for the data-explorer surface.
--
-- We use a permissive `Json` scalar for tuple field values and
-- filter values, because Tarantool fields can be any of:
--   * scalars (int / string / boolean / double / decimal as string)
--   * uuid (stringified RFC4122)
--   * map / array (already JSON-friendly when emitted by the resolver)
--   * binary (wrapped as {"_binary_base64": "..."})
--
-- A strict GraphQL type per field would explode the schema and
-- block adding new Tarantool types without coordinated codegen
-- redeploys. The SPA already knows how to render each shape from
-- the SpaceInfo.format hint.
--

local json  = require('json')
local types = require('graphql.types')

local M = {}

-- Permissive JSON scalar. Inbound values from variables arrive
-- already parsed by the graphql-server (table/string/number/...);
-- inbound literals (rare, almost never used by SPA) arrive as the
-- raw AST node. We accept both.
M.Json = types.scalar({
    name = 'Json',
    description = 'Arbitrary JSON value: scalar, array, or object. ' ..
        'Tuple fields and filter values use this because Tarantool ' ..
        'allows any of: int / string / bool / double / decimal-as-' ..
        'string / uuid-as-string / map / array / binary (wrapped as ' ..
        '`{"_binary_base64": "..."}`).',
    serialize = function(v) return v end,
    parseValue = function(v) return v end,
    parseLiteral = function(node)
        if node.kind == 'string' or node.kind == 'enum'
            or node.kind == 'boolean' then
            return node.value
        end
        if node.kind == 'int' or node.kind == 'float' then
            return tonumber(node.value)
        end
        if node.kind == 'null' then return nil end
        -- For list / object literals, fall back to JSON-encoding
        -- the AST source if available; the graphql lib does not
        -- pass us the raw source so we degrade to nil rather than
        -- raise.
        return nil
    end,
    isValueOfTheType = function() return true end,
})

M.FilterOp = types.enum({
    name = 'FilterOp',
    description = 'AND-combined filter operators. `like` follows ' ..
        'SQL semantics (% = any sequence, _ = single char) and is ' ..
        'anchored to the full string.',
    values = {
        EQ     = { value = 'eq' },
        NE     = { value = 'ne' },
        GT     = { value = 'gt' },
        GE     = { value = 'ge' },
        LT     = { value = 'lt' },
        LE     = { value = 'le' },
        LIKE   = { value = 'like' },
        PREFIX = { value = 'prefix' },
    },
})

M.TupleFilterInput = types.inputObject({
    name = 'TupleFilterInput',
    fields = {
        field = types.string.nonNull,
        op    = M.FilterOp.nonNull,
        value = M.Json,
    },
})

M.FieldFormat = types.object({
    name = 'FieldFormat',
    fields = {
        name        = types.string.nonNull,
        type        = types.string.nonNull,
        is_nullable = types.boolean,
        collation   = types.string,
    },
})

M.Tuple = types.object({
    name = 'Tuple',
    fields = {
        fields    = types.list(M.Json).nonNull,
        pk_string = types.string.nonNull,
    },
})

M.TupleConnection = types.object({
    name = 'TupleConnection',
    fields = {
        items        = types.list(M.Tuple.nonNull).nonNull,
        next_cursor  = types.string,
        total        = types.long,
        partial_scan = types.boolean.nonNull,
        truncated    = types.boolean.nonNull,
        index_used   = types.string,
    },
})

-- ── mutation surface ────────────────────────────────────────────────

M.UpdateOpKind = types.enum({
    name = 'UpdateOpKind',
    description = 'Tarantool space:update() operators. SET/ADD/SUB ' ..
        'mirror the `=`/`+`/`-` symbolic forms. INSERT inserts a new ' ..
        'field at `field` position; DELETE drops `value` fields ' ..
        'starting at `field` (value defaults to 1).',
    values = {
        SET    = { value = 'set' },
        ADD    = { value = 'add' },
        SUB    = { value = 'sub' },
        BAND   = { value = 'band' },
        BOR    = { value = 'bor' },
        BXOR   = { value = 'bxor' },
        SPLICE = { value = 'splice' },
        INSERT = { value = 'insert' },
        DELETE = { value = 'delete' },
    },
})

M.UpdateOpInput = types.inputObject({
    name = 'UpdateOpInput',
    fields = {
        op    = M.UpdateOpKind.nonNull,
        -- `field` accepts either a string name (resolved through
        -- the space format) or a 1-based numeric index. The Json
        -- scalar handles both shapes.
        field = M.Json.nonNull,
        value = M.Json,
    },
})

M.TupleMutationResult = types.object({
    name = 'TupleMutationResult',
    fields = {
        ok        = types.boolean.nonNull,
        before    = types.list(M.Json),
        after     = types.list(M.Json),
        forwarded = types.boolean,
        leader    = types.string,
    },
})

-- Re-export json encode for callers that need to stringify
-- mismatched scalar payloads at the resolver boundary.
M._json = json

return M
