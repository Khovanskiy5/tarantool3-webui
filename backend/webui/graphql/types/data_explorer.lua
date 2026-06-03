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
        -- `truncated` = the resolver returned `limit` tuples and more
        -- pages exist. Combined with `next_cursor` this is normal
        -- pagination — the SPA renders a "Next" button.
        truncated    = types.boolean.nonNull,
        -- `scan_aborted` = the residual-filter walker bailed early
        -- (`scanned >= fetch_cap * 50`) to protect the TX-thread
        -- against a pathological filter. Unlike `truncated` this is
        -- a real problem: results are incomplete with no
        -- `next_cursor` to resume from. SPA renders a warning chip
        -- only when this flag is true.
        scan_aborted = types.boolean.nonNull,
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

M.FieldFormatInput = types.inputObject({
    name = 'FieldFormatInput',
    fields = {
        name        = types.string.nonNull,
        type        = types.string.nonNull,
        is_nullable = types.boolean,
    },
})

M.SpaceMutationResult = types.object({
    name = 'SpaceMutationResult',
    fields = {
        ok             = types.boolean.nonNull,
        name           = types.string.nonNull,
        id             = types.long,
        forwarded      = types.boolean,
        leader         = types.string,
        -- truncateSpace populates this when `reset_sequence: true`
        -- and the space had an attached sequence. Other mutations
        -- leave it nil.
        sequence_reset = types.boolean,
    },
})

M.Collation = types.object({
    name = 'Collation',
    description = 'A collation registered in `_collation`. The schema ' ..
        'editor surfaces these so an operator can pick one when ' ..
        'declaring a string index part. Mutations live in DE-2.5; ' ..
        'this type is read-only.',
    fields = {
        id       = types.long.nonNull,
        name     = types.string.nonNull,
        type     = types.string,
        locale   = types.string,
        icu_opts = M.Json,
    },
})

M.CollationsPayload = types.object({
    name = 'CollationsPayload',
    fields = {
        collations = types.list(M.Collation.nonNull).nonNull,
    },
})

-- Per-space tuple memory breakdown for memtx spaces (Tarantool
-- 3.7 emits this as `space:stat().tuple.memtx`). Vinyl spaces
-- return an empty table so this stays nil. `field_map_size`
-- captures the in-memory index entry overhead — useful when
-- evaluating column-heavy formats.
M.SpaceMemtxTupleStat = types.object({
    name = 'SpaceMemtxTupleStat',
    fields = {
        data_size       = types.long.nonNull,
        header_size     = types.long.nonNull,
        waste_size      = types.long.nonNull,
        field_map_size  = types.long.nonNull,
    },
})

-- Engine-wide vinyl summary. Per-space vinyl attribution is not
-- exposed by Tarantool 3.7 directly — operators inspecting a vinyl
-- space see the cluster totals here while the per-space `byte_size`
-- column above still answers "how big is THIS space on disk".
M.SpaceVinylStat = types.object({
    name = 'SpaceVinylStat',
    fields = {
        memory_tuple        = types.long.nonNull,
        memory_tuple_cache  = types.long.nonNull,
        memory_level0       = types.long.nonNull,
        memory_page_index   = types.long.nonNull,
        memory_bloom_filter = types.long.nonNull,
        disk_data_bytes     = types.long.nonNull,
        disk_data_compacted = types.long.nonNull,
        disk_index_bytes    = types.long.nonNull,
    },
})

-- `box.slab.info()` projection. The raw payload returns ratios as
-- printable strings (`"30.08%"`) — the resolver parses them into
-- floats so the SPA can drive a progress bar without re-parsing.
M.SlabInfo = types.object({
    name = 'SlabInfo',
    fields = {
        quota_size        = types.long.nonNull,
        quota_used        = types.long.nonNull,
        quota_used_ratio  = types.float.nonNull,
        items_size        = types.long.nonNull,
        items_used        = types.long.nonNull,
        items_used_ratio  = types.float.nonNull,
        arena_size        = types.long.nonNull,
        arena_used        = types.long.nonNull,
        arena_used_ratio  = types.float.nonNull,
    },
})

M.MemtxEngineData = types.object({
    name = 'MemtxEngineData',
    fields = {
        total      = types.long.nonNull,
        garbage    = types.long.nonNull,
        read_view  = types.long.nonNull,
    },
})

M.SpaceStats = types.object({
    name = 'SpaceStats',
    description = 'Per-space memory and disk metrics plus the ' ..
        'engine-wide context (slab arena summary, memtx data, ' ..
        'vinyl summary). Used by the Data Explorer "Stats" ' ..
        'collapsible panel — read-only, viewer-gated.',
    fields = {
        name         = types.string.nonNull,
        id           = types.long.nonNull,
        engine       = types.string.nonNull,
        byte_size    = types.long.nonNull,
        row_count    = types.long.nonNull,
        memtx_tuple  = M.SpaceMemtxTupleStat,
        vinyl_engine = M.SpaceVinylStat,
        slab         = M.SlabInfo.nonNull,
        memtx_data   = M.MemtxEngineData.nonNull,
    },
})

-- ── sequences (DE-1.3) ────────────────────────────────────────────

M.SequenceAttachment = types.object({
    name = 'SequenceAttachment',
    description = 'Where a sequence is attached. Populated from ' ..
        '`_space_sequence`. A standalone sequence has an empty list.',
    fields = {
        space = types.string.nonNull,
        field = types.long,
        path  = types.string,
    },
})

M.SequenceInfo = types.object({
    name = 'SequenceInfo',
    description = 'A `_sequence` row plus its current value and the ' ..
        'spaces it is attached to. `current` is nullable: Tarantool ' ..
        'only records a value after the first `:next()` / `:set()`, ' ..
        'so a fresh sequence reports null until used.',
    fields = {
        id           = types.long.nonNull,
        name         = types.string.nonNull,
        step         = types.long.nonNull,
        min          = types.long.nonNull,
        max          = types.long.nonNull,
        start        = types.long.nonNull,
        cache        = types.long.nonNull,
        cycle        = types.boolean.nonNull,
        current      = types.long,
        attached_to  = types.list(M.SequenceAttachment.nonNull).nonNull,
    },
})

M.SequenceMutationResult = types.object({
    name = 'SequenceMutationResult',
    fields = {
        ok        = types.boolean.nonNull,
        name      = types.string.nonNull,
        id        = types.long,
        current   = types.long,
        forwarded = types.boolean,
        leader    = types.string,
    },
})

M.SequenceCreateInput = types.inputObject({
    name = 'SequenceCreateInput',
    fields = {
        name          = types.string.nonNull,
        step          = types.long,
        min           = types.long,
        max           = types.long,
        start         = types.long,
        cache         = types.long,
        cycle         = types.boolean,
        if_not_exists = types.boolean,
    },
})

M.SequenceAlterInput = types.inputObject({
    name = 'SequenceAlterInput',
    fields = {
        name  = types.string.nonNull,
        step  = types.long,
        min   = types.long,
        max   = types.long,
        start = types.long,
        cache = types.long,
        cycle = types.boolean,
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
