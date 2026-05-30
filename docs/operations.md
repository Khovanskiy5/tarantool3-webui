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

## Дальнейшие разделы

Появляются по мере реализации задач:

- `docker/docker-compose.dev.yml` (3 инстанса + etcd + HAProxy + dev-vite) → Task 10.
- HAProxy конфиги (dev + prod) → Task 10a.
- `docker/docker-compose.prod.example.yml` → Task 11.
- Kubernetes Helm chart → Task 11a.
- CI Pipeline → Task 12.
- Rolling upgrade процедура → Task 55.
- Backup стратегия → Task 27 + Task 55.
- Мониторинг через Prometheus rules → Task 42a + Task 55.
