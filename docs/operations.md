[← Architecture](architecture.md) · [Back to README](../README.md) · [Security →](security.md)

# Operations

> **Runbook каталог:** [runbooks/index.md](runbooks/index.md) — пошаговые инструкции по типовым операторским действиям (promote, expel, rollback, mode switch, split-brain recovery и др.).

Operator handbook: развёртывание, конфигурация, failover, мониторинг, бэкап, rolling upgrade.

## Локальное окружение

`docker/docker-compose.yml` поднимает кластер из 3 инстансов Tarantool 3.7 с HAProxy перед ними, трёхузловым кворумом etcd (`etcd`/`etcd-2`/`etcd-3`) и одноразовым init-контейнером `etcd-seed`:

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
| `05-box.yaml` | box-defaults (`database.use_mvcc_engine` для synchro) |
| `10-credentials.yaml` | пользователи (replicator, webui_peer, *_dev) |
| `20-replication.yaml` | `failover: supervised`, synchro-quorum |
| `30-log.yaml` | формат логов (`json`), уровень, вывод (`tee` → файл + stdout) |
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

## Логи

Логи пишутся в формате **JSON** (`log.format: json`) — каждая строка отдельный объект (`time`/`level`/`message`/…), удобно для агрегаторов.

`log.to` — единственный приёмник: либо файл, либо stderr. Чтобы получить **оба** сразу, конфиг использует `log.to: pipe` и теит поток в `tee`:

- **файл** `var/log/tarantool.log` (в контейнере `/opt/webui/var/lib/var/log/tarantool.log`) — его читает встроенный вьювер `GET /api/logs` (`backend/webui/api/logs.lua`; резолвер достаёт путь как аргумент `tee`, а фильтр уровня понимает JSON-строки);
- **stdout контейнера** — Tarantool стартует как pid 1, поэтому stdout `tee` уходит в поток контейнера: видно в `docker logs` / `make dev-logs` / агрегаторе.

`stdbuf -oL` держит stdout `tee` построчно-буферизованным, чтобы `docker logs` не отставали. Для чисто-контейнерного деплоя (без встроенного вьювера) можно упростить до `log.to: stderr` — тогда файла нет, и `/api/logs` отдаёт `NOT_CONFIGURED`.

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

WebUI реализует «supervised»-режим (аналог EE-функции) поверх Tarantool CE через open-source агент. **Канонический справочник модели** (инварианты, lease/term/vclockkeeper/fencing, тайминги, матрица Enterprise→OSS, индекс issue→runbook) — в [`failover.md`](failover.md); разбор инцидентов — в [`runbooks/failover-issues.md`](runbooks/failover-issues.md). Ниже — операционные детали (конфиг, тайминги, etcd-HA, рестарты, pause).

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
      appointment_interval: 2
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

### Push-watch (etcd streaming)

Чтобы реагировать на смену лидера за миллисекунды, а не ждать секундный поллинг, агент держит два потоковых etcd-watch'а через JSON-gateway `/v3/watch` (chunked HTTP io):

- **appointment-watch** (на каждом инстансе) — следит за `<prefix>/failover/replicasets/<rs>/leader`; на событие сразу вызывает реакцию вотчера (promote/demote), не дожидаясь `watcher_poll_interval_sec`;
- **coordinator-watch** (на каждом инстансе) — следит за `<prefix>/failover/coordinator`; на DELETE (истечение lease координатора) будит лишь «дремлющего» пира, чтобы тот мгновенно поборолся за вакансию вместо ожидания `keepalive_interval`.

Это **чистая оптимизация задержки**: поллинг-цикл и self-fence остаются safety net. Если стрим не поднялся (etcd-блип, нет поддержки chunked-io) — агент тихо деградирует на поллинг и периодически переподключает watch. Отключается через `roles_cfg.webui.failover.watch_enabled: false`; `watch_idle_timeout` (деф 10с) — как часто watch-файбер просыпается проверить флаг остановки на простаивающем стриме.

### Fallback и переключение режимов

- **Fallback `off`.** Агент по-прежнему стартует при `replication.failover: off` (legacy). Это запасной путь на случай сборки Tarantool, отвергающей `supervised` на CE; гарантии RO-при-рестарте в нём слабее — критичные спейсы должны быть `is_sync`. В логе при старте: `failover agent in legacy "off" mode …` (или `… in legacy "off" fallback …`, если сборка не поддерживает supervised).
- **Переключение на встроенный raft.** Один edit: `replication.failover: election` и `roles_cfg.webui.failover.agent: false`. Агент отказывается стартовать при `failover ∈ {election, manual}`, поэтому double-leadership на transition исключён.

## etcd HA — кворум control-plane

etcd хранит cluster-wide config И lease failover-координатора, поэтому это «голосующие» за лидерство: он обязан быть настоящим **нечётным кворумом**, а не одиночным узлом (SPOF).

**Топология (дефолт «3 полных + 3 etcd»):** etcd = **3 узла**. Кластер из 3 терпит падение **одного** члена и продолжает работать; падение **двух** — потеря кворума: коммиты конфига блокируются, новые промоуты failover замораживаются, лидер сам уходит в RO (см. ниже). dev-compose поднимает `etcd`/`etcd-2`/`etcd-3` (`docker/docker-compose.yml`), endpoints всех трёх прописаны в `config.etcd.endpoints` и `roles_cfg.webui.etcd_writer.endpoints` (клиент ходит round-robin с failover на живой узел).

**Anti-affinity / домены отказа.** Не размещать ≥2 из 3 etcd (или ≥2 Tarantool-членов + etcd) на одном хосте/AZ — падение одного домена уронит кворум сразу. Размещать 3 DB + 3 etcd по **разным** доменам отказа. Если DB-хостов всего два — допустим паттерн **2 DB + 1 дешёвый witness-хост только с etcd** (tiebreaker control-plane), но `synchro_quorum=2 из 2` DB не даёт fault-tolerance записи данных — это осознанный компромисс.

**Поведение при потере кворума etcd:**
- **Коммит конфига блокируется** до записи: `twophase.commit` зовёт `etcd:cluster_health()` и при `has_quorum=false` (достигнут ≥1 член, но большинство вне кворума) отдаёт `ETCD_QUORUM_LOST` — быстрый понятный отказ вместо таймаута, без частичного коммита и без fan-out reload.
- **Issue `etcd:cluster:cluster:quorum-lost` (critical)** — поднимается issues-сканером, гаснет при восстановлении.
- **Авто-промоуты замораживаются структурно:** координатор не может продлить lease (это запись) → слагает полномочия; новые appointment'ы не пишутся. Действующий лидер не может подтвердить лидерство через etcd → **self-fencing (FO-1)** уводит его в RO. Кластер держится в согласованном all-RO до восстановления члена etcd — доступность чтения сохраняется, запись приостановлена (CP-выбор без split-brain).
- **Локальный fallback-конфиг:** каждый коммит зеркалит YAML на диск каждого инстанса (`file_writer`), поэтому при кратко недоступном etcd инстанс поднимается last-known из файла.

**Восстановление:** вернуть кворум (поднять член etcd) → координатор переизбирается, лидер re-promote'ится, issue гаснет автоматически.

## Безопасные рестарты (rolling / demote-first / majority-guard)

Резкий рестарт большинства или внезапная гибель лидера — частая причина split-brain. Оркестратор (`lifecycle/orchestrator.lua`) делает рестарты безопасными:

- **Majority-guard.** Любой стоп/рестарт, который оставит `< N/2+1` живых инстансов, **блокируется** (`ETCD_QUORUM`-аналог для DB-слоя). Видно через `rollingRestartPlan.blocked` и в ошибке `safeRestartInstance`.
- **Rolling — по одному.** Рестарт идёт по одному инстансу; следующий — только после того как предыдущий вернулся и его репликация сошлась (`upstream.status ∈ {follow, sync}`).
- **Demote-first.** Перед рестартом лидера лидерство передаётся здоровому фолловеру (manual appointment + ожидание нового RW-лидера), и только потом гасится старый — теперь уже фолловер.
- **Orphan-adoption.** Инстанс после рестарта может побыть в `orphan`, пока догоняет реплику: Tarantool держит его RO и сам доводит до `running`, а агент не назначает orphan лидером (`score_candidate`). Залипший orphan виден как WARNING-issue.
- **Restart-lock.** Операции рестарта сериализуются кластерным lock'ом (etcd-ключ `<prefix>/lifecycle/restart_lock`, привязан к lease). Два параллельных `safeRestartInstance`/rolling-прогона не могут оба пройти majority-guard по одному снапшоту и снять кворум вместе; крашнувшийся держатель освобождает lock по TTL. Demote-first промоутит самого догнавшего (min lag) электабельного фолловера.

**API:**
- `query rollingRestartPlan` (viewer) — порядок безопасного rolling-рестарта (фолловеры → лидер последним) + флаг `blocked`.
- `mutation safeRestartInstance(alias)` (admin) — безопасно рестартит один инстанс: majority-guard → demote-first если лидер → graceful-restart (drain + exit, Docker respin'ит фолловером). Это строительный блок: вызывать по одному инстансу, дожидаясь возврата каждого.

Механизм рестарта — `webui_graceful_restart_remote` (дренаж synchro-очереди + `os.exit(0)`, **без** очистки WAL/snap — в отличие от `rebootstrapInstance`).

## Weak-subjectivity guard (возврат долго-мёртвой ноды)

Нода, вернувшаяся после долгого простоя/разделения, может принести **расходящийся хвост** — записи, которые текущий лидер никогда не подтверждал (приняла в изоляции). Пускать её как sync-источник нельзя: она либо воскресит неподтверждённые записи, либо вызовет `ER_SPLIT_BRAIN` на лидере. По аналогии с blockchain weak-subjectivity вводится **доверенный чекпоинт** = revert-limit.

- **Чекпоинт.** Координатор пишет в etcd `<prefix>/failover/checkpoint/<rs>` = `{term, leader, confirmed_vclock, ts}` каждый цикл при здоровом RW-лидере.
- **Детекция дивергенции.** При опросе пиров координатор сравнивает каждого с лидером. Сигнал дивергенции — **избыток vclock при РАЗНОМ synchro-term**: лидер не доминирует vclock пира (у пира есть лишние записи) **и** term пира отличается от term лидера. Только избытка vclock недостаточно — здоровый RO-фолловер легально продвигает свою компоненту локальными записями (audit и т.п.) при ТОМ ЖЕ term; терм-митмэтч отделяет настоящий партиционный хвост от безобидных локальных писем (Kafka KIP-320 epoch-mismatch). Терм неизвестен → дивергенция не подтверждается (без ложных срабатываний).
- **Действие.** Дивергентная нода: WARN в лог (персистентный аудит расхождения — не выкидывается молча) + **critical-issue `divergent-rejoin`**. По умолчанию авто-rebootstrap **выключен** — оператор подтверждает через `rebootstrapInstance` (сохранив data-dir для форензики). Включается `roles_cfg.webui.failover.auto_rejoin_rebootstrap: true`; авто-rebootstrap только в пределах окна `weak_subjectivity_max_term_gap` (деф 1) — долго-мёртвая нода (большой term-gap) или self-promoted (term выше лидера) всегда уходит к оператору.

Хвост не пропихивается на лидер и без этого guard'а — лимб Tarantool (term/LSN-фильтр, `ER_SPLIT_BRAIN`) его отвергает; FO-18 добавляет **упреждающую** детекцию + понятное действие.

## Maintenance pause (плановое обслуживание)

Чтобы безопасно обслуживать кластер (rolling-restart, остановка ноды/etcd) без срабатывания авто-failover, есть **pause** — etcd-ключ `<prefix>/failover/pause = {until_ts, by_user}` с жёстким TTL (деф 1ч, макс 24ч). Включается через `mutation pauseFailover(ttl)` / выключается `resumeFailover` (admin).

Под pause (по образцу Patroni):
- **Lease продлевается** — координатор держит lease, чтобы failover не сработал, но **не делает авто-promote/demote** (appointment-цикл замораживается).
- **Self-fencing (FO-1) выключен** — лидер при потере etcd НЕ уходит в RO (оператор намеренно гасит etcd/ноды). Проверено вживую: при полной потере etcd под pause лидер остаётся RW.
- **Watchdog / dead-man (FO-15) выключен** — нет принудительного `os.exit` лидера.
- **Два RW под pause** — авто-демоут не-назначенного RW **не** происходит (issue `two-rw` всё равно поднимается; оператор разруливает).
- **Ручной `promoteInstance`** под pause работает (appointment-цикл заморожен, поэтому единственные изменения appointment'а — операторские, и вотчер их применяет).

**Защита:** pause-окно оценивается по локальным часам относительно `until_ts`, поэтому даже если etcd недоступен (часть обслуживания), pause всё равно истечёт по TTL — fencing не может быть отключён навечно из-за залипшего состояния. Состояние видно в `agent.status().watcher.paused`.

> Ручной промоут/маin­tenance делать **под pause**; авто-rolling-restart (`safeRestartInstance`, FO-12) сам управляет лидерством через appointment — его под pause запускать НЕ нужно.

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

Поля — надмножество контракта Tarantool Enterprise stateboard (`hostname`/`pid`/`mode`/`ro_reason`/`status` из `tarantool-3.7.0/src/box/lua/config/descriptions.lua:2862` плюс `alias` и `ts`). Формат — JSON вместо YAML (единообразно с остальными ключами WebUI в etcd: `/failover/coordinator`, `/failover/replicasets/<rs>/leader`).

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
| GET   | `/api/snapshots/download`  | admin      | Скачать `.snap`/`.xlog`                           |
| GET   | `/api/config/download`     | admin      | Скачать текущий cluster YAML                      |
| POST  | `/api/config/upload`       | admin      | Загрузить YAML → `proposeConfig` (dry-run)        |
| POST  | `/api/eval`                | superuser  | Lua консоль (gating `console_enabled`)            |
| POST  | `/api/sql`                 | operator   | SQL-запрос (write-стейтменты эскалируют до `admin`) |
| POST  | `/api/sql/explain`         | operator   | `EXPLAIN` для SQL-запроса                         |
| GET   | `/api/logs`                | admin      | Хвост role-логов (фильтры через query)            |
| GET   | `/api/diagnostics/bundle`  | admin      | JSON-бандл состояния для тикетов поддержки        |
| POST  | `/api/diagnostics/rebootstrap` | admin  | Re-bootstrap инстанса (wipe WAL/snap; деструктивно) |
| GET   | `/ws`                      | session    | WebSocket подписка                                |
| POST  | `/admin/api`               | session    | GraphQL endpoint, RBAC на уровне резолверов       |
| GET   | `/admin/api/explore`       | admin      | GraphiQL (если `graphiql_enabled: true`)          |

CSRF: cookie `webui_csrf` (не HttpOnly) дублируется в заголовке `X-Csrf-Token` для всех `POST/PUT/PATCH/DELETE`.

## Каталог GraphQL операций

Полный per-field справочник — [`api/graphql-schema.md`](api/graphql-schema.md); точные роли — [`rbac-matrix.md`](rbac-matrix.md). Ниже — операции, сгруппированные по доменам (38 query + 52 mutation).

| Домен | Query | Mutation |
|---|---|---|
| Кластер | `cluster`, `clusterLiveness`, `serverTime` | — |
| Issues / suggestions | `issues`, `issuesSummary`, `suggestions` | `applyForceApply`, `applyRestartReplication`, `applyRefreshVshard`, `applyDisableServer`, `applyRefineUri`, `applyRestartFailover`, `applyBootstrapVshard` |
| Config 2PC | `config`, `configHistory`, `configRevision`, `configJsonSchema` | `proposeConfig`, `validateConfig`, `commitConfig`, `abortConfig`, `rollbackConfig`, `forceReapplyConfig`, `reloadRoles` |
| Топология | — | `editTopology`, `setReplicasetRoles`, `createReplicaset`, `editReplicaset`, `addInstance`, `expelInstance`, `setInstanceState` |
| Failover | `failover`, `failoverAgentStatus`, `failoverStateProviderStatus`, `failoverCommands`, `rollingRestartPlan` | `setFailoverMode`, `promoteInstance`, `demoteInstance`, `pauseFailover`, `resumeFailover`, `safeRestartInstance`, `rebootstrapInstance` |
| Recovery | `recoverySnapshot`, `recoveryPreflight` | `recoveryAction` (preflight-оценка риска + серверный gate для опасных действий) |
| vshard | `vshard`, `vshardKnownGroups`, `canBootstrapVshard` | `bootstrapVshard` |
| Data explorer | `spaces`, `tuples`, `spaceStats`, `sequenceInfo`, `collations`, `indexAction` | `tupleInsert/Replace/Update/Delete`, `createSpace`, `dropSpace`, `alterSpace`, `truncateSpace`, `createIndex`, `dropIndex`, `sequenceCreate/Alter/Drop/Reset/Set` |
| Users / saved queries | `users`, `savedQueries` | `saveQuery`, `deleteSavedQuery` |
| Audit / webhooks | `audit`, `verifyAuditChain`, `webhooks`, `webhookQueueDepth`, `webhookDeadLetter` | `exportAudit`, `testWebhook`, `clearDeadLetter` |
| Bootstrap | `bootstrapStatus`, `bootstrapTemplates`, `bootstrapRender` | `bootstrapInitialize` |
| Базовое / lifecycle | `ping`, `webuiVersion`, `roleStatus` | `probeUri` |

## Мониторинг

### `/api/metrics`

Prometheus-формат. Экспортируется rock `metrics` плюс маркер `webui_up=1`.

### `/api/metrics/webui`

Self-metrics WebUI-роли:

| Metric | Type | Назначение |
|---|---|---|
| `webui_up` | gauge | Маркер живости роли (`1`) |
| `webui_self_time` | gauge | Текущее время инстанса (epoch) |
| `webui_servers_seen` | gauge | Сколько инстансов видит поллер |
| `webui_audit_rows` | gauge | Размер `_webui_audit` |
| `webui_ws_connections` | gauge | Активные WebSocket-подписчики |
| `webui_webhook_queue_depth` | gauge | Pending-доставки webhooks |
| `webui_webhook_dead_letter_depth` | gauge | Записей в dead-letter |
| `webui_webhook_dead_letter_total` | counter | Всего ушло в dead-letter |
| `webui_webhook_deliveries_total` | counter | Успешные доставки |
| `webui_webhook_failures_total` | counter | Неуспешные попытки |
| `webui_webhook_retry_count_total` | counter | Ретраи доставки |

Failover-телеметрия (статус агента, anti-flap, weak-subjectivity, pause) отдаётся не Prometheus-метриками, а через GraphQL `failoverAgentStatus` / `agent.status()` и issue-сканер.

### Рекомендованные alerts

- `up == 0` или `webui_up == 0` дольше 30 секунд → page.
- Появление critical-issue `etcd-quorum-lost` / `two-rw` / `coordinator-stuck` (через `issuesSummary` или webhook `issue.appeared`) → page.
- `webui_audit_rows` > 80% retention budget → notice (расширить retention или прорежить).
- `webui_webhook_dead_letter_depth > 0` → notice (есть provider, который не отвечает).
- Появление WARNING-issue `transition-rate` или `failover suppressed: flapping` (через `issuesSummary` / `failoverAgentStatus`) → notice (flapping leader; failover-телеметрия идёт через GraphQL/issue-сканер, не через Prometheus).

## Snapshots и backup

### Создание snapshot'а

- Из UI: страница «Snapshots» → кнопка «Take snapshot» на нужном инстансе.
- Через REST: `POST /api/snapshots/take` (RBAC: admin). GraphQL-мутации для снапшота нет — канал только REST.

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
   ├── bun install --frozen-lockfile  (cache на package.json + bun.lock)
   └── bun run build                   → frontend/dist/

Stage 2 (tarantool/tarantool:3.7.0)
   ├── tt rocks install http 1.9.0 graphql 0.3.1 errors 2.2.1
   ├── COPY backend/webui              → /usr/share/tarantool/webui/
   ├── COPY backend/internal           → /usr/share/tarantool/internal/  (CE config-shim)
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

## See Also

- [Architecture](architecture.md) — failover-агент, 2PC, synchro-spaces
- [Security](security.md) — TLS, mTLS, peer-auth
- [Troubleshooting](troubleshooting.md) — runbooks для типовых инцидентов
- [RBAC matrix](rbac-matrix.md) — полная матрица операций
