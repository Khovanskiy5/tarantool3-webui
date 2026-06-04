# Справочник конфигурации кластера (`cluster.schema.json`)

> Полный разбор схемы конфигурации Tarantool 3.7, по которой валидируется
> `config/all` в etcd и которую использует Monaco-редактор в UI. Покрыты **все**
> параметры схемы. Источник истины схемы — `require('config'):jsonschema()` из
> живого бинарника Tarantool; семантика сверена с исходниками
> `tarantool-3.7.0/src/box/lua/config/{instance_config,cluster_config}.lua` и
> официальной документацией (`tarantool-docs/`).

## Как читать этот документ

- Формат строки параметра: **`имя`** — `тип`, `default` [, `enum`] [, **EE**] — назначение.
- **EE** = опция работает только в Tarantool Enterprise Edition. Сборка проекта —
  CE (open-source), поэтому такие опции в схеме присутствуют (схема — общая), но
  на CE-бинарнике не действуют. Исключение: централизованный источник конфигурации
  через etcd проект реализует **самостоятельно** на CE (см. `backend/webui/config_source/`),
  хотя в стоковом Tarantool `config.etcd`/`config.storage` — EE.
- `default=null` означает «не задано» (`box.NULL`); фактическое значение часто
  вычисляется динамически или наследуется (см. описание конкретной опции).
- Шаблон `{{ instance_name }}` в дефолтах подставляется именем инстанса на этапе
  применения конфигурации.

## Модель областей видимости (scope) и слияния

Конфигурация кластера — это **instance_config**, применённый на четырёх уровнях
иерархии, плюс несколько структурных ключей верхнего уровня. Порядок слияния
(каждый следующий уровень переопределяет предыдущий) задан в
`cluster_config.lua:instantiate()`:

```
global  →  groups.<g>  →  groups.<g>.replicasets.<rs>  →  groups.<g>.replicasets.<rs>.instances.<i>
```

То есть почти любую опцию (`iproto`, `database`, `replication`, `log`, `wal`,
`memtx`, …) можно задать на верхнем уровне (для всего кластера) и переопределить
ниже — вплоть до конкретного инстанса. Из-за этого в «сыром» JSON-schema блок
`groups` содержит полную копию instance_config на каждом уровне (~944 из ~1260
листьев — это повторы). Ниже каждая секция instance_config описана **один раз**.

**Структурно-кластерные ключи** (существуют только на верхнем уровне, не являются
частью instance_config): `groups`, `conditional`, `include`. Внутри replicaset
дополнительно доступны `leader` и `bootstrap_leader` (не instance_config-поля).

---

## Структура кластера (cluster-level)

### `groups` — топология кластера
`groups` :: `object` (map: имя группы → группа). Полное дерево топологии.
Имя группы/replicaset/инстанса: ≤63 символа, начинается с буквы, `[a-z0-9-_]`.

Дерево:
- **`groups.<group>`** — группа replicaset-ов. Содержит поля instance_config
  (scope `group`) + `replicasets`.
  - **`groups.<group>.replicasets.<rs>`** — replicaset. Содержит поля instance_config
    (scope `replicaset`) + структурные `leader`, `bootstrap_leader` + `instances`.
    - **`leader`** — `string`. Имя инстанса-лидера replicaset. Действует при
      `replication.failover: manual` (ручное управление лидерством).
    - **`bootstrap_leader`** — `string`. Имя инстанса — лидера первичного
      бутстрапа replicaset. Действует при `replication.bootstrap_strategy: config`.
    - **`groups.<group>.replicasets.<rs>.instances.<i>`** — конкретный инстанс.
      Содержит поля instance_config (scope `instance`) — самый приоритетный уровень.

### `conditional` — условные секции
`conditional` :: `array`. Части конфигурации, применяемые только при выполнении
условия. Каждый элемент — это вложенная конфигурация кластера плюс спец-поле
**`if`** с предикатом. В предикате доступна переменная `tarantool_version`,
литералы версий (`3.2.1`), операторы сравнения (`>`,`<`,`>=`,`<=`,`==`,`!=`),
логические (`||`,`&&`) и скобки. Внутри `conditional` нельзя вкладывать
`conditional`. Используется для опций, существующих только в определённых версиях
Tarantool. (`cluster_config.lua:apply_conditional`.)

### `include` — включение файлов
`include` :: `array of string`. Список путей к файлам конфигурации, подключаемым
в порядке перечисления. Путь абсолютный, относительный (относительно файла, где
указан `include`) или wildcard-шаблон.

### `labels` — пользовательские метки
`labels` :: `object` (map: строка → строка). Произвольные строковые атрибуты
инстанса (ключи и значения — строки). Используются для отбора/группировки.

### `isolated` — изоляция инстанса
`isolated` :: `boolean`, default=`false`. Временно изолирует инстанс для
ремонтных работ. Эффекты: перестаёт слушать новые IProto-соединения; рвёт
текущие; переходит в read-only; отключается от всех upstream-ов репликации;
остальные участники replicaset исключают его из своих upstream-ов. (То же поле
доступно и как instance_config-опция на любом уровне.)

### `roles` — роли приложения
`roles` :: `array of string`. Список ролей инстанса (имена соответствуют именам
модулей в `require`). В этом проекте здесь подключается роль `webui`.

### `roles_cfg` — конфигурация ролей
`roles_cfg` :: `object` (map: имя роли → конфиг роли). Конфигурация для ролей из
`roles`. В проекте `roles_cfg.webui.*` несёт все настройки WebUI/failover-агента.

---

## `config` — централизованная конфигурация

Подключение к внешнему хранилищу конфигурации и поведение перезагрузки. В стоковом
Tarantool источники `etcd`/`storage` — **EE**; данный проект реализует etcd-источник
на CE отдельно (`config_source/`). При `replication.failover: supervised` etcd также
хранит состояние координаторов failover.

- **`config.reload`** — `string`, default=`auto`, enum=`auto|manual`. Как
  перезагружается конфигурация: `auto` — автоматически при изменении; `manual` —
  только вручную через `config:reload()` в коде.
- **`config.context`** — `object` (map: имя → определение). Пользовательские
  переменные конфигурации, загружаемые из файла или переменной окружения.
  - **`config.context.<name>.from`** — `string`, enum=`env|file`. Тип источника.
  - **`config.context.<name>.file`** — `string`. Путь к файлу (при `from: file`).
  - **`config.context.<name>.env`** — `string`. Имя переменной окружения (при `from: env`).
  - **`config.context.<name>.rstrip`** — `boolean`. Срезать ли пробелы/переводы строк с конца данных.
- **`config.etcd`** — `object`, **EE** (в проекте — CE-реализация). Подключение к etcd.
  - **`config.etcd.endpoints`** — `array of string`. Список endpoint-ов etcd (например, `http://localhost:2379`).
  - **`config.etcd.prefix`** — `string`. Префикс ключей; Tarantool ищет по пути `<prefix>/config/*`. Должен начинаться со слеша `/`.
  - **`config.etcd.username`** — `string`. Имя пользователя для аутентификации.
  - **`config.etcd.password`** — `string`. Пароль для аутентификации.
  - **`config.etcd.watchers.reconnect_timeout`** — `number`. Таймаут (с) между попытками переподключения watcher-а к etcd.
  - **`config.etcd.watchers.reconnect_max_attempts`** — `integer`. Максимум попыток переподключения watcher-а.
  - **`config.etcd.ssl.verify_peer`** — `boolean`. Проверять SSL-сертификат пира.
  - **`config.etcd.ssl.verify_host`** — `boolean`. Проверять имя (CN) сертификата против хоста.
  - **`config.etcd.ssl.ca_file`** — `string`. Путь к файлу доверенных CA.
  - **`config.etcd.ssl.ca_path`** — `string`. Путь к каталогу с сертификатами для проверки пира.
  - **`config.etcd.ssl.ssl_cert`** — `string`. Путь к файлу SSL-сертификата.
  - **`config.etcd.ssl.ssl_key`** — `string`. Путь к приватному SSL-ключу.
  - **`config.etcd.http.request.timeout`** — `number`. Таймаут обработки HTTP-запроса к etcd (от отправки до ответа).
  - **`config.etcd.http.request.unix_socket`** — `string`. Unix-сокет для подключения к etcd.
  - **`config.etcd.http.request.interface`** — `string`. Исходящий сетевой интерфейс (имя/IP/хостнейм) для etcd-источника.
  - **`config.etcd.http.request.verbose`** — `boolean`. Печатать ли отладочную информацию по HTTP-запросам etcd-источника (в stderr, минуя настройки лога).
- **`config.storage`** — `object`, **EE**. Подключение к централизованному
  хранилищу конфигурации на базе самого Tarantool.
  - **`config.storage.prefix`** — `string`. Префикс ключей; поиск по `<prefix>/config/*`. Должен начинаться со `/`.
  - **`config.storage.timeout`** — `number`, default=`3`. Интервал (с) проверки состояния хранилища.
  - **`config.storage.reconnect_after`** — `number`, default=`3`. Задержка (с) перед переподключением к хранилищу.
  - **`config.storage.endpoints`** — `array`. Endpoint-ы хранилища. Каждый элемент:
    - **`.uri`** — `string`. URI инстанса хранилища.
    - **`.login`** — `string`. Имя пользователя.
    - **`.password`** — `string`. Пароль.
    - **`.params`** — `object`. SSL-параметры зашифрованного соединения (см. ниже общий блок `params.*`, **EE**).

---

## `credentials` — пользователи и роли

`credentials` :: `object`. Декларативное создание пользователей и ролей и выдача
им привилегий. Применяется при старте/reload.

### `credentials.roles.<role>` — роль
- **`privileges`** — `array` привилегий, выдаваемых роли (см. структуру привилегии ниже).
- **`roles`** — `array of string`. Имена других ролей, наследуемых этой ролью.

### `credentials.users.<user>` — пользователь
- **`password`** — `string`. Пароль пользователя.
- **`roles`** — `array of string`. Роли, выданные пользователю.
- **`privileges`** — `array` привилегий, выданных напрямую пользователю.

### Структура элемента `privileges[]`
Одинакова для ролей и пользователей:
- **`permissions`** — `array`, enum-элементы=`read|write|execute|create|alter|drop|usage|session`. Набор прав на перечисленные объекты.
- **`spaces`** — `array of string`. Имена спейсов, на которые распространяются `permissions`.
- **`functions`** — `array of string`. Имена зарегистрированных функций.
- **`sequences`** — `array of string`. Имена последовательностей.
- **`lua_eval`** — `boolean`. Право выполнять произвольный Lua-код.
- **`lua_call`** — `array of string`. Имена Lua-функций, которые можно вызывать; спец-значение `all` — любые глобальные не встроенные Lua-функции.
- **`sql`** — `array`, enum=`all`. Право выполнять произвольный SQL (пока только `all`).
- **`universe`** — `boolean`. Глобальные права на все типы объектов БД (read/write/execute/session/usage/create/drop/alter).

---

## `iproto` — бинарный протокол и сетевой слой

`iproto` :: `object`. Параметры взаимодействия клиентов и инстансов между собой.

- **`iproto.listen`** — `array`, default=`null`. URI для приёма входящих соединений; можно включить SSL для конкретного URI через `params`.
  - **`iproto.listen[].uri`** — `string`. URI вида `unix/:<path>` или `host:port`. Без логина/пароля и без query-параметров SSL (их задавать в `params`).
  - **`iproto.listen[].params`** — `object`. SSL-параметры (см. общий блок `params.*`, **EE**).
- **`iproto.advertise`** — `object`. URI, по которым участники кластера и клиенты узнают, куда подключаться.
  - **`iproto.advertise.peer`** — `object`. Как анонсировать текущий инстанс другим участникам кластера.
    - **`.uri`** — `string`. URI для анонса (по умолчанию берётся из `iproto.listen`).
    - **`.login`** — `string`. Имя пользователя для подключения к этому инстансу (по умолчанию — `guest`).
    - **`.password`** — `string`. Пароль (если задан логин без пароля — берётся из credentials пользователя).
    - **`.params`** — `object`. SSL-параметры (**EE**).
  - **`iproto.advertise.sharding`** — `object`. Как анонсировать инстанс роутеру и rebalancer-у (поля `uri`/`login`/`password`/`params` — аналогично `peer`).
  - **`iproto.advertise.client`** — `string`, default=`null`. URI для анонса инстанса внешним клиентам (`host:port` или `unix/:`); логин/пароль не допускаются.
- **`iproto.threads`** — `integer`, default=`1`. Число сетевых тредов. Увеличить (2+), если сетевой тред — узкое место (100% загрузка при незагруженном TX-треде).
- **`iproto.net_msg_max`** — `integer`, default=`768`. Лимит одновременно обрабатываемых сообщений (фиберов). По достижении — приём новых пакетов приостанавливается. Больше на мощных системах, меньше на слабых.
- **`iproto.readahead`** — `integer`, default=`16320`. Размер буфера упреждающего чтения на соединение. Увеличивать при крупных тюплах/батчинге.
- **`iproto.ssl`** — `object`, **EE**. SSL-параметры для IProto-сокетов и подключений к инстансам, требующим CA (см. общий блок `ssl.*`).

### Общий блок SSL-параметров (`params.*` / `ssl.*`) — **EE**
Встречается в `iproto.listen[].params`, `iproto.advertise.*.params`, `iproto.ssl`,
`config.*.params`, `replication.ssl`, `failover.iproto.ssl`, `failover.http.listen[].params`.
TLS-шифрование трафика доступно только в EE.
- **`transport`** — `string`, enum=`plain|ssl`. `plain` (default) — без шифрования; `ssl` — TLS 1.2 (**EE**).
- **`ssl_cert_file`** / **`ssl_cert`** — `string`. Путь к файлу SSL-сертификата (обязателен для сервера).
- **`ssl_key_file`** / **`ssl_key`** — `string`. Путь к приватному SSL-ключу (обязателен для сервера).
- **`ssl_ca_file`** / **`ca_file`** — `string`. Путь к файлу доверенных CA; включает взаимную проверку.
- **`ssl_ciphers`** — `string`. Список cipher-suite через `:` (не валидируется).
- **`ssl_password`** — `string`. Пароль к зашифрованному приватному ключу.
- **`ssl_password_file`** — `string`. Файл с паролями (по одному на строку) к зашифрованным ключам.

---

## `replication` — репликация и синхронность

`replication` :: `object`. Параметры репликации, failover, кворумов и выборов.

- **`replication.failover`** — `string`, default=`off`, enum=`off|manual|election|supervised`. Режим failover:
  - `off` — лидерство задаётся `database.mode` (можно master-master);
  - `manual` — лидер задаётся `<replicaset>.leader` (master-master запрещён);
  - `election` — автоматические выборы лидера (Raft-подобные);
  - `supervised` — внешний координатор назначает лидера (в проекте — кастомный агент поверх etcd-lease).
- **`replication.peers`** — `array of string`, default=`null`. URI инстансов replicaset для подключения как реплика (например, `replicator:pass@127.0.0.1:3301`). Альтернатива — `iproto.advertise.peer`.
- **`replication.election_mode`** — `string`, default=`null`, enum=`off|voter|manual|candidate`. Роль узла в выборах: `off` — не участвует; `voter` — голосует, но не лидер; `candidate` — может стать лидером; `manual` — явное управление через `box.ctl.promote()`.
- **`replication.election_timeout`** — `number`, default=`5`. Таймаут (с) между раундами выборов при split-vote. Часто можно снизить до 0.3–0.4 с. Рандомизируется 100–110%.
- **`replication.election_fencing_mode`** — `string`, default=`soft`, enum=`off|soft|strict`. Фенсинг лидера: при числе живых соединений < `synchro_quorum` лидер слагает полномочия и уходит в RO. `soft` — соединение мёртво после 4×`timeout`; `strict` — после 2×`timeout` (жёстче, исключает split-brain при симметричных разрывах).
- **`replication.synchro_quorum`** — `string|number`, default=`N / 2 + 1`. Сколько реплик должны подтвердить синхронную транзакцию до её коммита. Динамически пересчитывается при изменении числа реплик. Значение меньше канонического грозит split-brain.
- **`replication.synchro_timeout`** — `number`, default=`5`. Сколько секунд ждать кворум синхронной транзакции, прежде чем объявить её неуспешной и откатить (только на мастере). См. также `compat.replication_synchro_timeout`.
- **`replication.synchro_queue_max_size`** — `integer`, default=`16777216` (16 МБ). Лимит байт в очереди синхронных транзакций на мастере (0 — без лимита). При переполнении новые транзакции отвергаются («queue is full»).
- **`replication.timeout`** — `number`, default=`1`. Интервал (с) heartbeat-ов мастера реплике. Нет heartbeat 4×`timeout` → соединение рвётся и реплика переподключается.
- **`replication.reconnect_timeout`** — `number`, default=`null`. Таймаут (с) между попытками переподключения к мастеру; `null` = равен `replication.timeout`.
- **`replication.connect_timeout`** — `number`, default=`30`. Таймаут (с) ожидания при подключении реплики к мастеру (отличается от `timeout`).
- **`replication.sync_lag`** — `number`, default=`10`. Максимальное отставание (с) реплики, при котором она ещё считается `synced`. Большое значение — оставаться synced несмотря на сетевые задержки.
- **`replication.sync_timeout`** — `number`, default=`null`. Таймаут (с) синхронизации узла с остальными после подключения/обновления конфига. По истечении — узел переходит в `orphan`.
- **`replication.threads`** — `integer`, default=`1`. Число тредов декодирования входящих данных репликации (1–1000).
- **`replication.bootstrap_strategy`** — `string`, default=`auto`, enum=`auto|config|supervised|native|legacy`. Стратегия первичного бутстрапа replicaset: `auto` — кворум подключённых узлов; `config` — лидер из `<replicaset>.bootstrap_leader`; и т.д.
- **`replication.anon`** — `boolean`, default=`false`. Сделать инстанс анонимной репликой (read-only, не видна в `box.info.replication`, годна для бэкапов/CDC).
- **`replication.anon_ttl`** — `number`, default=`3600`. TTL (с) отключённой анонимной реплики, после которого она удаляется из инстанса.
- **`replication.linearizable_quorum`** — `string|number`, default=`N - Q + 1`. Сколько реплик опросить перед линеаризуемой транзакцией (гарантия чтения свежих данных).
- **`replication.skip_conflict`** — `boolean`, default=`false`. Игнорировать конфликты уникальных ключей (`ER_TUPLE_FOUND`) вместо остановки репликации.
- **`replication.autoexpel`** — `object`. Автоматическое исключение инстансов, удалённых из YAML-конфига.
  - **`.enabled`** — `boolean`, default=`false`. Включить авто-исключение (требует `by` и `prefix`).
  - **`.by`** — `string`, enum=`prefix`. Критерий принадлежности инстанса кластеру (пока только по префиксу имени).
  - **`.prefix`** — `string`. Шаблон имён «своих» инстансов (например, `{{ replicaset_name }}` или `i-`).

---

## `database` — режим БД и транзакции

`database` :: `object`.

- **`database.mode`** — `string`, default=`null`, enum=`ro|rw`. Режим инстанса; действует при `replication.failover: off`. По умолчанию для одиночного инстанса — `rw`, для нескольких — `ro`.
- **`database.instance_uuid`** — `string`, default=`null`. UUID инстанса (по умолчанию генерируется). Должен быть уникален, постоянен (хранится в снапшоте), RFC 4122, не nil.
- **`database.replicaset_uuid`** — `string`, default=`null`. UUID replicaset (по умолчанию генерируется).
- **`database.use_mvcc_engine`** — `boolean`, default=`false`. Включить MVCC-менеджер транзакций. В проекте включён (`05-box.yaml`) — обязателен для корректной изоляции синхронных транзакций.
- **`database.txn_isolation`** — `string`, default=`best-effort`, enum=`read-committed|read-confirmed|best-effort`. Уровень изоляции транзакций.
- **`database.txn_timeout`** — `number`, default=`3153600000`. Таймаут (с), после которого транзакция откатывается.
- **`database.txn_synchro_timeout`** — `number`, default=`5`. Таймаут (с), после которого фибер отцепляется от синхронной транзакции, собирающей кворум (транзакция не откатывается, ждёт кворум в фоне).
- **`database.hot_standby`** — `boolean`, default=`false`. Режим горячего резерва (failover без репликации). Не действует при `wal.mode: none`, для vinyl-спейсов и при большом `wal.dir_rescan_delay` на macOS/FreeBSD.

---

## `wal` — журнал упреждающей записи (WAL)

`wal` :: `object`.

- **`wal.mode`** — `string`, default=`write`, enum=`none|write|fsync`. Режим синхронизации: `none` — WAL не ведётся (узел не может быть мастером); `write` — ждать запись в WAL без `fsync`; `fsync` — `fsync(2)` после каждой записи.
- **`wal.dir`** — `string`, default=`var/lib/{{ instance_name }}`. Каталог `.xlog`-файлов (относительный путь — от `process.work_dir`). По умолчанию совпадает со `snapshot.dir`.
- **`wal.max_size`** — `integer`, default=`268435456` (256 МБ). Максимальный размер одного `.xlog`; при превышении создаётся новый файл.
- **`wal.dir_rescan_delay`** — `number`, default=`2`. Интервал (с) периодического сканирования каталога WAL (для репликации/hot standby).
- **`wal.queue_max_size`** — `integer`, default=`16777216` (16 МБ). Лимит байт очереди транзакций реплики на запись в WAL (ограничивает темп при догоне мастера).
- **`wal.cleanup_delay`** — `number`. Задержка (с) перед удалением WAL-файлов после рестарта узла — чтобы мастер не удалил WAL, нужные репликам, и они быстрее синхронизировались.
- **`wal.retention_period`** — `number`, default=`0`. Задержка (с) удаления WAL-файла после его закрытия GC (отсчитывается от mtime; при рестарте — заново). Полезно для анонимных реплик/CDC.
- **`wal.ext`** — `object`, default=`null`, **EE**. WAL-расширения (хранение старого/нового тюпла в записи WAL).
  - **`wal.ext.old`** — `boolean`. Хранить старый тюпл для каждой CRUD-операции (для всех спейсов).
  - **`wal.ext.new`** — `boolean`. Хранить новый тюпл для каждой CRUD-операции.
  - **`wal.ext.spaces.<space>.old`** / **`.new`** — `boolean`, default=`false`. Переопределение `old`/`new` для конкретного спейса (приоритетнее общих).

---

## `snapshot` — снапшоты и checkpoint-демон

`snapshot` :: `object`.

- **`snapshot.dir`** — `string`, default=`var/lib/{{ instance_name }}`. Каталог `.snap`-файлов memtx (относительный — от `process.work_dir`).
- **`snapshot.count`** — `integer`, default=`2`. Сколько снапшотов хранить; при превышении GC удаляет старые. `0` — не удалять.
- **`snapshot.snap_io_rate_limit`** — `number`, default=`null`. Лимит МБ/с записи `box.snapshot()` на диск (снижает влияние на INSERT/UPDATE/DELETE).
- **`snapshot.by.interval`** — `number`, default=`3600`. Интервал (с) между запусками checkpoint-демона при наличии изменений. `0` — демон выключен.
- **`snapshot.by.wal_size`** — `integer`, default=`1000000000000000000`. Порог суммарного размера WAL (байт) с момента последнего снапшота; при превышении — новый снапшот и удаление старых WAL.

---

## `memtx` — движок memtx

`memtx` :: `object`.

- **`memtx.memory`** — `integer`, default=`268435456` (256 МБ). Память под хранение тюплов. При достижении лимита INSERT/UPDATE падают с `ER_MEMORY_ISSUE`.
- **`memtx.allocator`** — `string`, default=`small`, enum=`small|system`. Аллокатор памяти тюплов: `small` — slab-аллокатор; `system` — на базе `malloc` (при патологической фрагментации).
- **`memtx.max_tuple_size`** — `integer`, default=`1048576` (1 МБ). Максимальный размер единицы аллокации (увеличить под крупные тюплы).
- **`memtx.min_tuple_size`** — `integer`, default=`16`. Минимальный размер единицы аллокации (уменьшить, если большинство тюплов очень мелкие).
- **`memtx.slab_alloc_factor`** — `number`, default=`1.05`. Множитель размеров чанков памяти под тюплы (меньше — меньше потерь).
- **`memtx.slab_alloc_granularity`** — `integer`, default=`8`. Гранулярность аллокации в small-аллокаторе (степень двойки, ≥4).
- **`memtx.sort_threads`** — `integer`, default=`null`. Число тредов сортировки ключей вторичных индексов при загрузке БД (1–256; по умолчанию — все ядра).
- **`memtx.use_sort_data`** — `boolean`, default=`false`. Использовать O(n)-сортировку вторичных ключей по доп. данным снапшота и писать эти данные при `box.snapshot()`.

---

## `vinyl` — движок vinyl (LSM)

`vinyl` :: `object`.

- **`vinyl.memory`** — `integer`, default=`134217728` (128 МБ). Максимум in-memory байт для vinyl.
- **`vinyl.cache`** — `integer`, default=`134217728` (128 МБ). Размер кэша vinyl (меняется динамически).
- **`vinyl.max_tuple_size`** — `integer`, default=`1048576` (1 МБ). Максимальный размер единицы аллокации.
- **`vinyl.page_size`** — `integer`, default=`8192`. Размер страницы (единица чтения/записи); дефолт для `create_index()`.
- **`vinyl.range_size`** — `integer`, default=`null`. Максимальный размер range индекса (влияет на решение о split). `null`/`0` — Tarantool подбирает сам.
- **`vinyl.run_count_per_level`** — `integer`, default=`2`. Максимум run-ов на уровне LSM до создания нового уровня; дефолт для `create_index()`.
- **`vinyl.run_size_ratio`** — `number`, default=`3.5`. Отношение размеров уровней LSM; дефолт для `create_index()`.
- **`vinyl.bloom_fpr`** — `number`, default=`0.05`. Целевая вероятность ложного срабатывания bloom-фильтра; дефолт для `create_index()`.
- **`vinyl.read_threads`** — `integer`, default=`1`. Максимум read-тредов (I/O, компрессия).
- **`vinyl.write_threads`** — `integer`, default=`4`. Максимум write-тредов.
- **`vinyl.timeout`** — `number`, default=`60`. Таймаут (с) запросов, когда планировщик компакции не успевает при нехватке памяти.
- **`vinyl.defer_deletes`** — `boolean`, default=`false`. Включить оптимизацию отложенного DELETE (выключена с 2.10 из-за возможной деградации чтения вторичных индексов).
- **`vinyl.dir`** — `string`, default=`var/lib/{{ instance_name }}`. Каталог файлов vinyl (относительный — от `process.work_dir`).

---

## `quiver` — движок quiver — **EE**

`quiver` :: `object`, **EE**. Параметры движка quiver.

- **`quiver.memory`** — `integer`, default=`134217728` (128 МБ). Максимальный размер in-memory буферов накопления записей; влияет на момент сброса на диск.
- **`quiver.run_size`** — `integer`, default=`16777216` (16 МБ). Максимальный размер run-файла; по нему дробится выходной поток при сбросе буферов.
- **`quiver.dir`** — `string`, default=`var/lib/{{ instance_name }}`. Каталог файлов quiver (относительный — от `process.work_dir`).

---

## `sql` — SQL

`sql` :: `object`.

- **`sql.cache_size`** — `integer`, default=`5242880` (5 МБ). Максимальный размер кэша всех подготовленных SQL-выражений (`box.info.sql().cache.size`).

---

## `log` — логирование

`log` :: `object`. Параметры логирования (см. также `docs/operations.md` → «Логи»).

- **`log.to`** — `string`, default=`stderr`, enum=`stderr|file|pipe|syslog`. Куда отправлять логи: stderr / файл / stdin внешней программы / системный логгер. Единственный приёмник за раз.
- **`log.level`** — `string|number`, default=`5`, enum=`0/fatal … 7/debug`. Уровень детализации: 0 fatal, 1 syserror, 2 error, 3 crit, 4 warn, 5 info, 6 verbose, 7 debug. Логируются события с уровнем ≥ заданного.
- **`log.format`** — `string`, default=`plain`, enum=`plain|json`. Формат записи: `plain` — текст; `json` — объект с доп. полями (`time`/`level`/`message`/`pid`/…). В проекте — `json`.
- **`log.file`** — `string`, default=`var/log/{{ instance_name }}/tarantool.log`. Файл логов (действует при `log.to: file`). При SIGHUP файл переоткрывается (logrotate).
- **`log.pipe`** — `string`, default=`null`. Команда, в stdin которой пишутся логи (при `log.to: pipe`). В проекте — `tee` (дублирование в файл и stdout контейнера).
- **`log.modules`** — `object`, default=`null`. Поуровневая настройка логирования для отдельных модулей (файлов с дефолтным логгером, кастомных логгеров `log.new()`, ядра `tarantool` для C-сообщений).
- **`log.nonblock`** — `boolean`, default=`false`. Не блокироваться при невозможности записи (писать сообщение о потере); быстрее, но возможны потери строк.
- **`log.syslog.identity`** — `string`, default=`tarantool`. Имя приложения в syslog (при `log.to: syslog`).
- **`log.syslog.server`** — `string`, default=`null`. Адрес syslog-сервера (`127.0.0.1:514` или `unix:/dev/log`).
- **`log.syslog.facility`** — `string`, default=`local7`. Facility syslog.

---

## `audit_log` — журнал аудита — **EE**

`audit_log` :: `object`, **EE**. Конфигурация аудит-логирования Tarantool. (В проекте
свой реплицируемый аудит-журнал в роли `webui`, см. `backend/webui/audit/` — это
отдельный от данной EE-функции механизм.)

- **`audit_log.to`** — `string`, default=`devnull`, enum=`devnull|file|pipe|syslog`. Включение и место назначения аудита.
- **`audit_log.file`** — `string`, default=`var/log/{{ instance_name }}/audit.log`. Файл аудита (переоткрывается на SIGHUP).
- **`audit_log.pipe`** — `string`, default=`null`. Команда, в stdin которой пишется аудит (при `to: pipe`).
- **`audit_log.format`** — `string`, default=`json`, enum=`plain|json|csv`. Формат записей аудита.
- **`audit_log.filter`** — `array`, enum-элементы — события/группы (`auth_ok`, `auth_fail`, `user_create`, `access_denied`, `ddl`, `dml`, `data_operations`, `all`, …). Подмножество событий для логирования.
- **`audit_log.spaces`** — массив имён спейсов или map. Для каких спейсов логировать DML-события (`space_insert/replace/delete/select`). `null` — для всех.
- **`audit_log.extract_key`** — `boolean`, default=`false`. В DML-событиях писать только первичный ключ вместо полного тюпла (полезно для крупных тюплов).
- **`audit_log.nonblock`** — `boolean`, default=`false`. Не блокироваться при невозможности записи (возможны потери).
- **`audit_log.syslog.identity`** — `string`, default=`tarantool`. Имя приложения в syslog.
- **`audit_log.syslog.server`** — `string`, default=`null`. Адрес syslog-сервера (`unix:`-путь или `ip:port`).
- **`audit_log.syslog.facility`** — `string`, default=`local7`. Facility syslog (при `to: syslog`).

---

## `security` — настройки безопасности

`security` :: `object`. Часть опций — политика паролей и задержки аутентификации —
доступны только в **EE**.

- **`security.auth_type`** — `string`, default=`chap-sha1`, enum=`chap-sha1|pap-sha256`. Протокол аутентификации. `chap-sha1` — хеши без соли (уязвимы к rainbow-таблицам при утечке БД); `pap-sha256` (**EE**) — соль на пользователя.
- **`security.auth_delay`** — `number`, default=`0`, **EE**. Задержка (с) до следующей попытки после неудачной аутентификации.
- **`security.auth_retries`** — `integer`, default=`0`, **EE**. Сколько попыток разрешено до включения `auth_delay`. Счётчик сбрасывается через `auth_delay` секунд или после успешного входа.
- **`security.disable_guest`** — `boolean`, default=`false`, **EE**. Запретить удалённый доступ неаутентифицированным/guest-пользователям (влияет и на соединения между участниками кластера, и на `net.box`).
- **`security.secure_erasing`** — `boolean`, default=`false`, **EE**. Перезаписывать файлы данных (`.xlog`, `.snap`, vinyl) несколько раз перед удалением (невосстановимое удаление).
- **`security.password_min_length`** — `integer`, default=`0`, **EE**. Минимальная длина пароля.
- **`security.password_enforce_uppercase`** — `boolean`, default=`false`, **EE**. Требовать заглавные буквы (A–Z).
- **`security.password_enforce_lowercase`** — `boolean`, default=`false`, **EE**. Требовать строчные буквы (a–z).
- **`security.password_enforce_digits`** — `boolean`, default=`false`, **EE**. Требовать цифры (0–9).
- **`security.password_enforce_specialchars`** — `boolean`, default=`false`, **EE**. Требовать спецсимвол (`&|?!@$`…).
- **`security.password_history_length`** — `integer`, default=`0`, **EE**. Сколько уникальных новых паролей до повторного использования старого.
- **`security.password_lifetime_days`** — `integer`, default=`0`, **EE**. Срок жизни пароля (дней); затем — «Password expired», восстановление через `box.schema.user.passwd`.

---

## `failover` — координатор supervised-failover

`failover` :: `object`. Параметры координатора при `replication.failover: supervised`.
Часть подсекций (`iproto`, `metrics`, `http`) — только в **EE**. В этом проекте
supervised-паритет реализован собственным агентом (см. `docs/failover.md`),
который опирается на тайминги lease/renew из этой секции.

- **`failover.lease_interval`** — `number`, default=`30`. Сколько секунд инстанс остаётся лидером без renew-запросов от координатора; по истечении сам уходит в RO (работает даже без связи с координатором).
- **`failover.renew_interval`** — `number`, default=`10`. Как часто (с) координатор шлёт продление RW-дедлайна (renew).
- **`failover.probe_interval`** — `number`, default=`10`. Как часто (с) мониторинг координатора опрашивает статус инстанса.
- **`failover.connect_timeout`** — `number`, default=`1`. Таймаут (с) соединений мониторинга/автофейловера.
- **`failover.call_timeout`** — `number`, default=`1`. Таймаут (с) вызовов в соединениях мониторинга/автофейловера.
- **`failover.replication_lag_threshold`** — `number`, default=`1`. Порог отставания репликации (с); при превышении координатор игнорирует инстанс при выборе лидера, если у replicaset `synchro_mode: true`.
- **`failover.stateboard`** — `object`. Хранение состояния координаторов в etcd.
  - **`.enabled`** — `boolean`, default=`true`. Вкл/выкл stateboard координатора.
  - **`.renew_interval`** — `number`, default=`2`. Как часто (с) координатор пишет своё состояние в etcd и читает новые команды.
  - **`.keepalive_interval`** — `number`, default=`10`. Сколько хранится транзитное состояние и как быстро истекает lock. Должен быть меньше `failover.lease_interval`, иначе смена координатора уводит лидера в RO.
- **`failover.log.to`** — `string`, default=`stderr`, enum=`stderr|file`. Куда писать логи координатора.
- **`failover.log.file`** — `string`. Файл логов координатора (при `failover.log.to: file`).
- **`failover.replicasets.<rs>.synchro_mode`** — `boolean`, default=`false`. Режим назначения лидера: асинхронный или для кворумной синхронной репликации.
- **`failover.replicasets.<rs>.learners`** — `array of string`. Инстансы, игнорируемые координатором при выборе мастера. Если learner в RW — координатор останавливает failover до перехода в RO.
- **`failover.replicasets.<rs>.priority`** — `object`. Приоритеты инстансов для supervised-режима (map инстанс → приоритет).
- **`failover.iproto.ssl.*`** — `object`, **EE**. SSL для подключения координатора к инстансам по IProto (общий блок `ssl.*`: `ca_file`, `ssl_cert`, `ssl_key`, `ssl_ciphers`, `ssl_password`, `ssl_password_file`).
- **`failover.metrics.exporters[]`** — `array`, **EE**. Экспортёры метрик координатора.
  - **`.path`** — `string`. URI-путь (`/metrics/prometheus` и т.п.).
  - **`.format`** — `string`, default=`prometheus`, enum=`prometheus|zabbix|telegraf|json`. Формат метрик.
- **`failover.http.listen[]`** — `array`, **EE**. HTTP-листенеры API координатора (метрики/healthcheck), привязка к `localhost:<port>`.
  - **`.uri`** — `string`. URI `<host>:<port>`.
  - **`.params`** — `object`, **EE**. SSL-параметры листенера (общий блок `params.*`) плюс:
    - **`.params.ssl_verify_client`** — `string`, default=`off`, enum=`off|on|optional`. Проверка клиентских сертификатов: `off` — нет; `on` — требовать и проверять; `optional` — проверять при наличии.

---

## `sharding` — шардирование (vshard)

`sharding` :: `object`. Параметры vshard (роутер/хранилище/rebalancer).

- **`sharding.roles`** — `array`, enum-элементы=`router|storage|rebalancer`. Роли replicaset в шардировании. `rebalancer` опционален и допустим лишь в одном replicaset (с ролью `storage`).
- **`sharding.bucket_count`** — `integer`, default=`3000`. Суммарное число бакетов в кластере.
- **`sharding.shard_index`** — `string`, default=`bucket_id`. Имя/ID TREE-индекса над bucket id. Спейсы без него не участвуют в шардировании.
- **`sharding.weight`** — `number`, default=`1`. Относительный объём данных, который может хранить replicaset.
- **`sharding.zone`** — `integer`. Зона роутеров/реплик (read-only запросы к ближайшей реплике).
- **`sharding.lock`** — `boolean`. Заблокирован ли replicaset (не принимает и не отдаёт бакеты).
- **`sharding.discovery_mode`** — `string`, default=`on`, enum=`on|off|once`. Режим фонового discovery-фибера роутера для поиска бакетов.
- **`sharding.rebalancer_mode`** — `string`, default=`auto`, enum=`manual|auto|off`. Как выбирается rebalancer: `auto` — автоматически; `manual` — по роли `rebalancer`; `off` — выключен.
- **`sharding.rebalancer_max_receiving`** — `integer`, default=`100`. Максимум одновременно принимаемых бакетов одним replicaset (ограничивает нагрузку на новый replicaset).
- **`sharding.rebalancer_max_sending`** — `integer`, default=`1`. Степень параллелизма отправки при ребалансировке.
- **`sharding.rebalancer_disbalance_threshold`** — `number`, default=`1`. Порог дисбаланса (%): `|etalon - real| / etalon * 100`.
- **`sharding.sync_timeout`** — `number`, default=`1`. Таймаут ожидания синхронизации старого мастера с репликами перед demote (при смене мастера / `sync()`).
- **`sharding.failover_ping_timeout`** — `number`, default=`5`. Таймаут (с), после которого узел считается недоступным failover-фибером vshard.
- **`sharding.sched_ref_quota`** — `number`, default=`300`. Квота storage-ref для map-reduce роутера: сколько map-reduce-запросов подряд при наличии ожидающих переносов бакетов.
- **`sharding.sched_move_quota`** — `number`, default=`1`. Квота переносов бакетов rebalancer-ом подряд при наличии ожидающих storage-ref.
- **`sharding.connection_outdate_delay`** — `number`. Время устаревания старых объектов при reload.

---

## `metrics` — сбор метрик

`metrics` :: `object`. Сбор и экспорт метрик Tarantool.

- **`metrics.include`** — `array`, enum-элементы=`all|network|operations|system|replicas|info|slab|runtime|memory|spaces|fibers|cpu|vinyl|memtx|luajit|clock|event_loop|cpu_extended|schema`. Группы метрик для включения.
- **`metrics.exclude`** — `array`, те же enum-значения. Группы метрик для выключения.
- **`metrics.labels`** — `object` (map). Глобальные метки, добавляемые к каждому наблюдению.

---

## `feedback` — телеметрия в Tarantool

`feedback` :: `object`. Отправка информации о работающем инстансе на feedback-сервер
Tarantool. (В закрытых контурах обычно отключают — `enabled: false`.)

- **`feedback.enabled`** — `boolean`, default=`true`. Отправлять ли информоб инстансе.
- **`feedback.host`** — `string`, default=`https://feedback.tarantool.io`. Адрес назначения.
- **`feedback.interval`** — `number`, default=`3600`. Интервал (с) отправки информации.
- **`feedback.send_metrics`** — `boolean`, default=`true`. Отправлять ли метрики (после отправки сбрасываются).
- **`feedback.metrics_collect_interval`** — `number`, default=`60`. Интервал (с) сбора метрик.
- **`feedback.metrics_limit`** — `integer`, default=`1048576` (1 МБ). Лимит памяти под метрики до отправки; при превышении ранние метрики отбрасываются.
- **`feedback.crashinfo`** — `boolean`, default=`true`. Отправлять ли информацию о крэше (uname, build, причина, стек).

---

## `flightrec` — «чёрный ящик» (flight recorder) — **EE**

`flightrec` :: `object`, **EE**. Кольцевые буферы логов/запросов/метрик для пост-мортем.

- **`flightrec.enabled`** — `boolean`, default=`false`. Включить flight recorder.
- **`flightrec.logs_size`** — `integer`, default=`10485760` (10 МБ). Размер хранилища логов (0 — выключить).
- **`flightrec.logs_max_msg_size`** — `integer`, default=`4096`. Максимальный размер строки лога (обрезается).
- **`flightrec.logs_log_level`** — `integer`, default=`6`, enum=`0..7`. Уровень детализации логов flight recorder (может отличаться от `log.level`).
- **`flightrec.requests_size`** — `integer`, default=`10485760` (10 МБ). Размер хранилища запросов/ответов (0 — выключить).
- **`flightrec.requests_max_req_size`** — `integer`, default=`16384`. Максимальный размер записи запроса (обрезается).
- **`flightrec.requests_max_res_size`** — `integer`, default=`16384`. Максимальный размер записи ответа (обрезается).
- **`flightrec.metrics_period`** — `number`, default=`180`. За какой период (с) хранятся метрики на момент дампа (глубина истории до крэша).
- **`flightrec.metrics_interval`** — `number`, default=`1`. Частота (с) дампа метрик (не должна превышать `metrics_period`).

---

## `fiber` — фиберы и кооперативная многозадачность

`fiber` :: `object`.

- **`fiber.io_collect_interval`** — `number`, default=`null`. Период сна (с) фибера между итерациями event loop (снижает CPU при многих редко-активных соединениях).
- **`fiber.too_long_threshold`** — `number`, default=`0.5`. Если обработка запроса дольше (с) — предупреждение в лог (действует при `log.level ≥ 4`).
- **`fiber.worker_pool_threads`** — `number`, default=`4`. Максимум тредов для внутренних процессов (`socket.getaddrinfo()`, `coio_call()`).
- **`fiber.tx_user_pool_size`** — `integer`, default=`768`. Размер пула фиберов в TX-треде для пользовательских колбэков (`tnt_tx_push()`).
- **`fiber.slice.warn`** — `number`, default=`0.5`. Период (с) предупреждающего slice (макс. время выполнения фибера без yield).
- **`fiber.slice.err`** — `number`, default=`1`. Период (с) ошибочного slice.
- **`fiber.top.enabled`** — `boolean`, default=`false`. Включить `fiber.top()` (диагностика CPU по фиберам; замедляет переключение фиберов ~на 15%).

---

## `lua` — Lua-runtime

`lua` :: `object`.

- **`lua.memory`** — `integer`, default=`2147483648` (2 ГБ). Лимит памяти Lua (минимум 256 МБ). Можно увеличить динамически; уменьшение — после рестарта.

---

## `process` — процесс ОС

`process` :: `object`. Параметры процесса Tarantool в системе.

- **`process.work_dir`** — `string`, default=`null`. Рабочий каталог (БД, логи, PID, console-сокет); инстанс делает `chdir` после старта. Относительные пути остальных опций трактуются относительно него. По умолчанию — текущий каталог запуска.
- **`process.pid_file`** — `string`, default=`var/run/{{ instance_name }}/tarantool.pid`. Файл PID (относительный — от `work_dir`).
- **`process.username`** — `string`, default=`null`. Системный пользователь, под которого переключиться после старта.
- **`process.background`** — `boolean`, default=`false`. Запуск демоном. Тогда `log.to` должен быть не `stderr` (file/pipe/syslog). Не использовать для приложений под `tt`.
- **`process.title`** — `string`, default=`tarantool - {{ instance_name }}`. Добавка к заголовку процесса (видна в `ps -ef`, `top -c`).
- **`process.coredump`** — `boolean`, default=`false`. Создавать core-дампы (сам выставляет rlimit и `dumpable`).
- **`process.strip_core`** — `boolean`, default=`true`. Не включать в core-дамп память тюплов (под нагрузкой она велика).

---

## `console` — административная консоль

`console` :: `object`. Консоль администратора (клиент — `tt connect`).

- **`console.enabled`** — `boolean`, default=`true`. Слушать ли Unix-сокет консоли. `false` — консоль выключена.
- **`console.socket`** — `string`, default=`var/run/{{ instance_name }}/tarantool.control`. Путь Unix-сокета (только Unix-домен, без префикса `unix:`; относительный — от `process.work_dir`).

---

## `connpool` — пул соединений к инстансам

`connpool` :: `object`. Пул соединений для общения с другими инстансами кластера.

- **`connpool.idle_timeout`** — `number`, default=`60`. Таймаут (с) закрытия неиспользуемых соединений. Не влияет на соединения, открытые через `connpool.connect()`.

---

## `threads` — группы прикладных тредов

`threads` :: `object`.

- **`threads.groups[]`** — `array`. Группы тредов.
  - **`.name`** — `string`. Имя группы (уникальное; имя `tx` зарезервировано за главным тредом).
  - **`.size`** — `integer`. Число тредов в группе.

---

## `stateboard` — отчёт о состоянии инстанса

`stateboard` :: `object`. Инстанс с включённым stateboard публикует своё состояние
в `<prefix>/state/by-name/{{ instance_name }}` (prefix — из `config.*.prefix`):
YAML с полями `hostname`, `pid`, `mode` (`ro`/`rw`), `ro_reason` и др. Open-source
аналог EE-блока `stateboard.*`; в проекте используется как liveness в etcd
(см. `docs/operations.md` → «State reporter»).

- **`stateboard.enabled`** — `boolean`, default=`false`. Вкл/выкл сервис stateboard.
- **`stateboard.renew_interval`** — `number`, default=`2`. Как часто (с) инстанс пишет состояние в stateboard.
- **`stateboard.keepalive_interval`** — `number`, default=`10`. Сколько хранится транзитное состояние.

---

## `app` — прикладной код (application server)

`app` :: `object`. Загрузка пользовательского Lua-приложения.

- **`app.file`** — `string`. Путь к Lua-файлу приложения.
- **`app.module`** — `string`. Lua-модуль приложения.
- **`app.cfg`** — `object`. Конфигурация приложения, загруженного через `app.file`/`app.module`.

---

## `compat` — совместимость поведения между версиями

`compat` :: `object`. Переключатели поведения между мажорными версиями Tarantool.
Каждая опция — `string`, enum=`old|new`. `new` — поведение текущей/следующей версии,
`old` — предыдущей. Меняйте осознанно: влияют на семантику ядра.

- **`compat.sql_priv`** — default=`new`. Проверка прав на SQL по iproto: `new` — проверять; `old` — разрешать всем.
- **`compat.binary_data_decoding`** — default=`new`. Хранение бинарных полей в Lua: `new` — varbinary; `old` — строки.
- **`compat.wal_cleanup_delay_deprecation`** — default=`old`. Опция `wal_cleanup_delay`: `new` (4.x) — ошибка; `old` — предупреждение об устаревании.
- **`compat.sql_seq_scan_default`** — default=`new`. Дефолт сессионной `sql_seq_scan`: `new` — `false`; `old` — `true`.
- **`compat.fiber_slice_default`** — default=`new`. Макс. время фибера без yield: `new` — `{warn=0.5, err=1.0}`; `old` — бесконечность.
- **`compat.skip_replication_names`** — default=`new`. Применять ли `instance_name`/`replicaset_name` при старте репликации: `new` — применять и валидировать; `old` — пропускать (для апгрейда с 2.11).
- **`compat.box_tuple_new_vararg`** — default=`new`. Трактовка аргументов `box.tuple.new`: `new` — значение с форматом тюпла; `old` — массив полей.
- **`compat.console_session_scope_vars`** — default=`old`. Своя ли область переменных у консольной сессии: `new` (4.x) — да; `old` — всё в глобалы.
- **`compat.json_escape_forward_slash`** — default=`new`. Экранировать ли `/` в `json.encode()`: `new` — не экранировать; `old` — экранировать.
- **`compat.box_space_max`** — default=`new`. Максимальный id спейса: `new` — 2147483646; `old` — 2147483647.
- **`compat.box_space_execute_priv`** — default=`new`. Привилегия `execute` на спейсы: `new` — ошибка; `old` — выдаётся без эффекта.
- **`compat.fiber_channel_close_mode`** — default=`new`. Поведение каналов после закрытия: `new` — read-only; `old` — уничтожать объект.
- **`compat.box_cfg_replication_sync_timeout`** — default=`new`. Дефолт sync-таймаута репликации: `new` — 0; `old` — 300 с.
- **`compat.box_recovery_triggers_deprecation`** — default=`old`. Триггеры спейсов/транзакций при локальном recovery/join: `new` (4.x) — не вызывать; `old` — вызывать. (Источник WARN `space on recovery triggers are deprecated`.)
- **`compat.box_error_unpack_type_and_code`** — default=`old`. Показ всех полей в `box.error.unpack()`: `new` (4.x) — скрывать `base_type`/`custom_type`/нулевой `code`; `old` — показывать.
- **`compat.yaml_pretty_multiline`** — default=`new`. Блочный стиль для многострочных строк в YAML: `new` — все многострочные; `old` — только с `\n\n`.
- **`compat.box_consider_system_spaces_synchronous`** — default=`old`. Считать ли системные спейсы синхронными независимо от `is_sync`: `new` (4.x) — да (с исключениями); `old` — нет.
- **`compat.box_error_serialize_verbose`** — default=`old`. Подробность сериализации ошибок: `new` (4.x) — с доп. полями; `old` — только сообщение.
- **`compat.box_session_push_deprecation`** — default=`old`. Ошибка при вызове устаревшей `box.session.push`: `new` (4.x) — да; `old` — нет.
- **`compat.box_tuple_extension`** — default=`new`. Кодирование тюплов в iproto call/eval: `new` — `MP_TUPLE`; `old` — `MP_ARRAY`.
- **`compat.c_func_iproto_multireturn`** — default=`new`. Обёртка множественных результатов C-функции в iproto: `new` — без обёртки; `old` — в MessagePack-массив.
- **`compat.box_info_cluster_meaning`** — default=`new`. Семантика `box.info.cluster`: `new` — весь кластер (а `box.info.replicaset` — replicaset); `old` — только replicaset.
- **`compat.replication_synchro_timeout`** — default=`old`. Что делает `replication.synchro_timeout`: `new` (4.x) — транзакция ждёт кворум бессрочно, таймаут только для promote/demote/gc; `old` — неподтверждённые синхронные транзакции откатываются по таймауту.

---

## Перекрёстные ссылки

- `docs/architecture.md` — слои, 2PC через etcd, synchro-спейсы.
- `docs/failover.md` — модель supervised-failover (lease/term/vclockkeeper/fencing), как тайминги `failover.*` и `replication.*` ложатся на агента.
- `docs/operations.md` — деплой, фрагменты конфига (`docker/configs/cluster/*.yaml`), логирование, etcd-HA.
- `docs/security.md`, `docs/rbac-matrix.md` — TLS/mTLS, `credentials`, `security`, аудит.
- Исходники Tarantool: `tarantool-3.7.0/src/box/lua/config/instance_config.lua` (поля, дефолты, валидаторы, EE-обёртки), `.../cluster_config.lua` (scope-иерархия, `groups`/`conditional`/`include`, слияние).
