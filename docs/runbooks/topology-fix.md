# Runbook: topology fix (починить URI репликации)

Когда кто-то отредактировал cluster YAML и URI одного из инстансов теперь указывает в никуда (опечатка, переименование контейнера, конфликт порта) — applier на каждом пире зависает на мёртвом адресе, в `/suggestions` видно «replication … is stopped: connect, called on fd …». Фиксится на странице **/cluster-recovery** (визард «Topology fix») или мутацией `recoveryAction`. Роль — `admin`.

Это **caution**-действие: оно меняет только URI в конфиге, **не трогает tuple-данные**. Риска потери данных нет; единственный эффект — reload/рестарт инстансов для применения нового адреса.

## Как это работает

1. **Диагностика** (`topology_fix_diagnose`, read-only): backend читает живой cluster YAML из etcd, обходит каждый объявленный инстанс и сверяет объявленный URI (`iproto.advertise.peer.uri`) с **наблюдаемым** — тем, к которому applier реально подключается (из peer-pool). Кандидатом на фикс становится инстанс, если:
   - наблюдаемый URI **достижим** и отличается от объявленного → предлагается авто-фикс (поле преднаполнено наблюдаемым адресом);
   - инстанс **недоступен** при непустом объявленном URI → авто-подсказки нет (правильный адрес узнать неоткуда), поле преднаполнено **объявленным** URI, чтобы оператор поправил опечатку вручную.
2. **Применение** (`topology_fix`): URI заменяются **точечной строковой правкой сырого YAML** — меняется только нужная строка, комментарии/форматирование/порядок ключей сохраняются. Патч идёт через штатный two-phase commit (валидация → запись в etcd → fan-out reload на всех пирах). Запись в `/audit` и revert-путь — как у любого config-коммита.

> Недоступный инстанс попадает в список и когда URI верен, а процесс просто **остановлен**. В этом случае менять адрес не нужно — подними процесс (визард подсказывает это прямо под таблицей). Опечатку от остановленного инстанса отличают по тому, выглядит ли объявленный адрес корректным.

## Шаги (визард)

1. Открой `/cluster-recovery` → визард **Topology fix**. Нажми «Diagnose».
2. Если все пиры достижимы и URI совпадают — «No issues detected», делать нечего.
3. Если есть кандидаты — увидишь таблицу `Peer | Reachable | Declared URI | URI to apply`. Для каждого проверь/поправь поле «URI to apply».
4. «Apply». Backend закоммитит точечный патч и сделает fan-out reload.

Эквивалент через GraphQL:

```graphql
# диагностика
mutation { recoveryAction(action: "topology_fix_diagnose")
  { ok results { peer ok msg } } }
# применение (fixes = map alias -> uri)
mutation { recoveryAction(action: "topology_fix",
  payload: "{\"fixes\":{\"tt-2\":\"tt-2:3301\"}}")
  { ok results { peer ok msg } } }
```

## Проверка и откат

- После apply: `/issues` и `/suggestions` должны очиститься от «replication stopped»; `box.info.replication[*].upstream.status` → `follow`.
- Если фикс оказался неверным — откати конфиг: `/config-editor` → History → предыдущая ревизия → Force apply (см. [rollback-config.md](rollback-config.md)).

## Если applier всё ещё stopped после фикса

URI поправлен, но инстансу нужен reload/рестарт, чтобы перечитать конфиг:

```bash
docker exec webui-tt-2 tt connect <control-socket> -e \
  "require('config'):reload(); return box.info.replication"
```

Если и после reload `upstream.status` не `follow` — проблема не в URI: проверь сетевую достижимость самого адреса (`docker exec webui-tt-1 sh -c 'nc -z tt-2 3301'`) и не уехал ли инстанс в split-brain ([split-brain-recovery.md](split-brain-recovery.md)).

## См. также

- [recovery-overview.md](recovery-overview.md) — модель риска.
- [rollback-config.md](rollback-config.md) — откат конфига, если фикс неверный.
- [failover-issues.md](failover-issues.md) — разбор failover/etcd issue'ов.
