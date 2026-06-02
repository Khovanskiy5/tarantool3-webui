# Operator runbooks

Каждый runbook — короткая пошаговая инструкция по одной операции из админки. Все runbook'и предполагают что у тебя `admin` или `superuser` роль (см. `docs/rbac-matrix.md`). Команды из админки идут через `setFailoverMode` / `promoteInstance` / `expelInstance` / `pauseFailover` / `createReplicaset` / `editTopology` / `rollbackConfig` / `forceReapplyConfig` GraphQL мутации; их можно дёрнуть из SPA, из GraphiQL (`/admin/api/explore`), или из CLI через curl.

## Каталог

| Runbook | Когда читать |
|---|---|
| [promote.md](promote.md) | Сделать конкретный инстанс лидером replicaset (плановая смена primary, балансировка нагрузки). |
| [failover-mode.md](failover-mode.md) | Переключить кластер между off / manual / election / supervised (наш OS agent). |
| [new-replicaset.md](new-replicaset.md) | Добавить новый replicaset с одним или несколькими инстансами. |
| [expel-instance.md](expel-instance.md) | Удалить инстанс из кластера (декомиссия, замена железа). |
| [rollback-config.md](rollback-config.md) | Откатить cluster YAML на предыдущую ревизию из /history/. |
| [pause-for-maintenance.md](pause-for-maintenance.md) | Остановить failover-агент на maintenance window. |
| [leader-autoreturn.md](leader-autoreturn.md) | Настроить автоматический возврат лидерства на preferred peer. |
| [split-brain-recovery.md](split-brain-recovery.md) | Восстановить кластер после split-brain (LSN-конфликты, "Split-Brain discovered" в логах). |

## Что общего у всех runbook'ов

Каждая операция:

1. **Идёт через 2PC + audit + commands journal.** На /audit видна запись с `action: cluster.<op>`, на /failover в "Commands history" — соответствующий ряд. Не нужно гадать "сработало ли".
2. **Имеет preview шаг.** Мутации с `apply: false` возвращают `diff_summary` и `prepared_id` — можно посмотреть что изменится, ничего не коммитя.
3. **Fan-out reload автоматический.** После успешного `apply: true` backend сам зовёт `config:reload()` на каждом peer'е (включая self), поэтому новый mode/leader/topology становится эффективным до того как мутация вернёт ответ.

## Если что-то пошло не так

Универсальные fallback'и:

* **Rollback config:** `/config-editor` → "History" → выбрать предыдущую ревизию → "Force apply". Создаёт новый commit с YAML из той ревизии + fan-out reload.
* **Pause failover на время разборок:** `/failover` → "Settings…" → или прямо через `pauseFailover(ttl_sec: 1800)`. Координатор перестаёт двигать лидерство, можно спокойно разбираться.
* **Manual rebootstrap follower'а:** `rebootstrapInstance(alias)` — wipe'ает WAL/snap'ы у follower'а и бутстрапит его заново из живых peer'ов. Не делать на лидере (он откажет — потеря committed-but-unconfirmed данных).
* **Логи:** `docker logs webui-tt-X --tail 200`. Backend пишет JSON-строки с tag'ами `twophase` / `failover.agent` / `webui.cluster_ops` — `grep -F '"tag":"failover.agent"'` сразу даёт картину состояния агента.

См. также: [`../operations.md`](../operations.md) — общее описание операционной модели, [`../troubleshooting.md`](../troubleshooting.md) — разбор частых ошибок.

## Developer reference

Не для оператора, а для разработчика, который трогает соответствующий backend-модуль.

| Документ | Когда читать |
|---|---|
| [data-explorer-architecture.md](data-explorer-architecture.md) | Прежде чем добавлять resolver в `data_mutations/` — структура модулей, dependency rules, deny-list, forward-to-leader, контракт фасада. |
