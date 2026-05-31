[← Operations](operations.md) · [Back to README](../README.md) · [RBAC matrix →](rbac-matrix.md)

# Security

Threat model, защитный baseline, аутентификация, RBAC, peer-to-peer, audit-стрим, TLS.

## Security HTTP-заголовки

Каждый REST-ответ принудительно несёт следующий набор заголовков. Применяются в `backend/webui/http/middleware.lua`:

```
Strict-Transport-Security: max-age=63072000; includeSubDomains
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';
                        img-src 'self' data:; font-src 'self' data:;
                        connect-src 'self' ws: wss:; worker-src 'self' blob:;
                        frame-ancestors 'none'; base-uri 'self'
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: geolocation=(), microphone=(), camera=()
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
```

### Обоснование

| Заголовок | Защита |
|---|---|
| `Strict-Transport-Security` | Принудительный HTTPS, защита от downgrade-атак |
| `Content-Security-Policy` | XSS: блокирует inline-скрипты, внешние домены |
| `X-Content-Type-Options: nosniff` | MIME-confusion атаки |
| `X-Frame-Options: DENY` | Clickjacking |
| `Referrer-Policy` | Утечка чувствительных URL во внешние домены |
| `Permissions-Policy` | Удаляет доступ к API, которые UI не использует |
| `Cross-Origin-Opener-Policy` | Изоляция browsing context |
| `Cross-Origin-Resource-Policy` | Ограничение использования ресурсов сторонними сайтами |

### CSP — нюансы

- `script-src 'self'` — Vue 3 SPA не требует `unsafe-inline` или `unsafe-eval`.
- `style-src 'self' 'unsafe-inline'` — PrimeVue и некоторые компоненты используют inline-стили.
- `worker-src 'self' blob:` — Monaco editor загружает language workers как blob URLs.
- `connect-src 'self' ws: wss:` — разрешает WebSocket `/ws` к собственному origin.

## Request-ID и cross-instance correlation

Заголовок `X-Request-Id` (UUID v4) присутствует в каждом запросе/ответе и в каждой записи structured-лога. Клиент может задать свой ID (валидный pattern `^[%w%-_:]+$`, длина ≤ 128); иначе сервер сгенерирует.

При cross-instance операциях (через `map_call`) request-id передаётся в `opts.context.request_id`. Это позволяет одним `grep` собрать полный flow с нескольких инстансов кластера.

## Error envelope

REST-ошибки никогда не отдают stack-trace или внутренние пути:

```json
{ "error": { "code": "STABLE_CODE", "message": "human readable", "request_id": "uuid", "details": {...}? } }
```

Класс ошибки `INTERNAL` (единственный с `capture_stack=true`) полностью маскируется во внешнем ответе: тело содержит `"message": "internal error"`, реальные данные пишутся в structured-лог с тем же `request_id`. Оператор находит их через `grep`. Полный каталог — `api/error-codes.md`.

## Аутентификация

Сессионная аутентификация реализована на REST: `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me`.

### `POST /api/auth/login`

- Тело: `{ "user": "...", "password": "..." }` (`application/json`).
- Проверка: `box.schema.user.password(password)` сравнивается с `_user[5]['chap-sha1']`.
- Системные пользователи (`webui_peer`, `replicator`) явно запрещены — `403 FORBIDDEN`.
- На успех — `200`, тело `{ user, csrf, expiresIn }`, заголовок `X-Csrf-Token`, cookie `webui_session=<id>` со флагами `Path=/; HttpOnly; SameSite=Strict; Max-Age=<ttl>`.
- Флаг `Secure` добавляется только если запрос пришёл через HTTPS (по `x-forwarded-proto: https`, которое выставляет HAProxy перед инстансом).
- На неуспех — `401 LOGIN_FAILED`.
- **Forward to leader.** `_webui_sessions` — реплицированный sync-space; запись идёт через `webui_session_put_remote` net.box shim на лидере. RO-инстансы прозрачно проксируют login.

### `POST /api/auth/logout`

- Cookie `webui_session` удаляется (`Set-Cookie` с `Max-Age=0`).
- Сессия в `_webui_sessions` удаляется (через forward-to-leader, если нужно).
- WebSocket-сессии этого пользователя force-close (`1001 Going Away`).
- Audit-log: `auth.logout`.

### `GET /api/auth/me`

- Требует cookie `webui_session`. Без cookie или с просроченной сессией → `401 UNAUTHORIZED`.
- Тело: `{ user, roles, expiresAt, csrf }`.

### Rate-limit (anti-bruteforce)

- `auth/rate_limit.lua` — in-memory sliding window: 5 неуспешных попыток / минута / IP / action.
- Успешный login сбрасывает счётчик для (IP, action).
- 6-я попытка возвращает `429 RATE_LIMITED` и логирует error.
- Хранилище локальное на инстансе — стоимость синхронизации между пирами не оправдывает столь маленький бюджет.

### Audit-log auth-событий

- `auth.login` (scope = `session`, payload = `{ ip }`) — на успешный вход.
- `auth.logout` (scope = `session`) — на выход.
- `auth.login_failed` — на провальный.

## RBAC

Четыре роли, ранжированные снизу вверх: `viewer` < `operator` < `admin` < `superuser`. Запрос проходит, если *любая* роль пользователя имеет ранг не ниже требуемого.

Production-маппинг подкладывается через `roles_cfg.webui.rbac.users` cluster-wide config'а:

```yaml
roles_cfg:
  webui:
    rbac:
      users:
        ops-team:   [admin]
        oncall:     [operator]
        bi-readers: [viewer]
        sre-leads:  [superuser]
```

Dev-фикстуры — `viewer_dev / operator_dev / admin_dev / superuser_dev` (определены в `backend/webui/auth/rbac.lua → DEFAULT_USER_TO_ROLES`).

CSRF: на каждом state-changing методе (`POST/PUT/PATCH/DELETE`) middleware читает заголовок `X-Csrf-Token`. Несовпадение с CSRF-токеном из `_webui_sessions` → `403 CSRF_INVALID`. Login исключён (на нём токен ещё не существует).

При отказе доступа middleware:
- логирует `info` (`rbac denied` или `csrf mismatch`),
- пишет в `_webui_audit` запись `action = "rbac.denied"` с `scope = required-role`, `payload = { handler, path }`.

Полная карта в `rbac-matrix.md`.

## WebSocket аутентификация

На handshake `/ws` сервер:

1. Проверяет `Origin` против `roles_cfg.webui.ws_allowed_origins` (пустой список = разрешить любой Origin).
2. Читает cookie `webui_session` и валидирует через `auth.session.get`.
3. Без сессии и без флага `WEBUI_DEV_ANONYMOUS_WS=1` (dev-режим) — `401`.
4. Иначе — стандартный `101 Switching Protocols`.

Реестр WS (`ws_registry`) хранит `session_id` и `user`. Хелпер `close_by_session(session_id, reason)` шлёт всем коннектам сессии `1001 Going Away` — используется `/api/auth/logout` для немедленного отзыва доступа.

## Peer authentication

Между инстансами есть два независимых канала:

| Канал | Пользователь | Назначение |
|---|---|---|
| `replication` (iproto) | `replicator` | Tarantool's нативная репликация |
| `webui_peer` (net.box pool) | `webui_peer` | RPC между инстансами WebUI-роли: probe, audit forwarding, session forwarding, prepared forwarding, failover appointments |

### `webui_peer` lifecycle

`backend/webui/cluster/peer_cookie.lua`:

1. Resolver приоритет пароля: `opts.config_password` → env `TT_WEBUI_PEER_PASSWORD` → `_webui_meta.peer_cookie` → auto-generated (32 chars URL-safe base64) + WARN.
2. На read-only инстансе DDL отложен через daemon-fiber с `box.ctl.wait_rw()` — лидер делает `create user`/`grant universe read,execute` и реплицирует.
3. `_webui_meta` — `is_local: true` (per-instance), но `peer_cookie` ключ всё равно сохраняется per-instance чтобы при rolling restart инстанс не сгенерировал новый пароль на пустом старте.

### Опциональный mTLS

В cluster YAML:

```yaml
iproto:
  advertise:
    peer:
      login: webui_peer
      password: '${WEBUI_PEER_PASSWORD}'
      params:
        transport: ssl
        ssl_ca_file:   '/etc/tarantool/tls/peer-ca.crt'
        ssl_cert_file: '/etc/tarantool/tls/peer.crt'
        ssl_key_file:  '/etc/tarantool/tls/peer.key'
  listen:
    - uri: '0.0.0.0:3301'
      params:
        transport: ssl
        ssl_ca_file:   '/etc/tarantool/tls/peer-ca.crt'
        ssl_cert_file: '/etc/tarantool/tls/peer.crt'
        ssl_key_file:  '/etc/tarantool/tls/peer.key'
```

Эти EE-only схемные ключи (`params.ssl_*`) разрешены на CE через shim `internal.config.extras` (см. `architecture.md`).

## Audit log

`_webui_audit` — реплицированный sync space. Поля: `id`, `ts`, `user`, `action`, `target`, `status`, `request_id`, `payload`.

Сюда пишутся:

- **Authentication** — `auth.login`, `auth.logout`, `auth.login_failed`.
- **Authorization** — `rbac.denied` (с `scope = required-role`).
- **Config commits** — `config.commit` (с `revision`, `diff_summary`).
- **Failover** — `failover.promote`, `failover.demote`, `failover.coordinator_change`.
- **Lifecycle** — `instance.expel`, `instance.join`, `replicaset.create`.
- **Console** — `eval.lua`, `eval.sql` (тело snippet + длительность).
- **Snapshots** — `snapshot.take`.
- **Webhooks** — `webhook.delivered`, `webhook.dead_letter`, `webhook.test`.
- **Diagnostics** — `bundle.downloaded`.

Audit не пропускает: ни одна mutation не выполняется без записи. Retention управляется `roles_cfg.webui.audit_retention_days` (default 90).

### Append-only гарантии

`_webui_audit` помечен `is_sync=true` → запись подтверждается только после ACK quorum'а follower'ов. Это исключает класс «лидер записал, ACK'нул клиенту, упал — потеря audit'а».

DELETE из `_webui_audit` происходит только из retention-фибера (на лидере), и audit-row для самого DELETE НЕ пишется (иначе бесконечная рекурсия). Retention sweep сам логируется в structured-лог (`tag=audit, msg=retention sweep, deleted=N`).

## Lua/SQL console

`POST /api/eval` (REST) и `runEval` / `runSql` (GraphQL):

- RBAC: `superuser`.
- Kill-switch: `roles_cfg.webui.console_enabled` (default `false`). Без флага — `403 CONSOLE_DISABLED`.
- Каждое выполнение пишется в `_webui_audit` (`eval.lua` или `eval.sql`) с полным snippet'ом, длительностью, выводом (truncated до 16 KiB).
- Production-манифесты обязаны держать `console_enabled: false`. Включать только для debug-сеансов с ограниченным окном.

## Secret management

Секреты в cluster YAML — через env substitution:

```yaml
credentials:
  users:
    replicator:
      password: '${REPLICATOR_PASSWORD}'
    webui_peer:
      password: '${WEBUI_PEER_PASSWORD}'

config:
  etcd:
    password: '${ETCD_PASSWORD}'
```

Источник секретов — `.env` файл (compose) или `docker secret create` (Swarm) или Vault/SSM (k8s).

Что **не должно** уходить в логи:
- raw HTTP `Authorization` header,
- cookie `webui_session`,
- значения секретов из cluster YAML,
- raw payload `POST /api/eval`.

Middleware масcкирует Authorization/Cookie в access-логе на уровне `info`. Console-eval audit пишет snippet в `_webui_audit`, но НЕ в stdout-лог.

## Threat model (STRIDE)

| Категория | Угроза | Mitigation |
|---|---|---|
| **Spoofing** | Подделка identity at HTTP-уровне | Session cookie HttpOnly+SameSite=Strict; CSRF token на mutations; rate-limit на login |
| **Spoofing (peer)** | Чужой инстанс присоединяется к replication | `replicator` с паролем + опц. mTLS; `webui_peer` с паролем + опц. mTLS |
| **Tampering** | Подмена audit-записей | `_webui_audit` синхронный + replicated; DELETE только из retention-фибера на лидере |
| **Tampering** | Concurrent config commit перетирает чужой | etcd CAS guard через `put_if_witness_unchanged(expected_rev)` |
| **Repudiation** | Оператор отрицает действие | Audit-log с user / action / target / request_id / payload |
| **Information disclosure** | Stack-trace в response | Error envelope маскирует `INTERNAL`; реальные данные только в structured-логе |
| **Information disclosure** | Чувствительные значения в логах | Маскирование Authorization/Cookie; не логировать `password`/`secret`/`token` поля |
| **Denial of Service** | Bruteforce login | Rate-limit 5/min/IP |
| **Denial of Service** | Slow WS-consumer держит backlog | `DEFAULT_BACKLOG_LIMIT=1000` frames → close 1008 |
| **Denial of Service** | Большие config-uploads | `LARGE_CONFIG` (4 MiB cap) → 413 |
| **Elevation of privilege** | Эскалация через Lua console | `superuser` RBAC + `console_enabled` kill-switch + audit каждого snippet |
| **Elevation of privilege** | RBAC bypass через GraphQL | Per-field check в каждом резолвере (`rbac.allowed`) |

## Раскрытие уязвимостей

Security advisories публикуются через GitHub Security Advisories. Patch-релизы для security-fix'ов выпускаются для последних трёх minor-веток.

## See Also

- [RBAC matrix](rbac-matrix.md) — кто что может
- [Operations](operations.md) — production checklist (TLS, secrets, firewall)
- [Troubleshooting](troubleshooting.md) — login failed, csrf mismatch, peer auth fail
