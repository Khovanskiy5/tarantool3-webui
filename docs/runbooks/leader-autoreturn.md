# Runbook: leader autoreturn

Настроить автоматический возврат лидерства на preferred peer.

## Когда применять

* DC primary: хочешь чтобы primary всегда был в DC-A (если он жив), а DC-B - только аварийный.
* Стабильность по гео-латенси: один из peer'ов ближе к клиентам.
* Equal preference but predictable: явно зафиксировать порядок чтобы не гадать кто будет лидером.

## Шаги

1. **Открыть /config-editor.**
2. В YAML добавить `failover_priority` ordered list на replicaset:
   ```yaml
   groups:
     default:
       replicasets:
         rs-1:
           failover_priority: [tt-1, tt-2, tt-3]
           instances:
             tt-1: {...}
             tt-2: {...}
             tt-3: {...}
   ```
3. **Preview → Apply.** Backend коммитит, fan-out reload пушит изменение на каждый peer.
4. На следующем `appointment_cycle` агент видит priority list и применяет bonus в score:
   * `priority[0]` → +(n)*100 к score
   * `priority[1]` → +(n-1)*100
   * `priority[n-1]` → +1*100
5. Если текущий лидер ≠ priority[0] И priority[0] healthy И прошло ≥ `autoreturn_delay` (default 60s) — агент пишет новый appointment, watcher на priority[0] делает `box.ctl.promote()`.

## Что делает backend

* `pick_leader` в `agent.lua` берёт priority list из cluster YAML на каждом тике.
* Score: `base_score(probe) + priority_index_bonus`. Среди всех eligible (reachable, lag < ceiling) выбирается max.
* Auto-return throttle: priority bonus применяется только когда current leader.ts < (now - autoreturn_delay). Иначе bonus игнорится, score решает по lag/RW. Так нет ping-pong'a между peer'ами после флапа.

## Knobs

В `roles_cfg.webui.failover`:
* `autoreturn_delay: 60` (sec) — минимум стабильности перед autoreturn.
* `min_promotion_interval: 10` (sec) — глобальный throttle между любыми promotions.

## Если что-то пошло не так

* **Priority list игнорится.** Проверь что failover mode = `off + agent` или `supervised`. Election/manual режимы не используют наш agent — там priority не применяется.
* **Ping-pong: лидер каждые N секунд переезжает туда-сюда.** Скорее всего `autoreturn_delay` слишком короткий или `min_promotion_interval` маленький. Увеличь оба.
* **`priority[0]` recovered but autoreturn не происходит.** Проверь `agent_status.last_error` — может быть synchro lag выше ceiling. Альтернатива: trigger руками через [promote.md](promote.md) `promoteInstance(priority[0])` — это manual_override который перебивает score-based selection.

## Как откатить

Убери `failover_priority` из YAML через /config-editor → preview → apply. Agent вернётся к alphabetical default ordering.
