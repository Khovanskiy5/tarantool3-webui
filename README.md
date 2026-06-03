# Tarantool 3.7 WebUI

> Веб-интерфейс администрирования кластера Tarantool 3.7 — функциональный эквивалент Cartridge UI, адаптированный под декларативную модель Tarantool 3.x.

Backend встроен в каждый инстанс кластера как Lua-роль `webui`: тот же бинарник, что запускает базу, отдаёт SPA и admin-API. Frontend — Vue 3 SPA, упакованная в Lua-модуль. Источник истины кластерного конфига — etcd (3-узловой кворум). Любой инстанс — точка входа; в production кластеру предшествует HAProxy с TLS termination, healthcheck и sticky-session для WebSocket.

## Быстрый старт

Требования: **Tarantool 3.7+**, **Docker + Docker Compose**, **Bun ≥ 1.1** (для frontend).

```bash
git clone <repo>
cd tarantool-webui
make dev
```

`make dev` собирает образ инстанса и поднимает локальный кластер: 3 ноды Tarantool + 3-узловой etcd + HAProxy. После healthy-сигнала откройте `http://localhost:8080` и войдите как `admin_dev / admin-dev-password`. Снести — `make dev-down`.

## Возможности

- **Кластер one-glance** — топология, статус инстансов, репликасеты, vshard-группы; bootstrap-wizard для пустого кластера.
- **Issues + suggestions** — live-диагностика (репликация, память, clock skew, synchro-кворум, failover, etcd, config) с предлагаемыми действиями.
- **Config editor** — Monaco + JSON Schema из живого бинарника + two-phase commit через etcd с CAS-guard, history и rollback.
- **Supervised failover на open-source** — координатор-агент на etcd-lease, единый writer через synchro-queue ownership; OSS-паритет Enterprise: self-fencing, RO-старт, vclockkeeper-switchover, anti-flap, etcd-HA, weak-subjectivity rejoin-guard, pause/maintenance.
- **Безопасные рестарты** — rolling restart с majority-guard и demote-first; восстановление после split-brain (rebootstrap, выбор победителя).
- **Data explorer** — обзор и редактирование спейсов/таплов, индексы, sequences, collations, статистика.
- **Schema / SQL / Console** — обзор спейсов и индексов, SQL-консоль с EXPLAIN, Lua-eval (только `superuser`, выключено по умолчанию).
- **Snapshots / Logs / Metrics** — ручные снапшоты + скачивание, просмотр логов, Prometheus-метрики.
- **RBAC** — четыре роли (`viewer / operator / admin / superuser`), enforced на уровне резолверов.
- **Audit trail** — каждое мутирующее действие пишется в реплицированный `_webui_audit` с retention и hash-chain верификацией.
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
| [Architecture](docs/architecture.md) | Layout, потоки данных, слои, 2PC, synchro-spaces |
| [Failover](docs/failover.md) | OSS supervised-parity: инварианты, lease/term/vclockkeeper, тайминги, матрица Enterprise→OSS, issue→runbook |
| [Operations](docs/operations.md) | Deploy, HAProxy, мониторинг, etcd-HA, pause, безопасные рестарты, каталоги API |
| [Security](docs/security.md) | TLS / mTLS, RBAC, audit, peer-auth, threat model |
| [RBAC matrix](docs/rbac-matrix.md) | Полная матрица ролей × операций |
| [Troubleshooting](docs/troubleshooting.md) + [Runbooks](docs/runbooks/index.md) | Разбор инцидентов и пошаговые операции |
| [Development](docs/development.md) | Setup, Makefile, FSD-конвенции, тесты, CI |
| [GraphQL API](docs/api/graphql-schema.md) · [REST API](docs/api/rest.md) · [Error codes](docs/api/error-codes.md) | Справочник API |

## Лицензия

BSD 2-Clause. См. `LICENSE`.
