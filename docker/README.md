# Docker

Этот каталог содержит артефакты контейнеризации Tarantool 3.7 WebUI инстанса:

- `Dockerfile.instance` — multi-stage Dockerfile, собирающий single-image для запуска одного инстанса кластера со встроенной admin UI.
- `entrypoint.sh` — entrypoint, который валидирует окружение и exec'ит `tarantool` с правильными флагами.

Сборка тестового образа из корня репозитория:

```bash
docker build -f docker/Dockerfile.instance -t webui-instance:dev .
# или через Makefile (зависит от make embed-assets и build-frontend)
make docker-build
```

## Layout

### Stage 1: `frontend-build` (oven/bun:1-alpine)

Производит production-бандл SPA через Vite. Артефакты — `dist/` со сжатыми brotli/gzip companion'ами.

Кэш-стратегия: сначала копируются `package.json` и `bun.lock`, `bun install --frozen-lockfile` выполняется ДО копирования исходников — изменение только source-файлов не инвалидирует install-слой.

### Stage 2: `runtime` (tarantool/tarantool:3.7.0)

Финальный образ.

- Установлены `ca-certificates`, `curl` (для HEALTHCHECK), `git` и `build-essential` (для нативных частей rocks типа `http`).
- `tt rocks install`: `http 1.6.0`, `graphql`, `errors`. `checks` — встроен в Tarantool 3.x core.
- `backend/webui/*` копируется в `/usr/share/tarantool/webui/*` (стандартный package.path) — `require('webui')` резолвится без LUA_PATH-надстроек.
- `embed-assets.lua` запускается во время билда: `frontend/dist/` → `/usr/share/tarantool/webui/assets/bundle.lua`. `frontend/dist/` удаляется после упаковки.
- Создаются runtime-директории `/opt/webui/{etc,var/{run,log,lib}}`, владелец — `tarantool` (uid 1000).
- Все процессы под пользователем `tarantool` (`USER tarantool`).
- ENV-defaults: `WEBUI_PORT=8081`, `WEBUI_LOG_LEVEL=info`, `TT_CONFIG=/opt/webui/etc/instance.yaml`, `TT_WORK_DIR=/opt/webui/var/lib`.
- `EXPOSE 8081 3301` (WebUI HTTP и iproto).
- `HEALTHCHECK` — `curl -fsS http://127.0.0.1:${WEBUI_PORT}/api/health`. `start-period=20s` чтобы у роли успел отработать lifecycle до first probe.
- `ENTRYPOINT ["/usr/local/bin/webui-entrypoint"]` (exec-form — pid 1 будет tarantool).

## Запуск контейнера

Минимальный пример:

```bash
docker run --rm \
    -e INSTANCE_NAME=tt-1 \
    -e WEBUI_PORT=8081 \
    -e WEBUI_LOG_LEVEL=debug \
    -v "$(pwd)/docker/configs/instance.yaml:/opt/webui/etc/instance.yaml:ro" \
    -v "$(pwd)/data/tt-1:/opt/webui/var/lib" \
    -p 8081:8081 \
    webui-instance:dev
```

Полноценный кластер из 3 инстансов + HAProxy + etcd разворачивается через docker-compose — см. `docker/docker-compose.dev.yml` (Task 10).

## Переменные окружения

| Var | Default | Назначение |
|---|---|---|
| `INSTANCE_NAME` (или `TT_INSTANCE_NAME`) | _required_ | Имя инстанса в cluster config; используется в `tarantool --name` |
| `TT_CONFIG` | `/opt/webui/etc/instance.yaml` | Путь к cluster YAML config |
| `TT_WORK_DIR` | `/opt/webui/var/lib` | Каталог для snap/xlog |
| `WEBUI_PORT` | `8081` | Порт HTTP-сервера WebUI (читается HEALTHCHECK и роутом) |
| `WEBUI_LOG_LEVEL` | `info` | Уровень structured-логов роли (`debug`/`info`/`warn`/`error`) |

## Безопасность

- Все runtime-процессы под non-root user (`tarantool`, uid 1000).
- В runtime-образе нет Bun, npm-кэша или frontend-исходников — они остаются в stage 1 и в финальный образ не попадают.
- HEALTHCHECK проверяет только `127.0.0.1` — никаких внешних сетевых вызовов.

## Build context

`.dockerignore` (в корне репо) исключает из контекста:

- Vendored sources (`cartridge-*/`, `tarantool-*/`)
- `frontend/node_modules/`, `frontend/dist/`, `.rocks/`
- Локальный VCS / IDE state (`.git/`, `.idea/` и прочие dev-only каталоги)
- Generated bundle (`backend/webui/assets/bundle.lua`)
- Documentation (`docs/`, `README.md`)
- Runtime артефакты (`*.snap`, `*.xlog`, `var/`)

Это сокращает контекст до нескольких МБ и держит cache-инвалидацию минимальной.

## Troubleshooting

- **`tarantool: command not found`** при HEALTHCHECK — это значит, что `curl` не установлен. В нашем Dockerfile он есть; если кастомизируете — проверьте apt-get секцию.
- **Healthcheck timeout** — start-period 20с; если ваша конфигурация требует больше времени на bootstrap (etcd, ssl), увеличьте `--start-period`.
- **PermissionDenied на work_dir** — bind-mounted volume должен быть writeable пользователем uid 1000. На macOS Docker Desktop обычно автоматически правит права; на Linux может потребоваться `chown 1000:1000 ./data/tt-1`.
- **Rocks install fails behind corporate proxy** — пробросить `HTTP_PROXY/HTTPS_PROXY` через `--build-arg` (требует доп. ARG в Dockerfile).
