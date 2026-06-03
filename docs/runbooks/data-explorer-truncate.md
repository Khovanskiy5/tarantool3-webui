# Data Explorer — Truncate space

## What it does

`truncateSpace(name, reset_sequence)` deletes every tuple in a user
space without dropping the space itself. The schema, indexes,
attached sequence, foreign keys, and constraints all stay in place.
Optionally the operator can ask the resolver to reset the attached
sequence so the next insert restarts from `start` (default 1).

It is the safe alternative to "drop and recreate" when the operator
wants a fresh data set without re-applying schema migrations.

## How to use it from the UI

1. Open `/data-explorer`.
2. Pick a user space from the sidebar.
3. Click the **Truncate** button between *Edit space* and *Drop* in
   the header.
4. Type the space name into the confirmation field. The Truncate
   button stays disabled until the input matches exactly.
5. Optionally tick **Reset attached sequence** — only meaningful when
   the space has a sequence. No-op when there is none.
6. Click **Truncate**. On success the grid reloads empty, the
   sidebar row count drops to 0, and the header meta refreshes.

The button is hidden entirely for system spaces (`_user`, `_priv`,
`_func`, …) and any name starting with `_`. The backend rejects
those names as well, so a direct API call cannot bypass the UI gate.

## How to use it from the API

GraphQL mutation:

```graphql
mutation Truncate($name: String!, $reset: Boolean) {
  truncateSpace(name: $name, reset_sequence: $reset) {
    ok
    name
    sequence_reset
    forwarded
    leader
  }
}
```

Variables:

```json
{ "name": "orders", "reset": true }
```

`sequence_reset` is `true` only when both conditions hold: the
operator asked for a reset AND the space had an attached sequence.
Otherwise it is `false` and no sequence was touched.

## Errors

| Code | Cause | Recovery |
|------|-------|----------|
| `FORBIDDEN` | Name is in the sensitive-space deny-list or starts with `_`. | System spaces are not truncatable via this surface — use dedicated mutations (`createUser`, `hotReloadModule`, …). |
| `NOT_FOUND` | Space does not exist. | Reload the sidebar; the space may have been dropped by another operator. |
| `TRUNCATE_INSIDE_TXN` | A transaction is currently open on the resolver fiber. | Commit or rollback the transaction first. Tarantool itself refuses to truncate inside a transaction; the resolver raises this structured error before reaching that internal check. |

## Operational notes

* The mutation is forwarded to the cluster leader automatically when
  the receiving instance is read-only — same path as the other DDL
  resolvers (see `backend/webui/graphql/resolvers/data_mutations/common.lua`
  `forward_ddl`).
* Audit trail: `space.truncate` action, scope `space:<name>`, payload
  carries the resolved space id and (when forwarded) the leader alias.
* Truncate is not transactional with the rest of your work: it
  bypasses synchronous replication's normal write path. If you need
  atomic "delete everything plus N other writes", use a transaction
  with explicit `:delete()` calls per primary key instead.
* Attached sequences keep their `current` value across truncate by
  default — Tarantool does not reset them automatically. The
  `reset_sequence: true` option exists to cover the common operator
  intent of "start over from 1 / start" after a truncate.

## Related

* `dropSpace` — destroys the space (schema + data).
* `dropIndex` — single index, leaves the space.
* `alterSpace` — change format / is_sync / rename.
