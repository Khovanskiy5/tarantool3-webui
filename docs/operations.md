[← Architecture](architecture.md) · [Back to README](../README.md) · [Security →](security.md)

# Operations

> **Runbook каталог:** [runbooks/index.md](runbooks/index.md) — пошаговые инструкции по типовым операторским действиям (promote, expel, rollback, mode switch, split-brain recovery и др.).

Operator handbook: развёртывание, конфигурация, failover, мониторинг, бэкап, rolling upgrade.

## Локальное окружение

`docker/docker-compose.yml` поднимает кластер из 3 инстансов Tarantool 3.7 с HAProxy перед ними, одиночным etcd и одноразовым init-контейнером `etcd-seed`:

```bash
make dev          # build + up -d
make dev-logs     # tail логов
make dev-down     # teardown + удалить volumes (форсирует пересев etcd)
```

Источник истины — etcd, ключ `/tarantool/webui/config/all`. На холодный старт `etcd-seed` склеивает файлы `docker/configs/cluster/*.yaml` (lex-сортировка) в один YAML-документ и кладёт его в etcd; на тёплом перезапуске (без `--volumes`) он видит существующий ключ и ничего не пишет, чтобы не затоптать правки сделанные через WebUI.

Каждый Tarantool-контейнер монтирует только тонкий стаб `docker/configs/etcd-source.yaml`, который сообщает Tarantool, где находится etcd. Топология, credentials, роли — всё приходит из etcd.

Структура исходных YAML-фрагментов:

| Файл | Что описывает |
|---|---|
| `00-iproto.yaml` | общий `iproto.advertise.peer.login` |
| `10-credentials.yaml` | пользователи (replicator, webui_peer, *_dev) |
| `20-replication.yaml` | `failover: supervised`, synchro-quorum |
| `30-log.yaml` | лог-файл и уровень |
| `40-topology.yaml` | groups → rs-1 → instances (tt-1/2/3) |
| `50-roles.yaml` | `roles: [webui]` + `roles_cfg.webui` |
| `60-etcd.yaml` | self-reference `config.etcd` (тот же endpoint, что в стабе) |

Top-level ключи между файлами не пересекаются, поэтому `cat` склеивает их в валидный YAML; редактировать фрагменты можно по-отдельности.

После healthy-сигнала:

| URL | Назначение |
|---|---|
| `http://localhost:8080` | Основная точка входа (HAProxy → один из `tt-N`) |
| `http://localhost:8081`/`8082`/`8083` | Прямой доступ к каждому инстансу (debug) |
| `http://localhost:8404` | HAProxy stats UI |
| `http://localhost:2379` | etcd (для `etcdctl`) |

Dev-фикстуры credentials: `admin_dev / admin-dev-password`, `operator_dev / operator-dev-password`, `viewer_dev / viewer-dev-password`, `superuser_dev / superuser-dev-password`.

## Production considerations

Локальный compose — отправная точка, не production-шаблон. При выкатке требуется отдельная инфраструктура с учётом следующих жёстких требований:

1. **External etcd cluster** — ≥3 нод, mTLS, RBAC. Single-node etcd из локального compose недостаточен.
2. **TLS bundle для HAProxy** — полный chain + private key (например, в `tls/webui.pem`).
3. **mTLS material для iproto** — peer-cert/key + CA. Порт 3301 НЕ публикуется наружу.
4. **TLS material для etcd-клиента** — CA + client cert/key.
5. **Секреты** — пароли (`replicator`, `webui_peer`, etcd) приходят из менеджера секретов, не из git'а.
6. **Закрытый stats UI** — bind на приватную подсеть или SSH/VPN-туннель.
7. **Snapshots** — `snapshot.by.interval: 86400` + push в внешнее хранилище (S3 / rsync).
8. **Мониторинг** — `/api/metrics` к Prometheus, log-shipper (vector / fluent-bit / journald).
9. **Firewall** — 443 (public), 80 (public redirect), stats на VPN, 3301 (internal mTLS), 2379 (etcd mTLS).

### Sizing guidelines

| Кластер | Per tt-N контейнер | HAProxy |
|---|---|---|
| 3–10 инстансов (small) | 1 vCPU, 512 MB | 0.5 vCPU, 128 MB |
| 10–50 (medium) | 2 vCPU, 1 GB | 1 vCPU, 256 MB |
| 50–256 (large) | 4 vCPU, 2 GB | 2 vCPU, 512 MB |

### HAProxy HA

Шаблон описывает один HAProxy — single point of failure. Для production:

- Запустить **две** ноды HAProxy (active/standby) с одинаковым конфигом.
- Управлять floating IP через **keepalived + VRRP** (master priority 110, backup 100; track HAProxy через `vrrp_script`).
- DNS A-record указывает на floating IP.

Альтернативы: AWS NLB / GCP TCP LB перед двумя HAProxy; Anycast IP в собственной AS.

## HAProxy tuning

`docker/haproxy/haproxy.cfg` калиброван под быстрый failover:

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
      # Тайминги по правилу Patroni: keepalive + 2*probe_timeout <= lease_ttl.
      lease_ttl_sec: 20           # время жизни coordinator/RW-лизы (ttl)
      keepalive_interval: 5       # период цикла координатора / продления лизы (loop_wait)
      probe_timeout_sec: 3        # бюджет одного запроса к etcd (retry_timeout)
      appointment_interval: 1
      watcher_poll_interval_sec: 1
```

#### Дисциплина таймингов (валидация + авто-коррекция)

Терминология выровнена с Patroni: `lease_ttl_sec` = `ttl`, `keepalive_interval` = `loop_wait`, `probe_timeout_sec` = `retry_timeout`. На старте агента (и на каждом `config:reload`) тайминги проверяются и при необходимости корректируются:

- **Каноничные инварианты:**
  - `keepalive_interval + 2*probe_timeout_sec ≤ lease_ttl_sec` — лидер получает два полных шанса продлить лизу до её истечения, поэтому короткий блип etcd не вызывает ложный failover;
  - `lease_ttl_sec ≥ 2*keepalive_interval` — нужно для арминга watchdog'а.
- **Минимумы (clamp вверх с WARN):** `keepalive_interval ≥ 1`, `probe_timeout_sec ≥ 3`.
- **Рекомендуемый порог:** `lease_ttl_sec ≥ 20`. Меньше — WARN (без отказа): для быстрого LAN-кластера математика ещё сходится, но под нагрузкой ложные перевыборы вероятнее.
- **Авто-коррекция (порядок Patroni):** при нарушении неравенства сперва ужимается `keepalive_interval`, затем `probe_timeout_sec` — до минимумов. Если даже на минимумах не помещается в `lease_ttl_sec` (слишком маленький ttl) — агент **отказывается стартовать** с понятной ошибкой; на `reload` сохраняется прежний валидный конфиг.
- `renew_deadline = lease_ttl_sec − safety_margin` (по умолчанию `safety_margin: 5`) — на нём срабатывает self-fencing (FO-1), раньше истечения лизы.

Все коррекции пишутся в лог как `failover timing adjusted` (WARN). Указывать значения, удовлетворяющие инвариантам сразу, — предпочтительно: меньше неожиданностей в проде.

И в `replication`:

```yaml
replication:
  failover: supervised            # applier стартует инстансы RO; агент назначает писателя
  bootstrap_strategy: auto        # минимально-именной инстанс бутстрапит реплизасет
  synchro_quorum: 'N/2+1'
  synchro_timeout: 5
  timeout: 1
```

И на уровне box (любой инстанс):

```yaml
database:
  use_mvcc_engine: true           # обязателен для корректной изоляции synchro-транзакций
```

`database.mode` **не задаётся** — в режиме `supervised` им управляет applier (RO везде, кроме первичного bootstrap-лидера), а писателя в рантайме назначает агент через synchro-очередь.

### Что нельзя делать

- Не задавать `database.mode` / `<rs>.leader` при `failover: supervised` — это запрещено режимом и переоткрывает окно RW при рестарте.
- Не выставлять `failover.replicasets.<rs>.synchro_mode` при активном агенте — он включит `election_mode=manual`, и встроенный raft подерётся с агентом.
- Не использовать `bootstrap_strategy: supervised`/`native` с агентом — они уводят box.cfg в externally-managed ветку; нужен `auto` (или `legacy`/`config`).
- Не нарушать неравенство таймингов `keepalive_interval + 2*probe_timeout_sec ≤ lease_ttl_sec`.

### Anti-flap — подавление штормов перевыборов

При частых рестартах наивный координатор «пинг-понгует» лидерство. Поверх гистерезиса (`min_promotion_interval`) и троттла авто-возврата (`autoreturn_delay`) работают четыре слоя подавления:

- **φ-accrual failure detection.** Лидер объявляется мёртвым по адаптивному уровню подозрения (Hayashibara φ), вычисляемому из распределения интервалов между успешными наблюдениями: стабильный «пульс» → быстрое обнаружение, дёрганый → терпеливое. Пороги: `phi_threshold` (8), `phi_min_samples` (3), `phi_min_stddev` (0.5с). Пока сэмплов мало — fallback на счётчик `dampen_cycles` (3) подряд промахов; жёсткий пол `min_misses` (2) гарантирует, что одиночный блип не вызывает failover.
- **primary_start grace.** Свеженазначенному лидеру даётся `primary_start_timeout` (по умолчанию 10с) на старт, прежде чем его можно заменить (он поднимается RO и должен успеть promote).
- **Suppression circuit-breaker.** Более `suppress_threshold` (по умолчанию 4) смен лидера за `suppress_window` (60с) замораживают авто-промоуты на `suppress_cooldown` (60с) и поднимают issue `failover suppressed: flapping` (WARNING). Ручной промоут оператора игнорирует заморозку. Заранее, ещё до заморозки, при росте частоты смен (≥ `suppress_threshold − 1` за окно) поднимается отдельный WARNING-issue `transition-rate` — раннее предупреждение о назревающем флапе.
- **Per-candidate backoff.** Смещённый или зависший на promote кандидат исключается из гонки на экспоненциально растущее окно (`promote_backoff_base`, кап = `lease_ttl_sec`), поэтому координатор предпочитает другого пира. Backoff никогда не оставляет реплизасет без лидера: если он убирает последнего кандидата, выбор повторяется без него.

Все тайминги опциональны и настраиваются в `roles_cfg.webui.failover.*` (`dampen_cycles`, `min_misses`, `primary_start_timeout`, `suppress_threshold`, `suppress_window`, `suppress_cooldown`, `promote_backoff_base`, `phi_threshold`, `phi_min_samples`, `phi_min_stddev`); при отсутствии берутся дефолты. Текущее состояние (φ, частота смен, заморозка, backoff) видно в `agent.status().antiflap` и в issue при активной заморозке / повышенной частоте.

### Fallback и переключение режимов

- **Fallback `off`.** Агент по-прежнему стартует при `replication.failover: off` (legacy). Это запасной путь на случай сборки Tarantool, отвергающей `supervised` на CE; гарантии RO-при-рестарте в нём слабее — критичные спейсы должны быть `is_sync`. В логе при старте: `failover agent running in legacy "off" mode`.
- **Переключение на встроенный raft.** Один edit: `replication.failover: election` и `roles_cfg.webui.failover.agent: false`. Агент отказывается стартовать при `failover ∈ {election, manual}`, поэтому double-leadership на transition исключён.

## State reporter — liveness в etcd

Open-source аналог верхнеуровневого блока `stateboard.*` из Tarantool Enterprise. Каждый инстанс с включённым reporter'ом пишет в etcd небольшой JSON со своим живым `box.info`. Запись привязана к etcd lease, поэтому:

- при штатной остановке (`docker stop`, role-reload) — синхронный `lease_revoke`, ключ исчезает за миллисекунды;
- при `kill -9` / OOM / сетевом разделе — lease истекает по TTL, ключ удаляется автоматически.

Это дополнительный канал к peer_poller'у: poller ходит по iproto и видит «недоступен» только после таймаута, а отсутствие свежей записи в etcd говорит однозначно — процесс мёртв.

### Включение

```yaml
roles_cfg:
  webui:
    state_reporter:
      enabled: true
      renew_interval: 2             # как часто переписывать, сек (default 2)
      keepalive_interval: 10        # TTL lease, сек (default 10)
```

`enabled: false` по умолчанию — фича опциональная, как и в Enterprise stateboard.

### Что появляется в etcd

Ключ — `<config-prefix>/state/by-name/<instance_name>`. Значение — JSON:

```json
{
  "hostname":  "tt-1.example",
  "pid":       4242,
  "alias":     "tt-1",
  "mode":      "rw",
  "ro_reason": null,
  "status":    "running",
  "ts":        1717372800.123
}
```

Поля совпадают с контрактом Tarantool Enterprise stateboard (`tarantool-3.7.0/src/box/lua/config/descriptions.lua:2862`). Единственное отличие — JSON вместо YAML (единообразно с остальными ключами WebUI в etcd: `/failover/coordinator`, `/failover/replicasets/<rs>/leader`).

### Проверка из CLI

```bash
etcdctl --endpoints=http://etcd:2379 \
  get --prefix /tarantool/webui/state/by-name/
```

Если ключ инстанса исчез — инстанс либо корректно остановлен (lease revoke), либо упал больше `keepalive_interval` секунд назад. В обоих случаях peer_poller подтвердит причину.

### Когда стоит включать

- Кластеры, где «упал процесс» vs «iproto залип» — actionable разница для дежурного.
- Метрики/алерты на основе etcd-watch — дешевле, чем поллинг каждого инстанса.
- Дополнительный sanity-check для координатора failover-агента (lease истёк ⇒ кандидат не в RW).

Если эти сценарии не нужны — оставь `enabled: false`, лишний writer в etcd на каждом тике не появится.

### В UI

На странице **Failover** появляется секция **Liveness reports (etcd)**: одна строка на каждый ключ в `/state/by-name/`, столбцы `Instance / Freshness / Age / Mode / Status / RO reason / Hostname / PID`. Свежесть классифицируется относительно `keepalive_interval`:

| Метка | Условие | Значение |
|---|---|---|
| `fresh`   | age ≤ keepalive_interval | штатно, инстанс пишет вовремя |
| `lagging` | keepalive_interval < age ≤ 2× | пропустил один renew (etcd flap, GC pause); поллер ещё считает живым |
| `stale`   | age > 2× keepalive_interval | инстанс не пишет — обычно процесс мёртв, lease вот-вот истечёт |

Тот же data source доступен GraphQL-запросом `clusterLiveness { entries { … } }` (RBAC: viewer) — пригодится для внешних дашбордов и алертов.

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
| Query     | `clusterLiveness`   | viewer     | Records published by `state_reporter` (etcd liveness) |
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
