# Runbook: split-brain recovery

Восстановить кластер после split-brain. Симптомы: "Split-Brain discovered: got a request with lsn from an already processed range" в логах, applier'ы stopped, replication broken.

## Рекомендуемый путь: страница /cluster-recovery

Основной способ — визард **Split-brain** на странице `/cluster-recovery`. Снапшот (`recoverySnapshot`) сам классифицирует пиры (split-brain / queue-owner / unreachable), группирует разошедшиеся узлы и подсказывает победителя по vclock. Визард предлагает три действия (мутация `recoveryAction(action: "split_brain_resolve", payload: ...)`):

| Действие | Что делает | Класс риска |
|---|---|---|
| `manual` | Только пишет аудит-запись — оператор чинит руками (шаги ниже). | safe |
| `rebootstrap_losing` | Wipe'ает проигравших и поднимает их от победителя. | **dangerous** (стирает дивергентные коммиты проигравших) |
| `force_promote_winner` | Понижает кворум до 1, промоутит победителя, восстанавливает кворум. | **dangerous** (откат неподтверждённых транзакций победителя) |

Перед любым `dangerous`-действием соблюдай универсальный порядок из [recovery-overview.md](recovery-overview.md): **пауза failover → бэкап data-dir → фиксация vclock/term → действие**. Панель показывает сводку оценки (что произойдёт, предупреждения, команды на случай неуспеха); для опасного варианта нужно подтверждение + ввод токена, и сервер откажет в применении без них.

Разделы ниже — **подробная ручная процедура** (то, что делает `manual`-ветка визарда, и что использовать, если нужен полный контроль или UI недоступен).

## Что такое split-brain

Synchronous replication гарантирует что только один peer может коммитить writes. Split-brain возникает когда два peer'а одновременно убеждены что они owner queue и каждый коммитит свою последовательность LSN. Когда они потом видят друг друга — applier'ы детектируют конфликт (lsn из range который уже processed) и переходят в stopped state.

Причины:
* `--force-recreate` контейнера мимо graceful shutdown (Tarantool не успевает demote).
* Network partition + переключение failover без `synchro_quorum`.
* Bug в выборе лидера (несколько promote() параллельно).
* Кривое восстановление из снапшота на одном peer'е.

## Шаги

### Step 1. Диагноз

```bash
docker exec webui-tt-1 tarantool -e "
local nb=require('net.box')
local c=nb.connect('webui_peer:webui-peer-dev-password@127.0.0.1:3301')
if c:wait_connected(3) then
  print(c:eval([[
    local out={}
    for _, r in pairs(box.info.replication) do
      out[#out+1] = string.format('id=%s us=%s msg=%s',
        r.id,
        r.upstream and r.upstream.status,
        r.upstream and (r.upstream.message or ''))
    end
    return table.concat(out, '\\n')
  ]]))
end"
```

Если видишь `us=stopped msg=Split-Brain discovered ...` — это оно.

### Step 2. Определить "правильный" peer

Кто из тех, что разошлись, имеет:
* самый старший vclock (`box.info.vclock`),
* больше unsynced commits (`box.info.synchro.queue.len > 0`),
* свежие clients (если знаешь куда они подключались).

Обычно это peer который был leader в момент инцидента. Назовём его `tt-trusted`.

### Step 3. Pause failover для безопасности

```graphql
mutation { pauseFailover(ttl_sec: 1800) { applied } }
```

Через UI: /cluster → Pause failover → TTL 30 minutes. Так агент не будет переизбрать лидера пока ты разбираешься.

### Step 4. Force-promote trusted peer (emergency)

Если queue lost owner ИЛИ нужно ОЧИСТИТЬ unconfirmed transactions из limbo (data loss accepted):

```graphql
mutation {
  promoteInstance(
    alias: "tt-trusted",
    force_inconsistency: true,
    skip_error_on_change: true
  ) { applied message }
}
```

`force_inconsistency: true` — ВНИМАНИЕ: unconfirmed sync transactions на trusted peer будут ROLLBACK'нуты. Reading clients могут увидеть откат "успешно committed" транзакций.

### Step 5. Rebootstrap пострадавших followers

Для каждого peer с `us=stopped` (split-brain side):

```graphql
mutation { rebootstrapInstance(alias: "tt-broken") { ok deleted_count message } }
```

Backend:
1. Forward'ит `_cluster` row delete для tt-broken через rpc.map_eval на trusted peer.
2. Стопит role на target.
3. Wipe'ит WAL/snap/vinyl на target.
4. `os.exit(0)` → Docker restart-policy перезапускает контейнер.
5. Tarantool на боoт'е делает full bootstrap join из trusted peer (новый UUID).

Это надёжный recovery: target идёт с нуля, его LSN history стирается, applier handshake чист.

### Step 6. Resume failover

```graphql
mutation { resumeFailover { applied } }
```

Через UI: кнопка `Resume now` в yellow banner.

### Step 7. Verify

* `box.info.replication` — все `us=follow` (или `sync`).
* `find_leader` возвращает alias.
* App writes проходят.

## Если force_inconsistency недопустим

Если ты НЕ можешь принять data loss (committed-but-unconfirmed transactions важны), тогда:

1. **Read out unconfirmed transactions** из `box.info.synchro.queue` на trusted peer перед promote — это поможет понять что будет потеряно.
2. **Manually replay** через `vinyl_dump`/`xlog_dump` критичные записи на trusted peer после recovery.
3. **Connect к Tarantool Enterprise support** — у них есть tools для split-brain recovery без data loss.

Полностью lossless-восстановление без участия оператора (автоматический merge дивергентных хвостов) — это область Enterprise-инструментов; OSS-сборка даёт UI-управляемое восстановление с явными предупреждениями о потере данных, но не автоматический lossless-merge. Приоритет — доступность при контролируемой потере неподтверждённых записей.

## Профилактика

* Никогда не делай `docker rm -f` / `kill -9` / `--force-recreate` без `pauseFailover` first.
* Используй `docker compose down` (SIGTERM + graceful) вместо `docker kill`.
* Установи `stop_grace_period: 10s` в compose чтобы agent.stop успел сделать `box.ctl.demote()` и drain'нуть limbo (это путь **реального** shutdown — там demote нужен).
* Synchro quorum ≥ N/2+1 (см. [failover-mode.md](failover-mode.md)).
* Регулярно проверяй /issues — issues scanner ловит split-brain через `check_replication` и поднимает CRITICAL alert.

**Структурная защита (уже в коде):**

* **Config-reload не демоутит лидера** (Patroni-принцип «reload ≠ failover»). Раньше `apply()` на каждый reload бросал роль → `agent.stop()` делал graceful demote → бамп term'а → re-promote; эта чехарда term'ов отравляла limbo любой ноды, которая в этот момент джойнилась (она наследовала старый term и застревала в split-brain против следующего `PROMOTE`). Теперь demote делается только на реальном shutdown/SIGTERM. Это убрало главный источник split-brain'а при re-bootstrap'е / правках топологии.
* **Re-bootstrap ждёт устаканивания limbo** перед join-снапшотом и сам ставит паузу failover — нода всегда джойнится из чекпойнта с чистым limbo текущего term'а. См. [rebootstrap.md](rebootstrap.md).

## См. также

- [recovery-overview.md](recovery-overview.md) — модель риска и универсальный порядок (пауза → бэкап → фиксация → действие).
- [leader-takeover.md](leader-takeover.md) — назначить владельца очереди (switchover vs force-promote).
- [failover-issues.md](failover-issues.md#two-rw) — issue `two-rw` (детект двух владельцев очереди).
- [promote.md](promote.md), [pause-for-maintenance.md](pause-for-maintenance.md).
