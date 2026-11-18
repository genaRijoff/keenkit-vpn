#!/bin/sh
# shellcheck shell=dash  # целевой shell — BusyBox ash (Keenetic/Entware)
# Установка и обновление keenkit-vpn: команда keenkit запускает KeenKit через доступный канал
# (напрямую или VPN) с переключением на лету. Сам KeenKit (/opt/keenkit.sh) не меняется.
#   curl -fsSL https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh
# Если GitHub доступен только через туннель — интерфейс указывается и для загрузки, и для установщика:
#   curl -fsSL --interface nwg0 https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main/install.sh | sh -s -- nwg0
set -u

REPO_RAW="${KEENKIT_VPN_REPO_RAW:-https://raw.githubusercontent.com/genaRijoff/keenkit-vpn/main}"
ROOT="${KEENKIT_VPN_ROOT:-}"
BIN="$ROOT/opt/bin/keenkit"
KK_SCRIPT="$ROOT/opt/keenkit.sh"
CURL="$ROOT/opt/bin/curl"
MARKER='# keenkit-vpn-launcher'
IFACE="${1:-}"
TMP=""

die() {
  echo "keenkit-vpn install: $*" >&2
  exit 1
}
cleanup() { [ -z "$TMP" ] || rm -f "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

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

TMP="$BIN.new.$$"
"$CURL" -fsSL --connect-timeout 5 -m 60 "$@" -o "$TMP" "$REPO_RAW/keenkit" ||
  die "не удалось скачать $REPO_RAW/keenkit"

# Защита от обрезанной/подменённой загрузки (страница ошибки, неполный файл)
head -n 1 "$TMP" | grep -qx '#!/bin/sh' || die "скачан не скрипт keenkit-vpn"
grep -qx "$MARKER" "$TMP" || die "скачан не скрипт keenkit-vpn"
new_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$TMP" | head -n 1)
[ -n "$new_ver" ] || die "в скачанном файле нет VERSION"
sh -n "$TMP" || die "скачанный файл содержит синтаксические ошибки"

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
echo "Запуск: keenkit   Проверка: keenkit --check   Убрать: keenkit --vpn-remove"
