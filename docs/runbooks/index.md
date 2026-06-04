# Operator runbooks

Каждый runbook — короткая пошаговая инструкция по одной операции из админки. Все runbook'и предполагают что у тебя `admin` или `superuser` роль (см. `docs/rbac-matrix.md`). Команды из админки идут через `setFailoverMode` / `promoteInstance` / `expelInstance` / `pauseFailover` / `createReplicaset` / `editTopology` / `rollbackConfig` / `forceReapplyConfig` GraphQL мутации; их можно дёрнуть из SPA, из GraphiQL (`/admin/api/explore`), или из CLI через curl.

## Каталог

| Runbook | Когда читать |
|---|---|
| [promote.md](promote.md) | Сделать конкретный инстанс лидером replicaset (плановая смена primary, балансировка нагрузки). |
| [failover-mode.md](failover-mode.md) | Переключить кластер между off / manual / election / supervised (community agent). |
| [new-replicaset.md](new-replicaset.md) | Добавить новый replicaset с одним или несколькими инстансами. |
| [expel-instance.md](expel-instance.md) | Удалить инстанс из кластера (декомиссия, замена железа). |
| [rollback-config.md](rollback-config.md) | Откатить cluster YAML на предыдущую ревизию из /history/. |
| [pause-for-maintenance.md](pause-for-maintenance.md) | Остановить failover-агент на maintenance window. |
| [leader-autoreturn.md](leader-autoreturn.md) | Настроить автоматический возврат лидерства на preferred peer. |
| [split-brain-recovery.md](split-brain-recovery.md) | Восстановить кластер после split-brain (LSN-конфликты, "Split-Brain discovered" в логах). |
| [failover-issues.md](failover-issues.md) | Разбор failover/etcd issue'ов: coordinator-stuck, etcd-quorum-lost, failover-suppressed, divergent-rejoin, alien, orphan. |
| [recovery-overview.md](recovery-overview.md) | Обзор страницы /cluster-recovery: модель риска (safe/caution/dangerous) и универсальный порядок для опасных действий. |
| [orphan-resolve.md](orphan-resolve.md) | Разрулить залипший orphan: когда force_reconnect (safe), когда rebootstrap (опасно), когда solo_promote (дизастер). |
| [rebootstrap.md](rebootstrap.md) | Чистый re-bootstrap follower'а со сбросом идентичности (vclock-чистый `_cluster` id + свежий uuid, чтобы пиры снова реплицировали ОТ ноды). |
| [leader-takeover.md](leader-takeover.md) | Аварийно назначить владельца synchro-очереди, когда владельца нет / он недоступен (vclock-доминирование, switchover). |
| [topology-fix.md](topology-fix.md) | Починить URI репликации в топологии, когда applier завис на мёртвом адресе. |
| [wal-repair.md](wal-repair.md) | Восстановить повреждённый xlog (хвостовое vs серединное повреждение, rejoin vs quarantine). |

> Модель failover целиком (инварианты, lease/term/vclockkeeper, матрица Enterprise→OSS) — в [`../failover.md`](../failover.md).

## Что общего у всех runbook'ов

Каждая операция:

1. **Идёт через 2PC + audit + commands journal.** На /audit видна запись с `action: cluster.<op>`, на /failover в "Commands history" — соответствующий ряд. Не нужно гадать "сработало ли".
2. **Имеет preview шаг.** Мутации с `apply: false` возвращают `diff_summary` и `prepared_id` — можно посмотреть что изменится, ничего не коммитя.
3. **Fan-out reload автоматический.** После успешного `apply: true` backend сам зовёт `config:reload()` на каждом peer'е (включая self), поэтому новый mode/leader/topology становится эффективным до того как мутация вернёт ответ.

## Если что-то пошло не так

Универсальные fallback'и:

* **Rollback config:** `/config-editor` → "History" → выбрать предыдущую ревизию → "Force apply". Создаёт новый commit с YAML из той ревизии + fan-out reload.
* **Pause failover на время разборок:** `/failover` → "Settings…" → или прямо через `pauseFailover(ttl_sec: 1800)`. Координатор перестаёт двигать лидерство, можно спокойно разбираться.
* **Manual rebootstrap follower'а:** `rebootstrapInstance(alias)` — стирает WAL/snap follower'а и бутстрапит его заново со сбросом идентичности (новый `_cluster` id, чтобы пиры снова реплицировали ОТ него). Полная процедура и инварианты — в [rebootstrap.md](rebootstrap.md). Не делать на лидере (он откажет — потеря committed-but-unconfirmed данных).
* **Логи:** `docker logs webui-tt-X --tail 200`. Backend пишет JSON-строки с tag'ами `twophase` / `failover.agent` / `webui.cluster_ops` — `grep -F '"tag":"failover.agent"'` сразу даёт картину состояния агента.

См. также: [`../operations.md`](../operations.md) — общее описание операционной модели, [`../troubleshooting.md`](../troubleshooting.md) — разбор частых ошибок.

## Developer reference

Документация по подсистемам для разработчиков вынесена из этой папки:

- [`../data-explorer/index.md`](../data-explorer/index.md) — data-explorer (обзор/мутации спейсов, индексы, коллации, бинарные поля).
