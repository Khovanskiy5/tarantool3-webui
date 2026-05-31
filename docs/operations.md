[← Architecture](architecture.md) · [Back to README](../README.md) · [Security →](security.md)

# Operations

Operator handbook: развёртывание, конфигурация, failover, мониторинг, бэкап, rolling upgrade.

## Локальное dev-окружение

`docker/docker-compose.dev.yml` поднимает рабочий кластер из 3 инстансов Tarantool 3.7 с HAProxy перед ними и одиночным etcd:

```bash
make dev          # build + up -d
make dev-logs     # tail логов
make dev-down     # teardown + удалить volumes
```

После healthy-сигнала:

| URL | Назначение |
|---|---|
| `http://localhost:8080` | Основная точка входа (HAProxy → один из `tt-N`) |
| `http://localhost:8081`/`8082`/`8083` | Прямой доступ к каждому инстансу (debug) |
| `http://localhost:8404` | HAProxy stats UI |
| `http://localhost:2379` | etcd (для `etcdctl`) |

Dev-фикстуры credentials: `admin_dev / admin-dev-password`, `operator_dev / operator-dev-password`, `viewer_dev / viewer-dev-password`, `superuser_dev / superuser-dev-password`.

## Production deployment template

Стартовая точка — `docker/docker-compose.prod.example.yml` + `docker/haproxy/haproxy.prod.example.cfg` + `docker/configs/cluster.prod.example.yaml`. Оператор копирует их в свою деплой-директорию и адаптирует.

### Hard prerequisites

1. **External etcd cluster** — ≥3 нод, mTLS, RBAC. Single-node etcd из dev-compose недостаточен.
2. **TLS bundle для HAProxy** — `tls/webui.pem` (полный chain + private key одним PEM).
3. **mTLS material для iproto** — `tls/peer.{crt,key}` + `tls/peer-ca.crt`. Iproto-порты (3301) НЕ публикуются наружу.
4. **TLS material для etcd-клиента** — `tls/etcd-ca.crt`, `tls/etcd-client.{crt,key}`.

### Production checklist

- [ ] Скопировать `docker-compose.prod.example.yml` → `docker-compose.prod.yml`.
- [ ] Скопировать `cluster.prod.example.yaml` → `cluster.prod.yaml`, адаптировать `config.etcd.endpoints`.
- [ ] Подготовить TLS material в `./tls/`.
- [ ] Создать `.env` с секретами:
  ```bash
  WEBUI_VERSION=1.0.0
  REPLICATOR_PASSWORD=<from secret manager>
  WEBUI_PEER_PASSWORD=<from secret manager>
  ETCD_PASSWORD=<from secret manager>
  WEBUI_LOG_LEVEL=info
  ```
- [ ] Заменить `${REPLICATOR_PASSWORD}` etc placeholders на ссылки на секреты (envsubst или Docker secrets).
- [ ] Обновить `haproxy.prod.cfg`: `bind *:443 ssl crt /etc/haproxy/certs/webui.pem`, ACL `trusted` для stats.
- [ ] Закрыть stats UI (`127.0.0.1:8404:8404` или SSH-туннель / VPN).
- [ ] Настроить snapshots (`snapshot.by.interval: 86400` + remote rsync/S3 push).
- [ ] Подключить Prometheus к `/api/metrics`.
- [ ] Настроить log-shipper (vector / fluent-bit / journald).
- [ ] Firewall: 443 (public), 80 (public, только redirect), 8404 (private/VPN), 3301 (internal cluster, mTLS), 2379 (etcd, mTLS).

### Sizing guidelines

| Кластер | Per tt-N контейнер | HAProxy |
|---|---|---|
| 3–10 инстансов (small) | 1 vCPU, 512 MB | 0.5 vCPU, 128 MB |
| 10–50 (medium) | 2 vCPU, 1 GB | 1 vCPU, 256 MB |
| 50–256 (large) | 4 vCPU, 2 GB | 2 vCPU, 512 MB |

Под medium baseline настроены `deploy.resources.limits` в `docker-compose.prod.example.yml`.

### HAProxy HA

Шаблон описывает один HAProxy — single point of failure. Для production:

- Запустить **две** ноды HAProxy (active/standby) с одинаковым конфигом.
- Управлять floating IP через **keepalived + VRRP** (master priority 110, backup 100; track HAProxy через `vrrp_script`).
- DNS A-record указывает на floating IP.

Альтернативы: AWS NLB / GCP TCP LB перед двумя HAProxy; Anycast IP в собственной AS.

## HAProxy tuning

`docker/haproxy/haproxy.dev.cfg` калиброван под быстрый failover:

| Параметр | Значение | Почему |
|---|---|---|
| `balance roundrobin` | — | равномерное распределение по новым сессиям |
| `stick-table` + `stick on req.cook(webui_session)` | size 16k, expire 1h | пин по логин-cookie: cluster.self стабилен на странице |
| `option httpchk` + `GET /api/health` | expect status 200 | degraded (200) держит в ротации, unhealthy (503) выводит |
| `inter 1s` | 1 секунда между healthcheck'ами в steady state | оперативная детекция падения |
| `fastinter 500ms` | 0.5 секунды между healthcheck'ами в transition | быстрое подтверждение down/up |
| `downinter 500ms` | то же для DOWN-узлов | быстрая детекция recovery |
| `fall 2` | 2 подряд failure → DOWN | hysteresis против single-probe noise |
| `rise 2` | 2 подряд success → UP | не возвращать траффик на flapping peer |
| `timeout tunnel 1h` | WebSocket держится 1 час | live updates не падают |

### Failover-окно с этими настройками

| Сценарий | Время восстановления |
|---|---|
| Kill процесса лидера (`docker stop` / `kill -9`) | 2–3 секунды (healthcheck fall + failover agent + watcher promote) |
| Kill процесса coordinator'а (не лидера) | без эффекта (next election через TTL+jitter) |
| Kill coordinator'а который ОДНОВРЕМЕННО лидер | 3–4 секунды (lease expiry + новый coordinator + appointment + promote) |
| Graceful `docker stop` лидера | 1–2 секунды (graceful lease_revoke на shutdown) |

## Supervised failover (open-source)

WebUI реализует «supervised»-режим (аналог EE-функции) поверх Tarantool CE через open-source агент. Подробности дизайна — в `architecture.md` (раздел *Supervised failover*).

### Включение

В `roles_cfg.webui`:

```yaml
roles_cfg:
  webui:
    failover:
      agent: true
      lease_ttl_sec: 3            # default 10; ниже = быстрее failover, выше = меньше нагрузки на etcd
      keepalive_interval: 1       # TTL/3 rule of thumb
      appointment_interval: 1
      watcher_poll_interval_sec: 1
```

И в `replication`:

```yaml
replication:
  failover: off                   # обязательно: raft/supervised встроенные сломали бы агент
  synchro_quorum: 'N/2 + 1'
  synchro_timeout: 3
```

И в `groups.default.replicasets.*.instances.*`:

```yaml
database:
  mode: rw                        # ВСЕ инстансы декларируют RW; synchro queue ownership — real lock
```

### Что нельзя делать

- Не выставлять `database.mode: ro` на followers — Tarantool будет перезаписывать `box.cfg{read_only}` при каждом config reload, фигатя агенту.
- Не выставлять `replication.failover: election` или `supervised` — агент откажется стартовать (`agent precondition failed`).
- Не понижать `lease_ttl_sec` ниже `keepalive_interval × 3` — keepalive не успеет, coordinator потеряет lease на ровном месте.

### Переключение на raft

```yaml
replication:
  failover: election

groups.default.replicasets.rs-1:
  instances:
    tt-1: { database: { mode: rw } }     # initial leader (опц.)
    tt-2: { database: { mode: ro } }     # после election может стать rw
    tt-3: { database: { mode: ro } }

roles_cfg.webui.failover.agent: false
```

Агент откажется стартовать при `replication.failover ≠ off`, поэтому double-leadership на transition исключён.

## Каталог HTTP-эндпоинтов

| Метод | Путь                       | RBAC       | Назначение                                        |
|-------|----------------------------|------------|---------------------------------------------------|
| GET   | `/api/health`              | public     | Liveness + TX-heartbeat                           |
| GET   | `/api/metrics`             | public     | Prometheus marker `webui_up=1` + rock `metrics`   |
| GET   | `/api/metrics/webui`       | public     | Self-metrics (WS, audit, peers, webhooks, etcd)   |
| POST  | `/api/auth/login`          | public     | Сессионный логин + cookies `webui_session`, `webui_csrf` |
| POST  | `/api/auth/logout`         | public     | Удаление сессии + force-close WS                  |
| GET   | `/api/auth/me`             | session    | Текущий user + roles                              |
| GET   | `/api/snapshots`           | admin      | Список `.snap`-файлов на инстансе                 |
| POST  | `/api/snapshots/take`      | admin      | `box.snapshot()`                                  |
| GET   | `/api/config/download`     | admin      | Скачать текущий cluster YAML                      |
| POST  | `/api/config/upload`       | admin      | Загрузить YAML → `proposeConfig` (dry-run)        |
| POST  | `/api/eval`                | superuser  | Lua/SQL консоль (gating `console_enabled`)        |
| GET   | `/api/diagnostics/bundle`  | admin      | JSON-бандл состояния для тикетов поддержки        |
| GET   | `/ws`                      | session    | WebSocket подписка                                |
| POST  | `/admin/api`               | session    | GraphQL endpoint, RBAC на уровне резолверов       |
| GET   | `/admin/api/explore`       | admin      | GraphiQL (если `graphiql_enabled: true`)          |

CSRF: cookie `webui_csrf` (не HttpOnly) дублируется в заголовке `X-Csrf-Token` для всех `POST/PUT/PATCH/DELETE`.

## Каталог GraphQL операций

| Тип       | Имя                 | RBAC       | Назначение                                    |
|-----------|---------------------|------------|-----------------------------------------------|
| Query     | `cluster`           | viewer     | Self / servers / replicasets / knownRoles     |
| Query     | `issues`            | viewer     | Live-issues с фильтрами                       |
| Query     | `suggestions`       | viewer     | Восстановительные suggestions                 |
| Query     | `config`            | viewer     | Текущий YAML + source (`file`/`memory`/`etcd`) |
| Query     | `audit`             | admin      | Paginated audit-log с фильтрами               |
| Query     | `schema`            | viewer     | Список спейсов и индексов                     |
| Query     | `users`             | admin      | Tarantool users + RBAC роли                   |
| Query     | `failover`          | admin      | Mode + per-server election state              |
| Query     | `vshard`            | viewer     | Groups summary (если sharding включён)        |
| Query     | `bootstrapStatus`   | admin      | Нужен ли initial bootstrap                    |
| Query     | `bootstrapTemplates`| admin      | Список шаблонов (single / replicaset-3 / vshard-3x3) |
| Query     | `bootstrapRender`   | admin      | Preview YAML без записи                       |
| Query     | `webhooks`          | admin      | Конфигурированные webhooks + per-receiver stats |
| Query     | `webhookQueueDepth` | admin      | Pending + dead-letter counts                  |
| Query     | `webhookDeadLetter` | admin      | Последние записи dead-letter                  |
| Mutation  | `validateConfig`    | operator   | Schema + cross-validate YAML                  |
| Mutation  | `proposeConfig`     | operator   | 2PC prepare → возвращает diff                 |
| Mutation  | `commitConfig`      | admin      | Применить prepared YAML с CAS-guard           |
| Mutation  | `abortConfig`       | operator   | Отменить prepared                             |
| Mutation  | `forceTakeLock`     | admin      | Перехватить edit-lock                         |
| Mutation  | `setFailover`       | admin      | Сменить failover mode                         |
| Mutation  | `promote`           | admin      | Принудительно promote инстанс                 |
| Mutation  | `expel`             | admin      | Expel инстанс из cluster config               |
| Mutation  | `joinInstance`      | admin      | Добавить новый инстанс                        |
| Mutation  | `setUserRoles`      | admin      | Изменить RBAC-роли пользователя               |
| Mutation  | `setLabels`         | operator   | Labels на инстансе                            |
| Mutation  | `setVshardWeight`   | admin      | Изменить vshard weight                        |
| Mutation  | `setVshardGroup`    | admin      | Перенести инстанс в другую vshard-группу      |
| Mutation  | `bootstrapVshard`   | admin      | `vshard.router.bootstrap()`                    |
| Mutation  | `bootstrapInitialize` | admin    | Initial-bootstrap из шаблона                  |
| Mutation  | `testWebhook`       | admin      | Synthetic event через указанный webhook       |
| Mutation  | `clearDeadLetter`   | admin      | TRUNCATE `_webui_webhook_dead_letter`         |
| Mutation  | `exportAudit`       | admin      | JSON-дамп audit-лога                          |
| Mutation  | `runEval`           | superuser  | Lua-eval (`POST /api/eval` GraphQL-эквивалент) |
| Mutation  | `runSql`            | superuser  | SQL-eval                                       |
| Mutation  | `hotReloadModule`   | superuser  | Перезагрузить Lua-модуль                       |

Полная RBAC-матрица — `rbac-matrix.md`.

## Мониторинг

### `/api/metrics`

Prometheus-формат. Экспортируется rock `metrics` плюс маркер `webui_up=1`.

### `/api/metrics/webui`

Self-metrics WebUI-роли:

| Metric | Type | Labels |
|---|---|---|
| `webui_ws_connections` | gauge | — |
| `webui_ws_backlog_bytes` | gauge | — |
| `webui_audit_rows` | gauge | — |
| `webui_audit_writes_total` | counter | `action` |
| `webui_peer_probe_success_total` | counter | `peer` |
| `webui_peer_probe_failure_total` | counter | `peer` |
| `webui_peer_backoff_seconds` | gauge | `peer` |
| `webui_config_commits_total` | counter | `status` |
| `webui_config_cas_conflicts_total` | counter | — |
| `webui_webhook_queue_depth` | gauge | — |
| `webui_webhook_dead_letter_depth` | gauge | — |
| `webui_webhook_deliveries_total` | counter | `name` |
| `webui_webhook_failures_total` | counter | `name` |
| `webui_etcd_request_total` | counter | `endpoint`, `op`, `status` |
| `webui_failover_promotions_total` | counter | `replicaset` |

### Рекомендованные alerts

- `up == 0` или `webui_up == 0` дольше 30 секунд → page.
- `webui_peer_probe_failure_total` rate > 0.5/min дольше 5 минут → page (cluster splits / network).
- `webui_audit_rows` > 80% retention budget → notice (расширить retention или прорежить).
- `webui_webhook_dead_letter_depth > 0` → notice (есть provider, который не отвечает).
- `webui_config_cas_conflicts_total` rate > 0.1/min дольше 10 минут → notice (конфликтующие операторы).
- `webui_failover_promotions_total` rate > 1/min → notice (flapping leader).

## Snapshots и backup

### Создание snapshot'а

- Из UI: страница «Snapshots» → кнопка «Take snapshot» на нужном инстансе.
- Через REST: `POST /api/snapshots/take` (RBAC: admin).
- Через GraphQL: mutation `takeSnapshot { instance }` (RBAC: admin).

Snapshot создаётся на текущем инстансе (роутинг прозрачен — кнопка работает на любом RO/RW peer).

### Расписание

В cluster YAML:

```yaml
snapshot:
  by:
    interval: 86400         # раз в сутки
  count: 7                  # хранить 7 snapshot'ов локально
```

### Backup off-site

Локальные snapshot'ы не защищают от потери ноды. Production-runbook должен включать push в внешнее хранилище:

```bash
# Пример: rsync на backup-host
rsync -a --delete /opt/webui/var/lib/*.snap backup-host:/backups/webui/$(hostname)/
```

или S3-clone (`aws s3 sync`, `mc mirror`) с retention-policy на стороне bucket'а.

### Restore

1. Остановить инстанс (`docker stop tt-1`).
2. Очистить `work_dir` (`rm /opt/webui/var/lib/*`).
3. Положить нужный `*.snap` + соответствующие `*.xlog` (если есть).
4. Запустить инстанс. Tarantool восстановит state из snapshot'а и доиграет xlog.

Для cluster-wide recovery (потеря всех нод) восстановить **один** инстанс из snapshot'а, сделать его лидером, остальные пересоздать с пустым `work_dir` — replication заберёт всё.

## Rolling upgrade

```bash
# 1. На деплой-хосте подготовить новую ревизию
git pull
docker compose build

# 2. Поочерёдно по одному инстансу
for i in 1 2 3; do
    docker compose stop "tt-$i"
    docker compose up -d "tt-$i"
    # Дождаться healthy
    until curl -fsS "http://localhost:808$i/api/health" > /dev/null; do sleep 1; done
done
```

HAProxy сам выводит инстанс из ротации через healthcheck (503 → DOWN), а во время restart'а трафик уходит на оставшиеся два пира. Failover agent при необходимости promote'ит нового лидера.

### Migration N/N+1 совместимость

Каждый migration step (`backend/webui/storage/migrations.lua`) обязан быть rolling-safe с предыдущей версией: новая схема читаема кодом N-1. Это гарантирует, что во время rolling upgrade нода со старым кодом, увидевшая через replication данные нового формата, продолжит работать корректно.

Если migration ломает контракт N/N+1 — нужно делать двухфазный upgrade: версия A (только пишет в new format), → весь кластер на A → версия B (читает new format).

## Audit retention

`_webui_audit` — реплицированный sync space. Фибер `audit.retention` раз в час свипает строки старше `roles_cfg.webui.audit_retention_days` (default 90, минимум 1) на лидере. Бюджет одного тика — 5000 удалений.

Долгосрочное хранение — outbound webhook на SIEM (или экспорт через `exportAudit` mutation в JSON для архивирования).

## Docker-образ инстанса

`docker/Dockerfile.instance` — multi-stage build (single image):

```
Stage 1 (oven/bun:1-alpine)
   ├── bun install --frozen-lockfile  (cache на package.json)
   └── bun run build                   → frontend/dist/

Stage 2 (tarantool/tarantool:3.7.0)
   ├── tt rocks install http graphql errors etcd-client ...
   ├── COPY backend/                   → /usr/share/tarantool/webui/
   ├── tarantool tools/embed-assets.lua → bundle.lua
   ├── COPY tools/, rockspec
   ├── non-root user (uid 1000)
   └── HEALTHCHECK curl /api/health
```

| Var | Default | Назначение |
|---|---|---|
| `INSTANCE_NAME` / `TT_INSTANCE_NAME` | _required_ | Имя инстанса в cluster config |
| `TT_CONFIG` | `/opt/webui/etc/instance.yaml` | Cluster YAML config |
| `TT_WORK_DIR` | `/opt/webui/var/lib` | Каталог snap/xlog |
| `WEBUI_PORT` | `8081` | HTTP-порт WebUI (читается HEALTHCHECK) |
| `WEBUI_LOG_LEVEL` | `info` | Уровень structured-логов |

Multi-stage обеспечивает, что Bun toolchain, frontend source и `node_modules` не попадают в финальный образ.

### Exit codes

| Code | Причина |
|---|---|
| 64 | `INSTANCE_NAME` не задан |
| 65 | `TT_CONFIG`-путь не существует в контейнере |
| 66 | Config-файл не readable |

## Cluster config через etcd на Community Edition

CE не поддерживает блок `config.etcd:` нативно. WebUI поставляет open-source shim — `backend/internal/config/extras.lua` (детали в `architecture.md`).

Конфиг такой же как в EE-документации Tarantool:

```yaml
config:
  etcd:
    prefix: '/tarantool/cluster-a'
    endpoints:
      - 'https://etcd-0.example.com:2379'
      - 'https://etcd-1.example.com:2379'
      - 'https://etcd-2.example.com:2379'
    username: 'webui'
    password: '${ETCD_PASSWORD}'
    ssl:
      ca_file:   '/etc/tarantool/tls/etcd-ca.crt'
      ssl_cert:  '/etc/tarantool/tls/etcd-client.crt'
      ssl_key:   '/etc/tarantool/tls/etcd-client.key'
      verify_peer: true
    http:
      request:
        timeout: 5
```

### Что поддержано

- Multi-endpoint failover (первый успех)
- Basic auth (JWT через `/v3/auth/authenticate`)
- TLS (CA, client cert, verify_peer)
- Canonical `<prefix>/config/all` + legacy `<prefix>/config` fallback
- Live updates через `box.watch('config.info', ...)`
- Edit-lock через etcd lease (для `proposeConfig`)
- CAS-write через `put_if_witness_unchanged`
- Self-metrics (`webui_etcd_request_total`)

## See Also

- [Architecture](architecture.md) — failover-агент, 2PC, synchro-spaces
- [Security](security.md) — TLS, mTLS, peer-auth
- [Troubleshooting](troubleshooting.md) — runbooks для типовых инцидентов
- [RBAC matrix](rbac-matrix.md) — полная матрица операций
