[← Troubleshooting](troubleshooting.md) · [Back to README](../README.md) · [GraphQL API →](api/graphql-schema.md)

# Development guide

Setup, Makefile, тесты, конвенции, CI. Для большой картины — `architecture.md`.

## Требования к окружению

| Компонент | Версия | Назначение |
|---|---|---|
| Tarantool | ≥ 3.7.0, < 4.0 | Runtime backend'а + `tools/dump-schema.lua`, `tools/embed-assets.lua` |
| Bun | ≥ 1.1 | Runtime и пакетный менеджер frontend'а |
| Docker + Docker Compose | актуальные | Локальный кластер, integration tests, e2e |
| LuaRocks | актуальный | Установка backend-зависимостей |
| luatest | актуальный | Backend tests |
| luacheck | актуальный | Backend linter |

Установка на macOS:

```bash
brew install tarantool luarocks
brew tap oven-sh/bun && brew install bun
luarocks install --local luatest luacheck luacov
```

На Linux: официальный репозиторий Tarantool, бинарный установщик Bun, системные пакеты LuaRocks/luacheck.

## Быстрый старт

```bash
git clone <repo>
cd tarantool-webui
make dev
```

После healthy-сигнала открыть `http://localhost:8080`. Dev-фикстуры credentials (см. `docker/configs/cluster/10-credentials.yaml`):

| User | Password | Role |
|---|---|---|
| `admin_dev` | `admin-dev-password` | admin |
| `operator_dev` | `operator-dev-password` | operator |
| `viewer_dev` | `viewer-dev-password` | viewer |
| `superuser_dev` | `superuser-dev-password` | superuser |

## Команды Makefile

```bash
make help                 # печатает список целей с описаниями
```

| Цель | Назначение |
|---|---|
| `make dev` | Поднять локальный кластер: HAProxy + 3 инстанса + etcd |
| `make dev-down` | Остановить кластер и удалить volumes |
| `make dev-logs` | Tail логов всех сервисов |
| `make lint` | `lint-backend` (luacheck) + `lint-frontend` (eslint) |
| `make lint-fix` | Автоисправления frontend (ESLint --fix) |
| `make test` | `test-backend` + `test-frontend` (unit only) |
| `make test-backend` | luatest unit tests |
| `make test-frontend` | vitest unit tests |
| `make test-integration` | Backend integration tests (luatest + docker-compose) |
| `make test-e2e` | Playwright e2e против поднятого dev compose |
| `make install` | `bun install --frozen-lockfile` для frontend |
| `make build-frontend` | Production build SPA (Vite via Bun) |
| `make dump-schema` | Export GraphQL SDL (offline, без поднятого кластера) |
| `make gen-types` | Сгенерировать TS-типы из SDL |
| `make gen-types-watch` | Watch SDL и регенерация TS-типов |
| `make embed-assets` | Упаковка `frontend/dist/` в `backend/webui/assets/bundle.lua` |
| `make docker-build` | Сборка Docker-образа инстанса |
| `make check-all` | Полный pre-PR прогон: lint + tooling-check + test |
| `make clean` | Удалить артефакты сборки |

## Тесты

### Unit-тесты — `make test`

| Команда | Что проверяет | Время |
|---|---|---|
| `.rocks/bin/luacheck backend/ tools/` | Backend Lua-стиль и сложность | ~1с |
| `.rocks/bin/luatest backend/test/unit/` | Unit-тесты модулей backend | ~2с |
| `cd frontend && bun run lint` | ESLint + plugin-vue + FSD boundaries | ~3с |
| `cd frontend && bun run format` | Prettier (check-only) | ~1с |
| `cd frontend && bun run type-check` | `vue-tsc --noEmit` | ~5с |
| `cd frontend && bun run test:unit` | Vitest + happy-dom | секунды |
| `cd frontend && bun run build` | Production Vite build | ~2с |

### Integration-тесты — `make test-integration`

`backend/test/helpers/` скрывает рутину поднятия Tarantool и etcd:

- `paths.lua` — `repo_root`, `package.path`/`package.cpath` для in-tree `backend/` и `.rocks/`.
- `server.lua` — наследник `luatest.server`. `wait_webui_ready(timeout)` поллит `GET /api/health`.
- `cluster.lua` — обёртка над `luatest.cluster`. `config_file` + `webui_ports = {alias = port}`.
- `etcd.lua` — `attach({endpoint=...})` для CI re-using compose, `spawn(...)` для эфемерного.
- `http_client.lua` — REST + GraphQL клиент с cookie-jar, in-memory CSRF, auto `x-request-id`.

Пример:

```lua
local paths   = require('test.helpers.paths')
local Cluster = require('test.helpers.cluster')
local Client  = require('test.helpers.http_client')

local cl = Cluster:new({
    config_file = paths.cluster_seed_dir .. '/40-topology.yaml',
    webui_ports = { ['tt-1'] = 18081, ['tt-2'] = 18082, ['tt-3'] = 18083 },
})
cl:start()
cl:wait_all_webui_ready(60)

local c = Client:new({ base_url = 'http://127.0.0.1:18081' })
local res = c:graphql_query('{ ping }')
c:assert_graphql_ok(res)

cl:drop()
```

### E2E-тесты — `make test-e2e`

Playwright, против `make dev`. Цель — поймать сломанный build до того, как доменные suites начнут искать настоящие баги.

```bash
make dev
cd frontend
bunx playwright install chromium    # один раз
bun run test:e2e
```

Артефакты (`playwright-report/`, `test-results/`) в `.gitignore`. На фейле — screenshot + trace + video.

Override target:

```bash
WEBUI_BASE_URL=http://localhost:8082 WEBUI_EXPECTED_INSTANCE=tt-2 bun run test:e2e
```

### Один тест локально

```bash
# Backend unit, один файл
luatest backend/test/unit/cluster_state_test.lua

# Backend unit, один тест по имени
luatest backend/test/unit/cluster_state_test.lua -p 'test_partial_failure'

# Frontend, один файл vitest
cd frontend && bunx vitest run src/entities/cluster

# Один e2e сценарий
cd frontend && bunx playwright test smoke.spec.ts
```

## Документация — обязательное обновление per task

После реализации **каждой** задачи соответствующая документация обновляется в **том же коммите**, что и код. Это hard rule проекта.

Что проверять при подготовке коммита:

- Изменился публичный API (GraphQL/REST) → `docs/api/*` + `docs/api/error-codes.md`.
- Изменилось поведение для оператора → `docs/operations.md` и/или `docs/troubleshooting.md`.
- Появились новые модули backend/frontend → `docs/architecture.md`.
- Появились новые зависимости/интеграции → `README.md`.
- Изменилась матрица доступов → `docs/rbac-matrix.md`.

Пропуск обновления — баг, не warning.

## Конвенции коммитов

[Conventional Commits](https://www.conventionalcommits.org) с типами `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `ci`, `perf`, `build`, `revert`.

Scope — подсистема: `feat(failover): ...`, `fix(backend): null check in poller`, `docs(operations): add helm chart instructions`.

Сообщение — в императиве, без trailing summary.

## Pre-commit и pre-PR

```bash
make check-all
```

Этот таргет должен быть зелёным **перед каждым PR**. Включает: lint backend + lint frontend + verify no internal-tooling mentions + unit-тесты.

## Frontend: Feature-Sliced Design

```
frontend/src/
├── app/         инициализация, провайдеры, router, глобальные стили
├── pages/       роутовые слайсы
├── widgets/     композитные UI-блоки
├── features/    пользовательские сценарии
├── entities/    бизнес-сущности
└── shared/      инфраструктура без знания домена
```

Направление импортов: `app → pages → widgets → features → entities → shared`. Импорт между слайсами — только через публичный `index.ts`. Контроль — `eslint-plugin-boundaries`.

`tsconfig.paths` и `vite.config.resolve.alias` зеркалируют слои через алиасы `@/app`, `@/pages`, …, `@/shared`. Алиасы обязаны быть побайтово идентичны в обоих файлах.

### Создание нового слайса

Слайсы создаются вручную по FSD-конвенции (отдельного scaffold-скрипта нет): директория `<layer>/<slice>/` с `index.ts` (public API), компоненты/composables внутри, импорт только из нижних слоёв через алиасы `@/...`. Сверяйся с соседним слайсом того же слоя как образцом.

### Bun-runtime

- Менеджер пакетов и runtime — **Bun ≥ 1.1**, не Node/npm.
- Lockfile — `bun.lock` (текстовый, коммитится).
- Vite, vue-tsc, ESLint, vitest, Playwright работают под Bun без модификаций.
- `bunfig.toml` фиксирует registry, отключает встроенный `bun test` (используем vitest для лучшей Vue-интеграции).

### Vite-сборка

- `base: './'` — относительные пути ассетов работают за HAProxy и sub-path-деплоями.
- `vite-plugin-compression2` — pre-compressed brotli+gzip за один проход.
- Manual chunks: `vendor-vue`, `vendor-urql`, `vendor-primevue`, `vendor-misc`, `monaco-editor`.
- Target `es2022`, `cssCodeSplit: true`, `sourcemap: 'hidden'`.
- Monaco workers — через native Vite `?worker`-импорт.

### i18n

`vue-i18n@^9` с `legacy: false`. Локали:

- `ru` (default), `en` — оба полностью покрыты ключами `common/app/widgets/pages/errors`.
- Стратегия определения: localStorage `webui:locale` → `navigator.language` → default `ru`.
- Missing-key: warning в dev, silent fallback на `en` в prod.

## Backend: Lua style

`backend/webui/` — Lua-код роли. Конвенции:

- **Простота и надёжность** — простой control flow, локали везде, явный `pcall`, таймауты на каждом `wait`, cleanup в failure paths.
- **Логирование только через `webui.log_util`** — прямое `log.*` запрещено в коде роли. Тегированные логгеры (`logger = log_util.with_tag('http')`).
- **Никаких side-effects из `validate`-функций ролей** — это контракт Tarantool.
- **Spaces создаются через `storage/spaces.lua`** — миграции через `storage/migrations.lua` с monotonic `schema_version`. Каждый migration step должен быть rolling-safe с предыдущей версией.
- **RPC только через `cluster/rpc.lua`** — никаких прямых `conn:call` из HTTP-обработчиков. Background fibers держат `last_seen`/`last_error` в `cluster/state.lua`.
- **Forward-to-leader через `webui_peer` pool** — для записи в реплицированные sync-spaces follower проксирует операцию лидеру через named net.box shim (`webui_audit_record_remote`, `webui_session_put_remote`, `webui_prepared_put_remote`, …).

### luacheck

`.luacheckrc` фиксирует LuaJIT stdlib, `max_line_length: 120`, исключения для `bundle.lua` и CLI-скриптов в `tools/`.

## Frontend codegen pipeline

```
backend/webui/graphql/schema.lua
   │  tarantool tools/dump-schema.lua
   ▼
frontend/src/shared/api/schema.graphql        (gitignored)
   │  bunx graphql-codegen --config codegen.yml
   ▼
frontend/src/shared/api/__generated/{gql,graphql}.ts  (gitignored)
```

Команды:

```bash
make dump-schema          # SDL
make gen-types            # SDL + TS-типы + Vue composables
make gen-types-watch      # Watch
```

После каждого backend-изменения в GraphQL схемы PR обязан включать regenerated `__generated/*.ts`. CI gate ловит drift.

## Storybook

`frontend/.storybook/` — Storybook 10 поверх `@storybook/vue3-vite`. Stories — TypeScript рядом с компонентами:

```bash
cd frontend
bun run storybook         # dev-сервер на http://localhost:6006
bun run build-storybook   # статика в frontend/storybook-static/
```

Аддоны: `addon-a11y` (axe-core), `addon-themes` (light/dark), `addon-vitest`. Глобальные декораторы: PrimeVue Aura, Pinia, vue-i18n, vue-router memory history.

Каждый UI-примитив в `frontend/src/shared/ui/` обязан идти вместе со story-файлом и проходить axe-checks.

## Локальный line check

```bash
make dev                                  # поднять compose
curl http://localhost:8080/api/health     # smoke
```

Время полного локального dev-старта — ~30–45 секунд.

## CI

`.github/workflows/ci.yml`:

| Job | Что делает |
|---|---|
| `lint-frontend` | bun lint + format + type-check |
| `unit-frontend` | vitest |
| `build-frontend` | Vite build, artifact |
| `lint-backend` | luacheck |
| `unit-backend` | luatest matrix |
| `lint-docker` | hadolint |
| `lint-shell` | shellcheck |
| `build-docker` | BuildKit cache |
| `integration` | compose smoke (test-integration) |
| `ci-done` | gate, требует все предыдущие зелёными |

## Project hygiene

- В коммитимых артефактах не должно быть упоминаний внутренних tooling-state директорий. CI-проверка: `make check-no-tooling-mentions`.
- Vendored референсные деревья (`cartridge-*`, `tarantool-*`) в `.gitignore`.
- Build артефакты (`frontend/dist/`, `frontend/node_modules/`, `bundle.lua`, `.rocks/`, `*.snap`, `*.xlog`) в `.gitignore`.

## See Also

- [Architecture](architecture.md) — общая картина, layout, потоки данных
- [GraphQL API](api/graphql-schema.md) — полный SDL
- [Operations](operations.md) — Docker, HAProxy, мониторинг
