# Runbook: rollback cluster config

Откатить cluster YAML на предыдущую ревизию из /history/.

## Когда применять

* Прошлый коммит сломал прод (бэкенды не отвечают, replication застряло, role не стартует).
* Хотим временно вернуться к старому набору ролей для регрессии.
* Force-apply revision N — частный случай, когда нужно "освежить" текущее состояние на отстающих peer'ах.

## Шаги (rollback)

1. **/config-editor → правая панель History.**
2. **Выбрать предыдущую ревизию** в timeline (например `#85` если текущая `#92`).
3. Можно сначала `Diff vs current` чтобы посмотреть что вернёт rollback.
4. **Кнопка `Rollback`** в строке ревизии. Native confirm: "Roll the cluster config back to revision #85? This will create a new commit and fan-out config:reload to every peer." → ОК.
5. Backend:
   * Pre-check schema compat: validate target YAML against current `config:jsonschema()`. Если target ссылается на role/user/key которые удалены в текущем environment — reject с `ROLLBACK_INCOMPATIBLE`.
   * `proposeConfig(yaml: <target>)` + `commitConfig` → новый etcd revision (например `#93`).
   * Audit: `config.rollback` с `from_revision` / `to_revision` / `diff_summary`.
   * Fan-out `config:reload()` на все peer'ы.

## Шаги (force apply revision)

Когда хотим РЕ-АППЛИТЬ ту же ревизию (например `config:reload()` отвалился на одном peer'е и его mode рассинхронизирован):

1. **/config-editor → History → выбрать current revision.**
2. **Кнопка `Force apply`** (красная).
3. **Type-to-confirm dialog:** ввести exactly номер ревизии (например `92`).
4. **`Force apply`** → backend `forceReapplyConfig(revision: 92)`.
   * Внутри: `rollbackConfig(revision=92)` — создаёт новый commit с YAML из #92.
   * fan-out reload автоматический.

## Что делает backend

* `mutation_rollback`:
  * Читает target YAML из `<prefix>/history/<rev>` storage.
  * Validate'ит через `config_schema.validate` (cross-validators).
  * `twophase.prepare` → `twophase.commit` (с `action: 'rollback'` для audit).
  * Audit row + fan-out reload.
* `mutation_force_reapply`:
  * Если `revision` указан → делегирует в `mutation_rollback`.
  * Без `revision` → просто fan-out `config:reload()` на все/перечисленные peers без change YAML.

## Если что-то пошло не так

* **`REVISION_NOT_FOUND`** — ревизия age'нулась beyond `MAX_HISTORY` (default 200). Можешь смотреть `oldest_available_revision` в footer history panel. Если нужный snapshot выпал — recovery через ручную сборку YAML.
* **`ROLLBACK_INCOMPATIBLE: target revision references config that is no longer valid: <details>`** — target ссылается на role/user которая удалена. Сценарий: ревизия N7 использовала `roles: [app.roles.beta]`, потом role была убрана в N8 и в текущем коде. Rollback к N7 reject'нется. Варианты:
  * Сначала добавь обратно удалённую role через /config-editor → commit → потом rollback.
  * Или ручной merge: открой N7 YAML (`configRevision` query), убери ссылку на удалённую role, commit как новую ревизию.
* **Rollback успешный, но один peer не среlоднулся.** Symptom: `Reload partial: failed on tt-X`. Сделай `forceReapplyConfig(instances: ["tt-X"])` — это сделает `config:reload()` адресно на peer'е без rollback.
* **Cluster.yaml на диске рассинхронизирован с etcd после rollback.** Не страшно — etcd берёт верх при reload. File mirror обновляется при следующем commit'е.

## Как откатить rollback

Сделать ещё один rollback вперёд. Например: было `#92`, откатили к `#85` (создалось `#93` с YAML из `#85`). Откат отката: `rollbackConfig(revision: 92)` создаст `#94` с YAML из `#92`. Идемпотентность: history-driven.
