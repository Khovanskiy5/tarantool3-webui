[Back to README](../README.md) · [Architecture →](architecture.md)

# Синхронная репликация Tarantool 3.x — внутренности

Кратко: что значит «synchronous quorum» против «synchronous space», как они
связаны, как живёт limbo, какие фильтры на нём отрабатывают split-brain, и
чем `election_quorum` отличается от `synchro_quorum`. Все ссылки на код —
в дереве `tarantool-3.7.0/` (вендорный референс, не часть продакшен-сборки).

Этот документ — карта для тех, кто чинит инциденты репликации или пишет
суждения вроде «можно ли тут понизить кворум». Он не заменяет
[runbooks/split-brain-recovery](runbooks/split-brain-recovery.md), а
объясняет, что под капотом.

---

## 1. Limbo — единственное место, где живёт synchronous

Вся синхронность 3.x вращается вокруг структуры **`txn_limbo`**
(`src/box/txn_limbo.{h,c}`). Это очередь транзакций per-instance, у
которой:

- **один владелец** в каждый момент: `limbo->queue.owner_id`
  (`txn_limbo.h:390-393` → `txn_limbo_has_owner`).
- **только владелец имеет право писать в синхронные спейсы**.
- владение забирается через `box.ctl.promote()` — пишется в WAL запись
  `IPROTO_RAFT_PROMOTE`, обновляется `queue.owner_id`, поднимается
  `limbo->term`.

«Синхронный лидер» = peer, у которого `box.info.synchro.queue.owner ==
box.info.id`. Без владельца limbo синхронные записи невозможны — попытка
вернёт `synchro queue is unclaimed`.

Limbo живёт в одном-единственном экземпляре на инстанс (`extern struct
txn_limbo txn_limbo` в `txn_limbo.h`). Все sync-операции идут через него
последовательно.

---

## 2. Synchro quorum — число подтверждений

Параметр `replication.synchro_quorum` в YAML / `box.cfg.replication_synchro_quorum`.

- Тип: число **или формула** со свободной переменной `N`
  (`N/2+1`, `math.floor(N/2)+1`).
- Tarantool компилирует формулу через `loadstring` и заново
  вычисляет при каждом изменении конфига —
  `box_eval_replication_quorum` в `src/box/box.cc:1480-1561`.
- `N` = число **зарегистрированных** реплик (vclock-слотов), не
  «онлайн».
- Защита: значение должно быть в `[1, VCLOCK_MAX-1]` (`box.cc:1581-1592`);
  формулы вроде `N-2` отвергаются как небезопасные.
- Дефолт `1` (`replication.cc:62`).

### Что quorum означает в рантайме

В limbo есть worker-fiber (`txn_limbo_worker_f`, `txn_limbo.c:206-218`).
Каждый раз, когда applier на лидере получает ACK от peer'а с его LSN:

1. `txn_limbo_ack` → `txn_limbo_queue_ack`. Если на LSN-точке набралось
   `quorum` ACK'ов (включая самого лидера) — `volatile_confirmed_lsn`
   бампается.
2. Worker замечает это, пишет в WAL `IPROTO_RAFT_CONFIRM{lsn}`
   (`txn_limbo.c:144-158`) и будит все ждущие транзакции до этой LSN.

Если за `replication.synchro_timeout` quorum не собрался — worker пишет
`IPROTO_RAFT_ROLLBACK{lsn}` (`txn_limbo.c:164-180`), все pending-транзакции
от этой точки откатываются.

**И CONFIRM, и ROLLBACK — отдельные WAL-записи после самой транзакции.**
Это и есть причина, почему наивный PITR небезопасен: обрезать xlog между
записью txn и её ROLLBACK-маркером значит «воскресить» откаченную
транзакцию.

---

## 3. Sync space — флаг на конкретном спейсе

`is_sync` живёт в `struct space_def->opts.is_sync` (`src/box/space_def.h:108`)
и в эффективном состоянии `space->state.is_sync`
(`src/box/space.h:300-302`).

### Создание

```lua
box.schema.space.create('foo', { is_sync = true })
-- или
box.space.foo:alter{ is_sync = true }
```

### Проверка при коммите

`txn_prepare_synchro_request` в `src/box/txn.c:959-994`:

```c
bool is_sync = txn_has_flag(txn, TXN_WAIT_ACK);
...
stailq_foreach_entry(stmt, &txn->stmts, next) {
    if (stmt->row->type != IPROTO_NOP) {
        is_sync = is_sync || (stmt->space != NULL &&
                              space_is_sync(stmt->space));
    }
    ...
}
```

Алгоритм: **если хотя бы один statement транзакции пишет в sync-спейс —
вся транзакция становится синхронной**, попадает в limbo, ждёт quorum.

### Системные спейсы

`_space`, `_index`, `_func`, `_user`, … — это все system-спейсы из списка
`sync_system_space_ids` (`src/box/space.c:85-89`). На них действует
compat-флаг `box_consider_system_spaces_synchronous`
(`src/box/lua/config/descriptions.lua:285-295`):

- В 3.x дефолт `old` → system-спейсы НЕ sync.
- В 4.x дефолт `new` → они автоматически становятся sync, как только
  limbo получает владельца (`txn_limbo_has_owner`).

Логика на старте/altere: `src/box/space.c:659-663` и
`system_spaces_update_is_sync_state` (`space.c:1508-1532`). Переключение
динамическое — `box.ctl.promote()` поднимает sync на системных
спейсах; `box.ctl.demote()` снимает.

Это нужно, чтобы DDL (создание спейсов, индексов, пользователей) тоже
шёл через quorum и не уехал на меньшинство при split-brain.

---

## 4. Связь quorum × is_sync

| Слой | Что задаёт | Где |
|---|---|---|
| `replication.synchro_quorum` | Сколько ACK'ов нужно, чтобы limbo подтвердил | Кластер-уровень, одно число/формула |
| `space.is_sync` | Какие транзакции обязаны проходить через limbo | На каждом спейсе отдельно |

`is_sync` — это **«дверь в limbo»**. `synchro_quorum` — это **«вес замка
на двери»**. Если ни одного sync-спейса нет — limbo пустует, quorum
*настроен*, но не *срабатывает*. Если sync-спейс есть, а quorum = `N/2+1`
при `N=3` — на каждый INSERT лидер ждёт ACK от **двух** инстансов
(включая себя).

---

## 5. Поток выполнения insert'а в sync-спейс

1. **Клиент**: `box.space.foo:insert{...}`, `foo.is_sync = true`.
2. **TX-тред**: `txn_prepare_synchro_request` (`txn.c:959`) ставит
   `TXN_WAIT_ACK`, транзакция пушится в limbo как `txn_limbo_entry`.
3. **WAL-тред**: пишет тело транзакции (без CONFIRM!) в WAL. После fsync
   применяет к памяти.
4. Применённая запись поднимает локальный LSN лидера → лидер сам себе
   делает ACK.
5. **Replication subsystem**: рассылает ту же запись по
   `replication.peers`. Каждый peer пишет в свой WAL и отправляет ACK с
   LSN.
6. **Limbo worker** на лидере: набрался quorum по LSN — пишет в WAL
   `IPROTO_RAFT_CONFIRM{lsn}`, будит fiber клиента, возвращает success.
7. Если за `synchro_timeout` quorum не набрался — пишет
   `IPROTO_RAFT_ROLLBACK{lsn}`, клиент получает ошибку. Транзакция
   физически лежит в xlog, но логически отменена ROLLBACK-маркером.

### TXN flags

В `src/box/txn.h`:

```c
TXN_WAIT_SYNC  = 0x10  // ждёт CONFIRM, не возвращается клиенту
TXN_WAIT_ACK   = 0x20  // ждёт ACK от quorum (всегда влечёт WAIT_SYNC)
TXN_FORCE_ASYNC = 0x40 // принудительно async (snapshot, recovery)
```

`TXN_FORCE_ASYNC` важен — он позволяет recovery проигрывать xlog без
повторного попадания в limbo. Иначе каждый sync-INSERT при старте опять
ждал бы кворума и инстанс не загрузился бы.

---

## 6. Limbo filter family — защита от split-brain

В `src/box/txn_limbo.c` живут шесть фильтров. Они отсеивают «чужие»
записи на входе limbo: фильтр должен пройти **до** того, как запись
будет применена. Если фильтр отклонил пакет — applier выбрасывает
`ER_SPLIT_BRAIN` и останавливает репликацию с этого peer'а.

### 6.1 `txn_limbo_filter_owner_match` (line 518)

`req.queue_owner_id` должен совпадать с `limbo->queue.owner_id`. Не
совпадает → `ER_SPLIT_BRAIN: got a request from a foreign synchro queue
owner`.

Этот фильтр срабатывает, если кто-то прислал CONFIRM/ROLLBACK от лица
старого владельца, а мы уже видели новое PROMOTE. Защита от
«потерянного» лидера.

### 6.2 `txn_limbo_filter_owner_set` (line 541)

`req.queue_owner_id != 0`. Защита от битых пакетов. Все sync-запросы
должны иметь не-нулевой owner.

### 6.3 `txn_limbo_filter_non_zero_lsn` (line 559)

LSN в CONFIRM/ROLLBACK должен быть > 0. То же — защита от битых
пакетов.

### 6.4 `txn_limbo_filter_confirm` (line 574)

```text
если req.confirm.lsn > already_confirmed_lsn
   → owner_match обязателен (новое подтверждение можно только от текущего владельца)
если req.confirm.lsn <= already_confirmed_lsn
   → молча OK (повторное CONFIRM, бывает при join'е, читает уже подтверждённый view)
```

Тонкая деталь: повторные CONFIRM безобидны логически
(`txn_limbo.c:597-608`) — реплика догоняет лидера через xlog, видит
CONFIRM-маркеры, которые уже отражены в её состоянии. Игнорируем без
шума.

### 6.5 `txn_limbo_filter_rollback` (line 614)

```text
если req.rollback.lsn <= already_confirmed_lsn
   → owner_match обязателен (нельзя задним числом откатывать уже подтверждённое)
иначе:
   origin_term = term, в котором написан ROLLBACK
   если origin_term == limbo.term: текущий лидер откатывает свои pending — owner_match
   если origin_term < limbo.term:  старый лидер прислал ROLLBACK, новый уже всё разрулил —
                                   «nopify» (молча трактуем как no-op)
```

Комментарий в коде (`txn_limbo.c:638-641`):

> In older terms though this is fine to nopify it. Those txns must have
> already been cancelled by the new leader anyway.

### 6.6 `txn_limbo_filter_promote_demote` (line 646)

Самый сложный фильтр. PROMOTE/DEMOTE приходит с двумя ключевыми полями:
`term` (новый Raft-term) и `promote.lsn` (LSN, на котором новый лидер
подхватил очередь).

Серия проверок:

1. **Терм не может быть нулевым** → `ER_UNSUPPORTED`.
2. **`limbo.term >= req.promote.term`** → `ER_SPLIT_BRAIN: got a
   PROMOTE/DEMOTE with an obsolete term`. Этот узел уже видел новые
   выборы, отправитель «жил в подпространстве».
3. **`limbo.confirmed_lsn > req.promote.lsn`** → `ER_SPLIT_BRAIN: got a
   request with lsn from an already processed range`. Мы подтвердили
   что-то, чего пришедший лидер ещё не видит — это надёжный признак
   split-brain.
4. **`limbo.confirmed_lsn == req.promote.lsn`** → OK, всё консистентно
   (новый лидер забирает limbo на точке, где старый закончил).
5. Иначе (новая LSN впереди подтверждённой):
   - **Если limbo пустой** → `ER_SPLIT_BRAIN: got a request mentioning
     future lsn`. У нас всё откатилось по таймауту, новый лидер
     полагает, что транзакции лежат в очереди.
   - **Если limbo не пустой** → `req.promote.lsn` должен лежать в
     диапазоне `[first_lsn, last_lsn]` очереди. Иначе тоже split-brain
     с «out of queue range».

В этом же фильтре длинный комментарий-исповедь
(`txn_limbo.c:726-741`):

> XXX: this case of split brain though is only possible (excluding cases
> of potential stray broken requests) if this node did the
> rollback-by-timeout on some txns, and later a PROMOTE/DEMOTE tries to
> confirm them.
>
> This is one of the reasons why the rollback-by-timeout is broken by
> design and needs to be eliminated in future versions entirely. It can
> produce the split-brain even in a perfectly working cluster if the
> old leader would slightly lag and decided to rollback its pending
> synchro txns, while they are actually confirmed by a newer leader.

То есть авторы признают: автоматический rollback-by-timeout — это
архитектурный долг, который **сам по себе может породить split-brain** в
правильно сконфигурированном кластере. Реальное правильное решение
— ждать решения нового лидера, а не откатываться по таймеру.

### 6.7 Applier-side split-brain (вне фильтров)

`src/box/applier.cc:1585-1617`:

```c
uint64_t term = txn_limbo_replica_term(&txn_limbo, row->replica_id);
if (term == txn_limbo.term) return 0;
assert(term < txn_limbo.term);
...
if (txn_limbo.queue.owner_id == REPLICA_ID_NIL) return 0;
/*
 * Any asynchronous transaction from an obsolete term when limbo is
 * claimed by someone is a marker of split-brain by itself: consider it
 * a synchronous transaction, which is committed with quorum 1.
 */
diag_set(ClientError, ER_SPLIT_BRAIN,
         "got an async transaction from an old term");
```

Это самая частая `ER_SPLIT_BRAIN`-ошибка в логах. Логика:

1. Applier тянет транзакцию от какого-то peer'а.
2. Видит, что term этой транзакции **меньше** текущего term limbo.
3. Если транзакция async (`row->wait_sync == false`) И limbo сейчас
   занят (есть owner) → это **гарантированный split-brain**: лидер
   старого term'а пишет в кластер, не зная, что уже выбран новый.
4. Применять нельзя — applier останавливается, peer становится в статус
   `stopped` с reason `Split-Brain discovered: got an async transaction
   from an old term`.

Именно эту ошибку лечит наш Split-Brain wizard в DR-1: реальный fix
— rebootstrap losing-side. Простая `restart_replication` suggestion
(`box.cfg{replication={}}` → `box.cfg{replication=saved}`)
*не помогает* — после reconnect applier тут же снова получит тот же
конфликт.

### Сводная таблица

| Фильтр | Что проверяет | Что делает при отклонении |
|---|---|---|
| `owner_match` | owner совпадает | `ER_SPLIT_BRAIN: foreign synchro queue owner` |
| `owner_set` | owner != 0 | `ER_UNSUPPORTED: zero replica_id` |
| `non_zero_lsn` | lsn > 0 | `ER_UNSUPPORTED: zero LSN for CONFIRM/ROLLBACK` |
| `confirm` | новый LSN от текущего owner; старые LSN — OK | `ER_SPLIT_BRAIN` (через owner_match) |
| `rollback` | rollback от текущего owner; старый term — nopify | `ER_SPLIT_BRAIN` (через owner_match) |
| `promote_demote` | term растёт, LSN не из прошлого, LSN в диапазоне limbo | `ER_SPLIT_BRAIN: obsolete term / processed range / future lsn / out of queue range` |
| applier async-term | async-txn от старого term при занятом limbo | `ER_SPLIT_BRAIN: got an async transaction from an old term` |

---

## 7. `synchro_quorum` vs `election_quorum`

Два числа, путаемые в обсуждениях. Они **разные** и используются для
разных вещей.

### 7.1 `replication_synchro_quorum`

Уже разобран в §2. Используется limbo worker'ом, чтобы решить, когда
писать CONFIRM. Применяется буквально как настроено (формула
вычисляется на текущем количестве реплик).

### 7.2 `election_quorum` (Raft-internal)

Это поле живёт в самом Raft state (`src/lib/raft/raft.c`).
Устанавливается через `raft_cfg_election_quorum` (raft.c:1259):

```c
raft->election_quorum = election_quorum;
if (raft_vote_count(raft) >= raft->election_quorum)
    /* ... могу стать лидером */
```

Используется в:
- `raft.c:592` — `if (vote_count < election_quorum) {`
  → ещё не стал лидером, продолжаем кандидатствовать.
- `raft.c:721` — `if (election_quorum == 1)` → особая быстрая
  cамо-электория.
- `raft.c:843, 880` — ассерты в дебаге.

Значение задаётся через `box_raft_update_election_quorum` (`raft.c:230`):

```c
void
box_raft_update_election_quorum(void)
{
    struct raft *raft = box_raft();
    int quorum = replicaset_healthy_quorum();
    raft_cfg_election_quorum(raft, quorum);
    int size = MAX(replicaset.registered_count, 1);
    raft_cfg_cluster_size(raft, size);
}
```

И вот `replicaset_healthy_quorum` (`src/box/replication.h:614-661`) — это
**не** просто `replication_synchro_quorum`:

```c
static inline int
replicaset_healthy_quorum(void)
{
    int max = MAX(replicaset.registered_count, 1);
    return MIN(max, replication_synchro_quorum);
}
```

То есть `election_quorum = MIN(зарегистрированных_реплик,
synchro_quorum)`.

### 7.3 Зачем это сделано — bootstrap

Длинный комментарий в `replication.h:611-659` объясняет:

> The problem with bootstrap is that when the replicaset boots, all the
> instances can't write to WAL and can't recover from their initial
> snapshot. They need one node which will boot first, and then they
> will replicate from it.
>
> [Этот первый узел] must be writable. It should have read_only = false,
> connection quorum satisfied, and be a Raft leader if Raft is enabled.
>
> To be elected a Raft leader it needs to perform election. But it can't
> be done before at least synchronous quorum of the replicas is
> bootstrapped. And they can't be bootstrapped because wait for a leader
> to initialize _cluster. Cyclic dependency.
>
> This is resolved by truncation of the election quorum to the number of
> registered replicas, if their count is less than synchronous quorum.
> That helps to elect a first leader.

То есть: если пользователь поставил `synchro_quorum: 3`, но
зарегистрирована пока только 1 реплика, никто не сможет выиграть выборы
(нужно 3 голоса, голосовать некому). Получается циклическая зависимость:
чтобы избрать — нужен кворум; чтобы зарегистрировать ещё реплики —
нужен лидер.

Решение: `election_quorum` урезается до `min(registered, synchro_quorum)`.
Первый узел становится единоличным лидером с 1 голосом, регистрирует
второй, потом третий — и постепенно `election_quorum` подтягивается к
полному `synchro_quorum`.

> The current solution is totally safe because
> - synchronous replication quorum is untouched — it is not truncated.
>   Only leader election quorum is affected. So synchronous data won't
>   be lost.

Ключевая гарантия: **`synchro_quorum` НЕ урезается**. Только
`election_quorum`. Поэтому данные не теряются — sync-записи всё равно
ждут полного настроенного кворума, даже если в кластере временно
зарегистрирована только одна реплика.

### 7.4 Когда `election_quorum` пересчитывается

Триггеры:

- `box.cfg{replication_synchro_quorum = ...}` → `box_set_replication_synchro_quorum`
  → `box_raft_update_election_quorum()` (`box.cc:2630`).
- Изменение `replicaset.registered_count` (JOIN/EXPEL).
- Изменение `replicaset.healthy_count` (peer пришёл в строй / выпал) —
  через `replicaset_on_health_change` (`replication.cc:693-700`),
  который дёргает триггеры `replicaset_on_quorum_gain` / `_loss`.

### 7.5 Практика

| Сценарий | `synchro_quorum` | `election_quorum` |
|---|---|---|
| N=3, quorum=N/2+1, все online | 2 | 2 |
| N=3, quorum=N/2+1, один peer offline | 2 | 2 (healthy=2 ≥ 2) |
| N=3, quorum=N/2+1, два peer'а offline | 2 | 2 (но healthy=1 < 2 — выборы блочатся, лидер может уйти в fence) |
| Bootstrap: N=1, quorum=2 (формула N/2+1 при N=3) | 2 | **1** (truncated to registered=1) |
| Dev: N=3, quorum=1 | 1 | 1 |
| Багованный конфиг: N=3, quorum=10 | 10 (записи блочатся всегда) | 3 (выборы работают как обычно) |

### 7.6 Чем грозит `synchro_quorum` ниже `N/2+1`

Это и есть тот самый split-brain. Допустим N=3, `synchro_quorum = 1`.
Сеть распадается на {tt-1} и {tt-2, tt-3}.

- tt-1 видит quorum=1 (сам себе), продолжает писать.
- tt-2, tt-3 выбирают нового лидера среди себя (election_quorum=2,
  выполнимо), новый лидер тоже видит quorum=2 ≥ 1, тоже пишет.

Когда сеть восстановится — у обеих сторон будут расходящиеся sync-данные
в одном и том же term-range. Это уже не «split-brain detected»
автоматикой — это «cluster data corruption» без надёжного способа
восстановления.

Поэтому наш `validate_failover_params` в
`backend/webui/graphql/resolvers/cluster_ops.lua:968-985` явно
**отклоняет** числовые значения `synchro_quorum < N/2+1`. Формула
`N/2+1` принимается всегда — она автоматически растёт с кластером.

---

## 8. Что это значит для WebUI

| Площадка | Решение | Почему |
|---|---|---|
| Все `_webui_*` спейсы | `is_sync = true` (коммит `9337f76`) | Audit, конфиг-хистори, sessions, prepared-stage 2PC, commands journal — должны лечь на quorum либо не появиться. Иначе rebootstrap отвалившегося peer'а привезёт фантомные строки. |
| Дев-cluster.yaml | `synchro_quorum: N/2 + 1` | Безопасный дефолт. Формула масштабируется. |
| `setFailoverMode` | Reject явных `synchro_quorum < N/2+1` | См. §7.6. |
| PITR | Снят как фича | Невозможно безопасно обрезать xlog между записью txn и её CONFIRM/ROLLBACK маркером (§5, §2). |
| Split-brain wizard | Rebootstrap losing-side | Никаким `restart_replication` это не лечится — applier снова отдаст `got an async transaction from an old term` (§6.7). |

---

## 9. Полезные ссылки в коде

| Тема | Файл | Линии |
|---|---|---|
| `txn_limbo` структура | `tarantool-3.7.0/src/box/txn_limbo.h` | 380-400 |
| Limbo CONFIRM | `src/box/txn_limbo.c` | 144-158 |
| Limbo ROLLBACK | `src/box/txn_limbo.c` | 164-180 |
| Limbo worker fiber | `src/box/txn_limbo.c` | 206-218 |
| Filter family | `src/box/txn_limbo.c` | 516-755 |
| `txn_prepare` — is_sync detect | `src/box/txn.c` | 959-994 |
| `space->state.is_sync` | `src/box/space.h` | 295-302 |
| `space_def->opts.is_sync` | `src/box/space_def.h` | 108 |
| Compat: system spaces sync | `src/box/space.c` | 1508-1542 |
| `synchro_quorum` формула | `src/box/box.cc` | 1480-1561 |
| `election_quorum = min(registered, synchro_quorum)` | `src/box/replication.h` | 614-661 |
| Raft uses `election_quorum` | `src/lib/raft/raft.c` | 591-598 |
| Applier split-brain detect | `src/box/applier.cc` | 1585-1617 |
| Compat doc — system spaces | `src/box/lua/config/descriptions.lua` | 285-295 |
