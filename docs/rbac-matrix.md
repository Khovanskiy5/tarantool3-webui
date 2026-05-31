[← Security](security.md) · [Back to README](../README.md) · [Troubleshooting →](troubleshooting.md)

# RBAC matrix

Полная матрица: какие роли могут вызывать какие операции. Источник истины — `backend/webui/auth/rbac.lua`.

## Роли (по возрастанию полномочий)

| Роль | Назначение |
|---|---|
| `public` | Без сессии. Доступны `GET /api/health`, `GET /api/metrics`, `POST /api/auth/login`, `POST /api/auth/logout`, `GET /ws` (handshake). |
| `viewer` | Read-only: видит весь кластер, конфиг, audit (no), issues, suggestions, schema, vshard. |
| `operator` | + propose/abort config, validate, labels на инстансах. Не может committin'ить. |
| `admin` | + commit config, manage users, lifecycle (promote/expel/join), vshard weights/groups, snapshots, webhooks, audit, diagnostics. |
| `superuser` | + Lua/SQL console, hotreload модулей. Минимально-привилегированная роль с полным runtime-доступом. |

Иерархия — строго ранговая: `superuser` может всё, что `admin`, который может всё, что `operator`, и так далее.

## REST endpoints

| Метод | Путь                       | Требуемая роль |
|-------|----------------------------|----------------|
| GET   | `/api/health`              | public         |
| GET   | `/api/metrics`             | public         |
| GET   | `/api/metrics/webui`       | public         |
| POST  | `/api/auth/login`          | public         |
| POST  | `/api/auth/logout`         | public         |
| GET   | `/api/auth/me`             | session        |
| GET   | `/ws`                      | public (handshake), затем session-валидация |
| GET   | `/api/snapshots`           | admin          |
| POST  | `/api/snapshots/take`      | admin          |
| GET   | `/api/config/download`     | admin          |
| POST  | `/api/config/upload`       | admin          |
| POST  | `/api/eval`                | superuser      |
| GET   | `/api/diagnostics/bundle`  | admin          |
| POST  | `/admin/api` (GraphQL)     | session (per-field в резолверах) |
| GET   | `/admin/api/explore` (GraphiQL) | admin     |

## GraphQL Query

| Поле                   | Требуемая роль |
|------------------------|----------------|
| `cluster`              | viewer         |
| `config`               | viewer         |
| `schema`               | viewer         |
| `users`                | admin          |
| `audit`                | admin          |
| `issues`               | viewer         |
| `issuesSummary`        | viewer         |
| `suggestions`          | viewer         |
| `metrics`              | viewer         |
| `health`               | viewer         |
| `failover`             | admin          |
| `failoverStateProviderStatus` | admin   |
| `vshard`               | viewer         |
| `vshardKnownGroups`    | viewer         |
| `canBootstrapVshard`   | viewer         |
| `bootstrapStatus`      | admin          |
| `bootstrapTemplates`   | admin          |
| `bootstrapRender`      | admin          |
| `webhooks`             | admin          |
| `webhookQueueDepth`    | admin          |
| `webhookDeadLetter`    | admin          |

## GraphQL Mutation

| Поле                          | Требуемая роль |
|-------------------------------|----------------|
| `validateConfig`              | operator       |
| `proposeConfig`               | operator       |
| `abortConfig`                 | operator       |
| `commitConfig`                | admin          |
| `forceTakeLock`               | admin          |
| `setFailover`                 | admin          |
| `promote`                     | admin          |
| `expel`                       | admin          |
| `joinInstance`                | admin          |
| `setUserRoles`                | admin          |
| `setLabels`                   | operator       |
| `setVshardWeight`             | admin          |
| `setVshardGroup`              | admin          |
| `bootstrapVshard`             | admin          |
| `bootstrapInitialize`         | admin          |
| `forceReapplyConfig`          | admin          |
| `reloadRoles`                 | superuser      |
| `takeSnapshot`                | admin          |
| `exportAudit`                 | admin          |
| `testWebhook`                 | admin          |
| `clearDeadLetter`             | admin          |
| `applyForceApply`             | admin          |
| `applyRestartReplication`     | admin          |
| `applyRefreshVshard`          | admin          |
| `applyDisableServer`          | admin          |
| `applyRefineUri`              | admin          |
| `applyRestartFailover`        | admin          |
| `applyBootstrapVshard`        | admin          |
| `runEval`                     | superuser      |
| `runSql`                      | superuser      |
| `hotReloadModule`             | superuser      |
| `probeUri`                    | admin          |

## Дефолты

- Query-поле без явной записи в `GRAPHQL_FIELD` → `viewer`.
- Mutation-поле без явной записи → `admin`.
- REST-маршрут без явной записи в `REST_AUTH` → `session` (login требуется).

## Когда что выбирать

| Кейс | Минимальная роль |
|---|---|
| Только дашборд / мониторинг | `viewer` |
| Подготовить YAML, валидировать, оставить admin'у на commit | `operator` |
| Полное управление кластером без shell-доступа | `admin` |
| Debug-сессия с Lua/SQL evaluation, hot-reload модулей | `superuser` |

`superuser` — это `admin` + runtime-control. Назначать минимально и держать `console_enabled: false` в production манифестах.

## Audit

Каждое выполнение `runEval` / `runSql` / `hotReloadModule` пишется в `_webui_audit` с user, snippet, длительностью и (truncated) выводом. Каждое `rbac.denied` — отдельная запись с `scope = required-role` и `handler` / `path` payload.

## See Also

- [Security](security.md) — аутентификация, CSRF, peer-auth
- [Operations](operations.md) — каталог REST + GraphQL операций
- [Troubleshooting](troubleshooting.md) — `FORBIDDEN`, `UNAUTHORIZED`, `CSRF_INVALID`
