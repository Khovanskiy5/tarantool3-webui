# REST API

Основная админ-поверхность — GraphQL по `POST /admin/api` (см. `docs/api/graphql-schema.md`). REST зарезервирован для случаев, где GraphQL только мешает: аутентификация, eval, метрики, health, upload/download конфигов, diagnostic bundle.

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

### Critical/degraded критерии (реализованные на M0)

| Условие | Verdict |
|---|---|
| Роль ещё не вышла в `ready` (`starting`/`stopping`) | `degraded` |
| Heartbeat-фибер не пульсировал > 5 сек (TX-тред заблокирован) | `unhealthy` (HTTP 503) |
| Роль не инициализирована | `unhealthy` (HTTP 503) |
| Идёт graceful shutdown | `degraded` |

Дополнительные проверки регистрируются модулями `etcd`, `cluster.poller`, `config_store.twophase` через `health.register_check(name, fn)` — они появятся по мере реализации Tasks 17, 27, 30.

### Тело `checks`

```json
{
  "checks": {
    "tx_thread": "ok | blocked",
    "etcd": "ok | down | slow",          // Task 30
    "peers": "ok | lost_majority",       // Task 17
    "config": "ok | stale",              // Task 27
    "shutdown": "ok | true"              // Task 3a
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

## Дальнейшие endpoint'ы

Появляются по мере реализации задач:

- `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me` — Tasks 25–26.
- `POST /api/eval` — Task 44 (Lua/SQL console).
- `GET /api/metrics`, `GET /api/metrics/webui` — Tasks 42, 42a.
- `GET /api/config/download`, `POST /api/config/upload` — Task 37.
- `GET /api/diagnostics/bundle` — Task 54.
- `POST /admin/api` (GraphQL) — Task 7, отдельный документ.
- `GET /admin/api/explore` (GraphiQL) — Task 7.
- `GET /ws` (WebSocket upgrade) — Tasks 21, 26a.

Каждая категория документируется отдельным разделом в этом файле или собственным документом.
