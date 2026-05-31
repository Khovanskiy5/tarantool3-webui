# Runbook: expel instance

Удалить инстанс из кластера. Декомиссия железа, замена peer'а, очистка тестовых инстансов.

## Когда применять

* Контейнер / VM с инстансом больше не нужен (был ошибочно создан, замена железа, downsize).
* Vshard shard выводится из эксплуатации: сначала rebalance buckets, потом expel.
* Чистка после неудачного `createReplicaset` со wrong URI.

## Шаги

1. **Проверить vshard buckets.** Если инстанс — vshard-storage с >0 buckets, ОБЯЗАТЕЛЬНО запусти `vshard.router.bucket_send()` rebalance первым. Иначе данные на expelled host'е потеряны.
2. **Promote leader на другой peer** (если expel'ишь текущего лидера). См. [promote.md](promote.md).
3. **/cluster → строка target alias → кнопка `Expel…`.**
4. **Type-to-confirm dialog:** ввести exactly alias инстанса (например `tt-3`).
5. **Кликнуть `Expel`.** UI вызывает `expelInstance(alias: "tt-3", force: false)`.

## Что делает backend

1. Локально парсит cluster YAML, ищет где живёт alias. Если не найден → `NOT_FOUND`.
2. Safety check: refuse to expel если это единственный инстанс в replicaset (replicaset стал бы без membres). `force: true` обходит проверку.
3. `editTopology` удаляет entry из `groups.<g>.replicasets.<rs>.instances.<alias>`. Также чистит ссылки в `failover_priority` других replicaset'ов.
4. `twophase.commit` + fan-out reload — peers видят новый YAML, peer pool в `cluster/peers.lua` диффит и закрывает iproto connections к expelled URI.
5. Post-commit: `_cluster` row cleanup на каждом достижимом peer'е. SELECT'ит row с alias=expelled, DELETE'ит. Best-effort: если кто-то ro — skip. Орфановая row только занимает replica_id slot.
6. Audit + commands journal: `cluster.expel_instance` со scope `cluster:` и payload (alias, replicaset, force).

## Если что-то пошло не так

* **`FORBIDDEN: refusing to expel the only instance of <rs>`** — replicaset станет пустым. Если действительно хочешь — pass `force: true`.
* **`NOT_FOUND: alias is not in cluster YAML`** — уже expel'нут, либо никогда не был. Проверь `cluster { servers }`.
* **Контейнер expel'нутого инстанса всё ещё пытается реконнектить.** Это нормально: процесс не убит — Tarantool в `box.cfg{ replication=... }` retry'ит, но cluster YAML его уже не знает. Останови контейнер (`docker stop webui-tt-3` или `kill -TERM`).
* **`_cluster` row остался на каком-то peer'е** ("skipped because it was ro"). Не критично — слот не освобождён, но другие операции работают. Cleanup вручную:
  ```
  box.space._cluster:delete({<replica_id>})
  ```
  Запустить на leader через `/console` (Lua mode, superuser only).
* **Vshard buckets остались на expelled host'е.** Если не сделал rebalance до expel — данные доступны только локально на expelled процессе, но cluster не знает откуда их читать. Recovery: запустить процесс обратно с тем же UUID (если есть snap'ы), сделать rebalance, потом expel заново. Если snap'ов нет — данные потеряны.

## Как откатить

* **Сразу после expel** (cluster YAML обновлён, instance процесс ещё жив, его данные нетронуты):
  1. [rollback-config.md](rollback-config.md) на предыдущую ревизию (до expel commit).
  2. Подождать reload fan-out.
  3. Инстанс реконнектится сам — peer pool diff увидит alias обратно и откроет connection.
* **После того как процесс остановился**: instance потерял `_cluster` row, его UUID больше не известен кластеру. При перезапуске Tarantool отрефьюзит join (другой UUID = другая identity). Effectively — нужен заново bootstrap'ить пустой инстанс через [new-replicaset.md](new-replicaset.md) (или editTopology / addInstance в существующий rs).
