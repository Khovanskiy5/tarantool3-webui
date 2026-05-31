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

## HTTP-сервер (Task 3)

`backend/webui/http/server.lua` — обёртка над rock'ом `http >= 1.6`. Один экземпляр `http.server` на инстанс. Адрес — `roles_cfg.webui.listen` (default `0.0.0.0:8081`).

### Структура запроса

```
client
  │
  ▼
http.server (TCP + HTTP parsing)
  │
  ▼ hook before_dispatch → req._webui_seen_at = fiber.time()
  ▼
http.server.match(method, path) → endpoint
  │
  ▼  middleware.wrap(name, handler) [pcall around handler]
  │   1. assign_request_id (header or generated UUID v4)
  │   2. CORS preflight short-circuit (если 'OPTIONS' и origin разрешён)
  │   3. pcall(handler, req)
  │   4. response.headers['x-request-id']
  │   5. apply_security_headers
  │   6. structured log entry (debug/info/error по status)
  │
  ▼
response → client
```

### Middleware (`http/middleware.lua`)

Реализован composition-подход через wrapper `middleware.wrap(name, sub, opts)`:

- **Request-ID** — заголовок `X-Request-Id` (валидация pattern и длины) или fresh UUID v4.
- **CORS** — конфигурируется через `opts.allowed_origins` (по умолчанию nil → CORS-заголовки не добавляются). Wildcard `*` запрещён на credentialed endpoint'ах.
- **Security headers** — обязательный набор (см. `docs/security.md`).
- **Error envelope** — handler выполняется в `pcall`; на panic возвращается `INTERNAL` envelope, реальная ошибка логируется с request_id.
- **Структурный лог** — debug на каждый ответ; info на 4xx; error на 5xx. Поля: `request_id`, `method`, `path`, `status`, `latency_ms`.

Auth и CSRF middleware появятся в Task 26 как extensions того же wrapper'а.

### Heartbeat-фибер

Каждую секунду пульсирует `STATE.last_heartbeat_at = fiber.time()`. Используется `/api/health` для детекции TX-thread block: если `now - last_heartbeat > 5s`, фибер не мог запуститься → TX-тред застрял → `status: "unhealthy"` + HTTP 503 + `Retry-After: 5`.

При остановке роли — cooperative stop с двухсекундным дедлайном; при превышении — warn в лог.

### Регистрация роутов

Другие модули вызывают:

```lua
local server = require('webui.http.server')
server.register_route('GET', '/api/foo', 'foo_handler', function(req)
    return { status = 200, body = '...' }
end, { allowed_origins = {...} })
```

Wrapper применяется автоматически.

### Error envelope (`http/error_envelope.lua`)

Единый формат REST-ошибок:

```json
{ "error": { "code": "STABLE_CODE", "message": "human readable", "request_id": "uuid", "details": {...}? } }
```

Принимает на вход: error-rock объекты (`.class_name`, `.err`), plain string, table `{code,message,details}` или nil. Нормализует в стабильную структуру. Внутренние ошибки (`code == INTERNAL`) полностью маскируются: тело содержит только generic `"internal error"`, реальные данные — в structured-логе.

HTTP-статус выводится из `errors.HTTP_STATUS[code]`, отсутствие → 500.

### Health endpoint (`api/health.lua`)

См. `docs/api/rest.md` — двухуровневый ответ ok/degraded/unhealthy с расширяемыми checks. Extension point — `health.register_check(name, fn)` для модулей, которые приходят позже (etcd → Task 30, peers → Task 17, config → Task 27).

## Frontend каркас (Task 4)

Frontend живёт в `frontend/` и собирается через **Bun + Vite + Vue 3 + TypeScript**. Архитектурно — Feature-Sliced Design.

### Слои FSD

```
src/
├── app/         инициализация (main.ts, App.vue), router, providers, глобальные стили
├── pages/       роутовые слайсы (errors/{not-found,forbidden,network-error} на момент Task 4)
├── widgets/     композитные блоки (sidebar, top-bar)
├── features/    пользовательские сценарии (появляются по мере задач)
├── entities/    бизнес-сущности (появляются по мере задач)
└── shared/      инфраструктура без знания домена (api, ui, lib, config, i18n)
```

Направление импортов: `app → pages → widgets → features → entities → shared`. Импорт только через публичный `index.ts` каждого слайса. Контроль — `eslint-plugin-boundaries`, конфиг в `frontend/.eslintrc.cjs` (правило `boundaries/element-types` и `boundaries/no-private`).

`tsconfig.paths` и `vite.config.resolve.alias` зеркалируют слои через алиасы `@/app`, `@/pages`, `@/widgets`, `@/features`, `@/entities`, `@/shared`. Алиасы обязаны быть побайтово идентичны в обоих файлах.

### Bun-runtime

- Менеджер пакетов и runtime — **Bun ≥ 1.1**, не Node/npm.
- Lockfile — `bun.lockb` (бинарный, коммитится).
- Vite, vue-tsc, ESLint, vitest, Playwright работают под Bun без модификаций.
- `bunfig.toml` фиксирует registry, отключает встроенный `bun test` (используем vitest для лучшей Vue-интеграции).

### Vite-сборка

- `base: './'` — относительные пути ассетов работают за HAProxy и sub-path-деплоями.
- `vite-plugin-compression2` — pre-compressed brotli+gzip за один проход (двойной вызов плагина гонится на одном rollup-output).
- Manual chunks: `vendor-vue`, `vendor-urql`, `vendor-primevue`, `vendor-misc`, `monaco-editor`.
- Target `es2022`, `cssCodeSplit: true`, `sourcemap: 'hidden'` (карты не ссылаются из HTML — пригодны для приватной загрузки в error-tracker).
- Monaco workers подключаются через native Vite `?worker`-импорт в `widgets/yaml-editor/ui/YamlEditor.vue` (Task 38), а не через legacy `vite-plugin-monaco-editor` (несовместим с Vite 5+).
- `tools/embed-assets.lua` пропускает `*.map` файлы при паковке бандла — Monaco source-maps занимают 12+ MiB и не нужны runtime'у (для error-tracker'а карты грузятся напрямую из `dist/` до деплоя).

### Initial bundle и бюджет

На пустом каркасе:
- `vendor-vue` (vue+router+pinia+vue-i18n): ~57 КБ gzipped.
- `vendor-primevue`: ~11 КБ gzipped.
- `vendor-urql`: ~10 КБ gzipped.
- `index` (app shell + widgets): ~21 КБ gzipped.
- Initial total ≈ **99 КБ gzipped** (бюджет initial — 350 КБ, см. Performance budgets).

Lazy chunks страниц ошибок — < 1 КБ каждая.

### i18n

`vue-i18n@^9` с `legacy: false`. Инстанс — `@/shared/i18n`, bootstrap — `@/app/providers/i18n`. Локали:

- `ru` (default), `en` — оба полностью покрыты ключами `common/app/widgets/pages/errors`.
- Стратегия определения: localStorage `webui:locale` → `navigator.language` → default `ru`.
- Missing-key: warning в dev, silent fallback на `en` в prod.
- Плюрализация — built-in pipe syntax `vue-i18n`.

Полная стратегия — `docs/development.md`, секция i18n.

### Клиентский логгер

`@/shared/lib/log` — пара функций + `withTag(tag)` для тегированных логгеров. Уровень из `VITE_LOG_LEVEL`, дефолт — `debug` в dev, `warn` в prod. Pretty-print в dev, JSON в prod. Hook `subscribeSink(sink)` позволит forward'ить critical errors на backend в одной из следующих задач.

### Error boundary

`@/app/providers/error-boundary` устанавливает `app.config.errorHandler`, `window.onerror`, `unhandledrejection` — все три путь логирования. Toast UX добавится вместе с shared/ui toast-утилитой.

### Страницы ошибок

`pages/errors/{not-found, forbidden, network-error}` — каждая со своим `index.ts`, экспортирующим Vue-компонент и `ROUTE`-константу. Router собирает все ROUTE в `@/app/router`. Все три страницы — accessibility-ready (`role="alert"`, `aria-live="polite"`, keyboard-focusable action).

### Сетевые прокси (dev)

`vite.config.server.proxy` направляет `/admin/api`, `/api/*`, `/ws` на `VITE_BACKEND_URL` (default `http://localhost:8081`). В compose-окружении это `tt-1`.

## Упаковка SPA в Lua-модуль (Task 5)

Frontend собирается Vite'ом в `frontend/dist/`. Чтобы любой Tarantool-инстанс мог отдавать SPA без отдельной файловой системы (важно для read-only контейнеров и rolling-rock-апгрейда), весь bundle упаковывается в Lua-модуль `backend/webui/assets/bundle.lua`.

### Пайплайн

```
frontend/source ──► bun run build ──► frontend/dist/
                                          │
                                          │ vite-plugin-compression2
                                          │ → emits .br + .gz siblings
                                          ▼
                            frontend/dist/
                              index.html  index.html.br  index.html.gz
                              assets/foo.js  assets/foo.js.br  assets/foo.js.gz
                              …
                                          │
                                          │ tools/embed-assets.lua
                                          │ (make embed-assets)
                                          ▼
                  backend/webui/assets/bundle.lua  ← generated, gitignored
```

### Формат bundle.lua

```lua
local base64_decode = require('digest').base64_decode
local function decode(b) return base64_decode(b) end

return {
  ['/index.html'] = {
    mime     = 'text/html; charset=utf-8',
    etag     = '"1ea2a56ced4fe73e90bbbfb391d259c5c16d6b01"',  -- strong, SHA-1 of raw
    size_raw = 1291,
    size_br  = 415,
    size_gz  = 598,
    body_raw = decode([[<base64>]]),
    body_br  = decode([[<base64>]]),
    body_gz  = decode([[<base64>]]),
  },
  ['/assets/index-XXXXX.js'] = { ... },
  …
}
```

### Дизайн-решения

- **Base64, а не `\xNN`-escape**: длинная строка `[[…]]` с base64 в 4 раза компактнее, чем `\xNN`-escape каждого байта. Base64-алфавит `A-Za-z0-9+/=` не содержит `]`, поэтому конфликта с закрывающим `]]` не возникает.
- **`size_*` метаданные**: позволяют статик-хендлеру вычислить `Content-Length` без `#body` (быстрее).
- **Strong ETag = `"<sha1_hex>"`**: совпадает с RFC 7232; вычисляется только от raw — pre-compressed варианты имеют один тот же ETag, что соответствует семантике «то же представление, другая кодировка».
- **MIME по расширению**: таблица в скрипте, по умолчанию `application/octet-stream`.
- **Pre-compressed варианты не пересжимаются**: используются те, что эмитнул Vite. Это гарантирует bit-identical артефакты между `make build-frontend` и `make embed-assets`.
- **Стабильная сортировка ключей** (`table.sort(ordered_keys)`) делает bundle.lua воспроизводимым — два разных запуска на тех же входных данных дают побайтово одинаковый файл.
- **Включаем `.map`-файлы**: они тяжёлые (vendor-vue.js.map ~1.1 МиБ), но загружаются только при открытии DevTools. Не сжимаются (sourcemaps — JSON, который уже компактен).

### Размер и время загрузки

На текущем каркасном frontend:

| Метрика | Значение |
|---|---|
| Assets total raw | 2.75 МиБ (включая sourcemaps) |
| Assets total brotli | 189 КиБ (только сжатые формы main + page chunks + monaco-css) |
| `bundle.lua` на диске | 4.22 МиБ (raw + br + gz в base64) |
| Время `require('webui.assets.bundle')` | ~11 мс (cold load, jit прогрев) |
| Память после декодирования | ~3 МиБ (per-instance; разделяется между fiber-ами) |

При production frontend (без sourcemaps): bundle ожидаемо < 2.5 МиБ на диске и < 1.5 МиБ в памяти.

### Что использует bundle.lua

См. ниже раздел «Раздача статики (Task 6)».

### Запуск

```bash
make embed-assets        # вызывает make build-frontend, потом tarantool tools/embed-assets.lua
tarantool tools/embed-assets.lua [<source-dir>] [<output-file>]   # вручную
```

CLI печатает таблицу с маршрутами, MIME и размерами raw/br/gz и итоговую сводку. Скрипт коммитится в `tools/`, сгенерированный `bundle.lua` — gitignored (`backend/webui/assets/bundle.lua`).

## Раздача статики (Task 6)

`backend/webui/http/static.lua` — обработчик статических ресурсов SPA. На каждый `GET /<path>`:

1. **Нормализация path**: strip query/fragment; `/` → `/index.html`.
2. **Поиск в bundle**: `bundle[path]`.
3. **SPA history-mode fallback**: если в bundle нет, и путь НЕ начинается с `NON_SPA_PREFIXES` (`/api/`, `/admin/`, `/ws`, `/assets/`, `/monacoeditorwork/`, `/favicon.ico`, `/robots.txt`, `/sitemap.xml`, `/.well-known/`) — отдаёт `/index.html`. Это разрешает прямой переход на `/cluster`, `/issues`, `/config-editor` и т.п.
4. **Content negotiation**: `Accept-Encoding` парсится без q-values; приоритет `br > gz > raw`.
5. **Conditional GET**: `If-None-Match == entry.etag` → `304 Not Modified` с теми же `ETag` и `Cache-Control`, пустое тело.
6. **Cache-Control**:
   - `/assets/*` и `/monacoeditorwork/*` (content-hashed имена от Vite) → `public, max-age=31536000, immutable`.
   - `index.html` и все SPA-пути → `no-cache, no-store, must-revalidate`. Это безопасно потому что HTML мал, а ETag-revalidation быстра.

### Регистрация роутов

В `http/server.lua → register_builtin_routes`:

```
explicit высокая частота:
  GET /                       → static
  GET /index.html             → static
  GET /favicon.ico            → static
  GET /robots.txt             → static

asset-папки (catch-all внутри префикса):
  GET /assets/*splat          → static
  GET /monacoeditorwork/*splat → static

SPA history fallback (регистрируется последним):
  GET /*splat                 → static
```

Порядок важен: http rock матчит роуты в порядке регистрации. `/api/health` (зарегистрирован первым в Task 3) выигрывает у `/*splat`. Когда появятся `/admin/api` (Task 7) и `/ws` (Task 21), они регистрируются через `M.register_route()` ДО `register_builtin_routes` или с явной поправкой в server.lua.

### Graceful degradation

Bundle загружается через `pcall(require, 'webui.assets.bundle')`. Если `make embed-assets` не запускался (unit-тесты без фронта), модуль грузится с пустой таблицей. Все `GET` отдают 404, `/api/health` и остальные API-роуты продолжают работать. Это позволяет CI юнит-тесты бэкенда без необходимости собирать SPA.

### Логирование

`tag = static`. Каждый запрос логируется на уровне `debug` с полями: `path`, `resolved` (после нормализации/fallback), `status`, `encoding` (`br`/`gz`/`raw`), `size`, `outcome` (`hit`/`spa_fallback`/`304`). При `WEBUI_LOG_LEVEL=info` (prod) статика молчит — middleware `http` всё равно логирует request на info-уровне.

### Проверка end-to-end

| Сценарий | Запрос | Ответ |
|---|---|---|
| Корень SPA | `GET /` (Accept-Encoding: br, gzip) | 200, body_br, ETag, Cache-Control: no-cache |
| SPA fallback | `GET /cluster` | 200, body /index.html, no-cache |
| Content-hashed asset, brotli | `GET /assets/index-XXX.js` (Accept-Encoding: br) | 200, body_br, Content-Encoding: br, immutable |
| Conditional GET (matching) | `GET /index.html` (If-None-Match: matching) | 304, пустое тело, тот же ETag |
| Stale ETag | `GET /index.html` (If-None-Match: stale) | 200 + body |
| Identity encoding | `GET /index.html` (Accept-Encoding: identity) | 200 без Content-Encoding |
| Missing asset | `GET /assets/missing.js` | 404 (без SPA fallback) |
| Missing /api/* | `GET /api/missing` | 404 |
| Bundle отсутствует | `GET /` | 404 |

## GraphQL skeleton (Task 7)

`backend/webui/graphql/*` — GraphQL поверхность WebUI. Транспорт — `POST /admin/api` для запросов, `GET /admin/api/explore` для self-hosted explorer'а.

### Модули

| Файл | Назначение |
|---|---|
| `graphql/schema.lua` | Композиция GraphQL-схемы (объединение types + resolvers). Точка `M.build()` пересоздаёт schema на каждом `graphql.server.init`. |
| `graphql/server.lua` | HTTP-хендлеры `POST /admin/api` и `GET /admin/api/explore`. Управление lifecycle (`init`, `stop`, `status`). |
| `graphql/error_envelope.lua` | Формирование стандартного GraphQL-error shape с `extensions.code/request_id`, маппинг code→HTTP. |
| `graphql/types/health.lua` | Тип `RoleStatus` (lifecycle роли). |

### Pipeline на запрос

```
POST /admin/api  Content-Type: application/json
   │
   ▼ middleware.wrap('graphql')  ← request-id, security headers, pcall, log
   │
   ▼ server.handler(req)
   │
   ├─ read body (req:read_cached)            → 400 INVALID_QUERY на read fail
   ├─ json.decode body                       → 400 INVALID_QUERY на JSON fail
   ├─ validate "query" field is non-empty    → 400 INVALID_QUERY
   ├─ pcall parse.parse(query)               → 400 INVALID_QUERY с err text
   ├─ pcall validate.validate(schema, doc)   → 400 VALIDATION_ERROR с err text
   ├─ pcall execute.execute(schema, doc, rootValue, vars, opName)
   │       где rootValue = { request_id }    → 500 INTERNAL на crash (message маскируется)
   │
   ▼ json.encode({data = result})
   │
   ▼ 200 OK
```

`pcall` на каждом шаге. Никаких stack-trace наружу. Реальный текст ошибки (для diagnostics) — в structured-логе по тому же `request_id`.

### Резолверы M0

Skeleton-резолверы для smoke и для будущей интеграции:

- `Query.ping: String!` → `"pong"`.
- `Query.serverTime: String!` → ISO 8601 UTC с микросекундами.
- `Query.webuiVersion: String!` → SemVer rock'а.
- `Query.roleStatus: RoleStatus!` → снимок lifecycle через `webui.status()`.
- `Query.configJsonSchema: String` → JSON-encoded `config:jsonschema()` Tarantool 3.x. Единый источник истины для backend-валидации (Task 32) и Monaco-autocomplete (Task 38). `null` если модуль `config` недоступен.
- `Mutation._noop: Boolean!` → placeholder, удаляется в Task 26 когда появятся реальные mutation'ы.

### GraphiQL Explorer

`GET /admin/api/explore` — self-contained минимальный explorer (textarea + кнопка + JSON-результат, ~3 КБ inline JS+CSS). НЕ полный GraphiQL (он бы потребовал vendor'ить React + ProseMirror ≈ 1 МБ).

Гейтинг:
- `roles_cfg.webui.graphiql_enabled = false` (default) → 404
- `roles_cfg.webui.graphiql_enabled = true` → 200 + relaxed CSP (`script-src 'self' 'unsafe-inline'`) для inline-скрипта explorer'а

В Task 26 добавится RBAC-проверка (доступ только `admin`/`superuser`); сейчас фильтр — только по конфигу роли.

### Регистрация роутов

В `http/server.lua → register_builtin_routes` после `/api/health`:

```
POST /admin/api          → middleware.wrap('graphql',          graphql.handler)
GET  /admin/api/explore  → middleware.wrap('graphql_explorer', graphql.graphiql_handler)
```

Затем static routes. SPA catch-all `/*splat` идёт последним.

### Quirks rock'а `graphql`

- `parse.parse` и `validate.validate` бросают исключение на ошибку (а не возвращают `nil, err`). Wrapping в `pcall` обязателен.
- `execute.execute` принимает 5 позиционных аргументов: `(schema, doc, rootValue, variables, operationName)`. **Нет** отдельного context-параметра. Per-request данные (request_id, в будущем user) передаются через `rootValue`.
- `execute.execute` не изолирует resolver-сбои. Если один резолвер кидает — всё выполнение фейлится. Для skeleton-резолверов это OK; для тяжёлых резолверов (cluster, config, …) в Tasks 18+ будем оборачивать каждый в локальный `pcall` и возвращать `nil, err` поверх стандартных результатов.

### Graceful degradation

`require('webui.graphql.server')` оборачивается в `pcall` в `register_builtin_routes`. Сбой загрузки модуля или `graphql_srv.init` → WARN/ERROR в логе, `/admin/api` не регистрируется, остальное (`/api/health`, статика) работает.

### Проверка end-to-end

| Сценарий | Запрос | Ответ |
|---|---|---|
| ping | `POST {query:"{ping}"}` | 200 `{"data":{"ping":"pong"}}` |
| roleStatus | `POST {query:"{roleStatus{state version}}"}` | 200 `{"data":{"roleStatus":{"state":"ready",…}}}` |
| introspection | `POST {query:"{__schema{queryType{name}}}"}` | 200 `{"data":{"__schema":{"queryType":{"name":"Query"}}}}` |
| Parse error | `POST {query:"{ ping"}` | 400 `{"errors":[{"code":"INVALID_QUERY",…}]}` |
| Validation error | `POST {query:"{ doesNotExist }"}` | 400 `{"errors":[{"code":"VALIDATION_ERROR",…}]}` |
| Empty body | `POST` без body | 400 `INVALID_QUERY` |
| Explorer (disabled) | `GET /admin/api/explore` | 404 |
| Explorer (enabled) | `GET /admin/api/explore` | 200 text/html, 3 КБ |

## Frontend codegen и API-клиенты (Task 8)

Типы и операции GraphQL генерируются из SDL, дампимого офлайн прямо из исходного кода схемы. Поднятый backend не нужен — это критично для CI и для разработки без docker-compose.

### Пайплайн

```
backend/webui/graphql/schema.lua    (источник правды)
    │
    │ tarantool tools/dump-schema.lua [path]
    │ (загружает модуль schema, не открывает сокет)
    ▼
frontend/src/shared/api/schema.graphql    (SDL, gitignored)
    │
    │ bunx graphql-codegen --config codegen.yml
    ▼
frontend/src/shared/api/generated.ts      (TS types + DocumentNodes + Vue composables, gitignored)
```

Оркестратор — `tools/gen-types.sh` (вызывается `make gen-types` или `bun run gen-types`).

### `tools/dump-schema.lua`

Собственный SDL-printer на Lua. Walk'ает `schema:getTypeMap()`, фильтрует built-ins (`String/Int/Float/Boolean/ID` и `__*` introspection-типы), эмитит в стабильном порядке:

```
schema { query: Query, mutation: Mutation }
scalars  (по алфавиту)
enums
interfaces
unions
objects
input objects
```

Поддерживает: `type/interface/input/enum/union/scalar`, описания (`""" … """`), nullability (`T!`), списки (`[T]`), interface implementations, аргументы.

Выход: stdout или файл по argv[1]. Stderr-логи только при `os.exit ≠ 0` или подтверждение записи в файл.

### `frontend/codegen.yml`

`graphql-codegen` плагины:
- `typescript` — базовые TS-типы из SDL.
- `typescript-operations` — типы результатов queries/mutations.
- **`typescript-vue-urql`** — импортирует из `@urql/vue` (не из React-flavoured `urql`). Эмитит `useFooQuery/useFooMutation` composables.

Конфиг:
- `avoidOptionals: true` — точное соблюдение nullability SDL.
- `maybeValue: 'T | null'` — плоский `T | null` вместо `Maybe<T>` для лёгкости чтения.
- `scalars: { DateTime: string, UUID: string, JSON: 'Record<string, unknown>' }` — стартовая карта кастомных скаляров (будет расти в Tasks 18+).
- `namingConvention: keep` — имена совпадают с SDL (PascalCase types, camelCase fields).

Сгенерированный файл — `frontend/src/shared/api/generated.ts`. Документы операций — `frontend/src/shared/api/graphql/*.graphql` (плюс будущие per-slice операции из `entities/*/api/*.graphql`).

### urql-клиент

`@/shared/api/graphql/client.ts` — `createWebuiClient(handlers?)`.

Exchanges (порядок):
1. `cacheExchange` — встроенный documentCache (без `@urql/exchange-graphcache` — для админ-интерфейса этого хватает; нормализованный кэш требует declare keys на каждый тип, выгода низкая).
2. `csrfExchange` — для mutations берёт `webui_csrf` из cookies (HttpOnly cookie сессии настраивается в Task 25), добавляет `X-CSRF-Token` в fetch-options.
3. `tapErrorCodes` — анализирует `result.error.graphQLErrors[].extensions.code`:
   - `UNAUTHORIZED` / `SESSION_EXPIRED` → `onUnauthorized` (default: redirect на `/login?reason=unauthorized`).
   - `FORBIDDEN` → `onForbidden` (default: redirect на `/forbidden`).
   - Прочие — warn в structured log с `code/request_id`.
   - Network errors → `onNetworkError` (default: error log).
4. `fetchExchange` — стандарт.

Параметр `handlers` принимает кастомные функции для тестов/Storybook (опт-аут от навигации).

`@/app/providers/urql` теперь обёртка над `createWebuiClient()` — установка клиента на Vue app остаётся в layer `app/`, но логика клиента — в `shared/api`.

### REST-клиент

`@/shared/api/rest/client.ts` — `RestClient` для эндпоинтов вне GraphQL.

- `get/post/put/delete<T>(path, body?, opts?)` — типизированные методы.
- На state-changing методах (`POST/PUT/DELETE`) автоматически добавляется `X-CSRF-Token`.
- 401/403 → те же handlers (`onUnauthorized`/`onForbidden`).
- Не-2xx ответ парсится как `{error: {code, message, request_id, details?}}` envelope (Task 3 формат), кидается `RestApiError(code, status, requestId, details)` — call site может switch'ить по стабильному `code`.
- Поддержка raw body (`opts.rawBody` для file upload) и raw response (`opts.raw` для blob download).
- Возврат `null` на 204.

Доступен как именованный экспорт `restClient` (instance на same-origin) и как класс `RestClient` для кастомных base-path / handlers.

### Команды

| Команда | Назначение |
|---|---|
| `make dump-schema` | Записать SDL в `frontend/src/shared/api/schema.graphql` |
| `make gen-types` | Полный пайплайн: dump-schema + graphql-codegen |
| `bun run gen-types` (frontend/) | То же без префикса `make` |
| `make gen-types-watch` | Watch-режим codegen (без re-dump SDL) |

### Что в gitignore

Артефакты пайплайна — gitignored, регенерируются по требованию:
- `frontend/src/shared/api/schema.graphql`
- `frontend/src/shared/api/generated.ts`

Source-документы (`frontend/src/shared/api/graphql/*.graphql`) — коммитятся.

## Дальнейшие разделы

Появляются по мере реализации задач:

- Graceful shutdown sequence → Task 3a.
- GraphQL skeleton + GraphiQL → Task 7.
- Cluster state, poller, issues, suggestions → Tasks 13–20.
- Two-phase commit + etcd → Tasks 30–34.
- Failover, vshard, lifecycle → Tasks 46–53.
