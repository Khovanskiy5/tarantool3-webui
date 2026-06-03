# Data Explorer — Space stats

## What it does

The Data Explorer's "Stats" collapsible panel (DE-1.7) projects
Tarantool's native memory and disk counters onto the SpaceView so
operators can size a space without leaving the page or opening a
console session. Backed by a single `spaceStats(name)` GraphQL
query — read-only, viewer-gated.

The panel is collapsed by default. The GraphQL round-trip only
fires when the operator expands it the first time per space — the
counters move slowly enough that a per-click refresh beats
polling.

## What the numbers mean

### Space

| Field      | Source                | Meaning |
|------------|-----------------------|---------|
| `size`     | `box.space.X:bsize()` | Bytes used by tuples in this space. For vinyl this is the on-disk size of the LSM. |
| `rows`     | `box.space.X:count()` | Number of tuples. For vinyl this counts the merged view, not raw runs. |
| `id`       | `box.space.X.id`      | Numeric space id. Useful when correlating with `_space` or with WAL records. |
| `engine`   | `box.space.X.engine`  | `memtx` or `vinyl`. Drives which sub-sections render. |

### Memtx tuple memory (memtx only)

Mirrors `box.space.X:stat().tuple.memtx`. Vinyl spaces hide this
section because Tarantool returns an empty table there.

| Field         | Meaning |
|---------------|---------|
| `data`        | Bytes spent on the actual tuple payload (the values you inserted). |
| `header`      | Per-tuple metadata overhead. Stays roughly proportional to `rows`. |
| `waste`       | Bytes allocated but unused by the slab allocator (fragmentation tax). High waste relative to data is a sign of churn — consider a snapshot rotation. |
| `field map`   | In-memory index entry overhead. Grows with column-heavy formats. |

### Slab arena (cluster-wide)

Three progress bars driven by `box.slab.info()` ratios. The raw
payload returns these as printable strings (`"30.08%"`) — the
resolver parses them into floats so the SPA can power the bar
directly.

| Bar    | Meaning |
|--------|---------|
| `quota` | `quota_used / quota_size` — total memory the slab allocator is allowed to claim from the OS. Hard ceiling. The progress bar is the primary out-of-memory indicator. |
| `arena` | `arena_used / arena_size` — memory the allocator has already grabbed from the OS. Tracks `quota` up to the high-water mark. |
| `items` | `items_used / items_size` — memory currently in tuples vs allocated slabs. Useful for fragmentation analysis. |

**Reading the gauge:** the `quota` bar is the one to monitor. If
it pushes past 80% and `arena` is also high, you are running out
of memory and should plan to grow `box.cfg.memtx_memory` (or shed
data). If `quota` is high but `arena` is low, the allocator is
holding back — usually harmless.

### Memtx engine (cluster-wide)

Snapshot of `box.stat.memtx().data`:

| Field        | Meaning |
|--------------|---------|
| `total`      | Bytes the memtx engine is currently using for tuples (sum across every space + auxiliary data). |
| `garbage`    | Memory marked unused, freed lazily on the next allocation. Persistent non-zero `garbage` is fine. |
| `read view`  | Memory pinned by open read views. Should be 0 unless an explicit `box.read_view.open` is active. DE-3.1 brings the read-view UI. |

### Vinyl engine (cluster-wide, vinyl only)

Renders only when the selected space is vinyl. The numbers are
engine-wide — Tarantool 3.7 does not expose per-space vinyl LSM
attribution, so the section answers "what is the vinyl footprint
in this cluster" rather than "in this space".

| Field              | Source                                | Meaning |
|--------------------|---------------------------------------|---------|
| `memory tuple`     | `box.stat.vinyl().memory.tuple`       | Tuples currently buffered in memory. |
| `tuple cache`      | `box.stat.vinyl().memory.tuple_cache` | Read cache. |
| `level 0`          | `box.stat.vinyl().memory.level0`      | In-memory level-0 (newest writes, pre-dump). |
| `page index`       | `box.stat.vinyl().memory.page_index`  | In-memory page index for disk pages. |
| `bloom`            | `box.stat.vinyl().memory.bloom_filter`| Bloom filter footprint. |
| `disk data`        | `box.stat.vinyl().disk.data`          | Raw disk bytes used by data pages. |
| `compacted`        | `box.stat.vinyl().disk.data_compacted`| Bytes reclaimed by the latest compaction pass. |
| `disk index`       | `box.stat.vinyl().disk.index`         | Disk bytes used by indexes. |

Per-LSM-level breakdown and compaction throughput land in DE-4.1
together with the manual compaction trigger.

## API

```graphql
query SpaceStats($name: String!) {
  spaceStats(name: $name) {
    name id engine byte_size row_count
    memtx_tuple { data_size header_size waste_size field_map_size }
    vinyl_engine {
      memory_tuple memory_tuple_cache memory_level0
      memory_page_index memory_bloom_filter
      disk_data_bytes disk_data_compacted disk_index_bytes
    }
    slab {
      quota_size quota_used quota_used_ratio
      items_size items_used items_used_ratio
      arena_size arena_used arena_used_ratio
    }
    memtx_data { total garbage read_view }
  }
}
```

Variables:

```json
{ "name": "orders" }
```

Errors:

| Code | Cause |
|------|-------|
| `VALIDATION_ERROR` | `name` empty. |
| `NOT_FOUND`        | The space does not exist. |
| `FORBIDDEN`        | Caller lacks the `viewer` role. |
| `UNAVAILABLE`      | `box` is not yet initialised (very early boot). |

## RBAC

`viewer`+. The query exposes only counters — no `auth.*`, no raw
tuple data — so the same gate as `tuplesQuery` applies.

## Operational notes

* The panel is hidden for system spaces (`_user`, `_priv`, …). The
  slab gauge would still be correct, but per-space numbers for
  system spaces add no operator value.
* No realtime polling. The panel re-queries when the operator
  picks a different space or clicks "Reload".
* The slab counters are cluster-wide, not space-wide. They are
  the same in every space's panel; we show them inline because
  comparing a space's footprint against the global quota is the
  most common operator question.
* Per-LSM-level vinyl breakdown and dump/compaction triggers land
  in DE-4.1 (Vinyl compaction trigger).

## Related

* `box.space.X:bsize()` — raw byte size, also surfaced in the
  sidebar.
* `box.stat.memtx()` / `box.stat.vinyl()` — engine totals.
* `box.slab.info()` — slab arena summary.
* DE-4.1 — vinyl compaction trigger + LSM-level breakdown.
