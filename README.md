# keenkit-vpn — `kvn` (KeenVPN)

> ⚠️ **Неофициальный проект.** Не связан с [KeenKit](https://github.com/spatiumstas/KeenKit) (spatiumstas) и [Project Athens](https://project-athens.com). `kvn` и `athena-patch` меняют поведение KeenKit на вашем роутере; сам KeenKit здесь не распространяется. С проблемами, вызванными этими скриптами, не обращайтесь к авторам KeenKit и Athena. Всё — на ваш риск.

Запуск [KeenKit](https://github.com/spatiumstas/KeenKit) через VPN-интерфейс Keenetic с раздельными OTA-источниками:

| Пункт KeenKit | Источник |
|---|---|
| 5. OTA Update (прошивки) | `https://osvault.project-athens.com` (Афина) |
| 8. KeenBOOT OTA Update | `https://spatiumstas.github.io/KeenKit` (Стас) |
| 9. Athena OTA Update | `https://osvault.project-athens.com/files/athena` (Афина) — с [athena-patch](#athena-patch), только aarch64 |

KeenKit не модифицируется: kvn кладёт перед ним в `PATH` обёртку `curl`, которая
- отправляет внешние запросы через выбранный канал (напрямую или `--interface <VPN>`), а при сетевой ошибке повторяет запрос через следующий канал из резерва;
- оставляет локальный RCI (`127.0.0.1:79`) напрямую;
- перенаправляет `<osvault>/files/keenboot/*` на GitHub Pages Стаса.

## Установка и обновление

Требуется Entware с `curl` и установленный KeenKit.

```sh
curl -fsSL https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh
```

Если GitHub у провайдера заблокирован — через туннель (интерфейс указывается дважды: для загрузки установщика и для загрузки kvn):

```sh
curl -fsSL --interface nwg0 https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh -s -- nwg0
```

Установщик проверяет скачанный файл (shebang, `VERSION`, `sh -n`) и заменяет kvn атомарно; при ошибке старая версия остаётся. Настройки `keenkit-vpn` 0.0.1 переносятся автоматически.

## Команды

```
kvn              первый рабочий канал из IFACES + резерв, запуск KeenKit
kvn nwg1         только nwg1, без резерва (kvn direct — только напрямую)
kvn check        каналы, источники, совместимость с KeenKit
kvn uninstall    удаление (с подтверждением)
```

Пример `kvn check`:

```
kvn 0.0.7
Прошивки (Афина): https://osvault.project-athens.com
KeenBOOT (Стас): https://spatiumstas.github.io/KeenKit
KeenKit: 2.9.5 OK
Athena-патч: 0.0.4 (п.9 -> Athena, https://osvault.project-athens.com/files/athena)
KeenKit.conf: OK
Порядок каналов: напрямую -> nwg0 -> nwg1 -> awg0

напрямую (x.x.x.x): KeenBOOT OK, прошивки OK
nwg0 (y.y.y.y): KeenBOOT OK, прошивки OK
```

## Настройки — `/opt/etc/kvn.conf`

| Ключ | По умолчанию | Назначение |
|---|---|---|
| `IFACES` | `direct auto` | каналы по порядку: `direct` — без туннеля, имена интерфейсов, `auto` — все `wg*/nwg*`, затем `awg*/nawg*`, затем `mitun*`. Первый, через который доступны оба источника, — основной, остальные — резерв (не прошедшие проверку — в конце). Старое значение по умолчанию `nwg0 nwg1 nwg2` переводится на `direct auto` автоматически |
| `FW_DOMAIN` | `https://osvault.project-athens.com` | источник прошивок (п.5) |
| `FW_LABEL` | `Афина` | подпись |
| `KB_BASE` | `https://spatiumstas.github.io/KeenKit` | источник KeenBOOT (п.8) |
| `KB_LABEL` | `Стас` | подпись |

Файл читается как данные (`KEY="value"`), а не исполняется; `` $ ` " \ `` в значениях запрещены.

### Переключение канала во время работы

Если запрос через текущий канал падает с сетевой ошибкой (нет соединения, таймаут, сброс TLS — коды curl 5, 6, 7, 16, 28, 35, 52, 55, 56), обёртка повторяет его через следующий канал и запоминает удачный (`/tmp/kvn-iface.<pid>`), чтобы следующие запросы шли сразу через него. Ответ сервера (404 и т.п.) не повторяется. Вывод неудачной попытки отбрасывается, поэтому в KeenKit не попадает обрывок ответа.

## Файлы на роутере

- `/opt/bin/kvn` — скрипт
- `/opt/etc/kvn.conf` — настройки
- `/opt/lib/kvn/curl` — обёртка (генерируется kvn)
- `/opt/etc/KeenKit.conf` — kvn записывает в него `FW_DOMAIN` при каждом запуске

## Совместимость

kvn опирается на внутренности KeenKit: `ota_path="/files/keenboot/..."` и формат `KeenKit.conf`. `kvn check` проверяет оба маркера. Проверенные версии KeenKit: 2.9.1–2.9.5.

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

Установка (если GitHub заблокирован — добавить `--interface nwg0`):

```sh
curl -fsSL -o /opt/bin/athena-patch https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/athena-patch.sh
chmod 755 /opt/bin/athena-patch
athena-patch status    # состояние
athena-patch diff      # что изменится, ничего не меняя
athena-patch           # применить
athena-patch revert    # вернуть оригинал
```

- Изменения вставляются после строк-якорей; каждый якорь должен встретиться ровно один раз, иначе KeenKit не трогается.
- Оригинал сохраняется как `/opt/keenkit.sh.<версия>.orig`; замена атомарная (работающий KeenKit не ломается).
- Патч v1 (`patch-athena.sh`, без метки) обновляется автоматически: оригинал берётся из `/opt/bin/keenkit.before-athena`.
- После «99. Обновить скрипт» в KeenKit патч нужно применить заново (`kvn check` покажет, применён ли он).

⚠️ Загрузчик — опасная процедура: только файл своей модели, стабильное питание, UART на случай отказа. «Не обновляйте загрузчик, если всё работает» (wiki Athena).

## Разработка

```sh
shellcheck kvn install.sh athena-patch.sh && shellcheck -s sh tests/run.sh tests/athena.sh
TEST_SH="busybox sh" sh tests/run.sh   # kvn, как на роутере
TEST_SH=dash sh tests/run.sh
KEENKIT_SRC=/путь/keenkit.sh busybox sh tests/athena.sh
# миграция с патча v1 проверяется, если указать путь к нему: V1_PATCH=/путь/patch-athena.sh
```

`tests/athena.sh` работает на настоящем KeenKit (в CI скачивается по закреплённому коммиту с проверкой SHA-256): установка, откат, миграция с v1, а также функциональные прогоны пропатченного `ota_update` с заглушками сети — п.9 (выбор версии, защита модели, mipsel), п.5 и п.8 в сравнении с оригиналом.

Тесты работают в изолированном корне (`KVN_ROOT`) с поддельными `curl`, `/sys/class/net` и KeenKit. CI — `.github/workflows/ci.yml`.
