[← GraphQL schema](graphql-schema.md) · [Back to README](../../README.md) · [Error codes →](error-codes.md)

# REST API

Основная админ-поверхность — GraphQL по `POST /admin/api` (см. `graphql-schema.md`). REST зарезервирован для случаев, где GraphQL только мешает: аутентификация, eval/SQL, метрики, health, скачивание/загрузка конфигов, снапшоты, логи, диагностический бандл, WebSocket.

Все ответы — `application/json; charset=utf-8`. Все запросы и ответы несут заголовок `X-Request-Id` (UUID v4) — клиент может передать свой, иначе сервер сгенерирует. Этот же ID попадает в structured-логи на всех инстансах кластера для cross-instance correlation.

При ошибке тело ответа всегда соответствует единому envelope:

```json
{
  "error": {
    "code": "STABLE_CODE",
    "message": "human-readable explanation",
    "request_id": "abc123",
    "details": { /* optional structured details */ }
  }
}
```

Полный список `code` — в `docs/api/error-codes.md`. Stack-trace, имена файлов и внутренние пути никогда не попадают в envelope.

## Каталог эндпоинтов

Точные требуемые роли — в [`rbac-matrix.md`](../rbac-matrix.md). Все мутирующие POST требуют валидный CSRF-токен (см. `security.md`).

| Метод | Путь | Назначение |
|---|---|---|
| GET | `/api/health` | Liveness/readiness для HAProxy и мониторинга (детали ниже) |
| POST | `/admin/api` | GraphQL — основная админ-поверхность |
| GET | `/admin/api/explore` | Минимальный GraphQL explorer (gated `graphiql_enabled`) |
| POST | `/api/auth/login` | Логин по `{username, password}` → session-cookie + CSRF |
| POST | `/api/auth/logout` | Завершить сессию |
| GET | `/api/auth/me` | Текущий пользователь + роли + CSRF-токен |
| POST | `/api/eval` | Lua-eval на выбранном инстансе (`superuser`, по умолчанию выключен; пишется в audit) |
| POST | `/api/sql` | SQL-запрос |
| POST | `/api/sql/explain` | `EXPLAIN` для SQL-запроса |
| GET | `/api/metrics` | Prometheus-экспозиция (метрики Tarantool) |
| GET | `/api/metrics/webui` | Prometheus-экспозиция self-метрик роли (`webui_*`) |
| GET | `/api/config/download` | Скачать текущий cluster YAML |
| POST | `/api/config/upload` | Загрузить cluster YAML (идёт через 2PC prepare) |
| GET | `/api/logs` | Хвост role-логов (фильтры через query-параметры) |
| GET | `/api/snapshots` | Список снапшотов инстанса |
| POST | `/api/snapshots/take` | Сделать снапшот (`box.snapshot`) |
| GET | `/api/snapshots/download` | Скачать `.snap`/`.xlog` |
| GET | `/api/diagnostics/bundle` | Диагностический бандл (логи + box.info + конфиг) |
| POST | `/api/diagnostics/rebootstrap` | Re-bootstrap инстанса (wipe WAL/snap; деструктивно) |
| GET | `/ws` | WebSocket live-обновлений (issues/state/audit) |

Статические роуты SPA (`/`, `/index.html`, `/assets/*`, `/favicon.ico`, `/robots.txt`, `/monacoeditorwork/*`, fallback `/*splat`) отдают упакованный фронтенд.

Ниже — детальные контракты ключевых эндпоинтов.

## GET /api/health

Двухуровневый liveness/readiness endpoint, используется HAProxy для healthcheck и мониторингом.

### Возможные ответы

**200 OK — `status: "ok"`** — всё в норме:
```json
{
  "status": "ok",
  "instance": "tt-1",
  "tarantool_version": "3.7.0-0-g78b01ac",
  "webui_version": "0.1.0",
  "role_state": "ready",
  "uptime_sec": 1234.5,
  "checks": { "tx_thread": "ok" }
}
```

**200 OK — `status: "degraded"`** — частичная деградация, но инстанс остаётся в ротации. Поле `checks` содержит проблемные пункты. HAProxy НЕ выводит из ротации (важно: 503 на 200 — намеренно), мониторинг подсвечивает.

**503 Service Unavailable — `status: "unhealthy"`** — серьёзная неисправность. HAProxy выводит из ротации. В заголовке отдаётся `Retry-After: 5`.

### Critical / degraded критерии

| Условие | Verdict |
|---|---|
| Роль ещё не вышла в `ready` (`starting`/`stopping`) | `degraded` |
| Heartbeat-фибер не пульсировал > 5 сек (TX-тред заблокирован) | `unhealthy` (HTTP 503) |
| Роль не инициализирована | `unhealthy` (HTTP 503) |
| Идёт graceful shutdown | `degraded` |

Дополнительные проверки регистрируются модулями `etcd`, `cluster.poller`, `config_store.twophase` через `health.register_check(name, fn)`.

### Тело `checks`

```json
{
  "checks": {
    "tx_thread": "ok | blocked",
    "etcd":      "ok | down | slow",
    "peers":     "ok | lost_majority",
    "config":    "ok | stale",
    "shutdown":  "ok | true"
  }
}
```

Значение `"ok"` или `false` считается «хорошим»; любое другое строковое значение поднимает общий status до `degraded` (или до `unhealthy` для `tx_thread = "blocked"`).

### Mandatory response headers

Любой ответ REST несёт security-набор заголовков:

```
Strict-Transport-Security: max-age=63072000; includeSubDomains
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: geolocation=(), microphone=(), camera=()
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
X-Request-Id: <uuid>
```

См. `docs/security.md` для обоснования каждого заголовка.

## POST /admin/api (GraphQL)

Основная админ-поверхность. Документация: `docs/api/graphql-schema.md`.

- Тело запроса: `{ query, variables, operationName }` (`Content-Type: application/json`).
- Тело ответа: `{ data, errors }` (GraphQL spec).
- HTTP-коды:
  - `200` — успех (или частичный успех с `errors[]`).
  - `400` — `INVALID_QUERY` или `VALIDATION_ERROR`.
  - `500` — `INTERNAL` (резолвер crashed; message маскируется).
  - `503` — `UNAVAILABLE` (GraphQL не инициализирован).
- Errors используют GraphQL envelope с `extensions.code` и `extensions.request_id`.

## GET /admin/api/explore

Self-contained минимальный GraphQL explorer. Открывает HTML-страницу с textarea для запроса, кнопкой Execute (Ctrl+Enter) и панелью JSON-результата.

- Гейтинг: `roles_cfg.webui.graphiql_enabled` (default `false`). При `false` → 404.
- CSP relaxed для этого route: `script-src 'self' 'unsafe-inline'`.
- Никаких внешних ассетов. Не полный GraphiQL (~3 КБ inline вместо ~1 МБ React-приложения).
- RBAC: `admin`.

## See Also

- [GraphQL schema](graphql-schema.md) — основной admin API
- [Error codes](error-codes.md) — стабильные коды ошибок
- [RBAC matrix](../rbac-matrix.md) — требуемая роль для каждого endpoint'а
