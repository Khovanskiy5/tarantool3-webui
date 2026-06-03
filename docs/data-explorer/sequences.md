# Data Explorer — Sequences

## What it is

Tarantool sequences are auto-increment generators backed by the
`_sequence` system space. An index part can opt in via
`sequence = <name>` at create / alter time; on every insert
Tarantool calls `seq:next()` to fill the field if the operator
left it nil.

The Data Explorer's "Sequence" collapsible panel (DE-1.3) sits in
the SpaceView header when the selected space has an attached
sequence (`spaceInfo.sequence` is non-null) and surfaces the
operator-level CRUD: view info, set the next-issued value, reset,
alter options, drop.

Attaching a sequence to an index lives in DE-1.4 (Index alter +
extended options). Until then the panel only manages sequences
that are already bound to a primary index.

## What the panel shows

The header tag advertises the current value:

* `unused` — the sequence has never been advanced (no
  `_sequence_data` row). `current` is null.
* `current: N` — last value returned by `:next()` / `:set()`.

When expanded, the grid lists every static field from `_sequence`
plus the live current value:

| Field    | Meaning |
|----------|---------|
| `current`| Last value handed out. `—` when unused. |
| `start`  | The value `:reset()` returns to. |
| `step`   | Increment per `:next()` call. Negative is allowed. |
| `min`    | Lower bound (inclusive). |
| `max`    | Upper bound (inclusive). |
| `cache`  | Pre-allocation hint — 0 disables. |
| `cycle`  | Wrap-around at min/max boundary. |
| `id`     | Tuple id in `_sequence`. |

If the sequence drives more than one index, the panel renders an
inline `Shared sequence` info banner listing every bound space.
That signals the drop will fail until every binding is detached.

## Actions

### Set value…

Opens a dialog that takes an integer and calls `seq:set(value)`.
The next `:next()` returns `value + step`. Useful after a bulk
import that pre-populated rows out of band — set the value to the
highest id so subsequent inserts pick up cleanly.

### Reset

Drops the `_sequence_data` row so the next `:next()` restarts from
`start`. The panel re-renders with `current = —` and the header
tag flips back to `unused`. Auditable as `sequence_reset`.

The same effect is offered by the Truncate Space action (DE-1.1)
when the `Reset attached sequence` checkbox is ticked.

### Alter…

Opens a dialog with every editable option (step, min, max, start,
cache, cycle). Empty fields keep the current value. Bound to
`box.sequence[name]:alter(opts)` — Tarantool validates the new
options against the existing value, so e.g. setting `min` higher
than the current value will error out.

### Drop

Confirms via `DestructiveActionDialog` (type the sequence name)
and calls `box.schema.sequence.drop`. Fails with
`SEQUENCE_HAS_REFERENCES` while the sequence is still attached to
an index — detach first via `alterIndex({sequence: false})` (DE-1.4).

## API

### Query

```graphql
query SequenceInfo($name: String!) {
  sequenceInfo(name: $name) {
    id name step min max start cache cycle current
    attached_to { space field path }
  }
}
```

* `current` is null when the sequence has never been advanced.
* `attached_to` walks `_space_sequence` and resolves space ids to
  names. An empty list means the sequence is standalone.

### Mutations

```graphql
mutation Create($input: SequenceCreateInput!) {
  sequenceCreate(input: $input) { ok name id current }
}

mutation Alter($input: SequenceAlterInput!) {
  sequenceAlter(input: $input) { ok name id current }
}

mutation Set($name: String!, $value: Long!) {
  sequenceSet(name: $name, value: $value) { ok name current }
}

mutation Reset($name: String!) {
  sequenceReset(name: $name) { ok name current }
}

mutation Drop($name: String!) {
  sequenceDrop(name: $name) { ok name }
}
```

Every mutation forwards to the cluster leader via the same path as
`createSpace` / `dropIndex` (`webui_space_mutation_remote` with a
`sequence_*` op prefix). Audit records carry `action = "sequence_*"`,
`scope = "space:<name>"` — but the "space" namespace is reused as
the audit scope umbrella for both sequences and indexes so the
audit cross-link (DE-7.2) finds them under one filter.

### RBAC

| Operation              | Role    | Reason |
|------------------------|---------|--------|
| `sequenceInfo`         | viewer  | Read-only metadata, mirrors `spaceStats`. |
| `sequenceCreate`       | admin   | Adds an `_sequence` row. |
| `sequenceAlter`        | admin   | Rewrites an `_sequence` row. |
| `sequenceSet`          | admin   | Writes a `_sequence_data` row. |
| `sequenceReset`        | admin   | Deletes the `_sequence_data` row. |
| `sequenceDrop`         | admin   | Removes the `_sequence` row. |

`superuser` is not required because sequences live in a regular
user-writable system space (not the `auth.*` lineage).

## Errors

| Code | Cause | Recovery |
|------|-------|----------|
| `NOT_FOUND` | Sequence does not exist. | Refresh the spaces list — it may have been dropped by another operator. |
| `FORBIDDEN` | Caller lacks the role above, or the requested name lives in the `_*` namespace. | Use a non-system name. |
| `VALIDATION_ERROR` | Empty name or non-integer `value` on `sequenceSet`. | Fix the input. |
| `SEQUENCE_HAS_REFERENCES` | Drop while still attached. | Detach via `alterIndex({sequence: false})` (DE-1.4). |
| `ER_UNSUPPORTED` | `seq:alter` got a key Tarantool's strict whitelist does not accept. | Use only the documented options. |

## Operational notes

* The current value is not replicated lazily — it lives in
  `_sequence_data`, which is replicated like any other space. A
  follower's `seq:current()` reflects the same value the leader
  reports (within the usual replication lag window).
* Sequences carry no privileges of their own — the `owner` column
  in `_sequence` only records who created them and does NOT gate
  use. Any role with insert access to the bound space can drive
  the sequence implicitly via `:next()`.
* `cache > 0` reserves a chunk of the range per worker process to
  avoid round-trips, at the cost of "wasted" ids on restart.
  Reset clears the cache too.
* Negative `step` makes the sequence descending — `start` then
  defaults to `max`, and the `cycle` boundary moves to `min`.

## Related

* `box.schema.sequence.create` — the underlying Tarantool API.
* `box.space._sequence` / `box.space._sequence_data` — the system
  spaces. The runbook for `_collation` (DE-1.4a) explains the same
  pattern of "read system space, project user-friendly subset".
* DE-1.4 — index alter, including `sequence: <name>` and
  `sequence: false` for attach / detach.
* DE-1.1 — truncate space with `reset_sequence: true`.
