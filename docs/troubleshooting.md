[← RBAC matrix](rbac-matrix.md) · [Back to README](../README.md) · [Development →](development.md)

# Troubleshooting

Runbooks для типовых инцидентов. Для каждого случая: симптомы → диагностика → действие.

## Где смотреть в первую очередь

| Источник | Что искать |
|---|---|
| `docker compose logs -f tt-1 tt-2 tt-3` | Lua-роль stdout (JSON, structured) |
| `docker compose logs -f haproxy` | health-check failures, balancer events |
| `http://localhost:8404` | HAProxy stats — какие пиры DOWN/UP, sticky-table |
| `http://localhost:8080/issues` | live issues роли (replication, memory, clock, config) |
| `http://localhost:8080/audit` | последние мутирующие действия по cluster'у |
| `grep -E "request_id=<UUID>"` через все три stdout | полный flow одного запроса между инстансами |

## Cluster startup / bootstrap

### Инстанс висит в `connecting to replicas`

**Симптомы.** На свежем кластере `tt-1` логирует `box.cfg: bootstrap_strategy=auto, connecting to 3 replicas`, не выходит из стадии `loading`.

**Причина.** `bootstrap_strategy: auto` требует подключения к majority пиров. Если compose выстраивал зависимость `tt-1 → tt-2 → tt-3`, первый инстанс не находит остальных.

**Действие.** Стартовать все три инстанса параллельно (как в `docker-compose.yml`: `depends_on` только на `etcd-seed`, не друг на друга).

### `box.cfg.leader cannot be used with replication.failover = election`

**Симптомы.** Tarantool отказывается стартовать с ошибкой про сочетание `leader:` + `failover: election`.

**Причина.** В режиме `election` initial leader выбирает raft автоматически; явный `leader:` запрещён.

**Действие.** Убрать `leader: tt-1` из YAML. На первом старте raft изберёт лидера за 1–3 секунды.

### `box.cfg: read_only=true, ro_reason=synchro`

**Симптомы.** Все три инстанса показывают RO, ни один не принимает запись. В `box.info.ro_reason` — `synchro`.

**Причина.** Synchronous queue ownership «зависла» у мёртвого предыдущего лидера — никто не владеет очередью, поэтому все RO. Обычно после жёсткого killing'а лидера, пока агент ещё не назначил нового.

**Действие.**
1. Убедиться, что режим — `replication.failover: supervised` и `roles_cfg.webui.failover.agent: true` (в логе агента при старте: `failover agent running under replication.failover { mode = supervised }`). В supervised `database.mode` **не задаётся** — applier сам держит инстансы RO до назначения.
2. Дать агенту пару секунд — он назначит лидера (appointment в etcd) и watcher сделает `box.ctl.promote`.
3. Если ничего не помогает — вручную `box.ctl.promote()` на самом догнавшем инстансе (через REST `/api/eval` под superuser или `tt console`), либо через UI `promoteInstance`.

### Новый инстанс падает с `No leader to register`

**Симптомы.** Свежий инстанс (без snap) не выходит из startup; в логе:
`Startup failure. No leader to register new instance "tt-3". All the instances in replicaset "rs-1" of group "default" are configured to the read-only mode.` Уже работающие пиры здоровы, login работает.

**Причина (только режим `off`-fallback).** Bootstrap-проверка в `box_cfg.lua:1107-1118` ищет в YAML писателя (`database.mode: rw`), который впишет новичка в `_cluster`. В legacy-режиме `failover: off` без RW-пира регистрироваться негде, и инстанс exit'ится. **В нативном `supervised` этой проблемы нет:** applier отключает `force_ro_on_startup` для supervised (`box_cfg.lua:1082-1084`), а новичка регистрирует лидер, назначенный агентом в рантайме — `database.mode` для этого не нужен.

**Диагностика.**
```bash
docker exec webui-etcd etcdctl get /tarantool/webui/config/all --print-value-only \
  | grep -E 'failover|bootstrap_strategy'
```
Должно быть `failover: supervised` + `bootstrap_strategy: auto`. Если видите `failover: off` без `database.mode: rw` ни у кого — это и есть причина (legacy-конфиг).

**Действие.**
1. Перевести кластер на `failover: supervised` (UI `setFailoverMode("supervised")` или правкой YAML), затем перезапустить «новый» инстанс — он пройдёт JOIN через агент-назначенного лидера.
2. Если по какой-то причине нужен `off`-fallback — дописать `database: { mode: rw }` хотя бы одному инстансу и `etcdctl put` обратно.

### Контейнер инстанса в loop'е с `Instance name for X is not set in snapshot`

**Симптомы.** После `docker compose down -v <инстанс>` + `up -d <инстанс>` контейнер не выходит из `Restarting (1)`. В `docker logs` каждые ~5 секунд:
```
Instance name for tt-1 is not set in snapshot and UUID is missing in the config.
Found 21481e47-9097-4529-bc3c-62abe0f2f810 in snapshot.
```
UUID при каждой итерации меняется. Остальные инстансы здоровы, login на оставшемся master'е работает.

**Причина.** Гонка в Tarantool 3.x bootstrap-протоколе:

1. Свежий инстанс с пустым томом запускает JOIN от master'а.
2. Master отдаёт initial snapshot **до** того, как впишет имя нового реплика в свой `_cluster` (см. `relay_initial_join` → `box_register_replica` в `tarantool-3.7.0/src/box/box.cc:5067-5081`).
3. Инстанс сохраняет полученный snap локально. В header'е snap'а есть его свежесгенерированный `instance_uuid`, но в `_cluster` нет строки для этого uuid → имя в snap'е равно nil.
4. Validate в `tarantool-3.7.0/src/box/lua/config/configdata.lua:545-551` стреляет:
   ```lua
   if saved_names.instance_name == nil and
      config_names.instance_uuid == nil then
       error('Instance name for ' .. name .. ' is not set in snapshot...')
   end
   ```
5. Tarantool падает. Docker рестартует. Tom уже не пустой — лежит «обрезанный» snap. Loop.

**Диагностика.**
```bash
docker logs --tail 50 webui-tt-1 | grep -E 'Instance name|UUID is missing'
docker run --rm -v webui_tt-1-data:/data busybox ls /data/var/lib/tt-1
```
Если в томе видны `*.snap` файлы — loop активен.

**Действие.**

1. **Остановить инстанс окончательно** (чтобы Docker перестал его поднимать):
   ```bash
   docker compose -f docker/docker-compose.yml stop tt-1
   ```
2. **Вычистить том вручную** (busybox-однострочник избегает recreate'а):
   ```bash
   docker run --rm -v webui_tt-1-data:/data busybox \
     rm -rf /data/var/lib/tt-1 /data/var/run/tt-1
   ```
3. **Прописать `database.instance_uuid`** для проблемного инстанса в etcd. UUID может быть любой валидный — если у инстанса была история (запись в vclock на остальных peer'ах), берите старый UUID, иначе vclock-конфликт на JOIN'е:
   ```bash
   docker exec webui-etcd-1 etcdctl get /tarantool/webui/config/all \
     --print-value-only > /tmp/cfg.yaml
   # отредактировать /tmp/cfg.yaml — добавить
   #   tt-1:
   #     database:
   #       mode: rw
   #       instance_uuid: <UUID>
   #     iproto: ...
   docker exec -i webui-etcd-1 etcdctl put /tarantool/webui/config/all \
     < /tmp/cfg.yaml
   ```
   Это выключает ветку в `validate` (поле `config_names.instance_uuid` становится non-nil), и Tarantool разрешает первый запуск со «здоровым» snap'ом.
4. **Запустить инстанс.** Первый цикл может ещё раз упасть с `Duplicate replica name X, already occupied by <uuid>` — это in-memory зомби в `replicaset.hash` на master'е (см. соседний runbook ниже). Docker рестартует контейнер; второй заход проходит, потому что connection guard на master'е уже отпустил старую incoming-connection.

**Связанная проблема: остановленный applier с тем же сообщением.** После того, как новый peer вошёл в кластер, у другого follower'а может остановиться upstream'овый applier:
```
status: stopped
message: 'Duplicate replica name tt-1, already occupied by <uuid>'
```
Это тот же зомби, только теперь у `follower_with_zombie` в hash висит старый `replica` struct с тем же uuid/именем. WAL-инсерт `[id, uuid, name]` от master'а отвергается в `on_replace_dd_cluster_insert` (`alter.cc:4883-4889`) ещё до того, как код проверит совпадение по uuid.

**Лечение зомби-applier'а:**
1. Остановить «новый» инстанс (`docker compose stop tt-1`) — иначе он мгновенно реконнектится и пересоздаёт зомби.
2. Рестартануть follower'а с зомби (`docker compose restart tt-3`). При старте `replicaset.hash` собирается из чистого `_cluster` на диске → зомби нет.
3. Дать follower'у догнать репликацию (∼5 секунд) — он применит WAL-инсерт от master'а и впишет нового peer'а в свой `_cluster`.
4. Запустить «новый» инстанс. Реконнект найдёт уже зарегистрированную строку и не упрётся в name-check.

**Корень.** Это поведение Tarantool 3.x bootstrap, оно не специфично для WebUI. Если фикс на стороне Tarantool пока не доехал, держим `database.instance_uuid` как long-term workaround для каждого инстанса в продакшен-конфиге (генерируется один раз через `uuid.str()` и фиксируется навсегда).

## Failover

> Модель failover целиком (инварианты, lease/term/vclockkeeper, матрица Enterprise→OSS) — [`failover.md`](failover.md). Разбор конкретных issue'ов с `/issues` (coordinator-stuck, etcd-quorum-lost, failover-suppressed, divergent-rejoin, alien, orphan) — [`runbooks/failover-issues.md`](runbooks/failover-issues.md).

### Failover не происходит, но лидер мёртв

**Симптомы.** `docker stop tt-1` (был лидером), прошло > 10 секунд, ни один из tt-2/tt-3 не promote'ил себя. На странице failover у обоих RW = `false`.

**Диагностика.**
```bash
# Coordinator кто?
curl http://localhost:8080/admin/api -X POST -b cookies.txt \
  -H 'content-type: application/json' \
  -d '{"query":"{ failover { coordinator { alias leaseTtlSec lastError } } }"}'

# Что лежит в etcd?
docker exec webui-etcd etcdctl get --prefix /tarantool/webui/failover/
```

**Возможные причины:**

1. **Coordinator был coloocated с лидером.** Lease истечёт через `lease_ttl_sec` (default 15s), затем новый coordinator избирается → appointment → watcher promote. Полный цикл — до ~TTL. Если ждали меньше — это нормально.
2. **Agent не стартовал.** Проверить `roles_cfg.webui.failover.agent: true` и `replication.failover: supervised` (либо `off` как fallback). Лог: `failover.agent: agent precondition failed` означает несовместимый режим (`election`/`manual` агент не запускает).
3. **etcd unreachable.** Лог: `failover.agent: lease keepalive failed`. Проверить `webui_etcd_request_total{status="error"}` и сетевой доступ из контейнера до etcd.
4. **Нет ни одного `running` кандидата.** Лог: `failover.agent: no eligible candidate for rs-1`. Кандидат должен быть `box.info.status='running'` с lag <= `max_replication_lag_sec` (default 5).

### Failover-flapping (постоянная смена лидера)

**Симптомы.** На странице failover лидер меняется каждые несколько секунд. `webui_failover_promotions_total` rate > 1/min.

**Возможные причины:**

1. **Слишком тесные тайминги.** Должно соблюдаться `keepalive_interval + 2*probe_timeout_sec ≤ lease_ttl_sec` (дефолт 5 + 2·2 = 9 ≤ 15). Если `lease_ttl_sec` занижен — keepalive не успевает и координатор теряет lease на ровном месте.
2. **Сетевые проблемы между coordinator'ом и etcd.** Проверить `webui_etcd_request_total{status="error"}`.
3. **Кандидат на границе health.** Hysteresis (`min_promotion_interval`, default 10s) должен предотвращать промоутинг чаще, чем раз в 10 секунд. Если flap'ает чаще — bug; собрать `diagnostics bundle` и приложить к issue.

### Все инстансы показаны как leader на странице кластера

**Симптомы.** На `/cluster` бейдж `leader` стоит на всех trёх инстансах.

**Причина.** Старая версия UI определяла leader по `box.info.ro === false`. В legacy-модели (`off` + `database.mode: rw` на всех) все три имели `ro=false`. В нативном supervised не-лидеры RO, так что баг не воспроизводится, но старый UI всё равно стоит обновить.

**Действие.** Обновить UI до текущей версии. Selector `isLeader(instance, leaderAlias)` теперь сравнивает `instance.alias === leaderAlias`, где `leaderAlias` приходит из `Replicaset.activeLeader || leader` резолвера.

## etcd

### `etcd not configured, committed in local mode`

**Симптомы.** При save'е конфига banner «yaml committed in local mode (etcd not configured)». Перезапуск инстанса теряет изменения.

**Причина.** `roles_cfg.webui.etcd_writer` не задан в cluster YAML.

**Действие.**
```yaml
roles_cfg:
  webui:
    etcd_writer:
      endpoints: ['http://etcd:2379']        # или https:// для prod
      prefix: '/tarantool/webui'
```

После reload роли (или restart инстанса) WebUI начнёт писать в etcd.

### `cannot fetch cluster config from etcd: HTTP 595`

**Симптомы.** На старте `[webui.config_source.etcd] cannot fetch cluster config from etcd: HTTP 595`.

**Причина.** etcd endpoint не резолвится или не отвечает. HTTP 595 в Tarantool — generic transport error.

**Действие.** Проверить:
- DNS-резолв `etcd` внутри контейнера: `docker exec tt-1 getent hosts etcd`.
- TCP-связность: `docker exec tt-1 nc -zv etcd 2379`.
- etcd жив: `docker compose logs etcd | tail -50`.
- TLS-материал доступен и валиден (для production).

### `CAS_CONFLICT` на commitConfig

**Симптомы.** UI показывает `CAS_CONFLICT`, banner «Config changed, reload».

**Причина.** Между чтением YAML и `commitConfig` другой оператор закоммитил свою версию. etcd revision увеличился — наш `expected_rev` стал stale.

**Действие.** Reload страницы, смержить свои правки поверх актуальной версии, повторить commit. Это by design — gate против lost updates.

### `EDIT_LOCK_HELD`

**Симптомы.** Banner «Another operator is editing the config» с кнопкой `Force take`.

**Действие.** Подождать (default lease TTL — 5 минут с keepalive). Если оператор не активен — `Force take` (RBAC: admin) переписывает lease на текущего пользователя; в audit будет запись `config.force_take`.

## Config 2PC

### `PREPARED_NOT_FOUND` на commit после prepare

**Симптомы.** UI делает propose, получает prepared_id, потом commit с этим ID возвращает `PREPARED_NOT_FOUND`.

**Возможные причины:**

1. **TTL истёк.** Default `PREPARED_TTL_SEC = 300` (5 минут). Garbage collector удалил prepared row.
2. **Очень старая версия backend'а** (до миграции №4), где prepared был in-memory per-instance. Сейчас `_webui_prepared` — реплицированный sync-space; round-robin balancer не воспроизводит этот баг.

**Действие.** Повторить propose → commit. Если воспроизводится — собрать `diagnostics bundle`.

## HTTP / Auth

### `401 UNAUTHORIZED` на каждом запросе несмотря на успешный login

**Симптомы.** После `POST /api/auth/login` cookie вернулся, но дальнейшие `GET /api/auth/me` возвращают 401.

**Возможные причины:**

1. **HAProxy не пропускает cookie.** Проверить, что `option forwardfor` и balancer не fritter'ит `Set-Cookie`.
2. **Sticky-session не работает.** Login пишет сессию в `_webui_sessions` (forward to leader). На следующем запросе HAProxy роутит на другой инстанс; если sticky-table не нашла cookie (например, `webui_session` имя cookie не совпадает) — будет ходить по новым инстансам, но `_webui_sessions` реплицируется sync'но, так что сессия должна быть видна везде в течение миллисекунд.
3. **System users (`webui_peer`, `replicator`) пытаются войти.** Backend явно блокирует — `403 FORBIDDEN`. Использовать `admin_dev` / `viewer_dev` / etc.

**Действие.** В Network tab DevTools сверить `Cookie:` header в follow-up запросе. Если нет — браузер не сохранил (Secure-флаг при HTTP, SameSite=Strict при cross-site).

### `403 CSRF_INVALID` на mutations

**Симптомы.** GraphQL mutation возвращает `CSRF_INVALID`.

**Причина.** Заголовок `X-Csrf-Token` либо отсутствует, либо не совпадает с CSRF-токеном из сессии.

**Действие.**
- На SPA — `frontend/src/shared/api/graphql/client.ts` (`csrfExchange`) автоматически добавляет `X-Csrf-Token` из cookie `webui_csrf` на каждый POST. Если не работает — DevTools → Application → Cookies — есть ли `webui_csrf` (HttpOnly: **off**, Secure если HTTPS).
- На curl — добавить вручную:
```bash
curl -X POST ... \
    -b cookies.txt \
    -H "X-Csrf-Token: $(grep webui_csrf cookies.txt | awk '{print $7}')"
```

### `429 RATE_LIMITED`

**Симптомы.** После нескольких неудачных login'ов — `429 RATE_LIMITED`, `Retry-After: N`.

**Причина.** Sliding window: 5 неуспешных попыток / минута / IP / action.

**Действие.** Подождать. Успешный login сбрасывает счётчик.

## WebSocket

### WS постоянно реконнект'ится

**Симптомы.** В DevTools `/ws` каждые несколько секунд CLOSE + OPEN.

**Возможные причины:**

1. **Slow consumer.** Backlog > 1000 frames → server закрывает 1008. Скорее всего, JS-обработчик медленный — проверить `wsClient` handlers.
2. **HAProxy `timeout tunnel` слишком короткий.** В dev должно быть `1h`. В prod проверить настройки.
3. **`Origin` не соответствует whitelist'у.** `roles_cfg.webui.ws_allowed_origins` пустой = «любой Origin разрешён», но если задан — проверить.
4. **Сессия истекла.** На каждом reconnect WS делает handshake; без валидной сессии — 401, потом client backoff.

### Live-updates не приходят

**Симптомы.** Что-то изменилось на бэке (commit конфига, новый issue), но UI не подсвечивает.

**Действие.**
1. Открыть DevTools → Network → /ws → Frames. Должны быть `{type: "config.committed", ...}` и т.п.
2. Если frames приходят, но UI не реагирует — проверить, что store/page подписался на `wsClient.onMessage`.
3. Если frames НЕ приходят — `webui_ws_connections` метрика > 0? `tcpdump` на 8081 покажет, доходят ли броадкасты до контейнера.

## Memory / replication

### `MEMORY` issue на странице issues

**Симптомы.** В UI issue `MEMORY warning / critical` с `arena_used_ratio > 0.85 / 0.95`.

**Действие.**
- Краткосрочно — увеличить `box.cfg.memtx_memory` (rolling restart).
- Долгосрочно — расширить cluster (новый replicaset для шардирования) или прорежить старые данные.

### `REPLICATION` issue

**Симптомы.** `lag > sync_lag` warning, или `upstream != follow` critical.

**Действие.**
- Проверить network между peers (`docker compose logs`).
- На странице suggestions может быть suggestion «Restart replication» — `applyRestartReplication` mutation выполнит `box.cfg{replication=box.cfg.replication}` на проблемном пирe.
- Если несколько повторных restart'ов не помогают — пересоздать problematic peer с пустым `work_dir`, replication забутстрапит его заново.

## Console

### `403 CONSOLE_DISABLED`

**Симптомы.** `POST /api/eval` возвращает `CONSOLE_DISABLED`.

**Действие.** В cluster YAML:
```yaml
roles_cfg:
  webui:
    console_enabled: true
```

И reload роли (`forceReapplyConfig` mutation или restart). **В production держать `false`** и включать только для ограниченного debug-окна — каждый eval пишется в audit.

### Multi-return дает «странный result»

**Симптомы.** `return box.info.name, box.info.uuid` отдаёт `["tt-1"]` вместо `["tt-1", "00000000-..."]`.

**Причина.** `rpc.interpret_result` распаковывает single-return массивы; multi-return приходит как массив. Если консоль показывает только первое значение — это селектор UI, не bug бэка.

**Действие.** Завернуть в table: `return { box.info.name, box.info.uuid }`.

## Webhooks

### `webhook_dead_letter_depth` > 0

**Симптомы.** Метрика растёт. На странице webhook'ов dead-letter rows.

**Диагностика.** `webhookDeadLetter` query → последние 50 проваленных доставок с `last_error`.

**Действие.**
- Если provider временно недоступен — подождать (max 5 попыток, exp backoff 1s/5s/30s/300s).
- Если провал постоянный — починить provider (URL, secret, network), затем `testWebhook(name)` для проверки, затем `clearDeadLetter` mutation.

## Diagnostics bundle

Для запутанных инцидентов:

```
GET /api/diagnostics/bundle           (RBAC: admin)
→ JSON: cluster state snapshot + issues + suggestions + recent audit + last N WS frames +
        peer connection table + failover state + recent logs
```

Прикладывать к issue/SOS-тикету.

## See Also

- [Operations](operations.md) — деплой, HAProxy, мониторинг
- [Architecture](architecture.md) — failover, 2PC, synchro spaces
- [Security](security.md) — auth, CSRF, peer-auth
