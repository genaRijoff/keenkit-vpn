#!/bin/sh
# shellcheck shell=dash  # целевой shell — BusyBox ash (Keenetic/Entware)
# Установка и обновление keenkit-vpn одной командой:
#   - команда keenkit запускает KeenKit через доступный канал (напрямую или VPN);
#   - athena-patch: п.9 «Athena OTA Update» на MT7981 (aarch64), keenkit возвращает его сам
#     после «99. Обновить скрипт».
# Сам KeenKit (/opt/keenkit.sh) меняется только athena-patch (оригинал сохраняется).
#   curl -fsSL https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh
# Если GitHub доступен только через туннель — интерфейс указывается и для загрузки, и для установщика:
#   curl -fsSL --interface nwg0 https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh -s -- nwg0
# Без п.9 Athena:  ... | sh -s -- --no-athena
set -u

REPO_RAW="${KEENKIT_VPN_REPO_RAW:-https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main}"
ROOT="${KEENKIT_VPN_ROOT:-}"
ARCH="${KEENKIT_VPN_ARCH:-$(uname -m)}"
BIN="$ROOT/opt/bin/keenkit"
ATHENA_BIN="$ROOT/opt/bin/athena-patch"
KK_SCRIPT="$ROOT/opt/keenkit.sh"
CURL="$ROOT/opt/bin/curl"
MARKER='# keenkit-vpn-launcher'
IFACE=""
ATHENA=1
TMP=""
TMP_ATHENA=""

die() {
  echo "keenkit-vpn install: $*" >&2
  exit 1
}
warn() { echo "keenkit-vpn install: $*" >&2; }
cleanup() { rm -f ${TMP:+"$TMP"} ${TMP_ATHENA:+"$TMP_ATHENA"}; }
trap cleanup EXIT
trap 'exit 130' INT TERM

for arg do
  case "$arg" in
  --no-athena) ATHENA=0 ;;
  -*) die "неизвестный параметр: $arg" ;;
  *)
    [ -z "$IFACE" ] || die "интерфейс указан дважды: $IFACE, $arg"
    IFACE=$arg
    ;;
  esac
done

[ -x "$CURL" ] || die "нет $CURL (opkg update && opkg install curl)"
[ -d "$ROOT/opt/bin" ] || die "нет $ROOT/opt/bin — Entware не установлен?"
[ -f "$KK_SCRIPT" ] || die "KeenKit не установлен ($KK_SCRIPT) — сначала установи KeenKit"
case "$IFACE" in
"") set -- ;;
*[!A-Za-z0-9_.-]*) die "недопустимое имя интерфейса: $IFACE" ;;
*)
  [ -d "$ROOT/sys/class/net/$IFACE" ] || die "интерфейс $IFACE не найден"
  set -- --interface "$IFACE"
  ;;
esac

download() {
  "$CURL" -fsSL --connect-timeout 5 -m 60 "$@"
}

# Лаунчер обязателен: без него установка прерывается, ничего не меняя.
TMP="$BIN.new.$$"
download "$@" -o "$TMP" "$REPO_RAW/keenkit" || die "не удалось скачать $REPO_RAW/keenkit"
# Защита от обрезанной/подменённой загрузки (страница ошибки, неполный файл)
head -n 1 "$TMP" | grep -qx '#!/bin/sh' || die "скачан не скрипт keenkit-vpn"
grep -qx "$MARKER" "$TMP" || die "скачан не скрипт keenkit-vpn"
new_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$TMP" | head -n 1)
[ -n "$new_ver" ] || die "в скачанном файле нет VERSION"
sh -n "$TMP" || die "скачанный файл содержит синтаксические ошибки"

# athena-patch не обязателен: при ошибке ставится только лаунчер.
athena_ok=0
TMP_ATHENA="$ATHENA_BIN.new.$$"
if ! download "$@" -o "$TMP_ATHENA" "$REPO_RAW/athena-patch.sh"; then
  warn "не удалось скачать athena-patch.sh — п.9 Athena не обновлён"
elif ! head -n 1 "$TMP_ATHENA" | grep -qx '#!/bin/sh' ||
  ! grep -q '^# athena-patch — ' "$TMP_ATHENA" ||
  ! grep -q '^PATCH_VERSION="[^"]*"$' "$TMP_ATHENA" ||
  ! sh -n "$TMP_ATHENA"; then
  warn "скачан не скрипт athena-patch — п.9 Athena не обновлён"
else
  athena_ok=1
fi

old_ver=""
if [ -f "$BIN" ] && [ ! -L "$BIN" ]; then
  if grep -qx "$MARKER" "$BIN"; then
    old_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$BIN" | head -n 1)
  else
    backup="$BIN.orig-$(date +%Y%m%d%H%M%S)"
    cp -p "$BIN" "$backup" || die "не удалось сохранить прежний $BIN"
    echo "Прежний $BIN (не симлинк KeenKit) сохранён: $backup"
  fi
fi

# mv заменяет сам симлинк /opt/bin/keenkit, а не /opt/keenkit.sh
if ! { chmod 755 "$TMP" && mv -f "$TMP" "$BIN"; }; then
  die "не удалось записать $BIN"
fi
TMP=""

if [ "$athena_ok" = 1 ]; then
  if { chmod 755 "$TMP_ATHENA" && mv -f "$TMP_ATHENA" "$ATHENA_BIN"; }; then
    TMP_ATHENA=""
  else
    athena_ok=0
    warn "не удалось записать $ATHENA_BIN"
  fi
fi

# Переход с kvn (0.0.2–0.0.7) и keenkit-vpn 0.0.1
# настройки kvn.conf — самые свежие, переносятся поверх keenkit-vpn.conf от 0.0.1
if [ -f "$ROOT/opt/etc/kvn.conf" ]; then
  mv -f "$ROOT/opt/etc/kvn.conf" "$ROOT/opt/etc/keenkit-vpn.conf" || die "не удалось перенести kvn.conf"
fi
rm -rf "$ROOT/opt/lib/kvn"
rm -f "$ROOT/opt/bin/kvn" "$ROOT/opt/bin/keenkit-vpn"

if [ -n "$old_ver" ]; then
  echo "keenkit-vpn обновлён: $old_ver -> $new_ver"
else
  echo "keenkit-vpn $new_ver установлен: команда keenkit теперь выбирает канал сама"
fi

# п.9 Athena: применяется через лаунчер, он же включает возврат после «99. Обновить скрипт»
if [ "$ATHENA" = 0 ]; then
  :
elif [ "$ARCH" != "aarch64" ]; then
  echo "Athena: только для MT7981 (aarch64), здесь $ARCH — п.9 не добавлен"
elif [ -f "$ATHENA_BIN" ]; then
  if out=$(KEENKIT_VPN_ROOT="$ROOT" KEENKIT_VPN_ARCH="$ARCH" sh "$BIN" --athena on 2>&1 </dev/null); then
    echo "Athena: п.9 в KeenKit, возвращается сам после «99. Обновить скрипт» (убрать: keenkit --athena off)"
  else
    warn "п.9 Athena не добавлен, keenkit работает без него:"
    printf '%s\n' "$out" | tail -n 3 >&2
  fi
fi
echo "Запуск: keenkit   Проверка: keenkit --check   Убрать: keenkit --vpn-remove"
