# Runbook: восстановление кластера — обзор и модель риска

Зонтичный runbook по странице **/cluster-recovery**. Объясняет, какие функции восстановления есть, как они классифицируются по риску потери данных и какой общий порядок безопасен для любого опасного действия. Все действия требуют роли `admin` и пишутся в `/audit`.

Страница `/cluster-recovery` строит **диагностический снапшот** (`recoverySnapshot`): классифицирует каждый пир (queue-owner / follower / orphan / split-brain / unreachable), показывает per-peer vclock, synchro-term, и выдаёт рекомендацию. Снапшот — read-only, дёргать можно сколько угодно.

## Модель риска

Каждое действие восстановления попадает в один из трёх классов по тому, может ли оно потерять **подтверждённые** (committed) данные при текущем состоянии кластера:

| Класс | Что значит | Примеры |
|---|---|---|
| **safe** | Подтверждённые данные не теряются в принципе. | restart replication, force-reconnect орфана, фикс URI топологии, takeover на догнавшего кандидата. |
| **caution** | Меняется control-plane / конфиг (reload / рестарт), но tuple-данные не теряются. | topology fix, restart failover, force apply config. |
| **dangerous** | При текущем состоянии возможна потеря подтверждённых данных. | rebootstrap, force-promote с откатом, quarantine не-хвостового xlog, takeover отставшего кандидата, понижение кворума до 1. |

Класс зависит **от состояния, а не от типа действия**: один и тот же leader takeover безопасен, если кандидат доминирует по vclock над владельцем очереди, и опасен, если отстаёт (тогда теряется неотреплицированный хвост).

## Как действие выглядит в UI

Перед применением любое действие показывает **сводку оценки** (assessment), которую бэкенд считает по живому состоянию (read-only preflight):

- **Бейдж риска** (зелёный `safe` / янтарный `caution` / красный `dangerous`) и флаг `dataLoss`.
- **Effects** — что именно произойдёт, по шагам.
- **Preconditions** — чек-лист предпосылок (галочки Ok/Cancel).
- **Warnings**, **Manual recovery** (как сохранить данные вручную) и **Failure commands** (готовые команды на случай неуспеха) — для опасных.

Дальше:

- **safe / caution** → одна кнопка **Apply** (без ввода токена). Если снапшот рекомендует безопасное действие, на карточке появляется **«Применить рекомендованное»**.
- **dangerous** → нужно отметить **acknowledge** и впечатать **токен** (например `TAKEOVER tt-2`, `QUORUM tt-1`, `WAL <file>`).

Защита не зависит от UI: сервер **повторно** считает оценку перед мутацией и **отказывает**, если опасное действие пришло без подтверждения, с устаревшим состоянием (`STALE_FINGERPRINT` — мир изменился, перечитай сводку), без подтверждения (`CONFIRMATION_REQUIRED`) или с невыполненными предусловиями (`PRECONDITION_FAILED`). Повторная отправка того же действия (двойной клик / ретрай) не выполняется дважды (idempotency-ключ).

> Те же действия доступны и из **баннера Suggestions** (предложения восстановления вверху страниц): `restart replication` (safe), `force apply` / reload config (caution), `restart failover agent` (caution) и `re-bootstrap` (dangerous). Они идут через **ту же** модель `recoveryPreflight` → панель оценки → enforced `recoveryAction` — никакого отдельного пути в обход риск-гейта.
>
> `restart failover agent` всплывает, когда инстанс настроен на supervised-агента (`webui.failover.agent: true`), но его loop-фибра не запущена или умерла (поллер собирает per-peer статус агента). Действие перезапускает фибры агента + watcher из конфига инстанса; координатор переизбирается на следующем тике. Данные не затрагиваются.

## Универсальный порядок для ЛЮБОГО опасного действия

Прежде чем выполнять `dangerous`-действие (rebootstrap / force-promote / quorum-escape / quarantine), всегда:

1. **Поставь failover на паузу** — `pauseFailover(ttl_sec: 1800)` (или `/failover` → Pause). Это не даёт агенту переизбрать/перепромоутить узел, который ты стираешь, и приостанавливает watchdog и self-demote по потере DCS.
2. **Сними бэкап до стирания** — `box.snapshot()` на узле, плюс копию data-dir, если расходящийся хвост может понадобиться:
   ```bash
   docker cp webui-tt-X:/opt/webui/var/lib /backup/recovery-tt-X-$(date +%s)
   ```
3. **Зафиксируй состояние** — выпиши `box.info.vclock`, `box.info.synchro` (owner/term/len) и `box.info.election.term` каждого затронутого пира. Это нужно и чтобы выбрать «победителя», и для разбора после инцидента.
4. **Действуй**, выбрав самый догнавший по vclock узел победителем.
5. **Сними паузу** — `resumeFailover` — после проверки, что кластер сошёлся (`box.info.replication` все `follow`/`sync`).

> Принцип: **сначала сохрани данные, потом стирай**. Re-bootstrap и quarantine необратимы.

> **Re-bootstrap сохраняет идентичность.** Перед стиранием действие закрепляет `database.instance_uuid` инстанса в cluster-config (прямой записью в etcd — у переезжаемой ноды репликация часто сломана) и **не** удаляет его строку из `_cluster`. Так стёртая нода при рестарте переиспользует тот же uuid и чисто переезжает под своим именем. Без этого в именованном кластере Tarantool 3.x rejoin с новым uuid осиротил бы имя, и нода зациклилась бы на старте с `Instance name … is not set in snapshot` (#3740). Если закрепить uuid не удалось — re-bootstrap прерывается, не стирая ноду.

## Конкретные процедуры

| Действие | Runbook |
|---|---|
| Сделать узел владельцем synchro-очереди (takeover / force-promote) | [leader-takeover.md](leader-takeover.md) |
| Разрешить split-brain (два владельца очереди) | [split-brain-recovery.md](split-brain-recovery.md) |
| Починить URI репликации в топологии | [topology-fix.md](topology-fix.md) |
| Восстановить повреждённый xlog | [wal-repair.md](wal-repair.md) |
| Разбор failover/etcd issue'ов | [failover-issues.md](failover-issues.md) |

## См. также

- [`../failover.md`](../failover.md) — модель failover: инварианты, lease/term/vclockkeeper.
- [`promote.md`](promote.md) — плановая смена лидера (без потери данных).
- [`pause-for-maintenance.md`](pause-for-maintenance.md) — пауза агента на maintenance.
