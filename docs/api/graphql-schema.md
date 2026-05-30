# GraphQL schema

Основная админ-поверхность — GraphQL по `POST /admin/api`. Этот документ описывает текущий контракт схемы. По мере реализации задач (Tasks 14, 18, 19, 20, 26, 30…) сюда добавляются новые типы, queries и mutations.

Документ ведётся вручную для удобства чтения. Сгенерированный SDL — артефакт релиза (`webui-schema-<ver>.graphql`), создаётся в Task 8 пайплайном `make dump-schema`.

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

JSON-encoded **JSON Schema** cluster config, как её отдаёт нативный `config:jsonschema()` Tarantool. Это единый источник истины для валидации конфига на backend (Task 32) и для Monaco-autocomplete на frontend (Task 38). Возвращает `null`, если модуль `config` недоступен (нестандартные тестовые конфигурации).

```graphql
query { configJsonSchema }
```

Клиент парсит результат как JSON и подаёт в любой JSON-Schema-валидатор.

## Mutation

### `_noop: Boolean!`

Placeholder. Возвращает `true`. Удаляется как только появятся настоящие mutation'ы в Tasks 26+.

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

**Гейтинг:** включается через `roles_cfg.webui.graphiql_enabled = true`. По умолчанию выключен в prod. В Task 26 добавится RBAC (доступ только `admin` или `superuser`); сейчас фильтр — только по конфигу роли.

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

Используется в Task 8 для генерации TypeScript типов через `graphql-codegen` поверх SDL, дампимого из `tools/dump-schema.lua`.

## Roadmap

Новые типы и операции добавляются по задачам:

- **Task 14:** `Query.cluster` — топология (`Server`, `Replicaset`, `Label`).
- **Task 18:** `Query.cluster.servers` пагинация (Relay connection).
- **Task 19:** `Query.issues`, `IssueBase` интерфейс + конкретные `…Issue` типы.
- **Task 20:** `Query.suggestions` (union), `Mutation.applySuggestion`.
- **Task 26:** `Query.me`, `Mutation.login/logout` (REST), RBAC-фильтрация резолверов.
- **Task 28a:** `Query.authParams`, `Mutation.updateAuthParams`.
- **Task 34:** `Mutation.configPrepare/Commit/Abort`, `Query.configHistory`.
- **Tasks 40, 41:** `Query.spaces`, `Query.users` (read-only части уже в схеме — резолверы в `graphql/resolvers/admin_data.lua`). Mutations (`createSpace`, `setUserRoles`) поедут через двухфазный коммит.
- **Tasks 46, 47, 50, 51, 52:** failover, vshard, lifecycle mutations.

Каждое расширение проходит проверку на breaking (см. `docs/api/deprecation.md` после Task 21).
