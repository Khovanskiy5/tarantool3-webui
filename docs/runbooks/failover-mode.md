# Runbook: change failover mode

Переключить кластер между четырьмя режимами выбора лидера: `off` (без агента) / `off + supervised agent` (наш OS аналог Cartridge supervised) / `manual` / `election` (raft).

## Когда применять

* Переход с прототипа (`off` + manual leader через `database.mode`) на production-grade автоматический failover (`supervised` или `election`).
* Maintenance: временно перейти в `manual` чтобы зафиксировать лидера на одном инстансе на час тестирования.
* Тестирование raft: переключить кластер в `election` и проверить как ведёт себя приложение под promote/demote.

## Шаги (через UI)

1. **Открыть /failover → кнопка `Settings…`.**
2. **Выбрать новый mode из dropdown.** Появятся dynamic-fields подходящие для выбранного режима:
   * `off` — toggle "Enable supervised agent on top of failover: off". По дефолту `true` (рекомендуемый production setup).
   * `manual` — никаких extra knobs; лидера будешь назначать через `editTopology` или через [promote.md](promote.md).
   * `election` — `election_timeout`, `election_fencing_mode` (off/soft/strict).
   * `supervised` — `lease_ttl_sec` (default 3s — TTL etcd-аренды координатора).
3. **(Опционально) выставить `synchro_quorum` / `synchro_timeout`** в SYNCHRO разделе. Пусто = backend оставит текущее значение. UI флагает красным баннером если ввести quorum < N/2+1 (split-brain risk).
4. **Preview** → backend возвращает `diff_summary: ['set_failover_mode → election']` и `prepared_id`. Можно перечитать что произойдёт.
5. **Apply** → backend коммитит в etcd + fan-out `config:reload()` на всех peer'ах (включая self). Ответ: `failover mode changed to election (revision 17). Reloaded on 3 peer(s) (self + 2).`

## Что делает backend под капотом

* Берёт live YAML из etcd (или из file mirror на свежем кластере).
* Меняет `replication.failover` и сопутствующие `synchro_*` / `election_*` knobs.
* Снимает `database.mode` со всех инстансов когда новый mode ≠ `off` (Tarantool схема не пускает оба одновременно).
* Тоглит `roles_cfg.webui.failover.agent`:
  * `election` / `manual` → forcibly `false` (наш agent не должен фитнуть Tarantool за queue ownership).
  * `supervised` → forcibly `true` (это и есть supervised path).
  * `off` → default `true` (preserve previous "agent on" for typical setups); `params.agent: false` отключает явно.
* Validate'ит assembled YAML (`config_schema.validate`).
* `twophase.prepare → commit`.
* Fan-out `config:reload()` self + foreign peers, чтобы новый mode стал effective до возврата мутации.

## Validation

* `synchro_quorum < N/2+1` (numeric) → `VALIDATION_ERROR: synchro_quorum N is below N/2+1=M, would allow split-brain`.
* Bad mode value → `VALIDATION_ERROR: mode must be off|manual|election|supervised`.
* `synchro_timeout <= 0` / `election_timeout <= 0` → reject.

## Transient quorum loss во время switch

Любое переключение mode перепроводит cluster через короткое window (1–5s) без queue owner:

* Tarantool's `cfg:reload()` сначала ставит `read_only=true` на текущем primary (config больше не указывает что он leader).
* НО: `box.ctl.demote()` НЕ вызывается автоматически — synchro queue ownership остается у старого primary, который теперь RO.
* Ни один sync write (включая audit row самой мутации `setFailoverMode`) не проходит до того как watcher / agent на новом leader'е вызовет `box.cfg{read_only=false} + box.ctl.promote()`.

Что это значит для оператора:
* **Apply Settings возвращает `applied: true`** — этот этап завершён.
* **Login или follow-up мутация могут вернуть** `UNAVAILABLE / NO_LEADER / queue doesn't belong to any instance` в течение 2–5 секунд после Apply.
* **Просто повтори запрос.** Cluster auto-recovery'тся: watcher на новом leader'е делает `box.cfg{read_only=false}` + `box.ctl.promote()` в течение пары secunds, и sync writes возобновляются.

Это known limitation Tarantool 3.x + supervised pattern. Cartridge решает то же самое в `cartridge/failover.lua::synchro_promote` тем же дуэтом (`box.cfg{read_only=false}` + `box.ctl.promote()`).

## Если что-то пошло не так

* **После Apply mode всё ещё старый в UI.** Подождать 1-2 сек (reload propagation). Если не помогло — F5 на /failover, mode читается из `config:get('replication').failover` на peer'е который отвечает на запрос; если landed на другой peer которому reload еще не пришёл — будет лаг.
* **`[GraphQL] no leader` после переключения.** Симптом: cluster без queue owner. Причины:
  1. Переключился в `manual` но не назначил лидера через [promote.md](promote.md) — `manual` mode ждёт явного `replicasets.<rs>.leader`.
  2. Переключился в `off` без agent (`params: {"agent": false}`) — нужен либо agent, либо явный `database.mode: rw` на target.
  3. Recovery: повторить Apply на любой mode с `agent: true` (либо просто `supervised`).
* **Cluster crash-loop'ит после Apply.** Скорее всего YAML stale — `database.mode` оставался на инстансах когда mode ≠ off. Backend это чистит автоматически (с фикса 2026-05-31), но если коммит pre-fix откати к предыдущей revision через [rollback-config.md](rollback-config.md).
* **fencing_mode `strict` блокирует writes.** В `election` mode с `strict` fencing любой network partition блокирует ВСЕ writes на minority side. Если такое не подходит — переключи на `soft` (default) или `off`.

## Как откатить

Запусти Settings ещё раз с предыдущим mode + явно поставь нужный `agent` / `synchro_*` параметр. Backend применит как обычный mode change.

В крайнем случае: [rollback-config.md](rollback-config.md) откатит весь YAML на нужную ревизию.
