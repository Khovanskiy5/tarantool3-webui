# Tarantool 3.7 WebUI

> Веб-интерфейс администрирования кластера Tarantool 3.7 — функциональный эквивалент Cartridge UI, адаптированный под декларативную модель Tarantool 3.x.

Backend встроен в каждый инстанс кластера как Lua-роль `webui`. Frontend — Vue 3 SPA, упакованная в Lua-модуль и отдаваемая тем же инстансом. Источник истины кластерного конфига — etcd. Любой инстанс является точкой входа; в production кластеру предшествует HAProxy с TLS termination, healthcheck и sticky-session для WebSocket.

## Быстрый старт

Требования: **Tarantool 3.7+**, **Docker + Docker Compose**, **Bun ≥ 1.1** (для frontend).

```bash
git clone <repo>
cd tarantool-webui
make dev
```

`make dev` собирает образ инстанса, поднимает локальный кластер из 3 нод с etcd и HAProxy. После healthy-сигнала откройте `http://localhost:8080` и войдите как `admin_dev / admin-dev-password`.

## Возможности

- **Кластер one-glance** — топология, статус всех инстансов, репликасеты, vshard-группы.
- **Issues + suggestions** — live-диагностика (replication, memory, clock skew, config alerts) с предлагаемыми действиями.
- **Config editor** — Monaco + JSON Schema из работающего бинарника + two-phase commit через etcd с CAS-guard.
- **Supervised failover на open-source** — кастомный coordinator-агент на etcd lease, единый writer через synchro-queue ownership, leader-change за 3–5 секунд.
- **Schema / Snapshots / Console** — обзор спейсов и индексов, ручные снапшоты, Lua/SQL eval для `superuser` (выключено по умолчанию).
- **RBAC** — четыре роли (`viewer / operator / admin / superuser`), RBAC enforced на уровне резолверов.
- **Audit trail** — каждое мутирующее действие пишется в реплицированный `_webui_audit` с retention.
- **Outbound webhooks** — Slack / Discord / SMTP / generic с retry и dead-letter.

## Пример

```bash
# Текущая топология одним GraphQL-запросом
curl -s -X POST http://localhost:8080/admin/api \
  -H 'content-type: application/json' \
  -b cookies.txt \
  -d '{"query":"{ cluster { self { alias } replicasets { name status servers { alias boxInfo { ro } } } } }"}'
```

Ответ перечислит все инстансы, их RO/RW-состояние и health, и пометит текущего лидера каждого репликасета.

---

## Документация

| Раздел | Назначение |
|---|---|
| [Architecture](docs/architecture.md) | Layout, потоки данных, failover-агент, 2PC, synchro-spaces |
| [Operations](docs/operations.md) | Deploy, HAProxy, мониторинг, snapshots, rolling upgrade, capacity |
| [Security](docs/security.md) | TLS / mTLS, RBAC, audit, peer-auth, threat model |
| [RBAC matrix](docs/rbac-matrix.md) | Полная матрица ролей × операций |
| [Troubleshooting](docs/troubleshooting.md) | Runbooks для типовых инцидентов |
| [Development](docs/development.md) | Setup, Makefile, FSD-конвенции, тесты, CI |
| [GraphQL API](docs/api/graphql-schema.md) | SDL, query/mutation справочник |
| [REST API](docs/api/rest.md) | Auth, eval, metrics, health, config IO, bundle |
| [Error codes](docs/api/error-codes.md) | Стабильные коды ошибок и UI-поведение |

## Лицензия

BSD 2-Clause. См. `LICENSE`.
