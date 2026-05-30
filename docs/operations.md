# Operations

Документ описывает оперативные процедуры для администраторов кластера: развёртывание, обновление, мониторинг, бэкап, troubleshooting. Документ растёт по мере реализации задач — на данный момент покрыт M0 раздел «Docker-образ инстанса».

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
- `roles_cfg.webui` — `listen: 0.0.0.0:8081`, `log_level: debug`, `graphiql_enabled: true` (только в dev), `console_enabled: false`.

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

## Дальнейшие разделы

Появляются по мере реализации задач:

- `docker/docker-compose.prod.example.yml` → Task 11.
- Kubernetes Helm chart → Task 11a.
- CI Pipeline → Task 12.
- Rolling upgrade процедура → Task 55.
- Backup стратегия → Task 27 + Task 55.
- Мониторинг через Prometheus rules → Task 42a + Task 55.
