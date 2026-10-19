#!/bin/sh
# shellcheck shell=dash  # целевой shell — BusyBox ash (Keenetic/Entware)
# Установка и обновление kvn (KeenVPN).
#   curl -fsSL https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh
# Если GitHub доступен только через туннель — укажи интерфейс и для загрузки, и для установщика:
#   curl -fsSL --interface nwg0 https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh -s -- nwg0
set -u

REPO_RAW="${KVN_REPO_RAW:-https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main}"
ROOT="${KVN_ROOT:-}"
BIN="$ROOT/opt/bin/kvn"
CURL="$ROOT/opt/bin/curl"
IFACE="${1:-}"
TMP=""

die() {
  echo "kvn install: $*" >&2
  exit 1
}
cleanup() { [ -z "$TMP" ] || rm -f "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

[ -x "$CURL" ] || die "нет $CURL (opkg update && opkg install curl)"
[ -d "$ROOT/opt/bin" ] || die "нет $ROOT/opt/bin — Entware не установлен?"
case "$IFACE" in
"") set -- ;;
*[!A-Za-z0-9_.-]*) die "недопустимое имя интерфейса: $IFACE" ;;
*)
  [ -d "$ROOT/sys/class/net/$IFACE" ] || die "интерфейс $IFACE не найден"
  set -- --interface "$IFACE"
  ;;
esac

TMP="$BIN.new.$$"
"$CURL" -fsSL --connect-timeout 5 -m 60 "$@" -o "$TMP" "$REPO_RAW/kvn" || die "не удалось скачать $REPO_RAW/kvn"

# Защита от обрезанной/подменённой загрузки (страница ошибки, неполный файл)
head -n 1 "$TMP" | grep -qx '#!/bin/sh' || die "скачан не скрипт kvn"
new_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$TMP" | head -n 1)
[ -n "$new_ver" ] || die "в скачанном файле нет VERSION"
sh -n "$TMP" || die "скачанный kvn содержит синтаксические ошибки"

old_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$BIN" 2>/dev/null | head -n 1)
if ! { chmod 755 "$TMP" && mv -f "$TMP" "$BIN"; }; then
  die "не удалось записать $BIN"
fi
TMP=""

# Миграция с keenkit-vpn (0.0.1)
if [ -f "$ROOT/opt/etc/keenkit-vpn.conf" ] && [ ! -f "$ROOT/opt/etc/kvn.conf" ]; then
  mv "$ROOT/opt/etc/keenkit-vpn.conf" "$ROOT/opt/etc/kvn.conf"
fi
rm -rf "$ROOT/opt/lib/keenkit-vpn" "$ROOT/opt/bin/keenkit-vpn" "$ROOT/opt/etc/keenkit-vpn.conf"

if [ -n "$old_ver" ]; then
  echo "kvn обновлён: $old_ver -> $new_ver"
else
  echo "kvn $new_ver установлен"
fi
echo "Проверка: kvn check   Запуск: kvn"
