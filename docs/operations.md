# Operations

Документ описывает оперативные процедуры для администраторов кластера: развёртывание, обновление, мониторинг, бэкап, troubleshooting. Документ растёт по мере реализации задач.

## Каталог HTTP-эндпоинтов (M2 + M3 + M4 + M6)

| Метод | Путь                       | RBAC       | Назначение                                        |
|-------|----------------------------|------------|---------------------------------------------------|
| GET   | `/api/health`              | public     | Liveness + TX-heartbeat.                          |
| GET   | `/api/metrics`             | public     | Prometheus marker `webui_up=1` + рок `metrics`.   |
| GET   | `/api/metrics/webui`       | public     | Self-metrics (WS, audit, peers).                  |
| POST  | `/api/auth/login`          | public     | Сессионный логин + cookie `webui_session` + `webui_csrf`. |
| POST  | `/api/auth/logout`         | public     | Удаление сессии + force-close WS.                 |
| GET   | `/api/auth/me`             | session    | Текущий user + roles.                             |
| GET   | `/api/snapshots`           | admin      | Список .snap-файлов на инстансе.                  |
| POST  | `/api/snapshots/take`      | admin      | `box.snapshot()`.                                 |
| GET   | `/api/config/download`     | admin      | Скачать текущий cluster YAML.                     |
| POST  | `/api/config/upload`       | admin      | Загрузить YAML → `proposeConfig` (dry-run).        |
| POST  | `/api/eval`                | superuser  | Lua/SQL консоль (gating `console_enabled`).       |
| GET   | `/api/diagnostics/bundle`  | admin      | JSON-бандл состояния для тикетов.                 |
| GET   | `/ws`                      | session    | WebSocket подписка (Origin + cookie + force-close на logout). |
| POST  | `/admin/api`               | session    | GraphQL endpoint, RBAC на уровне резолверов.      |
| GET   | `/admin/api/explore`       | admin      | GraphiQL.                                         |

CSRF: cookie `webui_csrf` (не HttpOnly) дублируется в заголовке `X-Csrf-Token` для всех POST/PUT/PATCH/DELETE.

## Каталог GraphQL операций

| Тип       | Имя                 | RBAC       | Назначение                                    |
|-----------|---------------------|------------|-----------------------------------------------|
| Query     | `cluster`           | session    | Self / servers / replicasets / knownRoles.    |
| Query     | `issues`            | session    | Live-issues, severity/category-фильтры.       |
| Query     | `suggestions`       | session    | Восстановительные suggestions.                |
| Query     | `failover`          | admin      | Mode + per-server election state.             |
| Query     | `vshard`            | session    | Groups summary (если sharding включён).        |
| Query     | `config`            | viewer     | Текущий YAML + source (`file`/`memory`/`etcd`).|
| Query     | `audit`             | admin      | Paginated audit-log с фильтрами.              |
| Mutation  | `validateConfig`    | operator   | Schema + cross-validate YAML.                 |
| Mutation  | `proposeConfig`     | operator   | Two-phase prepare → возвращает diff.          |
| Mutation  | `commitConfig`      | admin      | Применить prepared YAML.                      |
| Mutation  | `abortConfig`       | operator   | Отменить prepared.                            |
| Mutation  | `probeUri`          | admin      | net.box probe внешнего инстанса.              |
| Mutation  | `forceReapplyConfig`| admin      | `config:reload()` на peer'ах.                 |
| Mutation  | `reloadRoles`       | superuser  | Hotreload ролевых модулей.                    |
| Mutation  | `exportAudit`       | admin      | JSON-дамп аудит-лога.                          |
| Mutation  | `applyForceApply` / `applyRestartReplication` / ... | admin | Apply-handlers для suggestions. |

## Аудит и retention

`_webui_audit` — replicated space. Фибер `audit.retention` раз в час свипает записи старше `roles_cfg.webui.audit_retention_days` (default 90, минимум 1) на лидере. Бюджет одного тика — 5000 удалений.

## Docker-образ инстанса (Task 9)

`docker/Dockerfile.instance` собирает single-image для запуска одного инстанса кластера Tarantool 3.7 со встроенной admin UI.

### Сборка

Из корня репозитория:

```bash
docker build -f docker/Dockerfile.instance -t webui-instance:dev .
# или
make docker-build
```

`make docker-build` зависит от `make embed-assets`, который в свою очередь делает `bun run build` фронта — последовательность гарантирует, что в образе свежий SPA-бандл.

### Размеры

При полной сборке (M0 dependencies — http + graphql + errors rocks + SPA + tarantool runtime) ожидаемый размер finished image — ~250 МБ (большинство — Tarantool runtime + apt пакеты под `build-essential`).

Stage 1 (`oven/bun:1-alpine`) — временный и не попадает в финальный образ.

### Layout finalной image

```
/usr/share/tarantool/webui/      # Lua-роль webui (видна через package.path)
  init.lua
  log_util.lua
  version.lua
  errors.lua
  http/{server,middleware,error_envelope,static}.lua
  graphql/{server,schema,error_envelope,types/health}.lua
  api/health.lua
  assets/bundle.lua              # сгенерирован embed-assets на этапе билда

/opt/webui/                      # WORKDIR, runtime директория
  etc/                           # bind-mount cluster YAML config (instance.yaml)
  var/lib/                       # snap/xlog (TT_WORK_DIR)
  var/log/                       # рекомендованный path для stdout/stderr forwarding
  var/run/                       # pid/sock-файлы
  tools/embed-assets.lua         # можно перезапустить из контейнера при rolling
  tools/dump-schema.lua
  webui-scm-1.rockspec
  .rocks/                        # внешние rocks tree (http, graphql, errors)

/usr/local/bin/webui-entrypoint  # entrypoint shell, pid 1 → tarantool
```

### Запуск одного инстанса

```bash
docker run --rm \
    -e INSTANCE_NAME=tt-1 \
    -e WEBUI_PORT=8081 \
    -e WEBUI_LOG_LEVEL=info \
    -v "$(pwd)/instance.yaml:/opt/webui/etc/instance.yaml:ro" \
    -v "$(pwd)/data/tt-1:/opt/webui/var/lib" \
    -p 8081:8081 \
    webui-instance:dev
```

`instance.yaml` — это cluster YAML config Tarantool 3.x. Полная dev-конфигурация для 3 инстансов + etcd + HAProxy — в `docker/docker-compose.dev.yml` (Task 10).

### Переменные окружения

| Var | Default | Назначение |
|---|---|---|
| `INSTANCE_NAME` / `TT_INSTANCE_NAME` | _required_ | Имя инстанса в cluster config; передаётся в `tarantool --name` |
| `TT_CONFIG` | `/opt/webui/etc/instance.yaml` | Cluster YAML config |
| `TT_WORK_DIR` | `/opt/webui/var/lib` | Каталог для snap/xlog |
| `WEBUI_PORT` | `8081` | Порт HTTP-сервера WebUI (читается HEALTHCHECK) |
| `WEBUI_LOG_LEVEL` | `info` | Уровень structured-логов |

### Multi-stage и кеширование

1. **frontend-build** — Bun + Vite production-сборка SPA. Кэш-стратегия: сначала только `package.json` + `bun.lock`, затем `bun install --frozen-lockfile`, затем source — изменение source не инвалидирует install-слой.
2. **runtime** — финальный Tarantool-образ. Bun-toolchain, frontend-source и `node_modules` в финальный образ НЕ попадают.

### Безопасность

- Все runtime-процессы под non-root user `tarantool` (uid 1000). Это включает healthcheck-команду.
- `HEALTHCHECK` обращается только к `127.0.0.1` — нет внешних сетевых зависимостей.
- `apt-get install` за один RUN с `rm -rf /var/lib/apt/lists/*` — чистый слой, без apt-кэша.
- `embed-assets` запускается на этапе билда; `frontend/dist/` удаляется после упаковки — runtime не несёт raw SPA-файлы.

### `.dockerignore`

Корневой `.dockerignore` исключает vendored sources, build-артефакты, tooling-state, документацию и runtime-файлы (`*.snap`, `*.xlog`, `var/`). Build context — несколько МБ, что ускоряет передачу в daemon и держит cache-инвалидацию минимальной.

### HEALTHCHECK semantics

```
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${WEBUI_PORT}/api/health" || exit 1
```

- `start-period=20s` — даёт времени lifecycle роли пройти `validate → apply → start → ready`.
- `interval=10s` — каждые 10с проверка.
- `retries=3` — три fail подряд переводят контейнер в `unhealthy`.
- HAProxy в `docker-compose.dev.yml` (Task 10) использует тот же endpoint, и `degraded` (HTTP 200 с `{status:"degraded"}`) — оставляет инстанс в ротации.

### Troubleshooting

- **PermissionDenied на work_dir**: bind-mount volume должен быть writable uid 1000. На Linux: `chown -R 1000:1000 ./data/tt-X`. На macOS Docker Desktop обычно правит автоматически.
- **Healthcheck timeout** на медленном hardware: увеличить `--start-period` (можно override на уровне docker-compose).
- **`tt rocks install fails`** за корпоративным прокси: пробросить `HTTP_PROXY`/`HTTPS_PROXY` через `--build-arg` (требует добавления `ARG` в Dockerfile).
- **Контейнер выходит с кодом 64**: `INSTANCE_NAME` не задан.
- **Контейнер выходит с кодом 65**: `TT_CONFIG`-путь не существует в контейнере — проверить bind-mount.
- **Контейнер выходит с кодом 66**: config-файл не readable.

## Локальное dev-окружение (Tasks 10 + 10a)

`docker/docker-compose.dev.yml` поднимает полностью рабочий кластер из 3 инстансов Tarantool 3.7 с одной HAProxy перед ними и одиночным etcd для будущей интеграции.

### Image policy

Используются **только официальные upstream-образы**, без bitnami / community-derivatives:

| Сервис | Образ | Источник |
|---|---|---|
| etcd | `quay.io/coreos/etcd:v3.5.18` | официальный (Red Hat hosted) |
| HAProxy | `haproxy:3.3.4-alpine` | официальный Docker Hub |
| Tarantool инстансы | `webui-instance:dev` | сборка из `docker/Dockerfile.instance` (Task 9) |

### Запуск

```bash
make dev
# или явно:
docker compose -f docker/docker-compose.dev.yml up --build -d
```

После healthy-сигнала все шесть контейнеров:

```
NAME              STATUS                  PORTS
webui-etcd        Up X seconds (healthy)  0.0.0.0:2379->2379/tcp
webui-tt-1        Up X seconds (healthy)  0.0.0.0:8081->8081/tcp, 0.0.0.0:3301->3301/tcp
webui-tt-2        Up X seconds (healthy)  0.0.0.0:8082->8081/tcp, 0.0.0.0:3302->3301/tcp
webui-tt-3        Up X seconds (healthy)  0.0.0.0:8083->8081/tcp, 0.0.0.0:3303->3301/tcp
webui-haproxy     Up X seconds            0.0.0.0:8080->8080/tcp, 0.0.0.0:8404->8404/tcp
```

URL'ы:

- **http://localhost:8080** — основная точка входа (HAProxy → один из tt-N).
- **http://localhost:8081/2/3** — прямой доступ к каждому инстансу (для debug).
- **http://localhost:8404** — HAProxy stats UI (live view backend health, rates, sticky cookies).
- **http://localhost:2379** — etcd (через `etcdctl` для интеграционных тестов).

### Cluster YAML (`docker/configs/cluster.yaml`)

Один файл, описывающий все три инстанса. `tarantool --name $INSTANCE_NAME` выбирает per-instance секцию во время старта.

- `credentials.users.replicator` — встроенный replication account.
- `credentials.users.webui_peer` — будущий peer-cookie account (Task 15). В M0 имеет роль `super` чтобы стартануть; в Task 15 будет урезан.
- `replication.failover: election` — встроенный raft (`election` mode); supervised/manual режимы — в Task 46.
- `groups.default.replicasets.rs-1` — один replicaset c initial leader tt-1; raft при failover'е автоматически переизбирает.
- `roles: [webui]` — наша Lua-роль активируется на каждом инстансе.
- `roles_cfg.webui` — `listen: 0.0.0.0:8081`, `log_level: debug`, `graphiql_enabled: true` (только в dev), `console_enabled: true` (dev включает консоль; production-манифесты обязаны держать `false`).
- `credentials.users.*_dev` — четыре dev-фикстуры под все роли RBAC: `viewer_dev`, `operator_dev`, `admin_dev`, `superuser_dev` (последний нужен для /console и `POST /api/eval`).

### HAProxy (Task 10a) — `docker/haproxy/haproxy.dev.cfg`

| Аспект | Конфигурация |
|---|---|
| Frontend | `bind *:8080` (HTTP) |
| Backend | round-robin между tt-1/2/3, `init-addr last,libc,none` + `resolvers docker_dns` (127.0.0.11:53) для compose DNS |
| Healthcheck | `option httpchk` + `GET /api/health` + `expect status 200` — degraded (200) держит в ротации, unhealthy (503) выводит |
| Sticky session | Cookie `SRVID` insert indirect nocache postonly + `SameSite=Strict` (приклеивается на mutations, статика остаётся round-robin) |
| Таймауты | client/server/tunnel 1h — для WebSocket |
| Stats | `stats_in` на 8404 |
| Логирование | stdout, `log-format` с unique-id |
| Request-Id | НЕ генерируется HAProxy — backend middleware (Task 3) делает это сам |

### Шаги healthy-старта

```
etcd: started → 5s → healthy
  tt-1 ┐
  tt-2 ├─ стартуют параллельно (важно — см. ниже)
  tt-3 ┘   → bootstrap replication majority → role lifecycle uninitialized→starting→ready → healthy
      haproxy: started (depends_on=service_healthy всех tt-*) → ready
```

Полный bootstrap из чистого состояния — порядка 30–45 секунд (на текущем M0 каркасе).

#### Почему tt-1/2/3 стартуют параллельно

Tarantool 3.x `replication.bootstrap_strategy: auto` (default) при первом старте требует подключения к большинству peer'ов. Если бы compose выстраивал зависимость tt-1 → tt-2 → tt-3, tt-1 застрял бы в `connecting to 3 replicas` (тт-2/3 ещё не подняты), а затем упал бы с `failed to connect to one or more replicas`. Поэтому все три инстанса стартуют параллельно после healthy сигнала etcd.

#### Почему `roles_cfg.webui` не задаёт `leader`

В `replication.failover: election` (raft) явный `leader: tt-1` запрещён: Tarantool валидатор кидает «`leader` option cannot be used together with replication.failover = election». Initial leader выбирается raft'ом автоматически на первом старте (обычно тот, кто первым достиг кворума) — без подсказок в YAML.

### Volumes

| Volume | Назначение |
|---|---|
| `etcd-data` | etcd `/var/lib/etcd` |
| `tt-1-data`, `tt-2-data`, `tt-3-data` | per-instance work_dir (`/opt/webui/var/lib`) — snap/xlog |

`make dev-down` (или `docker compose down --volumes`) удаляет всё чисто.

### Network

`webui-dev-net` (bridge, user-defined). Контейнеры резолвят друг друга по имени (`tt-1`, `etcd`, `haproxy`).

### Failover smoke

```bash
# Остановить лидера
docker compose -f docker/docker-compose.dev.yml stop tt-1

# Через 1-2 сек:
curl http://localhost:8080/api/health        # 200 — HAProxy маршрутизирует на tt-2 или tt-3
curl http://localhost:8080/admin/api -X POST \
  -H 'content-type: application/json' \
  -d '{"query":"{ roleStatus { state instance } }"}'
# → data.roleStatus.instance: "tt-2" (новый лидер после raft re-election)

# Восстановить
docker compose -f docker/docker-compose.dev.yml start tt-1
```

### Конфигурируется через env

В `x-tarantool-common.environment`:

- `WEBUI_LOG_LEVEL=debug` (можно override на конкретный контейнер).
- `TT_CONFIG=/opt/webui/etc/cluster.yaml` — путь внутри контейнера.
- `INSTANCE_NAME=tt-N` — задан per-service.

### Что НЕ включено в dev compose

- **TLS** — HAProxy слушает HTTP (8080). Production-конфиг с TLS termination на 443 → Task 11.
- **External etcd cluster** — embedded etcd single-node. Production manifests подключают внешний etcd → Task 11.
- **HA для самого HAProxy** — единственный экземпляр. keepalived/VRRP опционально → Task 11.
- **Frontend dev-server (Vite HMR)** — для текущего M0 не нужен (SPA уже включён в каждый инстанс через embed-assets). HMR-режим вернётся как опциональный сервис когда понадобится для активной разработки фронта (вне M0 scope).

## Production deployment template (Task 11)

`docker/docker-compose.prod.example.yml` — стартовая точка для production-развёртывания на одном узле. Шаблон вынесен в репозиторий именно с суффиксом `.example`: операторы копируют его в свою деплой-директорию и адаптируют под конкретное окружение.

### Артефакты

| Файл | Назначение |
|---|---|
| `docker/docker-compose.prod.example.yml` | 3 инстанса + HAProxy на 443. External etcd через env-vars. TLS-сертификаты через bind-mount. Resource limits, `restart: unless-stopped`, capability drops |
| `docker/haproxy/haproxy.prod.example.cfg` | TLS termination на 443, HTTP→HTTPS redirect, HSTS, sticky cookie, stats UI с trusted-network ACL, TLS 1.3 only |
| `docker/configs/cluster.prod.example.yaml` | Tarantool 3.x cluster config с config source = etcd + mTLS, secrets через `${ENV_VAR}`, `roles_cfg.webui.graphiql_enabled: false` |

### Hard prerequisites

Шаблон **не функционален** без следующих шагов на стороне оператора:

1. **External etcd cluster** (≥3 нод, mTLS, RBAC). Single-node etcd из dev-compose недостаточен. Endpoints, username и password передаются через env vars / Docker secrets.
2. **TLS bundle для HAProxy** — `tls/webui.pem` (полная chain + private key одним PEM-файлом).
3. **mTLS material для iproto** — `tls/peer.{crt,key}` + `tls/peer-ca.crt`. Iproto-порты (3301) НЕ публикуются наружу — внутренний docker network single-host или production overlay/L3 fabric — единственный путь.
4. **etcd-client rock в образе** — добавляется в Task 30. До этого `tt-*` стартуют только если cluster config доступен как файл, а etcd использовать не получится.
5. **TLS material для etcd connections** — `tls/etcd-ca.crt`, `tls/etcd-client.{crt,key}` для mTLS клиента к etcd.

### Production checklist

Перед `docker compose up -d` пройдитесь по списку:

- [ ] Скопировать `docker-compose.prod.example.yml` → `docker-compose.prod.yml` в деплой-директории.
- [ ] Скопировать `cluster.prod.example.yaml` → `cluster.prod.yaml` и адаптировать `config.etcd.endpoints` под реальный etcd cluster.
- [ ] Подготовить TLS-материал в `./tls/`:
  - [ ] `webui.pem` — chain + key для HAProxy (получить от ACME / внутреннего CA).
  - [ ] `peer.{crt,key}` + `peer-ca.crt` — mTLS между Tarantool-инстансами (issued локальным cluster CA).
  - [ ] `etcd-client.{crt,key}` + `etcd-ca.crt` — mTLS к etcd.
- [ ] Создать `.env` файл с секретами:
  ```bash
  WEBUI_VERSION=1.0.0
  REPLICATOR_PASSWORD=<from secret manager>
  WEBUI_PEER_PASSWORD=<from secret manager>
  ETCD_PASSWORD=<from secret manager>
  WEBUI_LOG_LEVEL=info
  ```
  Compose автоматически читает `.env` из текущей директории; для Docker Swarm используйте `docker secret create`.
- [ ] Заменить placeholders `${REPLICATOR_PASSWORD}` etc в `cluster.prod.yaml` на ссылки на секреты (envsubst при деплое или Docker secrets).
- [ ] Удалить или закомментировать `127.0.0.1:8404:8404` если stats UI не нужен на этом хосте, либо добавить SSH-туннель / VPN access.
- [ ] Обновить `haproxy.prod.cfg`:
  - [ ] `bind *:443 ssl crt /etc/haproxy/certs/webui.pem` — путь к bundle верный.
  - [ ] `resolvers default_resolver { nameserver dns <IP>:53 }` — реальный DNS-сервер.
  - [ ] ACL `trusted` для stats UI — добавить нужные CIDR / удалить лишние.
- [ ] Настроить tarantool snapshots: рекомендуется `snapshot.by.interval: 86400` (раз в сутки) + remote rsync/S3 push (см. раздел Backup в `docs/architecture.md` контракт «Backup и DR»).
- [ ] Подключить Prometheus к `/api/metrics/webui` (Task 42a) когда оно появится.
- [ ] Настроить log-shipper (vector / fluent-bit / journald) для контейнерных stdout/stderr.
- [ ] Проверить firewall: 443 (public), 80 (public, only for redirect), 8404 (private/VPN), 3301 (internal cluster network only, mTLS), 2379 (etcd, mTLS).

### HAProxy high availability

Шаблон описывает один экземпляр HAProxy — single point of failure. Для production-grade развёртывания:

- Запустить **две** HAProxy ноды (active/standby) с одинаковым конфигом.
- Управлять floating IP через **keepalived + VRRP**:
  - Master priority 110, backup priority 100.
  - Track HAProxy через `vrrp_script` (например `pidof haproxy`).
  - Floating IP — публичный, на нём слушает `bind *:443 ssl crt …`.
- DNS A-record указывает на floating IP.

Альтернативы: AWS NLB / GCP TCP LB перед двумя HAProxy с собственной health check логикой; Anycast IP в собственной AS.

### Sizing guidelines

| Размер кластера | Per `tt-N` контейнер | HAProxy |
|---|---|---|
| 3–10 инстансов (small) | 1 vCPU, 512 MB | 0.5 vCPU, 128 MB |
| 10–50 (medium) | 2 vCPU, 1 GB | 1 vCPU, 256 MB |
| 50–256 (large) | 4 vCPU, 2 GB | 2 vCPU, 512 MB |

Текущие limits в `docker-compose.prod.example.yml` сделаны под medium baseline. Tune `deploy.resources.limits` под профиль.

### Rolling upgrade

Процедура подробно описана в `docs/architecture.md` → раздел «Release pipeline» (см. Task 55). Кратко:

1. `git pull` новой ревизии в деплой-директории.
2. `docker compose build` нового образа.
3. Поочерёдно по одному инстансу: `docker compose stop tt-X` → `docker compose up -d tt-X` → дождаться healthy → следующий.
4. HAProxy сам выводит из ротации через healthcheck.

### Не входит в шаблон

- **Multiple HAProxy nodes + keepalived** — упомянуто выше как опция, не разворачивается шаблоном.
- **External etcd cluster setup** — выходит за scope; операторы используют свой etcd (на baremetal, k8s через etcd-operator, или managed как DigitalOcean Managed etcd / AWS DocumentDB).
- **Сам Prometheus / Grafana / Vector** — `webui-instance` экспортирует метрики, оператор разворачивает сборщик в своём observability-стеке.

## `config.etcd` на Community Edition

Tarantool 3.7 принимает блок `config.etcd:` в cluster YAML только в **Enterprise** сборке: схема в `instance_config.lua` помечает узел `enterprise_edition` и без EE возвращает ошибку «available only in Tarantool Enterprise Edition». Для CE-инсталляций мы поставляем open-source аналог в виде модуля `internal.config.extras` — Tarantool сам подгружает его при старте, если файл лежит в `package.path`.

### Что делает наш `internal.config.extras`

`backend/internal/config/extras.lua` устанавливается образом в `/usr/share/tarantool/internal/config/extras.lua` (см. Dockerfile.instance). При вызове `config:_initialize()`:

1. Подменяет `tarantool.package` с `'Tarantool'` на `'Tarantool Enterprise'`. Все EE-валидаторы схемы (`enterprise_edition_validate`) пропускают проверку.
2. Регистрирует источник `webui.config_source.etcd_source` через `config:_register_source(...)`. Источник реализует контракт `name='etcd'`, `type='cluster'`, `sync(self, config, iconfig)`, `get(self)`.
3. На каждом `sync` источник:
   - Читает `config.etcd.{endpoints, prefix, username, password, ssl}` из текущего iconfig.
   - При наличии username — выполняет `POST /v3/auth/authenticate`, получает JWT.
   - `POST /v3/kv/range` для ключа `<prefix>/config/all` (canonical) → fallback на `<prefix>/config` (legacy).
   - Перебирает endpoints до первого успеха (sticky failover).
   - Декодирует value из base64, парсит YAML.
   - Возвращает результат как cluster config.

### Конфигурация в YAML

Та же, что и в EE-документации Tarantool:

```yaml
config:
  etcd:
    prefix: '/tarantool/cluster-a'
    endpoints:
      - 'https://etcd-0.example.com:2379'
      - 'https://etcd-1.example.com:2379'
      - 'https://etcd-2.example.com:2379'
    username: 'webui'
    password: '${ETCD_PASSWORD}'   # env substitution
    ssl:
      ca_file:   '/etc/tarantool/tls/etcd-ca.crt'
      ssl_cert:  '/etc/tarantool/tls/etcd-client.crt'
      ssl_key:   '/etc/tarantool/tls/etcd-client.key'
      verify_peer: true
    http:
      request:
        timeout: 5
```

### Tradeoffs нашего подхода

Подмена `tarantool.package` глобальна на процесс. Это **безопасно** для:
- Узлов схемы с EE-флагом (валидаторы становятся no-op'ами). Конкретно: `config.etcd`, `config.storage`, `iproto.advertise.peer.params.ssl_*`, `iproto.listen.params.ssl_*`.

Это **НЕ означает** что становятся доступны другие EE-функции:
- Лицензированные C-модули (`audit_log` встроенный, `integrity`, флаги в `box.cfg`) сами по себе не появляются — они отсутствуют в Community-бинарнике. Если в YAML включить `audit_log: yes`, схема валидируется, но box.cfg упадёт на C-уровне с unknown option.

Документируйте этот контракт явно в своих ops-runbook'ах: **наш extras расширяет только config-source surface**. Использование других EE-функций не поддерживается и не рекомендуется.

### Что поддержано / что в backlog

| Feature | Текущая M0-версия | Planned |
|---|---|---|
| Multi-endpoint failover (первый успех) | ✅ | — |
| Basic auth (JWT через `/v3/auth/authenticate`) | ✅ | — |
| TLS (CA, client cert, verify_peer) | ✅ | — |
| Canonical `<prefix>/config/all` + legacy `<prefix>/config` fallback | ✅ | — |
| Per-request timeout (из `config.etcd.http.request.timeout`) | ✅ | — |
| Live updates через etcd watch | ❌ | Task 30 |
| Edit-lock через etcd lease | ❌ | Task 30 |
| CAS-write через txn | ❌ | Task 30 |
| Self-metrics (`webui_etcd_request_*`) | ❌ | Task 42a |

### Проверка работы (без поднятого etcd)

```bash
# С нашим extras и фиктивными endpoint'ами:
tarantool --name tt-1 --config docker/configs/cluster.prod.example.yaml
# stderr показывает:
#   [webui.config.extras] etcd source registered { package: "Tarantool Enterprise" }
#   [webui.config_source.etcd] cannot fetch cluster config from etcd: ...
#     (HTTP 595 — endpoints не резолвятся, что и должно быть в этой пробе)
```

При поднятом etcd с правильно загруженным ключом cluster config — Tarantool запускает кластер штатно.

## Дальнейшие разделы

Появляются по мере реализации задач:
- Kubernetes Helm chart → Task 11a.
- CI Pipeline → Task 12.
- Rolling upgrade процедура → Task 55.
- Backup стратегия → Task 27 + Task 55.
- Мониторинг через Prometheus rules → Task 42a + Task 55.
