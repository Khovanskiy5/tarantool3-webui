# Architecture

Этот документ — техническая карта проекта. Он растёт вместе с кодом: каждая реализованная задача добавляет соответствующий раздел.

## Высокоуровневая картина

```
Browser  (Vue 3 + TypeScript + Pinia + Vue Router + Vite + urql)
   │
   │ HTTPS / WSS (единая точка входа)
   ▼
HAProxy  (L7 LB: TLS termination, healthcheck, sticky session для WebSocket)
   │
   ▼
Tarantool instance  ×  N         ←  любой инстанс — точка входа
   │  встроенная Lua-роль `webui`
   │  отдаёт SPA + REST + GraphQL + WebSocket
   ▼
   ├── net.box pool → другие инстансы (auth: webui_peer + опц. TLS)
   ├── etcd v3       → cluster-wide config (source of truth)
   └── prometheus    → опц. /metrics
```

Backend живёт внутри каждого инстанса как Lua-роль. Конфигурация роли — секция `roles_cfg.webui` в cluster config Tarantool 3.x.

## Lua-роль `webui` — lifecycle (Task 2)

Точка входа — модуль `webui` (файл `backend/webui/init.lua`). Реализует два интерфейса:

### Declarative role interface (Tarantool 3.x)

Вызывается самим Tarantool при применении конфигурации:

- `webui.validate(cfg)` — чистая проверка `roles_cfg.webui.*` без побочных эффектов. Возвращает `true` либо `(nil, err)`. Ошибка отменяет apply и попадает в `config:info().alerts`.
- `webui.apply(cfg)` — применение конфигурации. На первом вызове делегирует в `start(cfg)`; на повторных — выполняет `stop()` и затем `start(cfg)` с новой конфигурацией.

### Imperative interface (для тестов и standalone-скриптов)

- `webui.start(opts)` — запустить роль. Запрещает повторный старт, идempotent на «уже running».
- `webui.stop()` — остановить. Идempotent на «уже stopped».
- `webui.status()` — `{ state, version, tarantool, instance, started_at, uptime_sec, log_level }`.

### Состояния lifecycle

```
uninitialized ──start()──▶ starting ──▶ ready
                                            │
                                            ├── apply(new_cfg) ──▶ stopping ──▶ stopped ──start()──▶ ready
                                            │
                                            └── stop() ─────────▶ stopping ──▶ stopped
```

### Порядок инициализации (расширяется по задачам)

`start()` выполняет последовательность шагов в строго фиксированном порядке (контракт «Lua module loading»):

1. validate opts
2. configure logging
3. (Task 42a) metrics registry
4. (Task 24/24a) storage spaces + migrations
5. (Task 15) peer cookie
6. (Task 16) cluster.peers + rpc pool
7. (Task 17) cluster.state
8. (Task 17–20, 27) background fibers
9. (Task 3) HTTP server
10. (Task 7) GraphQL server
11. (Task 21) WebSocket endpoint
12. broadcast `webui.started`

На сегодня (Task 2) шаги 3–12 — TODO; `start()` доходит до шага 2 и сразу помечает state как `ready`, чтобы lifecycle был наблюдаем через `status()` и тесты.

### Совместимость по версиям

`backend/webui/version.lua` хранит SemVer роли и допустимый диапазон версий Tarantool: `MIN_TARANTOOL = "3.7.0"`, `MAX_TARANTOOL_EXCLUSIVE = "4.0.0"`. На старте `start()` вызывает `version.check_tarantool()` — отказ при несовместимой версии. Также модуль хранит `WS_PROTOCOL_VERSION` (для WebSocket-контракта) и `GRAPHQL_SCHEMA_GENERATION` (для compatibility-проверок).

## Логирование

`backend/webui/log_util.lua` — единая точка логирования. Прямое использование `log.*` из Tarantool запрещено в коде роли.

### Формат записи

Каждая запись — JSON в одну строку:

```json
{"ts":"2026-05-30T12:34:56.789012Z","level":"info","tag":"http","instance":"tt-1","msg":"request accepted","request_id":"abc","latency_ms":12}
```

Обязательные поля: `ts` (ISO 8601 UTC, микросекунды), `level`, `tag`, `instance` (если известен), `msg`.
Опциональные — любые domain-поля (request_id, user, latency_ms, error_code, …).

### API

```lua
local log_util = require('webui.log_util')

-- Конфигурация (вызывается из webui.start)
log_util.configure({ level = 'info', instance = box.info.name })

-- Тегированный логгер
local logger = log_util.with_tag('http')
logger.info('request accepted', { request_id = 'abc', latency_ms = 12 })
logger.error('handler failed', { request_id = 'abc', err = err })

-- Untagged (для случаев, когда тег не имеет смысла)
log_util.info('boot done')
```

### Теги (стандартный набор)

| Тег | Подсистема |
|---|---|
| `init` | Lifecycle роли |
| `http` | HTTP-сервер, middleware, статика |
| `cluster` | poller, state, issues, suggestions |
| `config` | config_store, twophase, history |
| `auth` | сессии, RBAC, peer-cookie |
| `audit` | audit-log, retention |
| `ws` | WebSocket |
| `graphql` | GraphQL-сервер |
| `etcd` | etcd-клиент, watch, lease |
| `metrics` | self-metrics |
| `fiber` | реестр фоновых фиберов |
| `migration` | миграции спейсов |

### Уровни и фильтрация

- Уровни: `debug` < `info` < `warn` < `error`.
- Уровень читается из `roles_cfg.webui.log_level` или env `WEBUI_LOG_LEVEL`. Default — `debug`.
- Записи ниже текущего уровня не сериализуются (быстрый short-circuit).

### Robustness

- JSON-сериализация обёрнута в `pcall`. При сбое (несериализуемые userdata) выдаётся degraded-строка с `"_encode_error":true` — никаких throw'ов наружу.
- Reserved keys (`ts`, `level`, `tag`, `instance`, `msg`) не могут быть перезаписаны полями из payload.

## Дальнейшие разделы

Появляются по мере реализации задач:

- HTTP server + middleware + error envelope → Task 3.
- Graceful shutdown sequence → Task 3a.
- Frontend FSD структура → Task 4.
- GraphQL skeleton + GraphiQL → Task 7.
- Cluster state, poller, issues, suggestions → Tasks 13–20.
- Two-phase commit + etcd → Tasks 30–34.
- Failover, vshard, lifecycle → Tasks 46–53.

См. план реализации в `.ai-factory/plans/tarantool-webui.md`.
