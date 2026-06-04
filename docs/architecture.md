[Back to README](../README.md) · [Operations →](operations.md)

# Architecture

Этот документ описывает как устроен Tarantool 3.7 WebUI: топология компонентов, потоки данных, ключевые архитектурные решения. Документ намеренно компактный — детали по протоколам см. в `api/`, по эксплуатации в `operations.md`.

## Высокоуровневая картина

```
Browser  (Vue 3 + TypeScript + Pinia + Vue Router + Vite + urql)
   │
   │ HTTPS / WSS (single entry point)
   ▼
HAProxy  (L7 LB: TLS termination, healthcheck, sticky cookie webui_session)
   │
   ▼
Tarantool instance  ×  N         ←  любой инстанс — точка входа в UI
   │  встроенная Lua-роль `webui`
   │  отдаёт SPA + REST + GraphQL + WebSocket
   ▼
   ├── net.box pool  → другие инстансы (auth: webui_peer + опц. TLS)
   ├── etcd v3       → cluster-wide config + supervised-failover lease
   └── prometheus    → опц. /api/metrics
```

Backend живёт внутри каждого инстанса как Lua-роль. Конфигурация роли — секция `roles_cfg.webui` в cluster config Tarantool 3.x.

## Принципы

| Принцип | Что это значит на практике |
|---|---|
| **Единый бинарник** | Отдельного UI-сервиса нет: тот же `tarantool`, что хранит данные, отдаёт SPA и admin-API. |
| **Любой инстанс — точка входа** | UI доступен с каждой ноды. Write-операции автоматически проксируются на лидера через `webui_peer` net.box pool. |
| **etcd — источник истины для cluster-wide config** | Запись через двухфазный протокол `prepare → validate-on-every-peer → commit/abort`, защищённый CAS по revision. |
| **Нет рукописной схемы конфига** | И backend-валидация, и Monaco-редактор используют `require('config'):jsonschema()` из работающего бинарника — схема всегда совпадает с версией хоста. |
| **In-memory cluster state — единственный источник данных для API** | Все резолверы читают `cluster/state.lua` snapshot. RPC к пирам выполняется в фоновых фиберах (`peer_poller`, `issues_scanner`, `suggestions_engine`). HTTP-обработчики никогда не дёргают `net.box` напрямую — это блокировало бы TX-тред. |
| **Synchronous spaces для critical state** | Сессии, аудит, prepared YAML, очередь webhooks помечены `is_sync=true`; запись подтверждается только после ACK от quorum follower'ов. |

## Backend layout

```
backend/webui/
├── init.lua                 точка входа роли: validate/apply/start/stop/status
├── version.lua              SemVer роли + допустимый диапазон Tarantool
├── log_util.lua             единая точка структурного JSON-логирования
├── errors.lua               каталог error classes + HTTP-status маппинг
├── http/                    HTTP-сервер, middleware, статика, WebSocket
├── api/                     REST: auth, health, metrics, eval, snapshots, diagnostics, config_io
├── graphql/                 GraphQL-сервер, типы, резолверы
├── cluster/                 net.box pool, poller, in-memory state, issues, suggestions, peer_cookie
├── cluster_ops/             атомарные топологические операции (promote, topology_edit)
├── config_store/            2PC (twophase), schema, diff, history, etcd HTTP client, file-mirror, bootstrap
├── config_source/           CE-совместимый Tarantool config source поверх etcd
├── failover/                Supervised-failover агент + watcher + fencing/watchdog/failsafe/
│                            antiflap/timings/identity/drain/pause
├── recovery/                split-brain, quorum-loss, wal-repair, orphan, weak-subjectivity,
│                            leader-takeover, snapshot, topology-fix
├── data_explorer/           обзор спейсов/таплов + мутации + filter/types
├── storage/                 spaces.lua (DDL служебных `_webui_*` спейсов) + migrations
├── auth/                    сессии, RBAC, rate-limit, peer-cookie
├── audit/                   audit-log + retention + hash-chain (chain/verifier) + forwarder
├── notifications/           outbound webhooks (slack/discord/email/generic)
├── lifecycle/               start/stop/apply/validate/state + orchestrator (rolling-restart)
└── assets/                  встроенный SPA-бандл (генерируется `embed-assets`)
```

## Frontend layout (Feature-Sliced Design)

```
frontend/src/
├── app/         инициализация, провайдеры (i18n, urql, pinia, error-boundary), router, стили
├── pages/       роутовые слайсы: cluster, cluster-recovery, issues, config-editor, console,
│                data-explorer, schema, sql, logs, snapshots, users, vshard, failover, metrics,
│                audit, webhooks-settings, bootstrap, login, errors
├── widgets/     композитные блоки: sidebar, top-bar, cluster-topology, issues-badge,
│                suggestions-banner, code-editor, log-viewer
├── features/    пользовательские сценарии: auth-login, auth-logout, audit-export
├── entities/    бизнес-сущности: session, cluster, replicaset, instance, issue, suggestion, audit-entry
└── shared/      инфраструктура без знания домена: api (gql + rest + ws), ui, lib, config, i18n
```

Направление импортов — `app → pages → widgets → features → entities → shared`. Импорт между слайсами идёт только через публичный `index.ts`. Контроль — `eslint-plugin-boundaries`.

Runtime и пакетный менеджер — **Bun ≥ 1.1**. Node.js и npm не используются. Lockfile — `bun.lockb` (бинарный, коммитится).

## Lifecycle Lua-роли `webui`

Точка входа — `backend/webui/init.lua`: тонкий фасад (≤ 40 строк, cap пинится `webui_facade_test.lua`), который только `require`'ит и реэкспортирует пять имён из `backend/webui/lifecycle/`:

| Файл | Что внутри |
|---|---|
| `lifecycle/state.lua` | Shared `STATE` table + `status()` + `instance_alias()` + `configure_logging()` |
| `lifecycle/validate.lua` | Чистая `validate(cfg)` — type-check каждого поля `roles_cfg.webui.*` |
| `lifecycle/apply.lua` | `apply(cfg)` — диспетчер: `start` или `stop` + `start` |
| `lifecycle/start.lua` | `start(opts)` — линейная boot-последовательность от storage до HTTP |
| `lifecycle/stop.lua` | `stop()` — фазы 0–6 graceful shutdown (failover lease → drain → fibers → pool) |
| `lifecycle/remote_shims.lua` | `install()` — все `webui_*_remote` net.box receivers в `_G` |
| `lifecycle/orchestrator.lua` | Безопасная оркестрация рестартов (rolling, demote-first, majority-guard, restart-lock) — вызывается из lifecycle-резолвера, не реэкспортируется через `init.lua` |

Поддерживает оба интерфейса Tarantool 3.x:

| Метод | Назначение |
|---|---|
| `webui.validate(cfg)` | Чистая проверка `roles_cfg.webui.*`. Ошибка отменяет apply и попадает в `config:info().alerts`. |
| `webui.apply(cfg)` | Первый вызов делегирует в `start(cfg)`; на повторных — `stop()` + `start(cfg)` с новой конфигурацией. |
| `webui.start(opts)` | Запустить роль. Идempotent на «уже running». |
| `webui.stop()` | Остановить. Идempotent на «уже stopped». Зарегистрирован также как `box.ctl.on_shutdown` hook. |
| `webui.status()` | `{ state, version, tarantool, instance, started_at, uptime_sec, log_level }`. |

### Состояния

```
uninitialized ──start()──▶ starting ──▶ ready
                                            │
                                            ├── apply(new_cfg) ──▶ stopping ──▶ stopped ──start()──▶ ready
                                            │
                                            └── stop() ─────────▶ stopping ──▶ stopped
```

### Порядок инициализации

`start()` выполняет следующие шаги в строго фиксированном порядке. Каждый шаг — отдельный pcall; сбой откатывает уже поднятые подсистемы:

1. validate opts
2. configure logging
3. metrics registry
4. storage spaces + migrations
5. peer cookie + net.box peer pool
6. cluster state cache
7. background fibers (`poller`, `issues`, `suggestions`, `config_watcher`)
8. HTTP server
9. GraphQL server
10. WebSocket endpoint
11. state reporter (если `roles_cfg.webui.state_reporter.enabled: true`)
12. failover agent + watcher (если `roles_cfg.webui.failover.agent: true`)
13. notifications dispatcher (только на лидере)
14. broadcast `webui.started`

`stop()` обходит подсистемы в обратном порядке, drain'я HTTP/WS перед остановкой fiber'ов и пулов.

### Graceful shutdown

При получении `M.stop()` (rolling deploy, `docker stop`, изменение `roles_cfg.webui` с переcr еа том):

1. **Failover release** — если этот инстанс был coordinator, активно отпускает свой etcd lease, чтобы новый coordinator мог приступить без ожидания TTL.
2. **Draining gate** — middleware начинает отвечать `503 SHUTDOWN_IN_PROGRESS` на новые запросы. `/api/health` сообщает `status: degraded, role_state: stopping` — HAProxy выводит инстанс из ротации.
3. **In-flight drain** — счётчик активных обработчиков + `fiber.cond:wait` до `shutdown_timeout` секунд (default 5).
4. **HTTP stop** → **WS shutdown (1001)** → **background fibers** → **peer pool close**.

## Cluster state — единственный источник данных для API

`cluster/state.lua` — in-memory snapshot всего, что API отдаёт фронту: per-instance `box.info`, статусы репликации, vclock, replication lag, `config:info().alerts`, RO-флаги, leader replicaset'а. Snapshot атомарно swap'ается на каждом тике одного producer'а (`cluster/poller.lua`).

```
poller (1.5s tick) ──► peers.refresh() ──► rpc.map_eval(PROBE_SRC) ──► state.apply_tick(snapshot)
                                                                            │
                                                                            ▼
                                                        snapshot()  ← резолверы (GraphQL/REST)
```

- **Single producer** — гарантирует atomicity: API всегда видит консистентный snapshot.
- **`rpc.map_eval` неблокирующий** — async-fan-out через `conn:eval(...)`+ shared deadline (default 1.0s, меньше 1.5s tick).
- **Backoff** — peer'ы с failed probe попадают в exponential backoff (1.5s/2x, cap 30s). Не блокируют успешных.
- **`box.watch('config.info', ...)`** — мгновенный repoll при изменении локальной конфигурации.

## Two-phase commit для cluster config

Конфиг кластера — секция `config:` в Tarantool 3.x. Источник истины — etcd по ключу `<prefix>/config/all`. Запись идёт через 2PC, чтобы исключить «частичный commit» (часть пиров приняла, часть отвергла):

```
        propose(yaml)
            │
            ▼
   ┌─────────────────────────────────────────┐
   │  PREPARE (local)                         │
   │   - JSON-Schema validate                 │
   │   - cross-field validate                 │
   │   - generate diff vs current             │
   │   - write to replicated _webui_prepared  │
   └─────────────────────────────────────────┘
            │ prepared_id
            ▼
   ┌─────────────────────────────────────────┐
   │  VALIDATE on every peer                  │
   │   - fan-out через net.box pool           │
   │   - каждый peer: validate(yaml)          │
   │   - объединить результаты                │
   └─────────────────────────────────────────┘
            │ all ok?
            ▼
   ┌─────────────────────────────────────────┐
   │  COMMIT                                  │
   │   - etcd txn: put_if_witness_unchanged   │
   │     guarded by expected_rev              │
   │   - на успех → cleanup _webui_prepared   │
   │   - на CAS-conflict → CAS_CONFLICT       │
   └─────────────────────────────────────────┘
            │
            ▼
   tarantool config-watcher на каждом пире
   ├─► applier цепочка validate → apply
   └─► box.watch('config.info') → poller repoll
```

Ключевые детали:

- **`_webui_prepared` — реплицированный sync-space.** Раньше prepared-state жил в локальной памяти каждого инстанса, что ломалось при round-robin balancer'е (prepare на tt-1, commit на tt-2). Сейчас prepared виден на всех нодах, commit может прийти на любую.
- **Толерантность к лагу репликации в commit/abort.** `prepare()` на read-only фолловере форвардит запись лидеру и возвращается после ACK sync-кворума; данный фолловер может ещё не входить в кворум, поэтому back-to-back `commit()`/`abort()` (rollback, force-apply, «Discard prepared», а также интерактивный commit на другом инстансе) мог прочитать prepared row локально раньше репликации и упасть с `PREPARED_NOT_FOUND`. Lookup идёт через `twophase.wait_prepared`: на read-only-инстансе он ждёт появления row до `PREPARED_REPLICATION_WAIT_SEC` (default 3 c), на writable-лидере miss мгновенный (реальное отсутствие). См. `docs/troubleshooting.md` → «PREPARED_NOT_FOUND на commit после prepare».
- **CAS на commit** — etcd `put_if_witness_unchanged(key, value, witness_key, witness_revision)`. Каждый commit guarded by `expected_rev`, который клиент получил вместе с current YAML. Конкурентная правка → `CAS_CONFLICT`, UI показывает «Config changed, reload».
- **History** — `_webui_config_history` хранит хвост закоммиченных YAML c хешами для diff/rollback.
- **Forward to leader** — `prepare` и `commit` мутируют реплицированные спейсы, поэтому follower проксирует операцию лидеру через `webui_peer` connection. Это прозрачно для клиента.

## Supervised failover на open-source

Tarantool Community Edition не предоставляет «supervised» failover-режим из EE. WebUI реализует open-source аналог через два кооперирующихся фибера на каждом инстансе:

```
┌──── instance tt-1 ────┐  ┌──── instance tt-2 ────┐  ┌──── instance tt-3 ────┐
│                       │  │                       │  │                       │
│  agent fiber          │  │  agent fiber          │  │  agent fiber          │
│  ├── lease election   │  │  ├── lease election   │  │  ├── lease election   │
│  │   (etcd txn_create │  │  │                   │  │  │                   │
│  │    on /failover/   │  │  │                   │  │  │                   │
│  │    coordinator)    │  │  │                   │  │  │                   │
│  ├── keepalive (1s)   │  │  └── (waits for      │  │  └── (waits for      │
│  └── appointment_loop │  │       coordinator    │  │       coordinator    │
│      (only on lease    │  │       to die)        │  │       to die)        │
│       holder)          │  │                       │  │                       │
│                       │  │                       │  │                       │
│  watcher fiber        │  │  watcher fiber        │  │  watcher fiber        │
│  └── poll appointment │  │  └── poll appointment │  │  └── poll appointment │
│      → box.ctl.promote│  │      → box.ctl.promote│  │      → box.ctl.promote
│      / box.ctl.demote │  │      / box.ctl.demote │  │      / box.ctl.demote │
└───────────────────────┘  └───────────────────────┘  └───────────────────────┘
```

### Гарантии

| Свойство | Механизм |
|---|---|
| **Election safety** | Не более одного coordinator одновременно. Lease связан с ключом через `txn_create`; при истечении lease etcd сам удаляет ключ. |
| **Appointment safety** | Каждая запись appointment'а CAS-bound к `mod_revision` ключа coordinator'а. Stale coordinator, проснувшийся после истечения lease, не может перезаписать appointment, выпущенный новым coordinator'ом. |
| **Hysteresis** | Не более одной смены лидера за `min_promotion_interval` секунд — защищает от flapping на borderline-healthy кандидате. |
| **Fencing** | Кандидат должен быть `box.info.status == 'running'` с ограниченным replication lag. Stale/orphan peers отвергаются. |
| **Idempotency** | Appointment не переписывается, если payload не изменился; lease keepalive работает даже при «тихом» периоде. |
| **Single-writer lock** | Режим `replication.failover: supervised`: applier поднимает инстансы read-only (RW только у bootstrap-лидера без снапшота), а в рантайме writer-lock — это ownership synchronous queue (`box.ctl.promote/demote`), назначаемый агентом. `database.mode` не задаётся. Все WebUI критичные спейсы синхронные → multi-master на них невозможен; term-фильтр лимба отвергает записи старого лидера (data-plane fence). |

### Latency

При TTL 15s + keepalive 5s + appointment 1s + watcher poll 1s:
- **Soft failover** (graceful shutdown лидера): ~1–2 секунды.
- **Hard failover** (kill -9 лидера, coordinator жив): ~2–3 секунды.
- **Coordinator + leader одной командой**: до ~TTL (нужно дождаться lease expiry + новой elections + appointment).

### Переключение режимов

- **Fallback `off`** (legacy): агент по-прежнему стартует при `replication.failover: off`; запасной путь, если сборка Tarantool отвергает `supervised` на CE. Гарантии RO-при-рестарте слабее.
- **Встроенный raft:** `replication.failover: election` + `roles_cfg.webui.failover.agent: false`. Агент отказывается стартовать при `failover ∈ {election, manual}`, double-leadership на transition исключён.

## Synchronous spaces

Все critical-state спейсы помечены `is_sync=true` (миграция №5). Запись подтверждается только после ACK от `synchro_quorum` follower'ов (`N/2+1` для 3 нод):

| Space | Хранит | Размер ~ |
|---|---|---|
| `_webui_sessions` | session cookie → user, expiry | 1 row per login |
| `_webui_audit` | actor, action, target, ts, request_id, payload | ~1 row per mutation |
| `_webui_webhook_queue` | pending outbound deliveries | ~ N retries × failed receivers |
| `_webui_webhook_dead_letter` | финально провалившиеся deliveries | rare |
| `_webui_prepared` | prepared YAML конфиги, TTL 5min | ≤ 5 одновременно |

`_webui_meta` — `is_local: true` (per-instance bookkeeping, `schema_version`). Не реплицируется и асинхронный.

Параметры в cluster YAML:

```yaml
replication:
  synchro_quorum: 'N/2 + 1'
  synchro_timeout: 3
```

## Audit log

`backend/webui/audit/log.lua` записывает каждое мутирующее действие в `_webui_audit`:

- Поля: `id`, `ts`, `user`, `action`, `target`, `status`, `request_id`, `payload`.
- Индексы: `primary{id}`, `by_ts`, `by_user` (миграция №2).
- Read-only follower'ы проксируют запись лидеру через `webui_audit_record_remote` net.box shim.
- Retention: фоновый фибер `audit.retention` раз в час свипает строки старше `roles_cfg.webui.audit_retention_days` (default 90, минимум 1). Бюджет одного тика — 5000 удалений; работает только на лидере.

## Outbound webhooks

`backend/webui/notifications/` подписывается на in-process события (`issue.appeared`, `config.committed`, `vshard.bootstrap`, `audit.security`, `bundle.downloaded`, …) и доставляет их по HTTPS/SMTP внешним адресатам:

```
emit(event)
   │
   ▼  fanout (match event vs webhooks list)
   │
   ▼  INSERT в _webui_webhook_queue (replicated, sync)
   │
   ▼  dispatcher fiber (только на лидере)
   │   ├── pick by_next_attempt index
   │   ├── HTTP POST (slack/discord/generic) / SMTP (email)
   │   ├── on success → DELETE row, audit
   │   └── on fail → exponential backoff (1s/5s/30s/300s, max 5)
   │                  → переместить в _webui_webhook_dead_letter
   ▼
```

Receivers: `slack`, `discord`, `generic` (HTTPS POST + опц. HMAC-SHA256 в `X-Webui-Signature`), `email` (SMTP с STARTTLS).

`testWebhook(name)` обходит очередь — синхронная доставка synthetic-события для проверки конфигурации. `clearDeadLetter` мутация — `TRUNCATE` на dead-letter.

## HTTP-сервер и middleware

Один экземпляр `http.server` (rock `http >= 1.6`) на инстанс. Адрес — `roles_cfg.webui.listen` (default `0.0.0.0:8081`).

```
client ─► http.server (TCP + HTTP parsing)
           │
           ▼  hook before_dispatch → req._webui_seen_at = fiber.time()
           ▼  http.server.match(method, path) → endpoint
           │
           ▼  middleware.wrap(name, handler)
           │   1. assign_request_id (header или UUID v4)
           │   2. CORS preflight short-circuit
           │   3. session lookup → ensure_authenticated
           │   4. RBAC route check
           │   5. CSRF на POST/PUT/PATCH/DELETE
           │   6. pcall(handler, req)
           │   7. response.headers['x-request-id']
           │   8. apply_security_headers
           │   9. structured-log (debug/info/error по status)
           ▼
        response ─► client
```

Heartbeat-фибер каждую секунду пульсирует `STATE.last_heartbeat_at = fiber.time()`. Используется `/api/health` для детекции TX-thread block: `now - last_heartbeat > 5s` → `unhealthy` → HAProxy выводит из ротации.

## SPA: pipeline и раздача

Frontend собирается Vite + Bun в `frontend/dist/`, упаковывается в `backend/webui/assets/bundle.lua` (base64 + ETag SHA-1 + MIME + pre-compressed br/gz варианты) и раздаётся `backend/webui/http/static.lua`:

```
frontend source ──► bun run build ──► frontend/dist/ (index.html + assets/* + .br + .gz)
                                              │
                                              ▼  tools/embed-assets.lua
                                              │
                                              ▼
                              backend/webui/assets/bundle.lua  (generated, gitignored)
                                              │
                                              ▼  static.lua handler
                                              │   ├── Accept-Encoding: br > gz > raw
                                              │   ├── If-None-Match → 304
                                              │   ├── /assets/* → immutable (1y)
                                              │   └── SPA history fallback → /index.html
                                              ▼
                                          browser
```

Размер production-бандла: ~189 КиБ brotli (initial chunks), ~4.2 МБ в `bundle.lua` на диске (raw + br + gz в base64).

## Frontend codegen

GraphQL SDL экспортируется offline прямо из исходного кода схемы (поднимать backend не нужно):

```
backend/webui/graphql/schema.lua
   │  tarantool tools/dump-schema.lua
   ▼
frontend/src/shared/api/schema.graphql  (gitignored)
   │  bunx graphql-codegen --config codegen.yml
   ▼
frontend/src/shared/api/__generated/{gql,graphql}.ts  (gitignored, TS types + DocumentNodes + Vue urql composables)
```

Команды: `make dump-schema` / `make gen-types` / `make gen-types-watch`.

## Live updates по WebSocket

`/ws` endpoint держит broadcast-канал для всех залогиненных клиентов. Источники событий:

- `poller` — каждый tick, если snapshot изменился (server appeared/disappeared, RO flip).
- `issues_scanner` — issue appeared/cleared.
- `suggestions_engine` — новая suggestion stored.
- `config_watcher` — config.committed на этом пирe.

Frontend через `@/shared/api/ws/client.ts` (singleton с auto-reconnect, exponential backoff 500ms…30s) делает refetch соответствующих GraphQL query на каждое подходящее сообщение.

Гейтинг: handshake требует валидную сессию (тот же `webui_session` cookie). Slow consumer (backlog > 1000 frames) → close 1008.

**Liveness двунаправленный.** Per-connection heartbeat-фибер считает соединение живым, если за `PONG_DEADLINE_SEC` (60s) пришёл pong **или** удалось отправить клиенту данные (успешный `safe_write` data-фрейма обновляет `last_send`). Закрытие (`idle_timeout`, 1008) — только когда обе стороны молчат дедлайн; ping (`PING_INTERVAL_SEC`, 30s) шлётся только на простаивающем линке. Так клиент, который активно получает снапшоты, не отрывается из-за того, что его pong-фреймы не доходят до сервера (их теряют некоторые прокси / сетевой стек dev-окружения), а реально мёртвый пир всё равно ловится — записи к нему начинают падать и writer выставляет `entry.closed`.

**Владение сокетом.** Сокет соединения закрывает `tcp_server_handler` http-rock'а (`shutdown()`+`close()`) ровно один раз, после возврата хендлера. Код роли сокет **не закрывает** — reader/writer/`close_fn` только выставляют `entry.closed`. Ранний `sock:close()` приводил к `attempt to use closed socket` в фибере `webui_ws_writer_<id>` на каждом реконнекте.

## Логирование

`backend/webui/log_util.lua` — единая точка. Прямое `log.*` из Tarantool запрещено в коде роли.

JSON в одну строку:

```json
{"ts":"2026-05-30T12:34:56.789012Z","level":"info","tag":"http","instance":"tt-1","msg":"request accepted","request_id":"abc","latency_ms":12}
```

Стандартные теги: `init`, `http`, `cluster`, `cluster.self_reporter`, `config`, `auth`, `audit`, `ws`, `graphql`, `etcd`, `metrics`, `fiber`, `migration`, `failover.agent`, `failover.watcher`, `notifications`.

Уровень — `roles_cfg.webui.log_level` или env `WEBUI_LOG_LEVEL`, default `debug`. JSON-сериализация в `pcall`; на сбое — degraded-строка с `"_encode_error":true`, никаких throw'ов.

## `config.etcd` на Community Edition

Tarantool 3.x принимает блок `config.etcd:` только в Enterprise — на CE он отвергается схемой по флагу `enterprise_edition = true` на узле. WebUI поставляет open-source аналог через `backend/internal/config/extras.lua`. Tarantool автоматически подгружает его при старте (см. `load_extras` в `src/box/lua/config/init.lua`).

### Targeted schema relaxation

`extras.lua` **не подменяет** `tarantool.package`. Глобальная подмена пропустила бы все EE-чекеры разом, включая узлы вроде `flightrec_*`, чьи default-значения дальше передаются в `box.cfg{...}` — а соответствующих C-подсистем в CE-бинарнике нет, и `box.cfg` падает.

Вместо этого `extras.lua` рекурсивно обходит схему `instance_config` и `cluster_config` и точечно заменяет `validate` и `apply_default_if` только на тех `enterprise_edition = true` узлах, чей путь начинается с одного из разрешённых префиксов:

```
config.etcd                    — etcd config source
config.storage                 — centralized config storage
iproto.listen                  — TLS listen params
iproto.advertise.peer          — TLS peer-advertise params
iproto.advertise.sharding      — TLS sharding-advertise params
iproto.advertise.client        — TLS client-advertise params
```

Всё, что вне allow-list (`flightrec_*`, `audit_*`, `wal_ext`, ...) сохраняет свой EE-валидатор и продолжает отвергаться на CE — то есть `box.cfg{...}` не получит дефолтов для подсистем, которых в CE нет.

Затем регистрируется `webui.config_source.etcd_source` через `config:_register_source(...)`. Источник реализует стандартный контракт `name='etcd'`, `type='cluster'`, `sync()`, `get()`.

На каждом `sync`:
- Читает `config.etcd.{endpoints, prefix, username, password, ssl}` из текущего iconfig.
- При наличии username → `POST /v3/auth/authenticate` → JWT.
- `POST /v3/kv/range` для `<prefix>/config/all` (canonical) → fallback `<prefix>/config` (legacy).
- Перебирает endpoints до первого успеха (sticky failover).
- Декодирует value из base64, парсит YAML.

### Что расширяет shim и что — нет

- ✅ Разрешает писать `config.etcd:` блок в cluster YAML на CE.
- ✅ Разрешает писать `config.storage:` блок.
- ✅ Разрешает iproto TLS-параметры (`ssl_ca_file`, `ssl_cert_file`, `ssl_key_file`, `ssl_ciphers`, `ssl_password`/`ssl_password_file`) для peer-to-peer mTLS.
- ✅ Регистрирует собственный config-source реализованный на стороне WebUI поверх etcd v3 HTTP API.
- ❌ Не включает другие EE-функции (`audit_log`, `flightrec_*`, `wal_ext` и т.п.) — лицензированных C-модулей в CE-бинарнике нет, и shim не пытается их «оживить».
- ❌ Не подменяет `tarantool.package` — инстанс продолжает идентифицироваться как Community Edition в `box.info`, логах и API.

## See Also

- [Operations](operations.md) — как разворачивать и эксплуатировать
- [Security](security.md) — TLS, RBAC, audit, threat model
- [GraphQL API](api/graphql-schema.md) — полный SDL и описание операций
