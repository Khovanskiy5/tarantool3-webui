# Runbook: create new replicaset

Добавить новый replicaset с одним или несколькими инстансами.

## Когда применять

* Горизонтальное расширение vshard: ещё один storage replicaset.
* Изоляция нагрузки: отдельный replicaset для read-only аналитики.
* Тестирование: временный replicaset чтобы проверить новый набор roles перед раскаткой на основной.

## Предусловия

* Контейнеры/процессы для будущих инстансов уже запущены (на сетевом уровне), либо у тебя есть план их поднять сразу после commit (Tarantool replicaset членов ждёт по `iproto.advertise.peer.uri` до handshake).
* Имя нового replicaset уникально cluster-wide. Aliases инстансов тоже уникальны.

## Шаги (через UI)

1. **/cluster → кнопка `New replicaset…`** в шапке.
2. Заполнить форму:
   * **Name** — имя нового replicaset (например `rs-2`).
   * **Group** — обычно `default` (создаёт `groups.default.replicasets.<name>`).
   * **Instances** — JSON map keyed by alias. Предзаполнен шаблоном:
     ```json
     {
       "tt-new": {
         "iproto": {
           "advertise": { "peer": { "uri": "tt-new:3301" } },
           "listen": [{ "uri": "0.0.0.0:3301" }]
         },
         "database": { "mode": "rw" }
       }
     }
     ```
     В реальном кластере `database.mode: rw` нужен только если failover=off без agent (иначе либо agent, либо raft назначит RW сам).
   * **Leader** — alias из instances. Может быть пусто (тогда выберет agent/raft автоматически).
   * **Weight** — для vshard placement. `0` для router-replicaset, `>0` для storage.
   * **Roles** — comma-separated. Например `app.roles.storage, vshard-storage`.
   * **vshard_group** — если присоединяешь к существующей vshard-группе ("hot", "cold").
3. **Preview** → backend возвращает `diff_summary` (`add /groups/default/replicasets/rs-2`, `add /groups/default/replicasets/rs-2/instances/tt-new`).
4. **Apply** → backend `createReplicaset` коммитит, peer pool после reload подхватывает новый peer.

## Что делает backend

* Композирует `editTopology` с одним `ReplicasetEdit`:
  ```lua
  {
    name = "rs-2", group = "default",
    roles = {...}, leader = "tt-new", weight = 0,
    join_instances = { ["tt-new"] = <spec> },
  }
  ```
* Валидирует:
  * `name` + `group` non-empty.
  * `leader`, если задан, должен быть среди `join_instances`.
  * `failover_priority`, если задан, — subset of `join_instances`.
  * `weight ≥ 0`.
* Применяет к копии cluster YAML, перепарсивает через `config_schema.validate` (cross-validators: уникальность URI, leader-in-replicaset).
* `twophase.prepare → commit → fan-out reload`.
* Audit row: `cluster.create_replicaset`, payload + diff_summary.

## Если что-то пошло не так

* **`VALIDATION_ERROR: name is required`** — пустое имя в форме.
* **`TOPOLOGY_EDIT_FAILED: leader X is not in the replicaset`** — leader alias не входит в `join_instances`. Поправь форму.
* **`VALIDATION_FAILED: peer URI X used by multiple instances`** — URI новой инстанции совпадает с существующей. Поменяй `iproto.advertise.peer.uri`.
* **Replicaset создался, но новый инстанс `unreachable` навсегда.** Контейнер за `uri` не отвечает. Подними процесс. Либо exp'ни (см. [expel-instance.md](expel-instance.md)) и создавай с нуля с правильным URI.
* **Vshard buckets не появились на новом storage replicaset.** Запусти `vshard.router.bootstrap()` через GraphQL `bootstrapVshard` или подожди пока rebalancer перетащит buckets.

## Как откатить

* **До Apply:** просто закрой dialog. Preview не делает commit.
* **После Apply:** удали replicaset через [expel-instance.md](expel-instance.md) каждого инстанса по очереди, либо одним [rollback-config.md](rollback-config.md) на предыдущую ревизию.
