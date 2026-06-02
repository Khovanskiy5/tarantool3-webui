# Data Explorer — backend architecture

Operational reference for the `/data-explorer` backend in `backend/webui/graphql/resolvers/data_mutations/`. Aimed at engineers adding a new resolver, debugging a forwarded mutation, or reviewing the deny-list path.

## Module layout

```
backend/webui/graphql/resolvers/
├── data_mutations.lua             ← 4-line shim, kept so the Lua loader
│                                    finds the package whether it picks
│                                    `data_mutations.lua` or
│                                    `data_mutations/init.lua` first.
└── data_mutations/
    ├── init.lua                   ← facade. Hard cap ≤ 80 lines.
    │                                Pure `require` + explicit re-export.
    │                                Pinned by data_mutations_facade_test.lua.
    ├── common.lua                 ← shared helpers, RBAC gate,
    │                                SENSITIVE_SPACES table, format
    │                                / pk introspection, forward_dml,
    │                                forward_ddl, tuple_to_wire,
    │                                audit_record, UPDATE_OPS alias.
    ├── tuple.lua                  ← tuple_insert / replace / update /
    │                                delete + local_apply table re-used
    │                                by remote.lua.
    ├── space.lua                  ← createSpace / dropSpace /
    │                                alterSpace. Also owns the shared
    │                                DDL dispatcher `ddl_apply` re-used
    │                                by index.lua.
    ├── index.lua                  ← createIndex / dropIndex.
    ├── remote.lua                 ← `remote_entry` (DML) and
    │                                `space_remote_entry` (DDL). Both
    │                                receivers re-enforce the deny-list
    │                                and audit on the leader side.
    ├── sequence.lua               ← placeholder for sequence ops.
    └── bulk.lua                   ← placeholder for bulk import/export.
```

`init.lua` is intentionally tiny. The hard cap and full export list are pinned by `backend/test/unit/data_mutations_facade_test.lua` — that test will fail if anyone adds business logic to the facade or removes a public name without going through every consumer first.

## Dependency rules

```
remote.lua → tuple.lua, space.lua, index.lua, common.lua
index.lua  → space.lua, common.lua
space.lua  → common.lua
tuple.lua  → common.lua
common.lua → (nothing inside this package)
init.lua   → all of the above
```

`common.lua` is the foundation; nothing inside the package may `require` it transitively in a way that produces a cycle. If you find yourself wanting `common.lua` to depend on another submodule, the helper you are about to put there belongs in that submodule instead.

## Adding a new resolver

1. Pick the right submodule by topic. Tuple-level CRUD → `tuple.lua`. Space DDL → `space.lua`. Index DDL → `index.lua`. Anything else gets its own submodule (the placeholders `sequence.lua` and `bulk.lua` are there for exactly that purpose).
2. Inside the submodule:
   - Use `common.require_role(root, 'graphqlFieldName')` for RBAC.
   - Use `common.assert_safe_space(name, op)` for tuple-level work or `common.assert_safe_ddl(name, op)` for DDL.
   - On followers (`common.is_read_only()` returns true), forward via `common.forward_dml` (DML) or `common.forward_ddl` (DDL). The shared `space.ddl_apply` dispatcher already wires this for every DDL op.
   - Audit with `common.audit_record({ user, action, scope, payload, request_id })`.
3. Register the new public function in `data_mutations/init.lua` with a single explicit assignment. **Do not** add `for k, v in pairs(...) do M[k] = v end` loops — silent name collisions are a known foot-gun and the facade contract test refuses to ship that pattern. If you go over 80 lines, the helper you just added belongs in `common.lua` or its own submodule.
4. Wire the GraphQL surface in `backend/webui/graphql/schema.lua` to point at the new public name.

## Deny-list and the `_` namespace

`common.SENSITIVE_SPACES` is the single source of truth for system spaces the GraphQL surface refuses to mutate at the tuple level (`_user`, `_priv`, `_func`, `_schema`, `_cluster`, `_session_settings`). Reads stay open under admin with masked credentials.

`common.assert_safe_ddl` adds a wider ban on any space whose name starts with `_` — Tarantool reserves that namespace for system spaces, and dedicated mutations (`createUser`, `hotReloadModule`, …) own those flows.

The DML receiver (`remote.remote_entry`) and DDL receiver (`remote.space_remote_entry`) both re-check the deny-list before doing anything else — a misbehaving follower cannot bypass the resolver guard by calling the receiver directly.

## Forward-to-leader

Two flavours, both go through the same `cluster.state.find_leader()` / `cluster.peers.get(leader_alias)` path with a 5-second `net.box:call` timeout:

- `common.forward_dml(op, space, payload, root)` → calls `webui_data_mutation_remote` on the leader. The leader-side handler is `remote.remote_entry`.
- `common.forward_ddl(op, payload, root)` → calls `webui_space_mutation_remote` on the leader. The leader-side handler is `remote.space_remote_entry`, which routes by op-prefix (`space_*` / `index_*`) to the matching `local_apply` table.

Both helpers tolerate a transport failure (pcall around the `net.box` call), an in-band error (response shaped as `{ _error = '...' }`), and a "leader is gone" failure (no peer connection). All three surface as a Lua error in the calling resolver so the user-facing GraphQL response is shaped exactly like the local-path error.

## Audit

Every state-changing path writes one audit entry. Followers write a "forwarded_to" entry on top of whatever the leader records, so the operator's intent is visible from the instance the user actually clicked on regardless of which peer accepted the write.

Audit calls are wrapped in `common.audit_record`, which pcall's the underlying sink — a broken audit pipeline must not break the user's operation.

## Lint and tests

- `make lint-backend` — luacheck across the package.
- `.rocks/bin/luatest backend/test/unit/data_mutations_test.lua` — 47 tests covering the public surface (CRUD happy paths, sensitive guard, RBAC, forward-to-leader, all update op codes, DDL e2e).
- `.rocks/bin/luatest backend/test/unit/data_mutations_facade_test.lua` — 3 tests pinning the facade contract (80-line cap, full export list, shim = init).

## Known limitations carried over from the previous monolith

- `:` (splice) update op passes `value` through as a single coerced field; Tarantool's wire protocol expects the triple `{position, length, replacement}` instead, so the op-code reaches the engine but the call fails with "wrong number of arguments". This is pinned as a known-limitation regression test (`test_update_op_splice_known_limitation`) so the refactor does not silently fix or worsen it. A proper splice path is out of scope for the refactor — track it separately when the data-explorer needs it.
