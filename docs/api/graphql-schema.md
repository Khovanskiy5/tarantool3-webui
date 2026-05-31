[← Development](../development.md) · [Back to README](../../README.md) · [REST API →](rest.md)

# GraphQL schema

Основная админ-поверхность — GraphQL по `POST /admin/api`. Этот документ описывает контракт схемы.

Документ ведётся вручную для удобства чтения. Сгенерированный SDL — артефакт сборки (`frontend/src/shared/api/schema.graphql`), создаётся пайплайном `make dump-schema`.

## Транспорт

- **Endpoint:** `POST /admin/api`
- **Content-Type запроса:** `application/json`
- **Тело запроса:**
  ```json
  { "query": "…GraphQL document…", "variables": { … }, "operationName": "…" }
  ```
- **Тело ответа:**
  ```json
  { "data": { … }, "errors": [ … ] }
  ```
- **HTTP-коды:**
  - `200` — успешное выполнение (или частичный успех с `errors[]`).
  - `400` — `INVALID_QUERY` или `VALIDATION_ERROR` (тело — стандартный GraphQL envelope).
  - `503` — `UNAVAILABLE`, GraphQL сервер не инициализирован.
  - `500` — `INTERNAL`, резолвер упал. Реальное сообщение в structured-логе по `request_id`.

Полный каталог `code` — `docs/api/error-codes.md`.

## Naming conventions

- Объектные типы и скаляры: `PascalCase` (`RoleStatus`, `Server`, `Issue`).
- Поля и аргументы: `camelCase` (`uptimeSec`, `replicasetName`).
- Enum-значения: `UPPER_SNAKE_CASE` (`ISSUE_SEVERITY_WARNING`).
- Mutation-имена: `verbObject` (`configCommit`, `expelInstance`).
- Input-типы: суффикс `Input`.
- Payload-типы (для mutations): суффикс `Payload`.

## Error envelope

```json
{
  "errors": [
    {
      "message": "human-readable",
      "extensions": {
        "code": "STABLE_CODE",
        "request_id": "uuid"
      },
      "locations": [{ "line": N, "column": N }],
      "path": ["field", "path"]
    }
  ]
}
```

`code` стабилен и является частью API-контракта. `INTERNAL` маскирует реальное сообщение — диагностика находится в structured-логе по `request_id`.

## Query

### `ping: String!`

Liveness check. Возвращает строку `"pong"`.

### `serverTime: String!`

ISO 8601 UTC текущее время на отвечающем инстансе, с микросекундной точностью.

```graphql
query { serverTime }   # → "2026-05-30T16:35:34.626560Z"
```

### `webuiVersion: String!`

SemVer этого WebUI rock'а.

```graphql
query { webuiVersion }   # → "0.1.0"
```

### `roleStatus: RoleStatus!`

Снимок lifecycle роли webui на отвечающем инстансе. См. тип ниже.

```graphql
query {
  roleStatus {
    state
    version
    tarantool
    instance
    uptimeSec
    logLevel
  }
}
```

### `configJsonSchema: String`

JSON-encoded **JSON Schema** cluster config, как её отдаёт нативный `config:jsonschema()` Tarantool. Это единый источник истины для валидации конфига на backend и для Monaco-autocomplete на frontend. Возвращает `null`, если модуль `config` недоступен (нестандартные тестовые конфигурации).

```graphql
query { configJsonSchema }
```

Клиент парсит результат как JSON и подаёт в любой JSON-Schema-валидатор.

## Mutation

### `_noop: Boolean!`

Placeholder. Возвращает `true`. Сохранён для введения unit-теста на GraphQL-execute path; рабочие мутации перечислены в `operations.md` и `rbac-matrix.md`.

### Cluster operator controls (Cartridge-style)

Четыре мутации меняют топологию кластера атомарно — через тот же 2PC pipeline, что и обычный `commitConfig`. Audit, fan-out reload, etcd-mirror на disk работают одинаково для всех.

Принцип: **`editTopology` — primary**, остальные три композируют через него же. `apply: true` коммитит сразу; `apply: false` (default для preview-форм) возвращает `prepared_id` для подтверждения через `commitConfig`. RBAC: все четыре требуют `admin`.

#### `editTopology(input: String!): TopologyEditResult!`

JSON-входной параметр — `{ servers: [...], replicasets: [...], apply: bool }`. Атомарно: любой ошибочный edit откатывает всю партию. `input` принимается строкой, потому что nested-spec инстансов = вся Tarantool 3.x instance schema; описывать её GraphQL InputObject'ом — гарантированный drift при каждом релизе Tarantool.

`ServerEdit`: `{ alias, mode?: "rw"|"ro", uri?, listen?, zone?, labels?, target_group?, target_replicaset? }`.
`ReplicasetEdit`: `{ name, group?, roles?, leader?, failover_priority?, weight?, vshard_group?, all_rw?, join_instances?: {alias: spec}, expel_instances?: [alias] }`.

Возможные коды ошибок: `VALIDATION_ERROR` (плохой JSON), `TOPOLOGY_EDIT_FAILED` (per-edit нарушение типа/шейпа), `VALIDATION_FAILED` (final YAML не проходит cross-validators), `NO_CHANGES`, `UNAVAILABLE` (etcd недоступен), `COMMIT_FAILED`.

```graphql
mutation Edit($i: String!) {
  editTopology(input: $i) {
    prepared_id
    applied
    revision
    diff_summary
    message
  }
}
```

#### `setReplicasetRoles(replicaset: String!, roles: [String!]!, apply: Boolean): TopologyEditResult!`

Типизированная обёртка над editTopology с одним ReplicasetEdit — меняет список ролей на указанном replicaset. Defaults to `apply: true`.

#### `createReplicaset(input: String!): TopologyEditResult!`

JSON-вход `{ name, group, instances?: {alias: instance-spec}, roles?, leader?, failover_priority?, weight?, vshard_group?, apply? }`. Валидирует, что `leader` входит в `instances`, что `failover_priority` — subset инстансов, что `weight ≥ 0`. Создаёт новый replicaset одной атомарной мутацией.

#### `editReplicaset(input: String!): TopologyEditResult!`

JSON-вход — частичный апдейт replicaset: roles/leader/failover_priority/weight/vshard_group/all_rw + `join_instances` (добавить) или `expel_instances` (удалить). На expel response получает прибавку про необходимость ручного rebalance vshard buckets.

### `TopologyEditResult`

```graphql
type TopologyEditResult {
  prepared_id: String       # null when apply=true succeeded
  expires_at: Float
  diff_summary: [String!]!  # bounded "op /path" list (+50 truncation)
  applied: Boolean!
  revision: Long!           # 0 when apply=false
  message: String
}
```

## Types

### `RoleStatus`

```graphql
type RoleStatus {
  "uninitialized | starting | ready | stopping | stopped"
  state: String!
  "WebUI rock SemVer"
  version: String!
  "Tarantool runtime version (_TARANTOOL)"
  tarantool: String!
  "Instance alias from box.info, null pre-bootstrap"
  instance: String
  "Epoch seconds when the role transitioned to ready"
  startedAt: Float
  "Seconds since the role transitioned to ready"
  uptimeSec: Float!
  "Current effective log level"
  logLevel: String!
}
```

## GraphiQL Explorer

`GET /admin/api/explore` — self-contained минимальный explorer. Не GraphiQL (полная GraphiQL весит ~1 МБ и требует React); embedded версия — текстовое поле для query, отправка через `POST /admin/api`, отображение ответа в JSON. Подходит для быстрых проверок и smoke-тестов.

**Гейтинг:** включается через `roles_cfg.webui.graphiql_enabled = true`. По умолчанию выключен в prod. RBAC: `admin`.

**CSP**: на этот единственный route релаксируется до `script-src 'self' 'unsafe-inline'` (для inline-скрипта explorer'а). Никакие внешние ресурсы не загружаются.

## Introspection

Поддерживается стандартный `__schema`:

```graphql
query {
  __schema {
    queryType { name }
    mutationType { name }
    types { name }
  }
}
```

Используется для генерации TypeScript типов через `graphql-codegen` поверх SDL, дампимого из `tools/dump-schema.lua`.

## Эволюция схемы

- **Удаление поля / типа** или **изменение nullability** — breaking change. Помечается `@deprecated(reason: "...")` в одной версии, удаляется минимум через одну minor.
- **Добавление поля / типа / аргумента с дефолтом** — non-breaking.
- **Сужение возвращаемого типа** (например, `T → T!`) — breaking. Расширение (`T! → T`) — breaking для клиентов, которые опираются на non-null guarantee.

CI gate: после каждого backend-изменения PR обязан включать regenerated `frontend/src/shared/api/__generated/{gql,graphql}.ts`. Drift между SDL и сгенерированными TS — CI failure.

## See Also

- [REST API](rest.md) — auth, eval, metrics, health, config IO
- [Error codes](error-codes.md) — стабильные коды ошибок
- [RBAC matrix](../rbac-matrix.md) — требуемая роль для каждой query/mutation
