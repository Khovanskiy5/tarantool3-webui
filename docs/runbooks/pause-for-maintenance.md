# Runbook: pause failover for maintenance

Временно остановить supervised-агента, чтобы провести maintenance окно без триггера автоматического failover.

## Когда применять

* Плановая перезагрузка / обновление одного из инстансов: чтобы агент не переизбрал нового лидера за время твоего kill -9.
* Тестирование: проверить как ведут себя app-клиенты при отсутствии available primary, не дёргая agent'a.
* Network partition тестинг.

## Шаги

1. **/cluster → кнопка `Pause failover…`** в шапке.
2. **Выбрать TTL (seconds).** Default 3600 (1 час). Hard cap 86400 (24h) — backend reject'ит больше с `PAUSE_TTL_TOO_LONG`.
3. **`Confirm pause`** → UI вызывает `pauseFailover(ttl_sec: <N>)`.
4. **Yellow banner появляется в toolbar** с countdown'ом: "Failover PAUSED — auto-resume in 59m 50s [Resume now]".

## Что делает backend

* `pauseFailover(ttl_sec)` пишет в etcd `<prefix>/failover/pause = {until_ts, by_user, ts}`.
* Coordinator в `appointment_cycle` на каждой итерации читает этот ключ. Если `until_ts > now` — пропускает promotion logic ПОЛНОСТЬЮ (никаких новых appointments).
* `lease_keepalive` продолжает работать — иначе координатор сменился бы во время паузы и pause-state в etcd могли бы не успеть прочитать.
* Audit + commands journal: `cluster.pause_failover` со ttl_sec.

## Pause не останавливает

* Watcher'ы на каждом peer'е продолжают работать. Если до паузы coord успел appoint = leader, watcher промоутит как обычно.
* Synchro replication, replication topology, vshard rebalancer — НЕ затрагиваются.
* Уже работающие транзакции (если лидер не убит) продолжают идти.

Pause тормозит ТОЛЬКО **новые** appointments — если лидер умрёт во время паузы, новый НЕ выберется до resume или истечения TTL.

## Резюме

Кликнуть `Resume now` в banner или подождать TTL. После resume:
* Backend `resumeFailover()` → DELETE `<prefix>/failover/pause`.
* Coordinator на следующем тике видит "no pause", probe'ит replicaset и appoint'ит лидера если нужно.

## Если что-то пошло не так

* **`PAUSE_TTL_TOO_LONG: pause TTL cannot exceed 86400s`** — попросил >24h. Используй [failover-mode.md](failover-mode.md) для долгого отключения (mode → off без agent).
* **Пауза истекла во время инцидента и failover сработал.** Если у тебя долгое maintenance — поставь pause длиннее. Default 1h может не хватить. Альтернатива: продли pause за пару минут до истечения (просто кликни Pause failover ещё раз, перезапишет).
* **`No leader` ошибка после resume.** Возможно во время паузы лидер потерял queue, и при resume никто не RW. Recovery: [promote.md](promote.md) на конкретный peer.
* **Случайно нажал Pause на production.** Кликни `Resume now` сразу же. Pause-state в etcd удалится в течение секунды, agent восстановит работу на следующем тике.

## Как откатить

`Resume now` в toolbar banner или `resumeFailover` mutation. Если совсем что-то не так — `etcdctl del /tarantool/webui/failover/pause` (требует доступа к etcd).
