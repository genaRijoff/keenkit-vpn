#!/bin/sh
# Тесты kvn в изолированном корне (KVN_ROOT) с поддельными curl, /sys/class/net и KeenKit.
# shellcheck disable=SC2015,SC2016  # ok/bad всегда возвращают 0; $(...) в тесте конфига — намеренно литерал
# Запуск: sh tests/run.sh [путь к kvn]   (рекомендуется: busybox sh tests/run.sh)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
KVN=${1:-$HERE/../kvn}
INSTALL=${INSTALL:-$HERE/../install.sh}
SH=${TEST_SH:-sh}
PASS=0
FAIL=0
T=""

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "нет «$3» в: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "лишнее «$3» в: $2" ;; *) ok "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "ожидалось «$3», получено «$2»"; fi; }

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/opt/bin" "$T/opt/etc" "$T/tmp" "$T/sys/class/net/nwg0" "$T/sys/class/net/nwg1" "$T/sys/class/net/eth0"
  touch "$T/dead_direct"
  cp "$KVN" "$T/opt/bin/kvn"
  # Поддельный curl: пишет аргументы в лог; $T/dead_<iface> — канал мёртв (dead_direct — без туннеля),
  # $T/dead_fw — osvault недоступен. По умолчанию провайдер блокирует (dead_direct)
  cat >"$T/opt/bin/curl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/curl.log"
case "\$*" in
*"--interface "*)
  i=\$(echo "\$*" | sed 's/.*--interface \([^ ]*\).*/\1/')
  [ -f "$T/dead_\$i" ] && { printf PARTIAL; exit 56; }
  ;;
*127.0.0.1*) ;;
*) [ -f "$T/dead_direct" ] && { printf PARTIAL; exit 7; } ;;
esac
case "\$*" in */404*) exit 22 ;; esac
case "\$*" in */body*) echo BODY; exit 0 ;; esac
case "\$*" in *osvault/*) [ -f "$T/dead_fw" ] && { case "\$*" in *http_code*) printf 000 ;; esac; exit 7; } ;; esac
case "\$*" in *ipify*) echo 203.0.113.9; exit 0 ;; esac
case "\$*" in *http_code*) printf 200 ;; esac
exit 0
EOF
  chmod +x "$T/opt/bin/curl"
  # Поддельный KeenKit: маркеры совместимости и типовые вызовы п.5/п.8/RCI
  cat >"$T/opt/keenkit.sh" <<EOF
#!/bin/sh
SCRIPT_VERSION="2.9.2"
# ota_path="/files/keenboot/\$arch"
# printf 'domain="%s"\n' "\$domain" > "\$CONFIG_FILE"
echo "KK IFACES=\$KK_IFACES"
D=\$(sed -n 's/^domain="\(.*\)"\$/\1/p' "$T/opt/etc/KeenKit.conf")
curl -s "http://127.0.0.1:79/rci/show/version"
curl -fLs --basic "\$D/osvault"
curl -fLs --basic "\$D/files/keenboot/aarch64" -I
curl -fLs --basic "\$D/files/keenboot/aarch64/KB-51/KeenBOOT TR3000.bin" --output "/tmp/a b.bin"
EOF
  : >"$T/curl.log"
}

run() { KVN_ROOT="$T" PATH="$T/opt/bin:$PATH" $SH "$T/opt/bin/kvn" "$@" 2>&1; }
teardown() { rm -rf "$T"; }

echo "== запуск через nwg0"
setup
out=$(run)
eq "код возврата 0" "$?" 0
has "шапка" "$out" "Прошивки: Афина  KeenBOOT: Стас  Интерфейс: nwg0 (резерв: nwg1 напрямую)"
has "KeenKit запущен через nwg0" "$out" "KK IFACES=nwg0 nwg1 direct"
log=$(cat "$T/curl.log")
has "RCI без --interface" "$log" "-s http://127.0.0.1:79/rci/show/version"
hasnt "RCI не через туннель" "$log" "--interface nwg0 -s http://127.0.0.1"
has "п.5 -> Афина через nwg0" "$log" "--interface nwg0 -fLs --basic https://osvault.project-athens.com/osvault"
has "п.8 листинг -> Стас" "$log" "--interface nwg0 -fLs --basic https://spatiumstas.github.io/KeenKit/files/keenboot/aarch64 -I"
has "п.8 файл с пробелом -> Стас" "$log" "https://spatiumstas.github.io/KeenKit/files/keenboot/aarch64/KB-51/KeenBOOT TR3000.bin --output /tmp/a b.bin"
eq "KeenKit.conf записан" "$(cat "$T/opt/etc/KeenKit.conf")" 'domain="https://osvault.project-athens.com"'
[ -x "$T/opt/lib/kvn/curl" ] && ok "обёртка установлена" || bad "обёртка установлена"
m1=$(ls -l --time-style=+%s%N "$T/opt/lib/kvn/curl" 2>/dev/null || stat -c %Y "$T/opt/lib/kvn/curl")
sleep 1
run >/dev/null
m2=$(ls -l --time-style=+%s%N "$T/opt/lib/kvn/curl" 2>/dev/null || stat -c %Y "$T/opt/lib/kvn/curl")
eq "обёртка не перезаписывается без изменений" "$m2" "$m1"
teardown

echo "== отказоустойчивость"
setup
touch "$T/dead_nwg0"
out=$(run)
has "nwg0 мёртв -> предупреждение" "$out" "nwg0: нет доступа к KeenBOOT (Стас)"
has "переключение на nwg1" "$out" "Интерфейс: nwg1"
rm "$T/dead_nwg0"; touch "$T/dead_fw"
out=$(run); rc=$?
has "osvault недоступен -> причина" "$out" "нет доступа к прошивкам (Афина)"
eq "все каналы без osvault -> rc=1" "$rc" 1
rm "$T/dead_fw"
out=$(run nwg7); rc=$?
has "несуществующий интерфейс" "$out" "Интерфейс nwg7 не найден"
eq "rc=1" "$rc" 1
out=$(run 'nwg0;id'); rc=$?
eq "инъекция в имени интерфейса -> rc=1" "$rc" 1
hasnt "id не выполнен" "$out" "uid="
teardown

echo "== конфиг"
setup
run check >/dev/null
[ -f "$T/opt/etc/kvn.conf" ] && ok "конфиг создан" || bad "конфиг создан"
eq "права 600" "$(stat -c %a "$T/opt/etc/kvn.conf")" 600
printf 'IFACES="nwg1"\nPROBE_URL="https://x/"\n' >"$T/opt/etc/kvn.conf"
out=$(run)
has "старый конфиг (PROBE_URL) принят, IFACES применён" "$out" "Интерфейс: nwg1"
hasnt "PROBE_URL без предупреждения" "$out" "неизвестный параметр"
printf 'IFACES="nwg0"\nFW_LABEL="$(touch %s/pwned)"\n' "$T" >"$T/opt/etc/kvn.conf"
out=$(run); rc=$?
eq "подстановка команды в конфиге -> rc=1" "$rc" 1
[ -e "$T/pwned" ] && bad "конфиг не исполняется" || ok "конфиг не исполняется"
printf 'IFACES="nwg0"\nFW_DOMAIN="https://a.b/"\n' >"$T/opt/etc/kvn.conf"
out=$(run); rc=$?
has "слеш в конце домена" "$out" "FW_DOMAIN: нужен"
printf 'IFACES="nwg0 bad;name"\n' >"$T/opt/etc/kvn.conf"
out=$(run); rc=$?
has "плохое имя в IFACES" "$out" "недопустимое имя интерфейса"
printf 'IFACES="nwg0"\nFOO="1"\n' >"$T/opt/etc/kvn.conf"
out=$(run)
has "неизвестный ключ -> предупреждение" "$out" "неизвестный параметр «FOO»"
teardown

echo "== совместимость с KeenKit"
setup
sed -i '/ota_path/d' "$T/opt/keenkit.sh"
out=$(run)
has "изменённый KeenKit -> предупреждение" "$out" "структура OTA изменилась"
out=$(run check)
has "check показывает несовместимость" "$out" "нужна проверка kvn"
teardown
setup
out=$(run check)
has "check: версия KeenKit" "$out" "KeenKit: 2.9.2 OK"
has "check: конфиг KeenKit ещё не задан" "$out" "не задан"
has "check: строка канала" "$out" "nwg0 (203.0.113.9): KeenBOOT"
hasnt "check: eth0 не в IFACES" "$out" "eth0 ("
teardown

echo "== athena-patch 0.0.4+: отдельный п.9"
setup
sed -i 's|^SCRIPT_VERSION=.*|&\nATHENA_PATCH="0.0.4"\n    9) ota_update "athena" ;; # athena-patch|' "$T/opt/keenkit.sh"
export KVN_ARCH=aarch64
out=$(run)
has "п.9: шапка KeenBOOT Стас + Athena п.9" "$out" "KeenBOOT: Стас  Athena: п.9  Интерфейс: nwg0"
has "п.9: канал проверяется по Pages (KeenBOOT)" "$(cat "$T/curl.log")" "--interface nwg0 -o /dev/null https://spatiumstas.github.io/KeenKit/"
out=$(run check)
has "check: п.9" "$out" "Athena-патч: 0.0.4 (п.9 -> Athena, https://osvault.project-athens.com/files/athena)"
has "check: KeenBOOT Стас" "$out" "KeenBOOT (Стас): https://spatiumstas.github.io/KeenKit"
export KVN_ARCH=mipsel
out=$(run)
hasnt "mipsel: без Athena в шапке" "$out" "Athena: п.9"
out=$(run check)
has "mipsel: Athena недоступна" "$out" "mipsel: Athena недоступна"
unset KVN_ARCH
teardown

echo "== athena-patch 0.0.2–0.0.3: Athena в п.8"
setup
sed -i 's|^SCRIPT_VERSION=.*|&\nATHENA_PATCH="0.0.3"\n    [ "$arch" != "aarch64" ] \|\| ota_path="/files/athena" # athena-patch|' "$T/opt/keenkit.sh"
export KVN_ARCH=aarch64
out=$(run)
has "aarch64 + патч: шапка KeenBOOT Афина" "$out" "KeenBOOT: Афина"
has "aarch64 + патч: проверка канала по /files/athena" "$(cat "$T/curl.log")" "--interface nwg0 -o /dev/null https://osvault.project-athens.com/files/athena/"
hasnt "aarch64 + патч: Pages не проверяется" "$(grep -- '-o /dev/null' "$T/curl.log")" "spatiumstas.github.io"
out=$(run check)
has "check: строка патча" "$out" "Athena-патч: 0.0.3 (п.8 -> Athena; обнови: athena-patch)"
has "check: источник KeenBOOT" "$out" "KeenBOOT (Афина): https://osvault.project-athens.com/files/athena"
export KVN_ARCH=mipsel
out=$(run)
has "mipsel + патч: KeenBOOT Стас" "$out" "KeenBOOT: Стас"
out=$(run check)
has "mipsel + патч: Athena недоступна" "$out" "mipsel: Athena недоступна"
unset KVN_ARCH
teardown
setup
sed -i 's|^# ota_path=.*|    ota_path="/files/athena"|' "$T/opt/keenkit.sh"
out=$(run)
has "патч v1: предупреждение" "$out" "старым патчем Athena v1"
out=$(run check)
has "check: патч v1" "$out" "старый патч Athena v1"
teardown

echo "== каналы: direct, auto, миграция"
setup
rm -f "$T/dead_direct"
out=$(run)
has "провайдер не блокирует: напрямую, туннели в резерве" "$out" "Интерфейс: напрямую (резерв: nwg0 nwg1)"
grep -qx -- '-fLs --basic https://osvault.project-athens.com/osvault' "$T/curl.log" && ok "напрямую: запрос без --interface" || bad "напрямую: запрос без --interface" "$(cat "$T/curl.log")"
mkdir -p "$T/sys/class/net/wg5" "$T/sys/class/net/awg0" "$T/sys/class/net/nawg1" "$T/sys/class/net/mitun0"
out=$(run check)
has "auto: порядок wg/nwg -> awg/nawg -> mitun" "$out" "Порядок каналов: напрямую -> nwg0 -> nwg1 -> wg5 -> awg0 -> nawg1 -> mitun0"
has "check: строка mitun0" "$out" "mitun0 (203.0.113.9)"
out=$(run direct)
has "kvn direct: без резерва" "$out" "Интерфейс: напрямую"
hasnt "kvn direct: резерв не добавляется" "$out" "резерв"
out=$(run nwg1)
has "kvn nwg1: только nwg1" "$out" "Интерфейс: nwg1"
hasnt "kvn nwg1: без резерва" "$out" "резерв"
touch "$T/dead_direct"
out=$(run direct); rc=$?
eq "kvn direct при блокировке: rc=1" "$rc" 1
has "kvn direct при блокировке: причина" "$out" "напрямую: нет доступа к KeenBOOT"
teardown

setup
printf 'IFACES="nwg0 nwg1 nwg2"\nFW_LABEL="Афина"\n' >"$T/opt/etc/kvn.conf"
out=$(run check)
has "миграция старого значения по умолчанию" "$out" "IFACES «nwg0 nwg1 nwg2» -> «direct auto»"
eq "миграция: конфиг обновлён" "$(cat "$T/opt/etc/kvn.conf")" "$(printf 'IFACES="direct auto"\nFW_LABEL="Афина"')"
eq "миграция: права 600" "$(stat -c %a "$T/opt/etc/kvn.conf")" 600
printf 'IFACES="nwg1 nwg0"\n' >"$T/opt/etc/kvn.conf"
out=$(run check)
hasnt "своё значение IFACES не трогается" "$out" "direct auto"
eq "своё значение IFACES сохранено" "$(cat "$T/opt/etc/kvn.conf")" 'IFACES="nwg1 nwg0"'
teardown

echo "== переключение канала на лету (обёртка)"
setup
run >/dev/null
W="$T/opt/lib/kvn/curl"
wrap() { KK_IFACES="$1" KK_STATE="$T/tmp/state" KK_REAL="$T/opt/bin/curl" $SH "$W" "$2" 2>"$T/err"; }
mkdir -p "$T/tmp"
: >"$T/curl.log"
touch "$T/dead_nwg0"
out=$(wrap "nwg0 nwg1" "https://x/body"); rc=$?
eq "отказ nwg0 -> ответ через nwg1: rc=0" "$rc" 0
eq "в выводе нет мусора от упавшей попытки" "$out" "BODY"
has "сообщение о переключении" "$(cat "$T/err")" "kvn: nwg0 не отвечает (curl 56), повтор через следующий канал"
eq "попытки по порядку" "$(grep -o -- '--interface nwg[0-9]' "$T/curl.log" | tr '\n' ' ')" "--interface nwg0 --interface nwg1 "
eq "запомнен удачный канал" "$(cat "$T/tmp/state")" "nwg1"
: >"$T/curl.log"
rm -f "$T/dead_nwg0"
out=$(wrap "nwg0 nwg1" "https://x/body")
has "следующий запрос сразу через запомненный канал" "$(head -n 1 "$T/curl.log")" "--interface nwg1"
: >"$T/curl.log"
out=$(wrap "nwg0 nwg1" "https://x/404"); rc=$?
eq "ответ сервера (404): rc curl сохранён" "$rc" 22
eq "ответ сервера: без повтора через другие каналы" "$(wc -l <"$T/curl.log" | tr -d ' ')" 1
touch "$T/dead_nwg0" "$T/dead_nwg1"
rm -f "$T/tmp/state"
out=$(wrap "nwg0 nwg1" "https://x/body"); rc=$?
eq "все каналы мертвы: rc последней попытки" "$rc" 56
eq "все каналы мертвы: подсказка только между попытками" "$(grep -c 'повтор через следующий канал' "$T/err")" 1
[ ! -e "$T/tmp/state" ] && ok "неудача не запоминается" || bad "неудача не запоминается"
rm -f "$T/dead_nwg0" "$T/dead_nwg1"
: >"$T/curl.log"
out=$(wrap "direct nwg0" "https://x/body")
eq "direct: первая попытка без --interface" "$(head -n 1 "$T/curl.log")" "https://x/body"
: >"$T/curl.log"
rm -f "$T/tmp/state"
out=$(wrap "direct nwg0" "https://x/body")
has "direct заблокирован -> nwg0" "$(cat "$T/curl.log")" "--interface nwg0 https://x/body"
has "подсказка для direct" "$(cat "$T/err")" "kvn: напрямую не отвечает"
: >"$T/curl.log"
out=$(KK_IFACES="nwg0" KK_REAL="$T/opt/bin/curl" $SH "$W" -s "http://127.0.0.1:79/rci/show/version")
eq "RCI: без --interface и без повторов" "$(cat "$T/curl.log")" "-s http://127.0.0.1:79/rci/show/version"
n=0; for f in "${TMPDIR:-/tmp}"/kvn-out.* "${TMPDIR:-/tmp}"/kvn-err.*; do [ -e "$f" ] && n=$((n + 1)); done
eq "временные файлы обёртки удалены" "$n" 0
teardown

echo "== обёртка без kvn"
setup
run >/dev/null
: >"$T/curl.log"
KK_REAL="$T/opt/bin/curl" $SH "$T/opt/lib/kvn/curl" -fLs https://osvault.project-athens.com/files/keenboot/x
eq "без KK_IFACE аргументы не меняются" "$(cat "$T/curl.log")" "-fLs https://osvault.project-athens.com/files/keenboot/x"
teardown

echo "== прочее"
setup
eq "--version" "$(run -V)" "0.0.7"
out=$(run --bad); rc=$?
eq "неизвестный параметр -> rc=1" "$rc" 1
out=$(echo n | run uninstall)
[ -f "$T/opt/bin/kvn" ] && ok "uninstall: n ничего не удаляет" || bad "uninstall: n ничего не удаляет"
run >/dev/null
out=$(echo y | run uninstall)
[ ! -e "$T/opt/bin/kvn" ] && [ ! -e "$T/opt/lib/kvn" ] && [ ! -e "$T/opt/etc/kvn.conf" ] &&
  ok "uninstall: y удаляет всё" || bad "uninstall: y удаляет всё"
[ -f "$T/opt/etc/KeenKit.conf" ] && ok "uninstall: KeenKit.conf сохранён" || bad "uninstall: KeenKit.conf сохранён"
teardown

echo "== install.sh"
inst_setup() {
  setup
  rm -f "$T/opt/bin/kvn"
  # curl для установщика: отдаёт файл из $T/src (режимы: ok, html, broken, fail)
  cat >"$T/opt/bin/curl" <<EOF
#!/bin/sh
echo "\$*" >>"$T/curl.log"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
case "\$(cat "$T/mode")" in
ok) cp "$T/src" "\$out" ;;
html) echo "<html>404</html>" >"\$out" ;;
broken) head -n 120 "$T/src" >"\$out" ;;
fail) exit 22 ;;
esac
EOF
  chmod +x "$T/opt/bin/curl"
  cp "$KVN" "$T/src"
}
inst() { KVN_ROOT="$T" $SH "$INSTALL" "$@" 2>&1; }

inst_setup; echo ok >"$T/mode"
out=$(inst); rc=$?
eq "установка: rc=0" "$rc" 0
has "установка: сообщение" "$out" "kvn $(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$KVN") установлен"
cmp -s "$T/opt/bin/kvn" "$KVN" && ok "установка: файл идентичен" || bad "установка: файл идентичен"
[ -x "$T/opt/bin/kvn" ] && ok "установка: исполняемый" || bad "установка: исполняемый"
hasnt "установка: без --interface по умолчанию" "$(cat "$T/curl.log")" "--interface"
out=$(inst); has "повтор: обновление" "$out" "kvn обновлён:"
: >"$T/curl.log"; inst nwg0 >/dev/null
has "через интерфейс" "$(cat "$T/curl.log")" "--interface nwg0"
out=$(inst nwg9); rc=$?; eq "нет интерфейса: rc=1" "$rc" 1
out=$(inst 'nwg0;id'); rc=$?; eq "инъекция в интерфейс: rc=1" "$rc" 1
teardown

for mode in html broken fail; do
  inst_setup; echo "$mode" >"$T/mode"; echo OLD >"$T/opt/bin/kvn"
  out=$(inst); rc=$?
  eq "$mode: rc=1" "$rc" 1
  eq "$mode: старый kvn сохранён" "$(cat "$T/opt/bin/kvn")" OLD
  n=0; for f in "$T"/opt/bin/*.new.*; do [ -e "$f" ] && n=$((n + 1)); done
  eq "$mode: временных файлов нет" "$n" 0
  teardown
done

inst_setup; echo ok >"$T/mode"
mkdir -p "$T/opt/lib/keenkit-vpn"; touch "$T/opt/bin/keenkit-vpn"; printf 'IFACES="nwg1"\n' >"$T/opt/etc/keenkit-vpn.conf"
inst >/dev/null
eq "миграция конфига keenkit-vpn" "$(cat "$T/opt/etc/kvn.conf")" 'IFACES="nwg1"'
[ ! -e "$T/opt/bin/keenkit-vpn" ] && [ ! -e "$T/opt/lib/keenkit-vpn" ] && ok "старые файлы удалены" || bad "старые файлы удалены"
teardown

echo
echo "Итого: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
