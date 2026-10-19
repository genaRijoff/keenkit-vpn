# keenkit-vpn — `kvn` (KeenVPN)

Запуск [KeenKit](https://github.com/spatiumstas/KeenKit) через VPN-интерфейс Keenetic с раздельными OTA-источниками:

| Пункт KeenKit | Источник |
|---|---|
| 5. OTA Update (прошивки) | `https://osvault.project-athens.com` (Афина) |
| 8. KeenBOOT OTA Update | `https://spatiumstas.github.io/KeenKit` (Стас) |

KeenKit не модифицируется: kvn кладёт перед ним в `PATH` обёртку `curl`, которая
- добавляет `--interface <VPN>` ко всем внешним запросам;
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
kvn              автовыбор рабочего интерфейса (IFACES) и запуск KeenKit
kvn nwg1         запуск через указанный интерфейс
kvn check        каналы, источники, совместимость с KeenKit
kvn uninstall    удаление (с подтверждением)
```

Пример `kvn check`:

```
kvn 0.0.4
Прошивки (Афина): https://osvault.project-athens.com
KeenBOOT (Стас): https://spatiumstas.github.io/KeenKit
KeenKit: 2.9.2 OK
KeenKit.conf: OK

напрямую (x.x.x.x): KeenBOOT OK, прошивки OK
nwg0 (y.y.y.y): KeenBOOT OK, прошивки OK
```

## Настройки — `/opt/etc/kvn.conf`

| Ключ | По умолчанию | Назначение |
|---|---|---|
| `IFACES` | `nwg0 nwg1 nwg2` | интерфейсы по порядку; используется первый, через который доступны оба источника |
| `FW_DOMAIN` | `https://osvault.project-athens.com` | источник прошивок (п.5) |
| `FW_LABEL` | `Афина` | подпись |
| `KB_BASE` | `https://spatiumstas.github.io/KeenKit` | источник KeenBOOT (п.8) |
| `KB_LABEL` | `Стас` | подпись |

Файл читается как данные (`KEY="value"`), а не исполняется; `` $ ` " \ `` в значениях запрещены.

## Файлы на роутере

- `/opt/bin/kvn` — скрипт
- `/opt/etc/kvn.conf` — настройки
- `/opt/lib/kvn/curl` — обёртка (генерируется kvn)
- `/opt/etc/KeenKit.conf` — kvn записывает в него `FW_DOMAIN` при каждом запуске

## Совместимость

kvn опирается на внутренности KeenKit: `ota_path="/files/keenboot/..."` и формат `KeenKit.conf`. `kvn check` проверяет оба маркера. Проверенные версии KeenKit: 2.9.1, 2.9.2.

Ограничение: DNS резолвится через роутер, а не через туннель.

## Разработка

```sh
shellcheck kvn install.sh && shellcheck -s sh tests/run.sh
TEST_SH="busybox sh" sh tests/run.sh   # как на роутере
TEST_SH=dash sh tests/run.sh
```

Тесты работают в изолированном корне (`KVN_ROOT`) с поддельными `curl`, `/sys/class/net` и KeenKit. CI — `.github/workflows/ci.yml`.
