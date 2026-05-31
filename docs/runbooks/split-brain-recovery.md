# Runbook: split-brain recovery

Восстановить кластер после split-brain. Симптомы: "Split-Brain discovered: got a request with lsn from an already processed range" в логах, applier'ы stopped, replication broken.

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

OS-сборка WebUI'а такой поддержки не даёт — этот runbook оптимизирован для типового demo / dev setup где availability > exact consistency.

## Профилактика

* Никогда не делай `docker rm -f` / `kill -9` / `--force-recreate` без `pauseFailover` first.
* Используй `docker compose down` (SIGTERM + graceful) вместо `docker kill`.
* Установи `stop_grace_period: 10s` в compose чтобы agent.stop успел сделать `box.ctl.demote()` и drain'нуть limbo.
* Synchro quorum ≥ N/2+1 (см. [failover-mode.md](failover-mode.md)).
* Регулярно проверяй /issues — issues scanner ловит split-brain через `check_replication` и поднимает CRITICAL alert.
