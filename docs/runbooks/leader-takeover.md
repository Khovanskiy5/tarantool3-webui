# Runbook: leader takeover (назначить владельца synchro-очереди)

Когда synchro-очередью никто не владеет (`box.info.synchro.queue.owner == 0`) или владелец мёртв/недостижим — синхронные записи заблокированы по всему кластеру, и нужно назначить нового владельца. Делается на странице **/cluster-recovery** (визард «Leader-takeover») или мутацией `recoveryAction(action: "leader_takeover", payload: ...)`. Роль — `admin`.

> Плановая смена лидера на здоровом кластере — это [promote.md](promote.md). Этот runbook — про аварийный захват, когда владельца нет или он недоступен.

## Как это работает

Действие зовёт `box.ctl.promote()` на выбранном узле. Важные свойства (Tarantool 3.7):

- promote **бампит synchro-term** и персистит его в WAL до записи PROMOTE.
- promote **ждёт кворум и catch-up** и **возвращает ошибку по таймауту** — это не fire-and-forget. Неуспешный promote означает, что лидерство **НЕ передано**; узел остался без очереди.
- promote в деградированный кворум (живых пиров меньше `synchro_quorum`) зависает/падает.

## Риск: доминирование по vclock

Безопасность takeover определяется тем, **догнал ли кандидат подтверждённое состояние**:

- **Есть владелец очереди:** кандидат должен **доминировать по vclock** над владельцем (применил всё, что владелец подтвердил). Тогда — безопасно.
- **Владельца нет:** кандидат должен доминировать **всех достижимых** пиров. Если есть более продвинутый достижимый пир — его хвост потеряется.

Если кандидат **не** доминирует — promote откатит (`rollback`) транзакции с LSN выше границы кандидата, то есть **потеряет подтверждённые записи** более продвинутого узла. Это data-loss. В логе отстающего пира это видно как `Split-Brain discovered: got a request with lsn from an already processed range` (`confirmed lsn X > request lsn Y`).

## Нюанс: отстающий пир и «future lsn»

Доминирование кандидата — необходимое, но **не достаточное** условие чистого takeover. Даже когда кандидат **впереди** (доминирует), достижимый пир, который ещё **не успел реплицировать** до vclock кандидата, отвергнет promote как `Split-Brain discovered: got a request mentioning **future lsn**` (`confirmed lsn Y < request lsn X`) — и его applier **залипнет терминально**. Это не потеря данных (пир просто отстал), но узел выпадает из репликации.

Причина — гонка: promote (claim очереди) долетает до пира раньше, чем строки, которыми пир должен догнать кандидата. Поэтому действие **сначала ждёт** (bounded), что все достижимые пиры догнали vclock кандидата, и только потом зовёт `box.ctl.promote`. Assess-панель **показывает** отстающих пиров отдельным preconditon'ом («Peers will catch up to candidate first»). Если пир не успел догнать за окно — в результате будет warning, а сам пир лечится rebootstrap'ом ([rebootstrap.md](rebootstrap.md)). Замечание: assess сравнивает **vclock** (limbo `confirmed_lsn` Tarantool в `box.info.synchro.queue` не отдаёт), а vclock-компонента бывшего владельца — это и есть прокси его подтверждённой позиции.

## Безопасный путь: switchover вместо force

Если текущий владелец **достижим**, не делай слепой force-promote. Сделай switchover (потерь нет):

1. Загони старого владельца в read-only первым — на нём `box.ctl.demote()` (или дождись его self-fence по lease).
2. Дай кандидату догнать LSN старого владельца (`box.info.vclock` кандидата ≥ владельца).
3. Только тогда промоуть кандидата.

Force (немедленный promote отстающего) оправдан **только когда владелец недостижим** и доступность важнее точной согласованности.

## Шаги (визард)

1. Открой `/cluster-recovery`. Снапшот покажет, что владельца нет (`No queue owner`) или он `unreachable`.
2. Открой визард **Leader-takeover**. По умолчанию подставится кандидат с максимальным LSN.
3. Сверь vclock кандидата с остальными пирами в таблице (колонки `Last LSN`, `Current term`). Бери самый продвинутый достижимый.
4. Подтверди (для опасного варианта — впечатай токен `TAKEOVER <alias>`).

Эквивалент через GraphQL:

```graphql
mutation { recoveryAction(action: "leader_takeover",
  payload: "{\"target_alias\":\"tt-2\"}") { ok results { peer ok msg } } }
```

## Если promote не удался

```bash
# проверь состояние выборов и очереди на кандидате
docker exec webui-tt-2 tt connect <control-socket> -e \
  "return { ro = box.info.ro, owner = box.info.synchro.queue.owner, \
            term = box.info.synchro.queue.term, election = box.info.election }"
```

- `owner` всё ещё 0 и promote вернул ошибку → кворум не собрался: проверь, что живых пиров ≥ `synchro_quorum`, или временно см. [quorum-escape в recovery-overview](recovery-overview.md).
- `queue.busy == true` → идёт PROMOTE/CONFIRM/ROLLBACK: подожди и повтори, не дёргай повторно.
- `election.term > queue.term` → выборы прошли, но очередь ещё не захвачена: повтори promote.

## См. также

- [recovery-overview.md](recovery-overview.md) — модель риска и универсальный порядок.
- [promote.md](promote.md) — плановая смена лидера.
- [split-brain-recovery.md](split-brain-recovery.md) — если два владельца очереди.
- [`../failover.md`](../failover.md) — vclockkeeper/term/lease.
