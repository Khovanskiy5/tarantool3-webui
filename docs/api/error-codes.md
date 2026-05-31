[← REST API](rest.md) · [Back to README](../../README.md)

# Error codes

Стабильная часть API контракта. Каждый код имеет HTTP-статус для REST, `extensions.code` для GraphQL, рекомендованное UI-поведение и i18n-ключ для локализации фронта.

Удаление кода или изменение его семантики — breaking change. Добавление кода — non-breaking.

## Authentication & Authorization

| Code | HTTP | Когда | UI behavior |
|---|---|---|---|
| `UNAUTHORIZED` | 401 | Нет валидной сессии | Redirect to `/login` |
| `SESSION_EXPIRED` | 401 | Сессия истекла | Redirect to `/login?reason=expired` |
| `LOGIN_FAILED` | 401 | Неверные credentials | Inline error в форме |
| `FORBIDDEN` | 403 | Сессия есть, прав не хватает | Redirect to `/forbidden` |
| `CSRF_INVALID` | 403 | CSRF token missing/mismatch | Reload page banner |
| `RATE_LIMITED` | 429 | Превышен лимит запросов | Toast «Try in N sec» |
| `PASSWORD_TOO_WEAK` | 400 | Не соответствует auth_params | Inline в форме |

## Validation

| Code | HTTP | Когда | UI behavior |
|---|---|---|---|
| `VALIDATION_ERROR` | 400 | Invalid input shape | Inline в форме |
| `CONFIG_SCHEMA_INVALID` | 400 | YAML не соответствует JSON Schema | Список ошибок в editor |
| `CONFIG_CROSS_VALIDATION_FAILED` | 400 | Cross-field валидация | Список ошибок |
| `LARGE_CONFIG` | 413 | Config > 4 МБ | Toast |
| `INVALID_URI` | 400 | URI неверного формата | Inline |
| `INVALID_INSTANCE_NAME` | 400 | Имя не соответствует pattern | Inline |

## Resource state

| Code | HTTP | Когда | UI behavior |
|---|---|---|---|
| `NOT_FOUND` | 404 | Запрашиваемый объект отсутствует | NotFound page |
| `CONFLICT` | 409 | Конфликт состояния | Toast + reload prompt |
| `CAS_CONFLICT` | 409 | etcd CAS на config | Banner «Config changed, reload» |
| `EDIT_LOCK_HELD` | 423 | Кто-то редактирует | Banner с force-take опцией |
| `PREPARED_LOCK_HELD` | 423 | Другой prepare в процессе | Toast с retry |
| `BUSY` | 423 | Ресурс занят (rebalancer, snapshot) | Toast |
| `ALREADY_EXISTS` | 409 | Создание уже существующего | Inline в форме |
| `STILL_IN_USE` | 409 | Удаление используемого ресурса | Toast |

## Cluster operations

| Code | HTTP | Когда | UI behavior |
|---|---|---|---|
| `INSTANCE_UNREACHABLE` | 503 | Peer недоступен | Inline в результате |
| `INSTANCE_INCOMPATIBLE_VERSION` | 400 | Probe нашёл несовместимую версию | Inline |
| `INSTANCE_DIFFERENT_CLUSTER` | 400 | Probe нашёл другой cluster_uuid | Inline |
| `TLS_HANDSHAKE_FAILED` | 400 | TLS не установился при probe | Inline |
| `CONFIG_NOT_APPLIED` | 503 | Convergence таймаут | Banner |
| `NO_LEADER` | 503 | В replicaset нет лидера | Banner |
| `NO_ROUTERS` | 503 | В vshard-группе нет live router'а | Banner |
| `FAILOVER_COORDINATOR_DOWN` | 503 | supervised mode без живого координатора | Banner |
| `READ_ONLY_SOURCE` | 403 | Попытка write на read-only config source | Banner |

## Internal / system

| Code | HTTP | Когда | UI behavior |
|---|---|---|---|
| `INTERNAL` | 500 | Необработанная ошибка (баг) | Toast с request_id |
| `UNAVAILABLE` | 503 | Сервис частично недоступен | Banner |
| `TIMEOUT` | 504 | Операция превысила бюджет | Toast |
| `ETCD_UNAVAILABLE` | 503 | etcd не отвечает | Banner read-only mode |
| `ETCD_AUTH_FAILED` | 503 | etcd креды неверны | Banner |
| `ETCD_COMPACTED_REVISION` | 503 | etcd revision compacted, watch reset | Silent retry |
| `TX_THREAD_BLOCKED` | 503 | Heartbeat поток не отвечает | Critical banner |
| `SHUTDOWN_IN_PROGRESS` | 503 | Roll-down в процессе | Retry-After header |

## Console / eval

| Code | HTTP | Когда | UI behavior |
|---|---|---|---|
| `CONSOLE_DISABLED` | 403 | `console_enabled=false` | Banner |
| `EVAL_TIMEOUT` | 504 | Превышен таймаут eval | Toast |
| `EVAL_FORBIDDEN` | 403 | Не superuser | Inline |

## Protocol

| Code | HTTP | Когда | UI behavior |
|---|---|---|---|
| `UNSUPPORTED_PROTOCOL_VERSION` | 426 | WS protocol_version mismatch | Reload page |
| `WS_SLOW_CONSUMER` | close 1008 | Backlog overflow | Reconnect |
| `WS_AUTH_FAILED` | close 1008 | Cookie auth fail on connect | Login redirect |

## Backend представление

`backend/webui/errors.lua` экспортирует error classes (rock `errors`). HTTP-маппинг — таблица `errors.HTTP_STATUS`.

```lua
local Err = require('webui.errors')
if not allowed then
    return nil, Err.FORBIDDEN:new('role %s required', required_role)
end
```

`backend/webui/http/error_envelope.lua` принимает на вход любой объект ошибки и собирает REST envelope с правильным HTTP-статусом.

## Frontend представление

`frontend/src/shared/api/error-codes.ts` — те же константы и маппинг на UI-поведение в `error-handler.ts`. i18n-ключи: `errors.<CODE>` (`frontend/src/shared/i18n/locales/{en,ru}.json`).

## Расширение

При добавлении нового кода:

1. Добавить `M.<NEW_CODE>` в `backend/webui/errors.lua`.
2. Добавить запись в `M.HTTP_STATUS` если код имеет нестандартный статус.
3. Добавить строку в соответствующую таблицу этого документа.
4. Добавить ключ в `frontend/src/shared/i18n/locales/{en,ru}.json` под `errors.<NEW_CODE>`.
5. (Если затрагивает frontend) обновить `frontend/src/shared/api/error-handler.ts`.

## See Also

- [GraphQL schema](graphql-schema.md) — где появляется `extensions.code`
- [REST API](rest.md) — error envelope формат
- [Security](../security.md) — error envelope маскирование internal errors
- [Troubleshooting](../troubleshooting.md) — что делать при популярных ошибках
