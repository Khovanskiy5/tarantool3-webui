# Runbook: разбор failover-issue'ов

Что делать, когда на `/issues` (или в логах `"tag":"issues"`) появился failover/etcd issue. Модель целиком — в [`../failover.md`](../failover.md). Для всех действий нужна роль `admin` (rebootstrap/pause — `admin`, Lua-консоль — `superuser`).

Общий первый шаг для любого issue:

```bash
# состояние агента (на координаторе видно is_coordinator=true)
docker logs webui-tt-1 --tail 200 | grep -F '"tag":"failover.agent"'
# текущие appointment'ы и режимы (координатор, лидеры репликасетов, pause/disabled)
docker exec webui-etcd-1 etcdctl get --prefix /tarantool/webui/failover/
# liveness-репорты инстансов (mode/status/ro_reason) — отдельная ветка
docker exec webui-etcd-1 etcdctl get --prefix /tarantool/webui/state/by-name/ --print-value-only
```

---

## <a id="coordinator-stuck"></a> `coordinator-stuck` (critical)

**Значит:** supervised-агент-координатор держит непустой `last_error` — не может писать appointment'ы (etcd недостижим / lease потерян / CAS-конфликт). Новых перевыборов не будет, пока не очистится.

1. Проверь достижимость etcd с инстансов: `docker exec webui-tt-1 sh -c 'curl -s http://etcd:2379/health'` (или `etcdctl endpoint health`).
2. Если etcd жив — посмотри `last_error` в `agent.status()` (через лог `failover.agent`): CAS-конфликт обычно саморазрешается (другой пир стал координатором). Затяжной — смотри сетевые таймауты `probe_timeout_sec`.
3. Если etcd потерял кворум — см. [`etcd-quorum-lost`](#etcd-quorum-lost).
4. Гаснет сам, как только координатор успешно пишет appointment.

## <a id="etcd-quorum-lost"></a> `etcd-quorum-lost` (critical)

**Значит:** etcd-control-plane потерял кворум (≥ половины членов недоступны). **Коммиты конфига заблокированы**, авто-промоуты заморожены, лидер ушёл в RO (self-fence) — кластер держится в согласованном all-RO.

1. Это деградация, **не порча** — данные целы, split-brain исключён.
2. Подними недостающие члены etcd: `docker start webui-etcd-2 webui-etcd-3` (или восстанови узлы на их доменах отказа).
3. Проверь: `docker exec webui-etcd-1 etcdctl endpoint health --endpoints=http://etcd:2379,http://etcd-2:2379,http://etcd-3:2379`.
4. Как только кворим вернулся — координатор переизбирается, лидер re-promote'ится, issue гаснет. Запись конфига снова разрешена.
5. **Не** пытайся форсить запись в minority-партицию — etcd сам отвергнет (нет кворума).

## <a id="failover-suppressed"></a> `failover-suppressed` (warning)

**Значит:** в этом replicaset'е было слишком много смен лидера за окно (`suppress_threshold` за `suppress_window`) — anti-flap circuit-breaker заморозил авто-промоуты на `suppress_cooldown`.

1. Найди источник флапа: нестабильный пир (рестарт-шторм, сетевые блипы, GC-паузы). Смотри `appointment changed` / `failover dampened` в логе `failover.agent`.
2. Заморозка временная — снимется по cooldown. Если флап продолжается, причина не устранена.
3. Срочный ручной промоут оператора **игнорирует** заморозку: `promoteInstance(alias)` (см. [promote.md](promote.md)).
4. Если флапает железо/сеть — выведи проблемный инстанс: `setInstanceState(disabled=true)` или почини домен.

## <a id="transition-rate"></a> `transition-rate` (warning)

**Значит:** частота смен лидерства растёт, но заморозки ещё нет — раннее предупреждение перед `failover-suppressed`.

1. Это сигнал «назревает флап». Проверь тот же источник, что и для `failover-suppressed`.
2. Действий не требует немедленно; если перейдёт в `suppressed` — действуй по разделу выше.

## <a id="divergent-rejoin"></a> `divergent-rejoin` (critical)

**Значит:** инстанс вернулся после простоя/разделения с **дивергентным хвостом** — записями, которые текущий лидер никогда не подтверждал (избыток vclock при другом synchro-term). Его хвост нельзя пускать в репликацию (воскресил бы неподтверждённые записи / вызвал `ER_SPLIT_BRAIN`).

1. По умолчанию авто-rebootstrap **выключен** — действие за оператором.
2. **Сначала сохрани форензику:** сними копию data-dir дивергентной ноды, если хвост может понадобиться (`docker cp webui-tt-X:/opt/webui/var/lib /backup/diverged-tt-X`).
3. Re-bootstrap ноды от текущего лидера: `rebootstrapInstance(alias)` — wipe'ает WAL/snap и поднимает заново из живых пиров. **Никогда** не делай это на владельце synchro-очереди.
4. Если включён `auto_rejoin_rebootstrap: true` — в пределах окна `weak_subjectivity_max_term_gap` rebootstrap уже произошёл автоматически (видно в логе `failover.agent`); долго-мёртвая / self-promoted нода всё равно ушла к оператору.

## <a id="alien"></a> `alien` (warning)

**Значит:** в одном replicaset (по имени) инстансы с РАЗНЫМИ UUID replicaset'а — два кластера делят один etcd-prefix / cluster-cookie. Агент отказывается промоутить «чужака».

1. Проверь, что инстансы реально из одного кластера. Чаще всего — ошибка конфигурации (переиспользованный prefix / cookie).
2. Выведи чужой инстанс из кластера или дай ему отдельный `<prefix>`.
3. Агент сам не промоутит alien (alien-guard FO-17), так что split-brain через него исключён — это диагностика.

## <a id="orphan"></a> `orphan` (warning)

**Значит:** инстанс в состоянии `orphan` — переподключается / догоняет реплику после рестарта. Tarantool держит его RO и сам доведёт до `running`; агент не назначит orphan лидером.

1. Обычно само-разрешается за секунды — подожди.
2. Если залип надолго — репликация заклинила: проверь `box.info.replication[*].upstream.status` на инстансе, сетевую связность с пирами, нет ли расхождения (тогда → [`divergent-rejoin`](#divergent-rejoin) / split-brain).

## <a id="two-rw"></a> два RW / split-brain (critical)

`synchro:...:two-rw` — два владельца synchro-очереди. Это активный split-brain. Полный разбор и восстановление — отдельный runbook: [split-brain-recovery.md](split-brain-recovery.md).

Кратко: под pause агент **не** авто-демоутит (оператор разруливает); выбери самого догнавшего по vclock, остальных rebootstrap'ни.

## См. также

- [`../failover.md`](../failover.md) — модель, инварианты, EE→OSS матрица.
- [`split-brain-recovery.md`](split-brain-recovery.md), [`promote.md`](promote.md), [`failover-mode.md`](failover-mode.md), [`pause-for-maintenance.md`](pause-for-maintenance.md).
- [`../troubleshooting.md`](../troubleshooting.md) — частые ошибки и их симптомы.
