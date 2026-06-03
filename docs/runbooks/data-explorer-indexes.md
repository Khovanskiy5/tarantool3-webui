# Data Explorer — Indexes

## What it is

DE-1.5 adds the **Indexes** collapsible panel to the SpaceView and
the `indexAction(space, index, action, key, iterator)` GraphQL
query that backs it. The panel lists every index of the selected
space (name, type, unique, parts) and exposes six read-only
inspection actions via a per-index dropdown menu:

| Action | Tarantool call                              | What it returns |
|--------|---------------------------------------------|-----------------|
| MIN    | `idx:min(key)`                              | The smallest tuple matching `key`. |
| MAX    | `idx:max(key)`                              | The largest tuple matching `key`. |
| RANDOM | `idx:random(seed)`                          | One tuple — seeded RNG. |
| COUNT  | `idx:count(key, {iterator = iter})`         | A numeric count. |
| STAT   | `idx:stat()`                                | Engine-specific stat table (memtx returns `{}` — vinyl is much richer). |
| BSIZE  | `idx:bsize()`                               | In-memory bytes used by the index. |

The panel is collapsed by default; clicking a Tools menu item
triggers a single GraphQL round-trip and renders the result inline
below the row. `Stat` opens a dialog because the nested structure
is unreadable as a flat inline string.

Add / Edit / Drop ship with DE-1.4. The panel intentionally lands
read-only so DE-1.5 can pay for itself today without waiting on
the heavier index-form work.

## How to use

1. Open `/data-explorer` and pick a user space.
2. Expand the **Indexes** panel.
3. Click **Tools** on any index → pick an action.
4. The result chip appears below the row. Click the × to clear.

Min / Max / Random show the tuple JSON (matches the format the
table grid uses). Count shows `count = N`. Bsize shows
`bsize = N B/KB/MB`. Stat opens a dialog with a pretty-printed
JSON of `idx:stat()` — empty `{}` for memtx, multi-level LSM
stats for vinyl.

## API

```graphql
query IndexAction(
  $space: String!
  $index: String!
  $action: IndexActionKind!
  $key: [Json]
  $iterator: IndexCountIterator
) {
  indexAction(space: $space, index: $index, action: $action,
              key: $key, iterator: $iterator) {
    action
    tuple    # MIN / MAX / RANDOM — nullable
    count    # COUNT — nullable
    bytes    # BSIZE — nullable
    stat     # STAT — nullable map
  }
}
```

`IndexActionKind` is one of `MIN | MAX | RANDOM | COUNT | STAT | BSIZE`.

`IndexCountIterator` is one of `EQ | GT | GE | LT | LE | REQ | ALL`.
Only consulted when `action = COUNT`. Defaults to `EQ` when a
`key` is supplied and `ALL` otherwise.

**Enum-variable gotcha:** the GraphQL server in this project
validates enum variables against the `.value` field, not the
symbol — sending `"COUNT"` as a variable crashes with
`Wrong variable "action" for the Enum`. The SPA round-trips
through `.toLowerCase()` to send the value (`"count"`); other
modules use the same trick for `FilterOp` (see
`DataExplorer.vue:loadTuples`). REST callers should follow the
same convention.

### Examples

Count all rows where `tag = 'b'` on the `by_tag` secondary:

```graphql
query {
  indexAction(
    space: "orders", index: "by_tag",
    action: COUNT, key: ["b"]
  ) {
    action count
  }
}
```

Range count `id > 5`:

```graphql
query {
  indexAction(
    space: "orders", index: "primary",
    action: COUNT, key: [5], iterator: GT
  ) {
    action count
  }
}
```

Min tuple under a prefix:

```graphql
query {
  indexAction(
    space: "users", index: "by_country",
    action: MIN, key: ["NL"]
  ) {
    tuple
  }
}
```

## RBAC

`viewer`+. Every action is read-only; the resolver does not even
load the mutation pipeline. Lives next to `spaceStats` /
`sequenceInfo` in the GRAPHQL_FIELD map.

## Errors

| Code | Cause |
|------|-------|
| `VALIDATION_ERROR` | Empty `space` / `index` / `action`; unknown `action`; unsupported `iterator`. |
| `NOT_FOUND` | The space or the named index does not exist. |
| `FORBIDDEN` | Caller lacks `viewer`. |

Engine-level errors from Tarantool propagate verbatim — e.g.
`idx:random` on an empty vinyl space, or `idx:count` with an
iterator the index does not support.

## Operational notes

* The resolver does NOT block the TX-thread on long scans — every
  call is a constant-time-ish `box.index` method. `idx:count`
  without a key is the only path that walks the index; Tarantool
  has a fast path for that case on memtx and a slower one on
  vinyl.
* `idx:random(seed)` uses a numeric seed. The resolver derives it
  from `clock.realtime()` if the caller does not pass one through
  `key` — two clicks in a row therefore return different rows.
* `Bsize` is the in-memory bytes used by the index ITSELF (the
  B-tree / hash / LSM metadata), not the tuples it references.
  Compare against the panel's `Stats` block for the tuple-side
  numbers.
* The panel renders for user spaces only (hides on `_*`). Reading
  `_space.index[0]:count()` from the operator console is fine
  but the panel intentionally does not expose system spaces — the
  numbers are not actionable.

## Related

* DE-1.4 (Index alter + extended options) — adds Add / Edit /
  Drop on the same panel.
* DE-1.7 (Space stats panel) — shows the per-space byte size /
  row count alongside the index numbers.
* DE-4.1 (Vinyl compaction trigger) — extends the panel with a
  per-vinyl-index Compact button + LSM-level breakdown.
