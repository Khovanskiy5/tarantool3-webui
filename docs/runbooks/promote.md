# Runbook: promote instance

Сделать конкретный инстанс лидером replicaset.

## Когда применять

* Плановый maintenance: текущий лидер уходит на обновление, нужно перевести нагрузку на конкретный peer заранее.
* Балансировка нагрузки между DC: переключить primary на инстанс ближе к большинству читающих клиентов.
* Recovery после флапа: один из followers'ов восстановился, надо явно вернуть на него primary.

## Шаги

1. **Открыть /cluster.** Убедиться что target alias (`tt-2` в примере) в статусе `running`, `reachable: true`, без replication issues.
2. **Кликнуть `Promote` в строке инстанса.** UI вызывает `promoteInstance(alias: "tt-2", ttl_sec: 300)`.
3. **Дождаться баннера успеха** в колонке Actions: "manual override appointment written for tt-2 on rs-1 (expires in 300s). box.ctl.promote() ok." Бэйдж `LEADER` сразу переезжает на target row.

В команды history (/failover → Commands history) появится ряд `cluster.promote` со статусом `success` и параметрами `{alias, mode}`.

## Что происходит на уровне бэкенда (по режиму failover)

| Mode | Действие |
|---|---|
| `off` (без agent) | `editTopology` ставит `database.mode: rw` на target и `mode: ro` на остальных в этом replicaset. |
| `supervised` (или `off` + agent fallback) | Запись `manual_override_until = now + ttl_sec` в `/failover/replicasets/<rs>/leader`. Coordinator уважает override TTL секунд (default 300s) и не выбирает другого. Параллельно `box.ctl.promote()` на target сразу переносит synchro queue. |
| `manual` | `editTopology` обновляет `replicasets.<rs>.leader: <alias>`. |
| `election` | `box.ctl.promote()` через net.box на target — Tarantool гоняет raft round. |

## Если что-то пошло не так

* **"NOT_FOUND: alias is not in cluster YAML"** — инстанс не описан в `groups.<g>.replicasets.<rs>.instances`. Проверь /config-editor: возможно его раньше exp'нули.
* **"already declared leader" + `skip_error_on_change: true` не помог** — operator-mutation уже идёт, дождись завершения предыдущей (Commands history покажет status pending/taken).
* **`box.ctl.promote()` warning: still rw on previous leader** — synchro queue не передалась. В режиме supervised это нормально (override TTL ещё не истёк); в `election` режиме — проверь `box.info.election`, нужно вручную увеличить election_timeout через [failover-mode.md](failover-mode.md).
* **Promote `force_inconsistency: true`** — emergency сценарий, см. [split-brain-recovery.md](split-brain-recovery.md).

## Как откатить

Promote'нуть обратно предыдущий primary тем же шагом — backend очистит override автоматически (новая appointment перезапишет ключ в etcd).
