# Data Explorer — Binary fields

## What it is

DE-1.2 adds a dedicated editor for byte-valued tuple fields:
`varbinary` columns, and `string` columns whose stored bytes are
not valid UTF-8 (the backend escapes those into the
`{_binary_base64: "..."}` envelope). Both render through
`BinaryField.vue` inside the tuple insert / edit dialog instead of
a plain text input.

The component offers three switchable representations and file
import / export:

| View   | Behaviour |
|--------|-----------|
| Hex    | Classic 16-bytes-per-row hex dump with offset column + ASCII gutter. Read-only render. |
| Base64 | Editable textarea showing the canonical base64. Paste tolerates embedded whitespace / newlines. |
| UTF-8  | Editable textarea — only enabled when the bytes decode as strict UTF-8. Disabled with an `(invalid)` label otherwise. |

A size tag (`7 B` / `1.4 KB` / …) sits next to the view switch.
**Download** saves the raw bytes to `tuple-field.bin`; **Upload**
replaces the value with a file's bytes.

## v-model contract

`BinaryField` reads and writes the canonical envelope
`{ _binary_base64: <base64> }` — the same wire shape the backend's
`coerce_field` accepts on insert / replace. It also accepts a plain
string (treated as UTF-8 bytes) or `null` for "no bytes". TupleForm
decides per field whether to mount BinaryField:

* `type === 'varbinary'` → always binary.
* `type === 'string'` AND the stored value arrived as the
  `_binary_base64` envelope → binary (the bytes are not UTF-8 and
  the backend escaped them). Plain-text strings keep the regular
  InputText UX.

## Backend wire format (two bugs fixed in DE-1.2)

Getting the editor to work surfaced two pre-existing backend bugs
in `data_explorer/types.lua`:

1. **varbinary read.** Tarantool 3.x returns a `varbinary` column
   as a `varbinary` cdata, not a Lua string. The old `encode_field`
   hit the generic `cdata` branch and `tostring`'d it, shipping
   mojibake. Fixed: detect `varbinary.is(v)` and emit
   `{ _binary_base64 = base64(tostring(v)) }`.

2. **varbinary write.** `coerce_field` returned the unwrapped bytes
   as a plain Lua string, which Tarantool rejects with
   `FIELD_TYPE: expected varbinary, got string`. Fixed: wrap in
   `varbinary.new(value)` for `varbinary` columns.

A related NULL bug fell out of the same area:

3. **box.NULL.** A stored NULL in a nullable field reads back as
   the `box.NULL` cdata. `encode_field` used to `tostring` it into
   the literal string `"cdata<void *>: NULL"`. Fixed: map
   `box.NULL` to Lua nil, and have the wire encoders
   (`tuple_to_wire`, `tuple_to_graphql`, the index-action tuple
   projection) substitute the `box.NULL` sentinel back into the
   list so (a) the list keeps its length — a Lua-nil in the middle
   truncates it — and (b) `json.encode` renders it as JSON `null`.

## Tests

* `binary-helpers.spec.ts` (vitest) — roundtrips for ASCII,
  multi-byte UTF-8, arbitrary high bytes, the chunked large-buffer
  path, whitespace-in-base64, the empty payload, the envelope/
  plain-string normalisation, and strict UTF-8 rejection.
* `data_mutations_test.lua` (luatest) — varbinary insert via the
  envelope roundtrips byte-for-byte and re-encodes as the envelope;
  a box.NULL insert keeps all field positions and reports the
  sentinel (not the cdata string).

## Operational notes

* The hex view is render-only; edits go through Base64 or UTF-8.
  This keeps the parser simple and avoids the ambiguity of partial
  hex edits.
* Upload reads the whole file into memory — fine for the small
  blobs a tuple field typically holds. Multi-megabyte payloads are
  technically allowed but will be slow to render in hex.
* The download filename is fixed (`tuple-field.bin`); the operator
  renames on save. We do not infer an extension because the field
  type carries no MIME hint.

## Tuple msgpack view (DE-1.6)

The tuple edit dialog has a **Show msgpack** toggle that reveals the
row's raw msgpack representation through the same `BinaryField` in
read-only mode (Upload hidden; hex / base64 / utf-8 views + Download
stay). It is the on-disk byte layout, authoritative because the
backend encodes the actual stored box tuple — not a client-side
re-encode, which could differ in int width or ext types.

* **Backend.** The `tuples` query takes a `with_msgpack: Boolean`
  arg (default false). When true, `tuple_to_graphql` adds
  `msgpack` = base64 of `msgpack.encode(tuple)` to each row. Off by
  default so the common browse path skips the encode + base64 work;
  the SPA opts in with `with_msgpack: true` because it wants the
  feature, paying a few KB per page.
* **Frontend.** `TupleRow.msgpack` flows into `TupleForm` (edit mode
  only — create has no stored tuple). The toggle wraps the base64
  into the envelope and feeds it to a read-only `BinaryField`.

Example: a tuple `{1, "red"}` shows hex `92 01 a3 72 65 64`
(`92` = 2-element array, `01` = int 1, `a3` = fixstr len 3, then
`red`). The msgpack view renders **only Hex / Base64** — the
`hide-utf8` prop drops the UTF-8 tab there, because raw msgpack is
never valid UTF-8 (the framing bytes `0x92`, `0xa5`, … are
continuation bytes) so a permanently-disabled "UTF-8 (invalid)"
tab would just be noise. Regular binary fields keep all three
tabs; their UTF-8 tab activates when the bytes happen to be text
(e.g. a `varbinary` column holding `"hello world"`).

## Related

* `data_explorer/types.lua` — `encode_field` / `coerce_field`, the
  envelope producers / consumers.
