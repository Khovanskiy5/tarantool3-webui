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
