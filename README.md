# Tarantool 3.7 WebUI

Веб-интерфейс администрирования кластера Tarantool 3.7, функциональный эквивалент Cartridge UI, адаптированный под декларативную модель конфигурации Tarantool 3.x.

Backend встраивается в каждый инстанс Tarantool как Lua-роль `webui`. Frontend — Vue 3 + TypeScript SPA, упакованная в Lua-модуль и отдаваемая тем же инстансом. Источник истины кластерной конфигурации — etcd. Любой инстанс — точка входа в UI. В production кластеру предшествует HAProxy с TLS termination, healthcheck и sticky session для WebSocket.

## Быстрый старт

Требования:

- Tarantool 3.7.0 или новее
- Docker и Docker Compose
- Bun (для разработки фронта): https://bun.sh

```bash
git clone <repo>
cd tarantool-webui
make dev
```

`make dev` поднимает локальный кластер из 3 инстансов с etcd и HAProxy. После healthy-сигнала откроется `http://localhost:8080` с консолью администратора.

## Документация

| Документ | Назначение |
|---|---|
| `docs/architecture.md` | Архитектура, потоки данных, two-phase commit, FSD |
| `docs/operations.md` | Развёртывание, Helm chart, мониторинг, rolling upgrade |
| `docs/security.md` | TLS, peer-cookie, threat model |
| `docs/rbac-matrix.md` | Матрица ролей × эндпоинтов |
| `docs/troubleshooting.md` | Runbooks и типовые ошибки |
| `docs/development.md` | Setup для контрибьюторов, FSD-конвенции |
| `docs/api/` | GraphQL schema, REST endpoints, error codes |

## Команды Make

| Цель | Действие |
|---|---|
| `make dev` | Поднять локальный кластер с UI |
| `make dev-down` | Остановить локальный кластер |
| `make lint` | Запустить линтер (luacheck + eslint) |
| `make lint-fix` | Авто-исправление lint |
| `make test` | Unit-тесты (backend + frontend) |
| `make test-integration` | Интеграционные тесты через docker-compose |
| `make build-frontend` | Сборка SPA через Bun + Vite |
| `make gen-types` | Генерация TS-типов из GraphQL schema |
| `make embed-assets` | Упаковка `frontend/dist/` в `backend/webui/assets/bundle.lua` |
| `make docker-build` | Сборка Docker-образа инстанса |
| `make clean` | Удалить артефакты сборки |

## Лицензия

BSD 2-Clause. См. `LICENSE`.
