# Development guide

Этот документ — стартовая точка для контрибьюторов. Он описывает требования к рабочей среде, базовые команды и конвенции, которые проверяются в CI.

## Требования к окружению

| Компонент | Версия | Назначение |
|---|---|---|
| Tarantool | ≥ 3.7.0, < 4.0 | Runtime backend'а и инструменты `tools/dump-schema.lua`, `tools/embed-assets.lua` |
| Bun | ≥ 1.0 | Runtime и пакетный менеджер для frontend (https://bun.sh) |
| Docker + Docker Compose | актуальные | Локальный кластер, integration tests, e2e |
| LuaRocks | актуальный | Установка backend-зависимостей |
| luatest | актуальный | Backend tests |
| luacheck | актуальный | Backend linter |

Установка инструментария зависит от платформы. На macOS:

```bash
brew install tarantool
brew tap oven-sh/bun && brew install bun
brew install luarocks
luarocks install --local luatest luacheck luacov
```

На Linux: использовать официальный репозиторий Tarantool, бинарный установщик Bun и системные пакеты LuaRocks/luacheck.

## Быстрый старт

```bash
git clone <repo>
cd tarantool-webui
make dev
```

После healthy-сигнала открыть `http://localhost:8080`. Кредиты администратора печатаются в stdout compose'а.

## Команды Makefile

| Цель | Назначение |
|---|---|
| `make dev` | Поднять локальный кластер: HAProxy + 3 инстанса + etcd + dev frontend (HMR) |
| `make dev-down` | Остановить кластер и удалить тома |
| `make dev-logs` | Tail логов всех сервисов |
| `make lint` | `lint-backend` (luacheck) + `lint-frontend` (eslint) |
| `make lint-fix` | Автоисправления frontend |
| `make test` | `test-backend` + `test-frontend` (unit only) |
| `make test-integration` | Backend integration tests через docker-compose |
| `make test-e2e` | Playwright e2e против поднятого dev compose |
| `make install` | `bun install --frozen-lockfile` для frontend |
| `make build-frontend` | Production build SPA (Vite via Bun) |
| `make dump-schema` | Экспорт GraphQL SDL из backend (offline, без поднятого кластера) |
| `make gen-types` | Генерация TS-типов из SDL через `bunx graphql-codegen` |
| `make gen-types-watch` | Watch SDL и регенерация TS-типов |
| `make embed-assets` | Упаковка `frontend/dist/` в `backend/webui/assets/bundle.lua` |
| `make docker-build` | Сборка Docker-образа инстанса |
| `make check-fsd` | Валидация направлений импортов FSD |
| `make check-no-tooling-mentions` | Проверка отсутствия внутренних tooling-упоминаний |
| `make check-all` | Полный набор pre-PR проверок: lint + FSD + tooling-mentions + test |
| `make clean` | Удалить артефакты сборки |

## Документация — обязательное обновление per task

После реализации **каждой** задачи плана соответствующая документация обновляется в **том же коммите**, что и код. Это hard rule, см. `.ai-factory/rules/base.md` (раздел «Обновление документации после каждой задачи»).

Что проверять при подготовке коммита:

- Изменился публичный API (GraphQL/REST) → `docs/api/*` + `docs/api/error-codes.md`.
- Изменилось поведение для оператора → `docs/operations.md` и/или `docs/troubleshooting.md`.
- Появились новые модули backend/frontend → `docs/architecture.md` + `AGENTS.md`.
- Появились новые зависимости/интеграции → `README.md` + `.ai-factory/DESCRIPTION.md`.
- Завершена задача в плане → чекбокс/статус в `.ai-factory/plans/tarantool-webui.md`.

Пропуск обновления — баг, не warning.

## Конвенции коммитов

[Conventional Commits](https://www.conventionalcommits.org) с типами `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `ci`, `perf`, `build`, `revert`.

Scope — фаза или подсистема: `feat(m0): scaffold repo`, `fix(backend): null check in poller`, `docs(operations): add helm chart instructions`.

Сообщение — в императиве, без trailing summary, без подписей AI-инструментов.

## Pre-commit и pre-push

Хуки настраиваются через lefthook (см. `lefthook.yml` после Task 12). Локально вручную:

```bash
make check-all
```

Этот таргет должен быть зелёным **перед каждым PR**.

## Локальный линт и тесты

Используются те же команды, что и в CI (см. `.github/workflows/ci.yml`), так что зелёный локальный прогон практически гарантирует зелёный CI.

| Команда | Что проверяет | Время |
|---|---|---|
| `.rocks/bin/luacheck backend/ tools/` | Backend Lua-стиль и сложность | ~1с |
| `.rocks/bin/luatest backend/test/unit/` | Unit-тесты модулей backend | ~2с |
| `cd frontend && bun run lint` | ESLint + plugin-vue + FSD boundaries | ~3с |
| `cd frontend && bun run format` | Prettier (check-only) | ~1с |
| `cd frontend && bun run type-check` | `vue-tsc --noEmit` | ~5с |
| `cd frontend && bun run test:unit` | Vitest + happy-dom | секунды |
| `cd frontend && bun run build` | Production Vite build | ~2с |
| `hadolint docker/Dockerfile.instance` | Dockerfile стиль/best practices | ~1с |
| `shellcheck docker/entrypoint.sh tools/gen-types.sh` | Shell-скрипты | <1с |
| `haproxy -c -f docker/haproxy/haproxy.dev.cfg` | HAProxy конфиг (с сертификатами) | <1с |
| `make dev` + `curl http://localhost:8080/api/health` | Integration smoke (полный стек) | ~30с |

Полный pre-PR прогон одной командой: `make check-all` (зависит от установленных rocks `luacheck` и `luatest`).

## Запуск отдельных тестов

```bash
# Один файл backend unit
luatest backend/test/unit/cluster_state_test.lua

# Один тест по имени
luatest backend/test/unit/cluster_state_test.lua -p 'test_partial_failure'

# Один компонент frontend
cd frontend && bunx vitest run src/entities/cluster

# Один e2e сценарий
cd frontend && bunx playwright test smoke.spec.ts
```

## Backend test helpers

В `backend/test/helpers/` лежат тонкие обёртки, которые скрывают рутину поднятия Tarantool и etcd в интеграционных тестах:

- `paths.lua` — общий: вычисляет `repo_root`, идемпотентно расширяет `package.path`/`package.cpath` для in-tree `backend/` и `.rocks/`. Любой другой helper грузит его первым.
- `server.lua` — наследник `luatest.server`. Прокидывает `LUA_PATH`/`LUA_CPATH` в spawned-процесс, добавляет `wait_webui_ready(timeout)` (поллит `GET /api/health` до `status ∈ {ok, degraded}`), `webui_health()`, `webui_base_url()`.
- `cluster.lua` — обёртка над `luatest.cluster`. Принимает `config_file` (YAML) и map `webui_ports = {alias = port}`. Делегирует `start/stop/drop/size/each`, добавляет `wait_all_webui_ready` — обходит каждый инстанс и переиспользует `Server:wait_webui_ready`.
- `etcd.lua` — режим `attach({endpoint=...})` для существующего etcd (CI re-использует compose-овский) и `spawn({image?,port?})` для эфемерного `quay.io/coreos/etcd:v3.5.18` через `docker run -d --rm`. API поверх etcd v3 HTTP gateway: `put/get/delete/delete_prefix/health/endpoint/stop`.
- `http_client.lua` — клиент поверх `http.client`. Cookie-jar, in-memory CSRF, авто-`x-request-id`. REST: `rest_get/post/put/delete`. GraphQL: `graphql_query/graphql_mutation` распаковывают `res.json.data`/`res.json.errors`. Ассерты `assert_status` и `assert_graphql_ok` падают с информативным сообщением. `login()` — стаб до Task 25.

Пример integration-теста:

```lua
local paths = require('test.helpers.paths')
local Cluster = require('test.helpers.cluster')
local Client = require('test.helpers.http_client')

local cl = Cluster:new({
    config_file = paths.cluster_dev_yaml,
    webui_ports = { ['tt-1'] = 18081, ['tt-2'] = 18082, ['tt-3'] = 18083 },
})
cl:start()
cl:wait_all_webui_ready(60)

local c = Client:new({ base_url = 'http://127.0.0.1:18081' })
local res = c:graphql_query('{ ping }')
c:assert_graphql_ok(res)

cl:drop()
```

Публичная поверхность helper'ов покрыта офлайн-тестом `backend/test/unit/helpers_test.lua` (11 кейсов) — если кто-то сломает API или удалит метод, CI упадёт сразу, без Docker.

## Storybook (frontend компоненты)

В `frontend/.storybook/` лежит конфиг Storybook 8 поверх `@storybook/vue3-vite`. Stories пишутся в TypeScript рядом с компонентами и формируют живой каталог UI-кита.

Что включено:

- **Framework:** `@storybook/vue3-vite` — переиспользует тот же Vite pipeline и FSD-алиасы (`@/shared`, `@/widgets`, ...), что и приложение.
- **Аддоны:** `addon-essentials` (controls, actions, viewport, docs), `addon-a11y` (axe-core отчёт на каждой story), `addon-themes` (light/dark переключатель через `.webui-dark` class), `addon-interactions` (play-функции для сценариев), `addon-viewport` (mobile/tablet/laptop/wide).
- **Глобальные декораторы** (`preview.ts`): PrimeVue с Aura, Pinia, vue-i18n, vue-router на `createMemoryHistory()` со stub-маршрутами под все пункты сайдбара. CSS-переменные подгружаются через `src/app/styles/index.css`.
- **Branding** (`manager.ts`): тёмная тема Storybook, цвета совпадают с UI-кит.
- **Auto-docs**: каждая story-файл с тегом `autodocs` получает страницу Docs c props table (через vue-docgen-api).

Команды:

```bash
cd frontend
bun run storybook         # запускает dev-сервер на http://localhost:6006
bun run build-storybook   # собирает статический сайт в frontend/storybook-static/
```

`storybook-static/` в .gitignore и публикуется как часть проектного сайта (Task 11 — деплой).

## Smoke e2e (Playwright)

`frontend/playwright.config.ts` + `frontend/tests/e2e/smoke.spec.ts` — минимальный набор end-to-end проверок, которые гоняются против поднятого `docker-compose.dev.yml`. Цель — поймать сломанный билд до того, как доменные suite'ы начнут искать настоящие баги.

Что покрыто (3 теста):
1. **`/` отдаёт SPA shell**: 200, `<title>` `Tarantool WebUI`, в DOM виден бренд TopBar (если JS взлетел).
2. **`/api/health` отвечает 200 с identity**: `status: ok`, `role_state: ready`, `instance: tt-1`, версии Tarantool/WebUI присутствуют.
3. **SPA из браузера достучится до `/api/health`**: тот же fetch с `credentials: 'same-origin'`, ловит CSP/CORS/HAProxy regressions, которых не видно из чистого `request.get`.

Запуск локально:

```bash
make dev               # поднять compose, дождаться healthy
cd frontend
bunx playwright install chromium    # один раз
bun run test:e2e
```

Переопределение target'а:

```bash
# Прогнать против HAProxy (port 8080) или произвольного URL
WEBUI_BASE_URL=http://localhost:8080 bun run test:e2e

# Сменить ожидаемое имя инстанса
WEBUI_EXPECTED_INSTANCE=tt-2 WEBUI_BASE_URL=http://localhost:8082 bun run test:e2e
```

Playwright артефакты (`playwright-report/`, `test-results/`) в `.gitignore`. На фейле сохраняется screenshot + trace + video для диагностики; открыть trace — `bunx playwright show-trace test-results/<path>/trace.zip`.

В CI ожидается, что workflow поднимает `docker-compose.dev.yml --wait`, потом гоняет `bun run test:e2e` с `WEBUI_BASE_URL` указывающим на CI-сервис. Настройка `forbidOnly: !!CI` ломает сборку при случайно оставленном `.only`.

**Известный M0 trade-off:** `Content-Security-Policy` в `backend/webui/http/middleware.lua` временно разрешает `'unsafe-eval'` — без него vue-i18n рантайм-компилятор кидает `EXPECTED_TOKEN` через `new Function`. AOT-precompile через `@intlify/unplugin-vue-i18n` ломает runtime-only build vue-i18n (IR-формат vs ожидаемые функции), так что AOT-подход отложен. Smoke этот регрессионный сценарий ловит — если SPA снова перестанет рендериться, тест #1 (`serves the SPA shell at /`) упадёт первым. Следующая итерация CSP — отдельная задача после миграции с vue-i18n runtime compiler.

## Добавление нового shared UI компонента

Каждый UI-примитив в `frontend/src/shared/ui/` обязан идти вместе со story-файлом и проходить axe-checks через `addon-a11y`.

1. **Создать компонент:**

   ```
   frontend/src/shared/ui/button/
   ├── index.ts            ← re-export Button.vue
   ├── ui/
   │   ├── Button.vue
   │   └── Button.stories.ts
   └── model/              ← опц., props types если переиспользуются
   ```

   `index.ts` должен экспортировать только публичное API (компонент + типы props). Внутренние файлы (`ui/`, `model/`) недоступны извне — это гарантирует `eslint-plugin-boundaries`.

2. **Подключить компонент к kit:**

   В `frontend/src/shared/ui/index.ts` добавить re-export:

   ```ts
   export { default as Button, type ButtonProps } from './button';
   ```

3. **Написать story:** скелет `Button.stories.ts`:

   ```ts
   import type { Meta, StoryObj } from '@storybook/vue3';
   import { Button } from '@/shared/ui';

   const meta: Meta<typeof Button> = {
     title: 'Shared/Button',
     component: Button,
     tags: ['autodocs'],
     argTypes: {
       variant: { control: 'select', options: ['primary', 'secondary', 'ghost'] },
       size: { control: 'select', options: ['sm', 'md', 'lg'] },
       disabled: { control: 'boolean' },
     },
   };

   export default meta;
   type Story = StoryObj<typeof Button>;

   export const Default: Story = { args: { label: 'Save' } };
   export const Disabled: Story = { args: { label: 'Save', disabled: true } };
   export const Loading: Story = { args: { label: 'Save', loading: true } };
   export const Danger: Story = { args: { label: 'Delete', variant: 'danger' } };
   ```

   Минимальное покрытие — **все интересные состояния**: `Default`, `Disabled`, `Loading`, `Error`, `Focused` (где применимо). Это — материал для axe-аудита и для дизайн-ревью.

4. **Проверить локально:**

   ```bash
   cd frontend
   bun run storybook            # визуальная проверка
   bun run lint                 # ESLint + boundaries
   bun run type-check           # vue-tsc
   bun run build-storybook      # сборка должна проходить
   ```

5. **Добавить unit-тест** (если у компонента есть нетривиальная логика): `Button.test.ts` через `@vue/test-utils` + `vitest`.

Widget-уровень (`frontend/src/widgets/<name>/ui/<Widget>.stories.ts`) — то же самое, только под `title: 'Widgets/<Name>'` и с моками из `frontend/tests/fixtures/` (когда появятся).

## Структура и архитектура

Полная картина — в `docs/architecture.md`. Кратко:

- `backend/` — Lua-роль `webui`, встраивается в каждый инстанс Tarantool.
- `frontend/` — Vue 3 + TypeScript SPA, организован по Feature-Sliced Design.
- `docker/` — Dockerfile и docker-compose для dev и prod-шаблона.
- `deploy/helm/` — Helm chart для Kubernetes.
- `tools/` — `embed-assets.lua`, `dump-schema.lua`, `scaffold.ts`, `check-fsd.ts`.
- `docs/` — пользовательская и операционная документация.

## Добавление нового frontend-слайса

FSD структура. Каждый слой имеет публичный API через `index.ts`. Создание через scaffold:

```bash
cd frontend && bun run scaffold entity book
cd frontend && bun run scaffold feature book-borrow
cd frontend && bun run scaffold widget library-shelf
cd frontend && bun run scaffold page library
```

Шаблоны в `tools/scaffold/templates/`.

## Добавление нового backend-резолвера

```bash
bun run scaffold lua-resolver library_search
```

Создаёт `backend/webui/graphql/types/library.lua`, `backend/webui/graphql/resolvers/library.lua`, skeleton unit-теста.

## IDE setup

VSCode рекомендуемые расширения — в `.vscode/extensions.json`. Lua autocomplete через sumneko-lua + EmmyLua аннотации в каждом модуле.

## Где задавать вопросы

- Issues: GitHub issues репозитория.
- Дискуссии: GitHub Discussions.
- Security: `docs/security.md` → contact section.
