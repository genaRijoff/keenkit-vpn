# keenkit-vpn

> ⚠️ **Неофициальный проект.** Не связан с [KeenKit](https://github.com/spatiumstas/KeenKit) (spatiumstas) и [Project Athens](https://project-athens.com). Лаунчер `keenkit` и `athena-patch` меняют поведение KeenKit на вашем роутере; сам KeenKit здесь не распространяется. С проблемами, вызванными этими скриптами, не обращайтесь к авторам KeenKit и Athena. Всё — на ваш риск.

Команда `keenkit` запускает [KeenKit](https://github.com/spatiumstas/KeenKit) через доступный канал — напрямую или через VPN-интерфейс Keenetic — с раздельными OTA-источниками:

| Пункт KeenKit | Источник |
|---|---|
| 5. OTA Update (прошивки) | `https://osvault.project-athens.com` (Афина) |
| 8. KeenBOOT OTA Update | `https://spatiumstas.github.io/KeenKit` (Стас) |
| 9. Athena OTA Update | `https://osvault.project-athens.com/files/athena` (Афина) — [athena-patch](#athena-patch), только MT7981 (aarch64) |

Как это устроено: установщик заменяет симлинк `/opt/bin/keenkit` лаунчером и ставит `athena-patch`. Лаунчер кладёт перед KeenKit в `PATH` обёртку `curl`, которая
- отправляет каждый внешний запрос через каналы по порядку, начиная с последнего удачного; при сетевой ошибке повторяет его через следующий канал;
- оставляет локальный RCI (`127.0.0.1:79`) напрямую;
- перенаправляет `<osvault>/files/keenboot/*` на GitHub Pages Стаса.

KeenKit (`/opt/keenkit.sh`) меняет только athena-patch (п.9, оригинал сохраняется). После «99. Обновить скрипт» `keenkit` при следующем запуске сам возвращает п.9.

## Установка и обновление

Требуется Entware с `curl` и установленный KeenKit.

```sh
curl -fsSL https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh
```

Одна команда ставит всё: лаунчер `keenkit`, `athena-patch` и на MT7981 (aarch64) сразу добавляет п.9 Athena. Та же команда обновляет.

Если GitHub у провайдера заблокирован — через туннель (интерфейс указывается дважды: для загрузки установщика и для загрузки скриптов):

```sh
curl -fsSL --interface nwg0 https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh -s -- nwg0
```

Без п.9 Athena:

```sh
curl -fsSL https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh -s -- --no-athena
```

Установщик проверяет скачанные файлы (shebang, метка, версия, `sh -n`) и заменяет их атомарно. Ошибка загрузки лаунчера — ничего не меняется; ошибка `athena-patch` — лаунчер ставится, п.9 нет (с предупреждением). Прежняя версия `kvn` удаляется, её настройки переносятся. Если `/opt/bin/keenkit` был не симлинком KeenKit, а чужим файлом (например, KeenKit со старым патчем Athena v1), он сохраняется рядом (`keenkit.orig-<дата>`).

После переустановки самого KeenKit (его `install.sh` заново создаёт симлинк) запустите установщик keenkit-vpn ещё раз.

## Команды

```
keenkit                  запуск KeenKit (аргументы передаются KeenKit как есть)
keenkit --iface nwg1     только nwg1, без резерва (direct — только напрямую)
keenkit --check          каналы, источники, совместимость с KeenKit
keenkit --athena on      добавить п.9 Athena (aarch64), возвращать после обновления KeenKit
keenkit --athena off     убрать п.9, вернуть оригинальный KeenKit
keenkit --athena         состояние п.9
keenkit --vpn-remove     вернуть обычный запуск KeenKit (с подтверждением)
keenkit --vpn-version    версия keenkit-vpn
keenkit --vpn-help       справка
```

Пример `keenkit --check`:

```
keenkit-vpn 0.0.9
Прошивки (Афина): https://osvault.project-athens.com
KeenBOOT (Стас): https://spatiumstas.github.io/KeenKit
KeenKit: 2.9.5 OK
Athena-патч: 0.0.5 (п.9 -> Athena, https://osvault.project-athens.com/files/athena), возврат после обновления KeenKit: вкл
KeenKit.conf: OK
Порядок каналов: напрямую -> nwg0 -> nwg1 -> awg0
Последний удачный: nwg0

напрямую (x.x.x.x): KeenBOOT OK, прошивки OK
nwg0 (y.y.y.y): KeenBOOT OK, прошивки OK
```

## Настройки — `/opt/etc/keenkit-vpn.conf`

| Ключ | По умолчанию | Назначение |
|---|---|---|
| `IFACES` | `direct auto` | каналы по порядку: `direct` — без туннеля, имена интерфейсов, `auto` — все `wg*/nwg*`, затем `awg*/nawg*`, затем `mitun*`. Старое значение по умолчанию `nwg0 nwg1 nwg2` переводится на `direct auto` автоматически |
| `FW_DOMAIN` | `https://osvault.project-athens.com` | источник прошивок (п.5) |
| `FW_LABEL` | `Афина` | подпись |
| `KB_BASE` | `https://spatiumstas.github.io/KeenKit` | источник KeenBOOT (п.8) |
| `KB_LABEL` | `Стас` | подпись |
| `ATHENA` | `off` (установщик на aarch64 ставит `on`) | `on` — возвращать п.9 после «99. Обновить скрипт». Меняется командами `keenkit --athena on/off` (и `athena-patch apply/revert`) |

Файл читается как данные (`KEY="value"`), а не исполняется; `` $ ` " \ `` в значениях запрещены. Ошибка в настройках не блокирует KeenKit: он запускается как обычно, с предупреждением.

### Выбор канала

Лаунчер не проверяет каналы при старте — KeenKit открывается сразу. Каждый внешний запрос идёт через последний удачный канал (`/tmp/keenkit-vpn.iface`), а если его нет — по порядку `IFACES`. При сетевой ошибке (нет соединения, таймаут, сброс TLS — коды curl 5, 6, 7, 16, 28, 35, 52, 55, 56) запрос повторяется через следующий канал, удачный запоминается. Ответ сервера (404 и т.п.) не повторяется. Вывод неудачной попытки отбрасывается, поэтому в KeenKit не попадает обрывок ответа.

## Файлы на роутере

- `/opt/bin/keenkit` — лаунчер (вместо симлинка на `/opt/keenkit.sh`)
- `/opt/bin/athena-patch` — патч п.9
- `/opt/keenkit.sh.<версия>.orig` — оригинал KeenKit (если применён athena-patch)
- `/opt/etc/keenkit-vpn.conf` — настройки
- `/opt/lib/keenkit-vpn/curl` — обёртка (генерируется лаунчером)
- `/tmp/keenkit-vpn.iface` — последний удачный канал
- `/opt/etc/KeenKit.conf` — лаунчер записывает в него `FW_DOMAIN` при каждом запуске

## Совместимость

Лаунчер опирается на внутренности KeenKit: `ota_path="/files/keenboot/..."` и формат `KeenKit.conf`. `keenkit --check` проверяет оба маркера. Проверенные версии KeenKit: 2.9.1–2.9.5.

Ограничение: DNS резолвится через роутер, а не через туннель.

## athena-patch

Патч KeenKit: пункт «9. Athena OTA Update» ставит загрузчик [Athena](https://project-athens.com/ru/wiki/helpful/athena) (Project Athens) на роутерах MT7981 (aarch64). Пункты 5 и 8 остаются как в оригинале. Проверено на Cudy TR3000 и CMCC RAX3000Me: Athena r41 записана через `keenboot_writer` с побайтной проверкой, роутеры загружаются.

Что меняется (только в `/opt/keenkit.sh`, оригинал сохраняется):

| | |
|---|---|
| п.9 (aarch64) | модель → версия Athena (`r41`, …) → файл; одна версия выбирается автоматически; запись тем же `keenboot_writer`, что и п.8 |
| п.5, п.8 | без изменений (тесты сравнивают запросы и вывод с оригиналом) |
| Защита модели | папка не совпадает с моделью роутера → запись только после ввода `YES` (RAX3000Me ↔ `CMCC_RAX3000M` считается совпадением — один файл по wiki Athena) |
| Шапка | `Загрузчик: Athena r41 (2.14.0)` вместо `U-Boot phase` |

Ставится установщиком keenkit-vpn (см. [Установка](#установка-и-обновление)). Управление:

```sh
keenkit --athena on      # применить и возвращать после «99. Обновить скрипт»
keenkit --athena off     # вернуть оригинал и не возвращать
keenkit --athena         # состояние
athena-patch diff        # что изменится, ничего не меняя
```

`athena-patch` работает и без лаунчера (`apply`, `revert`, `status`, `diff`); если стоит keenkit-vpn, `apply`/`revert` также включают/выключают `ATHENA` в его настройках.

- Изменения вставляются после строк-якорей; каждый якорь должен встретиться ровно один раз, иначе KeenKit не трогается.
- Оригинал сохраняется как `/opt/keenkit.sh.<версия>.orig`; замена атомарная (работающий KeenKit не ломается).
- Патч v1 (`patch-athena.sh`, без метки) обновляется автоматически: оригинал берётся из `/opt/bin/keenkit.before-athena`.
- После «99. Обновить скрипт» `keenkit` применяет патч заново при следующем запуске (`ATHENA="on"`). Если структура новой версии KeenKit не совпала, KeenKit запускается без п.9 с предупреждением.

⚠️ Загрузчик — опасная процедура: только файл своей модели, стабильное питание, UART на случай отказа. «Не обновляйте загрузчик, если всё работает» (wiki Athena).

## Разработка

```sh
shellcheck keenkit install.sh athena-patch.sh && shellcheck -s sh tests/run.sh tests/athena.sh
TEST_SH="busybox sh" sh tests/run.sh   # лаунчер и установщик, как на роутере
TEST_SH=dash sh tests/run.sh
KEENKIT_SRC=/путь/keenkit.sh busybox sh tests/athena.sh   # athena-patch и возврат п.9 через лаунчер
# миграция с патча v1 проверяется, если указать путь к нему: V1_PATCH=/путь/patch-athena.sh
```

`tests/athena.sh` работает на настоящем KeenKit (в CI скачивается по закреплённому коммиту с проверкой SHA-256): установка, откат, миграция с v1, а также функциональные прогоны пропатченного `ota_update` с заглушками сети — п.9 (выбор версии, защита модели, mipsel), п.5 и п.8 в сравнении с оригиналом.

Тесты работают в изолированном корне (`KEENKIT_VPN_ROOT`, `ATHENA_ROOT`) с поддельными `curl`, `/sys/class/net` и KeenKit. CI — `.github/workflows/ci.yml`.
