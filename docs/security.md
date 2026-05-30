# Security

Этот документ описывает security baseline проекта: threat model, security-заголовки HTTP, политику секретов, TLS-настройку и audit-стрим. Документ растёт по мере реализации задач — на данный момент покрыт M0 (security headers, error envelope).

## Security HTTP-заголовки (Task 3)

Каждый REST-ответ принудительно несёт следующий набор заголовков. Применяются в `backend/webui/http/middleware.lua`, перекрытие со стороны handler'а допустимо только для CSP (например, на странице с inline-чартами — но в нашем проекте такого нет).

```
Strict-Transport-Security: max-age=63072000; includeSubDomains
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'
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
- `connect-src 'self' ws: wss:` — разрешает WebSocket `/ws` к собственному origin (в dev и prod).

## Request-ID и cross-instance correlation

Заголовок `X-Request-Id` (UUID v4) присутствует в каждом запросе/ответе и в каждой записи structured-лога. Клиент может задать свой ID (валидный pattern `^[%w%-_:]+$`, длина ≤ 128); иначе сервер сгенерирует.

При cross-instance операциях (через `map_call`, см. Tasks 16, 30) request-id передаётся в `opts.context.request_id`. Это позволяет одним `grep` собрать полный flow с нескольких инстансов кластера.

## Error envelope

REST-ошибки никогда не отдают stack-trace или внутренние пути. Подробности — `docs/api/error-codes.md` и `backend/webui/http/error_envelope.lua`.

Класс ошибки `INTERNAL` (единственный с `capture_stack=true`) полностью маскируется во внешнем ответе: тело содержит `"message": "internal error"`, а реальные данные пишутся в structured-лог с тем же `request_id` — оператор находит их через `grep`.

## Аутентификация (REST `/api/auth/*`, Task 25)

Сессионная аутентификация реализована на REST. Канал — `POST /api/auth/login`, `POST /api/auth/logout`, `GET /api/auth/me`.

Контракт `/login`:

- Тело: `{ "user": "...", "password": "..." }` (`application/json`).
- Проверка: `box.schema.user.password(password)` сравнивается с `_user[5]['chap-sha1']` (Tarantool 3.x не экспортирует `auth_password`). Системные пользователи (`webui_peer`, `replicator`) явно запрещены — `403 FORBIDDEN`.
- На успех — `200`, тело `{ user, csrf, expiresIn }`, заголовок `X-Csrf-Token`, cookie `webui_session=<id>` со флагами `Path=/; HttpOnly; SameSite=Strict; Max-Age=<ttl>`.
- Флаг `Secure` добавляется только если запрос пришёл через HTTPS (по `x-forwarded-proto: https`, которое выставляет HAProxy перед инстансом).
- На неуспех — `401 LOGIN_FAILED`.

Контракт `/logout`:

- Cookie `webui_session` удаляется (Set-Cookie с `Max-Age=0` + просроченным `Expires`).
- Сессия в `_webui_sessions` удаляется.
- Если зарегистрирован реестр WebSocket-подключений (`webui.http.ws_registry.close_by_session`), все WS-сессии этого пользователя закрываются (полноценное закрытие — Task 26a).
- Audit-log: запись с `action = "auth.logout"`.

Контракт `/me`:

- Требует cookie `webui_session`. Без cookie или с просроченной сессией → `401 UNAUTHORIZED`.
- Тело: `{ user, roles, expiresAt, csrf }`. Поле `roles` сейчас пустой массив — RBAC-резолвинг подключается в Task 26.

Rate-limit (anti-bruteforce):

- `auth/rate_limit.lua` — in-memory sliding window: 5 неуспешных попыток / минута / IP / action.
- Успешный login сбрасывает счётчик для (IP, action).
- 6-я попытка возвращает `429 RATE_LIMITED` и логирует error.
- Хранилище локальное на инстансе — стоимость синхронизации между пирами не оправдывает столь маленький бюджет.

Audit-log:

- `auth.login` (scope = `session`, payload = `{ ip }`) — на успешный вход.
- `auth.logout` (scope = `session`) — на выход.

## Дальнейшие разделы

Появляются по мере реализации задач:

- Аутентификация (sessions, cookie, CSRF) → Tasks 25 ✅, 26.
- RBAC (`viewer/operator/admin/superuser`) → Task 26 + `docs/rbac-matrix.md`.
- TLS: HAProxy на 443 + mTLS на peer net.box → Task 11, 16.
- Peer-cookie (`webui_peer` system user) → Task 15.
- Audit-log + retention → Tasks 24, 27.
- Edit-lock TTL и force-take → Tasks 30, 34.
- Lua/SQL console: gating, audit, rate-limit → Task 44.
- WebSocket auth + Origin check + force-close on logout → Tasks 21, 26a.
- Bruteforce mitigation → Task 25.
- Supply chain (Bun lockfile, rock checksums) → Task 12.
- Penetration testing checklist → Task 12 (OWASP ZAP в CI).
- Threat model по STRIDE — добавляется при наличии всех компонентов (Tasks 25, 26, 30+).

## Раскрытие уязвимостей

Security advisories публикуются через GitHub Security Advisories. Patch-релизы для security-fix'ов выпускаются для последних трёх minor-веток (см. `docs/operations.md`, раздел Release pipeline).

Для приватного раскрытия — контакт в README репозитория.
