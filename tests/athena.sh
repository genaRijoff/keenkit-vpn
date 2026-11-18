#!/bin/sh
# shellcheck disable=SC2015,SC2016  # ok/bad всегда возвращают 0; литералы $... в фикстурах намеренно
# Тесты athena-patch на реальном KeenKit (оригинал не хранится в репозитории — лицензия KeenKit).
# Запуск: KEENKIT_SRC=/путь/к/keenkit.sh busybox sh tests/athena.sh
# Миграция с патча v1 проверяется при V1_PATCH=/путь/patch-athena.sh (в репозитории его нет).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=${PATCH:-$HERE/../athena-patch.sh}
SRC=${KEENKIT_SRC:?укажи KEENKIT_SRC — путь к оригинальному keenkit.sh}
SH=${TEST_SH:-busybox sh}
PASS=0
FAIL=0
R=""

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "нет «$3» в: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "лишнее «$3»" ;; *) ok "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "ожидалось «$3», получено «$2»"; fi; }
same() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "файлы различаются: $2 $3"; fi; }

setup() {
  R=$(mktemp -d)
  mkdir -p "$R/opt/bin" "$R/opt/etc" "$R/tmp"
  cp "$SRC" "$R/opt/keenkit.sh"
  ln -s "$R/opt/keenkit.sh" "$R/opt/bin/keenkit"
}
teardown() { rm -rf "$R"; }
run() { ATHENA_ROOT="$R" $SH "$PATCH" "$@" 2>&1; }
T() { echo "$R/opt/keenkit.sh"; }
VER=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$SRC")
leftovers() {
  n=0
  for f in "$R"/opt/*.athena.* "$R"/opt/*.athena.lock; do [ -e "$f" ] && n=$((n + 1)); done
  echo "$n"
}

echo "== установка (KeenKit $VER)"
setup
out=$(run status)
has "status до патча" "$out" "не применён"
out=$(run); rc=$?
eq "apply: rc=0" "$rc" 0
has "apply: сообщение" "$out" "Патч 0.0.4 применён к KeenKit $VER"
eq "метка версии патча" "$(sed -n 's/^ATHENA_PATCH="\(.*\)"$/\1/p' "$(T)")" "0.0.4"
same "копия оригинала" "$R/opt/keenkit.sh.$VER.orig" "$SRC"
[ -L "$R/opt/bin/keenkit" ] && ok "симлинк сохранён" || bad "симлинк сохранён"
$SH -n "$(T)" && ok "синтаксис пропатченного KeenKit" || bad "синтаксис пропатченного KeenKit"
grep -q '^    ota_path="/files/keenboot/\$arch"$' "$(T)" && ok "оригинальная строка ota_path на месте (kvn)" || bad "оригинальная строка ota_path на месте (kvn)"
eq "домен OTA" "$(cat "$R/opt/etc/KeenKit.conf")" 'domain="https://osvault.project-athens.com"'
eq "временных файлов нет" "$(leftovers)" 0
cp "$(T)" "$R/patched.ref"
m1=$(md5sum <"$(T)")
out=$(run apply)
has "повтор: уже применён" "$out" "уже применён"
eq "повтор: файл не тронут" "$(md5sum <"$(T)")" "$m1"
out=$(run diff)
has "diff на пропатченном" "$out" '+ATHENA_PATCH="0.0.4"'
eq "diff: файл не тронут" "$(md5sum <"$(T)")" "$m1"
out=$(run status)
has "status после патча" "$out" "0.0.4"
out=$(run revert); rc=$?
eq "revert: rc=0" "$rc" 0
same "revert: оригинал восстановлен" "$(T)" "$SRC"
[ -L "$R/opt/bin/keenkit" ] && ok "revert: симлинк сохранён" || bad "revert: симлинк сохранён"
out=$(run revert)
has "повторный revert" "$out" "откатывать нечего"
teardown

echo "== отказ без изменений"
setup
grep -v "^  DIR_ENCODED=\$(echo \"\$DIR\" | sed 's/ /%20/g')\$" "$SRC" >"$(T)"
cp "$(T)" "$R/before"
out=$(run); rc=$?
eq "изменённая структура: rc=1" "$rc" 1
has "изменённая структура: причина" "$out" "не совпадает с ожидаемой"
same "изменённая структура: KeenKit не тронут" "$(T)" "$R/before"
eq "изменённая структура: временных файлов нет" "$(leftovers)" 0
teardown

setup
sed 's|^SCRIPT_VERSION=.*|&\nATHENA_PATCH="0.0.1"|' "$SRC" >"$(T)"
cp "$(T)" "$R/before"
out=$(run); rc=$?
eq "чужой патч без оригинала: rc=1" "$rc" 1
has "чужой патч без оригинала: подсказка" "$out" "п.99"
same "чужой патч без оригинала: не тронут" "$(T)" "$R/before"
out=$(run revert); rc=$?
eq "revert без оригинала: rc=1" "$rc" 1
teardown

setup
mkdir "$R/opt/keenkit.sh.athena.lock"
out=$(run); rc=$?
eq "блокировка: rc=1" "$rc" 1
has "блокировка: причина" "$out" "уже выполняется"
same "блокировка: KeenKit не тронут" "$(T)" "$SRC"
teardown

echo "== обновление патча и миграция с v1"
setup
cp "$SRC" "$R/opt/keenkit.sh.$VER.orig"
sed 's|^SCRIPT_VERSION=.*|&\nATHENA_PATCH="0.0.1"|' "$SRC" >"$(T)"
out=$(run); rc=$?
eq "старая версия патча -> обновлена: rc=0" "$rc" 0
REF=$(mktemp -d); mkdir -p "$REF/opt/bin" "$REF/opt/etc"; cp "$SRC" "$REF/opt/keenkit.sh"
ATHENA_ROOT="$REF" $SH "$PATCH" >/dev/null 2>&1
same "старая версия патча -> как чистая установка" "$(T)" "$REF/opt/keenkit.sh"
teardown

if [ -n "${V1_PATCH:-}" ] && [ -f "$V1_PATCH" ]; then
  setup
  sed -e "s|/tmp/|$R/tmp/|g" -e "s|/opt/|$R/opt/|g" "$V1_PATCH" >"$R/v1.sh"
  $SH "$R/v1.sh" >/dev/null 2>&1
  grep -q 'ota_path="/files/athena"' "$(T)" && ok "v1 применён (подготовка)" || bad "v1 применён (подготовка)"
  out=$(run status)
  has "status видит v1" "$out" "v1"
  out=$(run); rc=$?
  eq "миграция v1: rc=0" "$rc" 0
  has "миграция v1: сообщение" "$out" "Найден патч v1"
  same "миграция v1 -> как чистая установка" "$(T)" "$REF/opt/keenkit.sh"
  same "миграция v1: копия = оригинал" "$R/opt/keenkit.sh.$VER.orig" "$SRC"
  run revert >/dev/null
  same "миграция v1: revert к оригиналу" "$(T)" "$SRC"
  teardown
else
  echo "  skip миграция v1 (V1_PATCH не задан)"
fi

# ---------- функциональные тесты пропатченного ota_update ----------

extract() { # extract <файл> <функция...>
  f="$1"
  shift
  for fn in "$@"; do
    awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) \\{" {p = 1} p {print} p && /^}/ {exit}' "$f"
  done
}

W=$(mktemp -d)
export W
extract "$REF/opt/keenkit.sh" ota_update parse_bootloader_version print_list_with_highlight >"$W/patched_funcs.sh"
PATCHED_KK="$W/patched_keenkit.sh"
cp "$REF/opt/keenkit.sh" "$PATCHED_KK"
extract "$SRC" ota_update parse_bootloader_version print_list_with_highlight >"$W/orig_funcs.sh"
rm -rf "$REF"

cat >"$W/harness.sh" <<'EOF'
# Заглушки окружения KeenKit; сеть эмулирует ota_request, журнал — $W/log
RED='' GREEN='' CYAN='' NC=''
STORAGE_DIR="$W/storage" TMP_DIR="$W/tmpd"
mkdir -p "$STORAGE_DIR" "$TMP_DIR"
D="https://osv"
check_host() { :; }
packages_checker() { :; }
get_architecture() { echo "$ARCH"; }
is_uboot_writable() { :; }
get_ota_domain() {
  [ "${1:-}" != "new" ] || { echo "ASK_NEW_DOMAIN"; exit 0; }
  echo "$D"
}
save_ota_domain() { :; }
get_device() { echo "$DEVICE"; }
exit_main_menu() { :; }
main_menu() { echo "MAIN_MENU"; exit 0; }
exit_function() { echo "EXIT_FUNCTION"; exit 0; }
print_message() { printf '%s\n' "$1"; }
get_internal_storage_size() { echo 100; }
show_progress() { :; }
ota_cleanup() { :; }
uboot_write_aarch64() { echo "WRITE_AARCH64 $1"; }
perform_dd() { echo "DD $1 $2"; }
update_firmware_block() { echo "FIRMWARE $1"; }
reboot() { echo "REBOOT"; }
dir() { printf '<a href="../">..</a>'; for x in "$@"; do printf '<a href="%s">%s</a>' "$x" "$x"; done; }
ota_request() {
  url="$1"
  shift
  echo "$url $*" >>"$W/log"
  case "$*" in
  -I) printf 'HTTP/2 200\r\ncontent-length: 3\r\n'; return ;;
  --output*)
    out="$2"
    case "$url" in
    */md5sum) printf '%s  %s\n' "$(printf IMG | md5sum | cut -d' ' -f1)" "$FILE" >"$out" ;;
    *) printf IMG >"$out" ;;
    esac
    return
    ;;
  esac
  case "$url" in
  "$D/files/athena") dir Cudy_TR3000/ Xiaomi_AX3000T/ Multi_TR3000/ CMCC_RAX3000M/ Athena_UART.zip md5sum ;;
  "$D/files/athena/CMCC_RAX3000M/") dir r41/ ;;
  "$D/files/athena/CMCC_RAX3000M/r41/") dir Athena_CMCC_RAX3000M_r41.bin md5sum ;;
  "$D/files/athena/Cudy_TR3000/") dir r41/ ;;
  "$D/files/athena/Cudy_TR3000/r41/") dir Athena_Cudy_TR3000_r41.bin md5sum ;;
  "$D/files/athena/Xiaomi_AX3000T/") dir r41/ ;;
  "$D/files/athena/Xiaomi_AX3000T/r41/") dir Athena_Xiaomi_AX3000T_r41.bin md5sum ;;
  "$D/files/athena/Multi_TR3000/") dir r40/ r41/ ;;
  "$D/files/athena/Multi_TR3000/r40/") dir Athena_Multi_TR3000_r40.bin md5sum ;;
  "$D/files/athena/Multi_TR3000/r41/") dir Athena_Multi_TR3000_r41.bin md5sum ;;
  "$D/files/keenboot/mipsel") dir Netis_N6/ ;;
  "$D/files/keenboot/aarch64") dir KB-41/ ;;
  "$D/files/keenboot/aarch64/KB-41/") dir KeenBOOT_TR3000_KB-41.bin md5sum ;;
  "$D/files/keenboot/mipsel/Netis_N6/") dir KeenBOOT_N6_KB-41.bin md5sum ;;
  "$D/osvault") dir Cudy%20TR3000/ ;;
  "$D/osvault/Cudy%20TR3000/") dir Cudy_TR3000_5.2_Beta_3_single.bin md5sum ;;
  *) return 1 ;;
  esac
}
. "$FUNCS"
ota_update "$MODE"
EOF

flow() { # flow <funcs> <mode> <arch> <device> <ввод>
  rm -rf "$W/log" "$W/storage" "$W/tmpd"
  : >"$W/log"
  printf '%b' "$5" | FUNCS="$1" MODE="$2" ARCH="$3" DEVICE="$4" $SH "$W/harness.sh" 2>&1
}
P="$W/patched_funcs.sh"
O="$W/orig_funcs.sh"

echo "== п.9 Athena (aarch64)"
out=$(flow "$P" athena aarch64 TR3000 '1\n1\nn\n')
log=$(cat "$W/log")
has "каталог /files/athena" "$log" "https://osv/files/athena "
has "одна версия -> r41 автоматически" "$log" "https://osv/files/athena/Cudy_TR3000/r41/ "
has "размер файла из r41" "$log" "https://osv/files/athena/Cudy_TR3000/r41/Athena_Cudy_TR3000_r41.bin -I"
has "md5sum из r41" "$log" "https://osv/files/athena/Cudy_TR3000/r41/md5sum --output"
has "заголовок версий с подпапкой" "$out" "Версии для Cudy_TR3000/r41"
hasnt "одна версия: без меню выбора версии" "$out" "Версии Athena для"
has "MD5 совпал" "$out" "MD5 хеш совпадает"
has "предупреждение KeenKit о загрузчике" "$out" "Обновление загрузчика опасная процедура"
hasnt "без YES-запроса для своей модели" "$out" "не совпадает с моделью"
hasnt "n — запись не выполнена" "$out" "WRITE_AARCH64"
out=$(flow "$P" athena aarch64 TR3000 '1\n1\ny\n')
has "y — запись Athena через keenboot_writer" "$out" "WRITE_AARCH64 $W/storage/Athena_Cudy_TR3000_r41.bin"
has "y — сообщение об успехе" "$out" "Загрузчик успешно обновлён"
out=$(flow "$P" athena mipsel TR3000 '1\n')
has "mipsel: п.9 недоступен" "$out" "Athena доступна только для MT7981 (aarch64)"
eq "mipsel: сеть не трогается" "$(cat "$W/log")" ""

echo "== выбор версии Athena"
out=$(flow "$P" athena aarch64 TR3000 '3\n2\n1\nn\n')
has "несколько версий: меню" "$out" "Версии Athena для Multi_TR3000"
has "несколько версий: список" "$out" "2. r41"
has "выбрана r41" "$(cat "$W/log")" "https://osv/files/athena/Multi_TR3000/r41/ "
hasnt "r40 не открыта" "$(cat "$W/log")" "Multi_TR3000/r40/ "
out=$(flow "$P" athena aarch64 TR3000 '3\n9\nx\n1\n1\nn\n')
has "неверный номер версии -> повтор" "$out" "Неверный выбор. Выберите от 1 до 2."
has "после повтора выбрана r40" "$(cat "$W/log")" "https://osv/files/athena/Multi_TR3000/r40/ "
out=$(flow "$P" athena aarch64 TR3000 '3\n00\n')
has "00 в выборе версии -> главное меню" "$out" "MAIN_MENU"

echo "== защита модели (п.9)"
out=$(flow "$P" athena aarch64 TR3000 '2\nno\n')
has "чужая модель: предупреждение" "$out" "не совпадает с моделью роутера: TR3000"
has "чужая модель: отказ" "$out" "EXIT_FUNCTION"
hasnt "чужая модель: каталог не открыт" "$(cat "$W/log")" "Xiaomi_AX3000T/ "
out=$(flow "$P" athena aarch64 TR3000 '2\nyes\n')
hasnt "чужая модель: «yes» строчными не принимается" "$(cat "$W/log")" "Xiaomi_AX3000T/ "
out=$(flow "$P" athena aarch64 TR3000 '2\nYES\n1\nn\n')
has "чужая модель: YES — продолжить" "$(cat "$W/log")" "https://osv/files/athena/Xiaomi_AX3000T/r41/ "
out=$(flow "$P" athena aarch64 RAX3000ME '4\n1\nn\n')
hasnt "RAX3000Me -> CMCC_RAX3000M без YES (как в wiki Athena)" "$out" "не совпадает с моделью"
has "RAX3000Me -> r41" "$(cat "$W/log")" "https://osv/files/athena/CMCC_RAX3000M/r41/ "
out=$(flow "$P" athena aarch64 RAX3000ME '1\nno\n')
has "RAX3000Me -> Cudy_TR3000: требует YES" "$out" "не совпадает с моделью роутера: RAX3000ME"
out=$(flow "$P" athena aarch64 RAX3000M '4\n1\nn\n')
hasnt "RAX3000M -> CMCC_RAX3000M без YES" "$out" "не совпадает с моделью"
out=$(flow "$P" athena aarch64 "" '1\nno\n')
has "модель неизвестна -> подтверждение" "$out" "неизвестна"
hasnt "модель неизвестна: каталог не открыт" "$(cat "$W/log")" "Cudy_TR3000/ "

echo "== п.5 и п.8 без изменений (сравнение с оригиналом)"
same_flow() { # same_flow <название> <mode> <arch> <ввод>
  flow "$O" "$2" "$3" TR3000 "$4" >"$W/o_out"
  cp "$W/log" "$W/o_log"
  flow "$P" "$2" "$3" TR3000 "$4" >"$W/p_out"
  if cmp -s "$W/log" "$W/o_log" && cmp -s "$W/p_out" "$W/o_out"; then
    ok "$1: идентично оригиналу (запросы и вывод)"
  else
    bad "$1: идентично оригиналу (запросы и вывод)" "$(diff "$W/o_log" "$W/log"; diff "$W/o_out" "$W/p_out")"
  fi
}
same_flow "п.8 aarch64" keenboot aarch64 '1\n1\nn\n'
has "п.8 aarch64: /files/keenboot/aarch64" "$(cat "$W/log")" "https://osv/files/keenboot/aarch64 "
same_flow "п.8 aarch64, запись" keenboot aarch64 '1\n1\ny\n'
same_flow "п.8 mipsel" keenboot mipsel '1\n1\nn\n'
same_flow "п.5" firmware aarch64 '1\n1\nn\n'

echo "== меню"
grep -q '^    \[ "\$arch" != "aarch64" \] || echo "9. Athena OTA Update" # athena-patch$' "$PATCHED_KK" && ok "п.9 в меню только для aarch64" || bad "п.9 в меню только для aarch64"
grep -q '^    9) ota_update "athena" ;; # athena-patch$' "$PATCHED_KK" && ok "обработчик 9)" || bad "обработчик 9)"
grep -q '^    8) ota_update "keenboot" ;;$' "$PATCHED_KK" && ok "обработчик 8) без изменений" || bad "обработчик 8) без изменений"

echo "== шапка: версия загрузчика"
pbv() { $SH -c ". \"$1\"; parse_bootloader_version \"\$(printf '%b' \"\$2\")\"" _ "$2" "$3"; }
eq "Athena r41" "$(pbv "$P" x "foo\n2.14.0_athena-r41\nU-Boot phase")" "Athena r41 (2.14.0)"
eq "KeenBOOT без изменений" "$(pbv "$P" x "Version: (KB-41 [54e0ab3])")" "KeenBOOT KB-41 [54e0ab3]"
eq "U-Boot без изменений" "$(pbv "$P" x "U-Boot 2025.07-rev-3")" "$(pbv "$O" x "U-Boot 2025.07-rev-3")"
eq "оригинал показывал «U-Boot phase»" "$(pbv "$O" x "foo\n2.14.0_athena-r41\nU-Boot phase")" "U-Boot phase"

rm -rf "$W"
echo
echo "Итого: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
