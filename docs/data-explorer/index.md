# Data Explorer — developer reference

Документы для разработчика, который трогает подсистему **data-explorer** (обзор спейсов/таплов и их мутации, `backend/webui/data_explorer/` + `backend/webui/graphql/resolvers/data_mutations/`). Не операторские runbook'и — операционные инструкции по failover/recovery лежат в [`../runbooks/`](../runbooks/index.md).

## Каталог

| Документ | О чём |
|---|---|
| [architecture.md](architecture.md) | Структура модулей `data_mutations/`, dependency rules, deny-list, forward-to-leader, контракт фасада. Читать прежде чем добавлять resolver. |
| [indexes.md](indexes.md) | Панель индексов: создание/удаление и utility-действия (min/max/random/count/stat/bsize). |
| [sequences.md](sequences.md) | Последовательности: чтение и изменение значения. |
| [collations.md](collations.md) | Коллации: список и применение в индексах. |
| [stats.md](stats.md) | Статистика спейсов (размер, число таплов, bsize). |
| [binary-fields.md](binary-fields.md) | Бинарные поля: редактор hex/base64/utf-8, varbinary, raw-msgpack-вид тапла. |
| [truncate.md](truncate.md) | Truncate спейса: семантика и ограничения. |

## См. также

- [`../architecture.md`](../architecture.md) — общая архитектура роли webui.
- [`../runbooks/index.md`](../runbooks/index.md) — операторские runbook'и (failover / recovery / config).
