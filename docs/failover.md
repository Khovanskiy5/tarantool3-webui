# Failover — OSS supervised-parity model

Канонический справочник по тому, **как устроен** failover в этом WebUI: инварианты, модель lease / term / vclockkeeper / fencing, тайминги, и матрица «механизм Enterprise → реализация OSS». Операционные команды и конфиг-сниппеты — в [`operations.md`](operations.md); пошаговые действия по инцидентам — в [`runbooks/failover-issues.md`](runbooks/failover-issues.md).

## TL;DR

Кластер работает в нативном режиме Tarantool **`replication.failover: supervised`** + `bootstrap_strategy: auto`, а назначение писателя (RW) делает встроенный community-агент (`backend/webui/failover/*`) через **etcd-lease координатора**. Это open-source паритет Enterprise `supervised` failover: те же гарантии против split-brain, без Enterprise-бинарника.

Почему supervised, а не `failover: off`: applier платформы сам стартует инстансы **read-only** (snapshot-aware) и не трогает RO/RW на `config:reload()` — то, что в `off` пришлось бы городить руками. Агенту остаётся только promote/demote + self-fencing + консистентный switchover. `failover: off` оставлен документированным fallback'ом.

## Инварианты

Соблюдаются всегда; каждый механизм либо вводит, либо защищает один из них.

1. **Единственный RW.** В любой момент synchro-очередь принадлежит ≤ 1 инстансу. Лидер = владелец очереди, не просто `box.cfg.read_only = false`.
2. **RW только после catch-up.** Инстанс становится RW лишь когда (a) назначен лидером актуальным координатором, (b) его vclock ≥ vclock прежнего лидера, (c) выиграл vclockkeeper-CAS.
3. **Старт в RO.** Любой (ре)старт начинается read-only; переход в RW — только через подтверждённое назначение.
4. **Self-fencing.** Лидер, не сумевший продлить RW-lease за `renew_deadline` и не видящий кворума, сам уходит в RO, не дожидаясь нового appointment.
5. **Снапшоты неприкосновенны.** Авто-восстановление никогда не стирает `.snap`/`.xlog`. Re-bootstrap (стирание) — только по явному решению оператора.
6. **Монотонность решений.** Каждое назначение несёт монотонный `failover_term`; запись с меньшим term отвергается.
7. **Деградация, не порча.** Потеря кворума etcd → блок записи конфига + заморозка авто-промоутов (кластер RO), но не частичное применение и не «вторая голова».
8. **Fencing на data-plane.** Lease/term фенсят control-plane; финальная защита — synchro-очередь сама отвергает записи со старым term (`txn_limbo.c` → `ER_SPLIT_BRAIN`). Поэтому failover ВСЕГДА через `box.ctl.promote`, term выровнен с термом лимба, критичные спейсы `is_sync`.
9. **Безопасность не зависит от своевременности агента.** Зависший/паузнутый процесс не должен пробить инвариант 1 — watchdog/dead-man гасит ноду, если она не продлила lease к hard-deadline.
10. **Время монотонное, демоут до TTL.** Вся lease-математика на `fiber.clock()`; лидер замолкает на `renew_deadline = ttl − safety_margin`, раньше чем кто-то легально захватит lease; зазор покрывает clock-skew.

## Архитектура

```
                         etcd (3-узловой кворум, control-plane)
   <prefix>/failover/coordinator        ← lease-выбор единственного координатора
   <prefix>/failover/replicasets/<rs>/leader      ← appointment {leader, term, prev_vclock}
   <prefix>/failover/replicasets/<rs>/vclockkeeper ← CAS-claim перед RW (FO-3)
   <prefix>/failover/checkpoint/<rs>     ← доверенный чекпоинт {term, confirmed_vclock} (FO-18)
   <prefix>/failover/pause               ← maintenance-окно (FO-19)
   <prefix>/lifecycle/restart_lock       ← сериализация рестартов (FO-12)
                         │
          ┌──────────────┼──────────────┐
        tt-1            tt-2            tt-3        (по одному агенту+вотчеру на инстанс)
   agent.lua (только координатор пишет appointment'ы)
   watcher.lua (на каждом: читает appointment → box.ctl.promote/demote)
```

- **agent.lua (координатор).** Один инстанс держит lease на `coordinator`-ключе и пишет appointment'ы. Probe'ит пиров, выбирает лучшего кандидата (`score_candidate`/`pick_leader`), пишет `{leader, term=mod_revision, prev_vclock}` под CAS на coordinator-key.
- **watcher.lua (на каждом инстансе).** Читает appointment (push-watch FO-7 + 1с-поллинг fallback), применяет: promote (после catch-up + vclockkeeper-CAS), demote, RO не-назначенного RW. Отдельный `fencing_loop` — self-fencing по монотонным часам.
- **Последняя линия — лимб Tarantool.** Даже если control-plane ошибётся, synchro-очередь отвергнет запись со старым term (`ER_SPLIT_BRAIN`).

## Lease / term / vclockkeeper

- **Lease (FO-1).** Координатор держит etcd-lease с TTL = `lease_ttl_sec`. Лидер подтверждает лидерство каждым успешным чтением своего appointment'а (обновляет монотонный `last_leader_confirm_mono`). Если за `renew_deadline = lease_ttl − safety_margin` подтверждения нет → **self-fence в полный RO** (sync+async).
- **Term (FO-4).** `failover_term` = `mod_revision` координаторского ключа etcd. Строго монотонен. Вотчер отбрасывает appointment с term ниже уже применённого. На data-plane term выровнен с термом лимба → `ER_SPLIT_BRAIN` отвергает чужой хвост.
- **vclockkeeper switchover (FO-3).** Новый лидер перед RW: (1) догоняет до `prev_vclock` прежнего лидера (`box.ctl.wait_*`), (2) CAS-claim'ит `vclockkeeper`-ключ, и только тогда `read_only=false` + `promote`. Не теряет подтверждённые записи при смене лидера.
- **Checkpoint (FO-18).** Координатор пишет доверенный `{term, leader, confirmed_vclock}`. Вернувшаяся нода с дивергентным хвостом (избыток vclock при РАЗНОМ synchro-term) → не пускается как sync-источник, идёт на rebootstrap / к оператору.

## Тайминги (дисциплина Patroni)

Терминология выровнена с Patroni: `ttl` = `lease_ttl_sec`, `loop_wait` = `keepalive_interval`, `retry_timeout` = `probe_timeout_sec`. Инварианты валидируются и авто-корректируются на старте (FO-5):

- `loop_wait + 2·retry_timeout ≤ ttl` — лидер получает два полных шанса продлить lease до истечения (короткий блип etcd не вызывает ложный failover);
- `ttl ≥ 2·loop_wait` — нужно для арминга watchdog'а;
- `renew_deadline = ttl − safety_margin` — на нём срабатывает self-fence, раньше истечения lease;
- минимумы `retry_timeout ≥ 3`, `loop_wait ≥ 1`; рекомендуемый `ttl ≥ 20`. Дефолт dev: `ttl=20, loop_wait=5, retry_timeout=3`.

Anti-flap (FO-6): φ-accrual детектор смерти лидера + suppression circuit-breaker + per-candidate backoff — против штормов перевыборов. Подробности и все тюнинги — в [`operations.md`](operations.md).

## Матрица: Enterprise / Cartridge → OSS

| Механизм EE / Cartridge | Что даёт | Реализация OSS |
|---|---|---|
| **Master self-fencing по lease-дедлайну** (`supervised_failover.rst`; Cartridge `fencing_healthcheck`) | Лидер сам уходит в RO при невозможности продлить RW-lease, даже при нулевой связи с etcd | **FO-1** `watcher.lua::fencing_loop` (монотонные часы, демоут на `renew_deadline`) |
| **Старт в RO + RO-реассерт на reload** (`box_cfg.lua` supervised) | Рестартующий инстанс не успевает побыть RW до подтверждения лидерства | **FO-0/FO-2** нативный `failover: supervised` (applier стартует RO) + вотчер демоутит не-назначенный RW |
| **vclockkeeper-before-writable** (Cartridge `constitute_oneself`) | Новый лидер догоняет LSN старого + CAS-фиксируется до записи — не теряет подтверждённые | **FO-3** `watcher.lua::prepare_to_promote` (wait-vclock + vclockkeeper-CAS) |
| **Монотонный fencing-token** (EE `failover/active/term`; Cartridge `ordinal` CAS) | Устаревший координатор не перезапишет свежее решение | **FO-4** `failover_term` = mod_revision + CAS на coordinator-key; data-plane — лимб |
| **etcd-кворум / stateboard HA** | Control-plane — настоящий нечётный кворум, не SPOF | **FO-8** 3-узловой etcd + quorum-gate на commit + issue `etcd-quorum-lost` |
| **Watch (longpoll) вместо поллинга** | Реакция за миллисекунды | **FO-7** streaming-watch на `/v3/watch` + poll-fallback |
| **Anti-flap / immunity / suppression** (Cartridge `coordinator.lua`; Patroni `primary_start_timeout`) | Нет «пинг-понга» лидерства при шторме рестартов | **FO-6** φ-accrual + suppression + backoff |
| **Watchdog / STONITH** (Patroni watchdog) | Зависший лидер не остаётся RW дольше lease | **FO-15** dead-man-switch (`os.exit` к hard-deadline) |
| **Failsafe-режим** (Patroni failsafe) | Доступность при потере DCS без split-brain | **FO-16** opt-in: RW только если ВСЕ пиры подтвердили |
| **Pause / maintenance** (Patroni pause) | Плановое обслуживание без авто-failover | **FO-19** pause-ключ: self-fence/watchdog/авто-демоут off |
| **Rolling-restart / switchover** (patronictl) | Не убить большинство, не ронять лидера резко | **FO-12** majority-guard + demote-first + restart-lock |
| **Weak-subjectivity rejoin** (blockchain; Kafka KIP-320) | Долго-мёртвая нода не пропихивает дивергентный хвост | **FO-18** checkpoint + term-mismatch детект → rebootstrap/оператор |
| **Anti-affinity / failure domains** | Падение одного домена не роняет кворум сразу | Документировано (см. [`operations.md`](operations.md) → etcd HA) |

## Health-issues и runbook'и

Issues-сканер (`cluster/issues.lua`) поднимает (и гасит) issue'и; полный разбор и действия — [`runbooks/failover-issues.md`](runbooks/failover-issues.md).

| Issue id | Severity | Что значит | Runbook |
|---|---|---|---|
| `synchro:replicaset:<rs>:two-rw` | critical | Два владельца synchro-очереди (активный split-brain) | [split-brain-recovery](runbooks/split-brain-recovery.md) |
| `etcd:cluster:cluster:quorum-lost` | critical | etcd потерял кворум — коммиты/промоуты заморожены | [failover-issues](runbooks/failover-issues.md#etcd-quorum-lost) |
| `failover:cluster:cluster:coordinator-stuck` | critical | Координатор не пишет appointment'ы (last_error) | [failover-issues](runbooks/failover-issues.md#coordinator-stuck) |
| `failover:replicaset:<rs>:suppressed` | warning | Авто-failover заморожен из-за флапа | [failover-issues](runbooks/failover-issues.md#failover-suppressed) |
| `failover:replicaset:<rs>:transition-rate` | warning | Повышенная частота смен лидера (предупреждение) | [failover-issues](runbooks/failover-issues.md#transition-rate) |
| `failover:instance:<alias>:divergent-rejoin` | critical | Нода вернулась с дивергентным хвостом | [failover-issues](runbooks/failover-issues.md#divergent-rejoin) |
| `failover:replicaset:<rs>:alien` | warning | Инстансы с разными UUID replicaset'а в одном prefix | [failover-issues](runbooks/failover-issues.md#alien) |
| `replication:instance:<alias>:orphan` | warning | Инстанс orphan (догоняет реплику; RO) | [failover-issues](runbooks/failover-issues.md#orphan) |

## См. также

- [`operations.md`](operations.md) — операционная модель, конфиг, тайминги, etcd-HA, мониторинг.
- [`runbooks/failover-issues.md`](runbooks/failover-issues.md) — что делать по каждому issue.
- [`runbooks/failover-mode.md`](runbooks/failover-mode.md) — переключение режимов.
- [`runbooks/recovery-overview.md`](runbooks/recovery-overview.md) — страница /cluster-recovery: модель риска (safe/caution/dangerous) и визарды восстановления.
- [`runbooks/split-brain-recovery.md`](runbooks/split-brain-recovery.md) — восстановление после split-brain.
- [`sync-replication-internals.md`](sync-replication-internals.md) — лимб, term/LSN-фильтры, `ER_SPLIT_BRAIN`.
