#!/bin/sh
# Тесты keenkit-vpn (лаунчер /opt/bin/keenkit и install.sh) в изолированном корне
# (KEENKIT_VPN_ROOT) с поддельными curl, /sys/class/net и KeenKit.
# shellcheck disable=SC2015,SC2016  # ok/bad всегда возвращают 0; $(...) в тесте конфига — намеренно литерал
# Запуск: sh tests/run.sh [путь к keenkit]   (рекомендуется: TEST_SH="busybox sh" sh tests/run.sh)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LAUNCHER=${1:-$HERE/../keenkit}
INSTALL=${INSTALL:-$HERE/../install.sh}
SH=${TEST_SH:-sh}
VER=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$LAUNCHER")
PASS=0
FAIL=0
T=""

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "нет «$3» в: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "лишнее «$3» в: $2" ;; *) ok "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "ожидалось «$3», получено «$2»"; fi; }
logline() { grep -qxF -- "$2" "$T/curl.log" && ok "$1" || bad "$1" "нет строки «$2» в журнале:
$(cat "$T/curl.log")"; }
nologline() { grep -qxF -- "$2" "$T/curl.log" && bad "$1" "лишняя строка «$2»" || ok "$1"; }

# Поддельный curl: пишет аргументы в журнал.
#   $T/dead_<iface> — канал мёртв (dead_direct — без туннеля), $T/dead_fw — osvault недоступен.
# По умолчанию провайдер блокирует (dead_direct).
fake_curl() {
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
}

# Поддельный KeenKit: маркеры совместимости и типовые вызовы п.5/п.8/RCI
fake_keenkit() {
  cat >"$T/opt/keenkit.sh" <<EOF
#!/bin/sh
SCRIPT_VERSION="2.9.2"
# ota_path="/files/keenboot/\$arch"
# printf 'domain="%s"\n' "\$domain" > "\$CONFIG_FILE"
echo "KK ARGS=\$*"
echo "KK IFACES=\${KK_IFACES:-}"
D=\$(sed -n 's/^domain="\(.*\)"\$/\1/p' "$T/opt/etc/KeenKit.conf" 2>/dev/null)
curl -s "http://127.0.0.1:79/rci/show/version"
curl -fLs --basic "\$D/osvault"
curl -fLs --basic "\$D/files/keenboot/aarch64" -I
curl -fLs --basic "\$D/files/keenboot/aarch64/KB-51/KeenBOOT TR3000.bin" --output "/tmp/a b.bin"
EOF
}

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/opt/bin" "$T/opt/etc" "$T/tmp" "$T/sys/class/net/nwg0" "$T/sys/class/net/nwg1" "$T/sys/class/net/eth0"
  touch "$T/dead_direct"
  cp "$LAUNCHER" "$T/opt/bin/keenkit"
  fake_curl
  fake_keenkit
  : >"$T/curl.log"
}
teardown() { rm -rf "$T"; }
run() { KEENKIT_VPN_ROOT="$T" PATH="$T/opt/bin:$PATH" $SH "$T/opt/bin/keenkit" "$@" 2>&1; }
ext_log() { grep -v '127.0.0.1' "$T/curl.log"; }

echo "== запуск keenkit (провайдер блокирует, туннели есть)"
setup
out=$(run)
eq "код возврата 0" "$?" 0
has "шапка" "$out" "Прошивки: Афина  KeenBOOT: Стас  Каналы: напрямую -> nwg0 -> nwg1"
has "KeenKit запущен с каналами" "$out" "KK IFACES=direct nwg0 nwg1"
hasnt "старт без проверочных запросов" "$(cat "$T/curl.log")" "-o /dev/null"
logline "RCI без --interface" "-s http://127.0.0.1:79/rci/show/version"
logline "п.5: попытка напрямую" "-fLs --basic https://osvault.project-athens.com/osvault"
logline "п.5: повтор через nwg0" "--interface nwg0 -fLs --basic https://osvault.project-athens.com/osvault"
has "сообщение о переключении" "$out" "keenkit-vpn: напрямую не отвечает (curl 7), повтор через следующий канал"
logline "п.8 -> Стас сразу через запомненный nwg0" "--interface nwg0 -fLs --basic https://spatiumstas.github.io/KeenKit/files/keenboot/aarch64 -I"
nologline "п.8: без лишней попытки напрямую" "-fLs --basic https://spatiumstas.github.io/KeenKit/files/keenboot/aarch64 -I"
logline "файл с пробелом в имени" "--interface nwg0 -fLs --basic https://spatiumstas.github.io/KeenKit/files/keenboot/aarch64/KB-51/KeenBOOT TR3000.bin --output /tmp/a b.bin"
eq "запомнен удачный канал" "$(cat "$T/tmp/keenkit-vpn.iface")" "nwg0"
eq "KeenKit.conf записан" "$(cat "$T/opt/etc/KeenKit.conf")" 'domain="https://osvault.project-athens.com"'
[ -x "$T/opt/lib/keenkit-vpn/curl" ] && ok "обёртка установлена" || bad "обёртка установлена"
m1=$(ls -l --time-style=+%s%N "$T/opt/lib/keenkit-vpn/curl" 2>/dev/null || stat -c %Y "$T/opt/lib/keenkit-vpn/curl")
sleep 1
: >"$T/curl.log"
out=$(run)
m2=$(ls -l --time-style=+%s%N "$T/opt/lib/keenkit-vpn/curl" 2>/dev/null || stat -c %Y "$T/opt/lib/keenkit-vpn/curl")
eq "обёртка не перезаписывается без изменений" "$m2" "$m1"
eq "повторный запуск: первый запрос через запомненный канал" "$(ext_log | head -n 1)" "--interface nwg0 -fLs --basic https://osvault.project-athens.com/osvault"
out=$(run script_update)
has "аргументы передаются KeenKit" "$out" "KK ARGS=script_update"
teardown

echo "== прямой доступ работает"
setup
rm -f "$T/dead_direct"
out=$(run)
logline "п.5 напрямую" "-fLs --basic https://osvault.project-athens.com/osvault"
nologline "туннель не используется" "--interface nwg0 -fLs --basic https://osvault.project-athens.com/osvault"
eq "запомнен direct" "$(cat "$T/tmp/keenkit-vpn.iface")" "direct"
hasnt "без сообщений о переключении" "$out" "не отвечает"
teardown

echo "== --iface"
setup
out=$(run --iface nwg1)
has "--iface nwg1: только nwg1" "$out" "KK IFACES=nwg1"
has "--iface nwg1: шапка" "$out" "Каналы: nwg1"
out=$(run --iface nwg1 script_update)
has "--iface: аргументы KeenKit после канала" "$out" "KK ARGS=script_update"
out=$(run --iface direct)
has "--iface direct" "$out" "KK IFACES=direct"
out=$(run --iface nwg7); rc=$?
eq "--iface nwg7: rc=1" "$rc" 1
has "--iface nwg7: причина" "$out" "Интерфейс nwg7 не найден"
out=$(run --iface 'nwg0;id'); rc=$?
eq "--iface с инъекцией: rc=1" "$rc" 1
hasnt "--iface с инъекцией: id не выполнен" "$out" "uid="
out=$(run --iface); rc=$?
eq "--iface без значения: rc=1" "$rc" 1
teardown

echo "== сбои keenkit-vpn не мешают запуску KeenKit"
setup
printf 'FW_DOMAIN="https://a.b/"\n' >"$T/opt/etc/keenkit-vpn.conf"
out=$(run)
has "ошибка в настройках: KeenKit всё равно запущен" "$out" "KK ARGS="
has "ошибка в настройках: предупреждение" "$out" "ошибка в $T/opt/etc/keenkit-vpn.conf"
has "ошибка в настройках: запуск без каналов" "$out" "KK IFACES="
hasnt "ошибка в настройках: без шапки каналов" "$out" "Каналы:"
teardown
setup
printf 'IFACES="nwg9"\n' >"$T/opt/etc/keenkit-vpn.conf"
out=$(run)
has "нет ни одного интерфейса из IFACES -> напрямую" "$out" "KK IFACES=direct"
has "нет интерфейсов: предупреждение" "$out" "только напрямую"
teardown
setup
mv "$T/opt/bin/curl" "$T/realcurl"
out=$(KEENKIT_VPN_ROOT="$T" PATH="$T/opt/bin:/usr/bin:/bin" $SH "$T/opt/bin/keenkit" 2>&1)
has "нет curl: KeenKit запущен без выбора канала" "$out" "KK ARGS="
has "нет curl: предупреждение" "$out" "без выбора канала"
teardown
setup
rm -f "$T/opt/keenkit.sh"
out=$(run); rc=$?
eq "KeenKit не установлен: rc=1" "$rc" 1
has "KeenKit не установлен: причина" "$out" "KeenKit не установлен"
teardown

echo "== настройки"
setup
run --check >/dev/null
[ -f "$T/opt/etc/keenkit-vpn.conf" ] && ok "конфиг создан" || bad "конфиг создан"
eq "права 600" "$(stat -c %a "$T/opt/etc/keenkit-vpn.conf")" 600
has "по умолчанию direct auto" "$(cat "$T/opt/etc/keenkit-vpn.conf")" 'IFACES="direct auto"'
teardown
setup
printf 'IFACES="nwg1"\n' >"$T/opt/etc/kvn.conf"
out=$(run)
has "kvn.conf переносится" "$out" "Настройки перенесены"
has "kvn.conf: значение применено" "$out" "KK IFACES=nwg1"
[ ! -e "$T/opt/etc/kvn.conf" ] && ok "kvn.conf удалён после переноса" || bad "kvn.conf удалён после переноса"
teardown
setup
printf 'IFACES="nwg1"\nPROBE_URL="https://x/"\n' >"$T/opt/etc/keenkit-vpn.conf"
out=$(run)
has "старый ключ PROBE_URL принимается" "$out" "KK IFACES=nwg1"
hasnt "PROBE_URL без предупреждения" "$out" "неизвестный параметр"
printf 'IFACES="nwg0"\nFW_LABEL="$(touch %s/pwned)"\n' "$T" >"$T/opt/etc/keenkit-vpn.conf"
out=$(run --check); rc=$?
eq "подстановка команды в конфиге: --check rc=1" "$rc" 1
out=$(run)
[ -e "$T/pwned" ] && bad "конфиг не исполняется" || ok "конфиг не исполняется"
printf 'IFACES="nwg0 bad;name"\n' >"$T/opt/etc/keenkit-vpn.conf"
out=$(run --check)
has "плохое имя в IFACES" "$out" "недопустимое имя интерфейса"
printf 'IFACES="nwg0"\nFOO="1"\n' >"$T/opt/etc/keenkit-vpn.conf"
out=$(run)
has "неизвестный ключ -> предупреждение" "$out" "неизвестный параметр «FOO»"
printf 'IFACES="nwg0 nwg1 nwg2"\nFW_LABEL="Афина"\n' >"$T/opt/etc/keenkit-vpn.conf"
out=$(run --check)
has "старое значение по умолчанию -> direct auto" "$out" "IFACES «nwg0 nwg1 nwg2» -> «direct auto»"
eq "миграция: конфиг обновлён" "$(cat "$T/opt/etc/keenkit-vpn.conf")" "$(printf 'IFACES="direct auto"\nFW_LABEL="Афина"')"
printf 'IFACES="nwg1 nwg0"\n' >"$T/opt/etc/keenkit-vpn.conf"
out=$(run --check)
eq "своё значение IFACES не трогается" "$(cat "$T/opt/etc/keenkit-vpn.conf")" 'IFACES="nwg1 nwg0"'
teardown

echo "== --check"
setup
mkdir -p "$T/sys/class/net/wg5" "$T/sys/class/net/awg0" "$T/sys/class/net/nawg1" "$T/sys/class/net/mitun0"
out=$(run --check)
has "версия" "$out" "keenkit-vpn $VER"
has "KeenKit OK" "$out" "KeenKit: 2.9.2 OK"
has "KeenKit.conf ещё не задан" "$out" "не задан"
has "auto: порядок wg/nwg -> awg/nawg -> mitun" "$out" "Порядок каналов: напрямую -> nwg0 -> nwg1 -> wg5 -> awg0 -> nawg1 -> mitun0"
has "строка канала" "$out" "mitun0 (203.0.113.9): KeenBOOT"
hasnt "eth0 не в каналах" "$out" "eth0 ("
hasnt "без последнего удачного до запуска" "$out" "Последний удачный"
run >/dev/null
out=$(run --check)
has "последний удачный канал" "$out" "Последний удачный: nwg0"
eq "--vpn-version" "$(run --vpn-version)" "$VER"
has "--vpn-help" "$(run --vpn-help)" "keenkit --iface nwg1"
teardown

echo "== совместимость с KeenKit и athena-patch"
setup
sed -i '/ota_path/d' "$T/opt/keenkit.sh"
out=$(run)
has "изменённый KeenKit -> предупреждение" "$out" "структура OTA изменилась"
has "изменённый KeenKit: всё равно запущен" "$out" "KK ARGS="
out=$(run --check)
has "check показывает несовместимость" "$out" "нужна проверка keenkit-vpn"
teardown
setup
sed -i 's|^# ota_path=.*|    ota_path="/files/athena"|' "$T/opt/keenkit.sh"
out=$(run)
has "патч v1: предупреждение" "$out" "старым патчем Athena v1"
teardown
setup
sed -i 's|^SCRIPT_VERSION=.*|&\nATHENA_PATCH="0.0.4"\n    9) ota_update "athena" ;; # athena-patch|' "$T/opt/keenkit.sh"
export KEENKIT_VPN_ARCH=aarch64
out=$(run)
has "athena 0.0.4: шапка с п.9" "$out" "KeenBOOT: Стас  Athena: п.9  Каналы:"
out=$(run --check)
has "athena 0.0.4: check" "$out" "Athena-патч: 0.0.4 (п.9 -> Athena, https://osvault.project-athens.com/files/athena)"
export KEENKIT_VPN_ARCH=mipsel
out=$(run)
hasnt "mipsel: без п.9 в шапке" "$out" "Athena: п.9"
out=$(run --check)
has "mipsel: Athena недоступна" "$out" "mipsel: Athena недоступна"
unset KEENKIT_VPN_ARCH
teardown
setup
sed -i 's|^SCRIPT_VERSION=.*|&\nATHENA_PATCH="0.0.3"\n    [ "$arch" != "aarch64" ] \|\| ota_path="/files/athena" # athena-patch|' "$T/opt/keenkit.sh"
export KEENKIT_VPN_ARCH=aarch64
out=$(run)
has "athena 0.0.3: KeenBOOT Афина" "$out" "KeenBOOT: Афина"
out=$(run --check)
has "athena 0.0.3: предложение обновить" "$out" "Athena-патч: 0.0.3 (п.8 -> Athena; обнови: athena-patch)"
unset KEENKIT_VPN_ARCH
teardown

echo "== обёртка: переключение канала на лету"
setup
run >/dev/null
W="$T/opt/lib/keenkit-vpn/curl"
wrap() { KK_IFACES="$1" KK_STATE="$T/tmp/state" KK_REAL="$T/opt/bin/curl" $SH "$W" "$2" 2>"$T/err"; }
: >"$T/curl.log"
touch "$T/dead_nwg0"
out=$(wrap "nwg0 nwg1" "https://x/body"); rc=$?
eq "отказ nwg0 -> ответ через nwg1: rc=0" "$rc" 0
eq "в выводе нет мусора от упавшей попытки" "$out" "BODY"
has "сообщение о переключении" "$(cat "$T/err")" "keenkit-vpn: nwg0 не отвечает (curl 56), повтор через следующий канал"
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
has "direct заблокирован -> nwg0" "$(cat "$T/curl.log")" "--interface nwg0 https://x/body"
has "подсказка для direct" "$(cat "$T/err")" "keenkit-vpn: напрямую не отвечает"
printf 'evil;rm\n' >"$T/tmp/state"
: >"$T/curl.log"
out=$(wrap "nwg0 nwg1" "https://x/body")
has "чужое значение в файле состояния игнорируется" "$(head -n 1 "$T/curl.log")" "--interface nwg0"
: >"$T/curl.log"
out=$(KK_IFACES="nwg0" KK_REAL="$T/opt/bin/curl" $SH "$W" -s "http://127.0.0.1:79/rci/show/version")
eq "RCI: без --interface и без повторов" "$(cat "$T/curl.log")" "-s http://127.0.0.1:79/rci/show/version"
: >"$T/curl.log"
KK_REAL="$T/opt/bin/curl" $SH "$W" -fLs https://osvault.project-athens.com/files/keenboot/x >/dev/null
eq "без KK_IFACES аргументы не меняются" "$(cat "$T/curl.log")" "-fLs https://osvault.project-athens.com/files/keenboot/x"
n=0; for f in "${TMPDIR:-/tmp}"/keenkit-vpn-out.* "${TMPDIR:-/tmp}"/keenkit-vpn-err.*; do [ -e "$f" ] && n=$((n + 1)); done
eq "временные файлы обёртки удалены" "$n" 0
teardown

echo "== --vpn-remove"
setup
run >/dev/null
printf 'domain="x"\n' >"$T/opt/etc/KeenKit.conf"
out=$(echo n | run --vpn-remove)
[ -f "$T/opt/bin/keenkit" ] && [ ! -L "$T/opt/bin/keenkit" ] && ok "n: ничего не меняется" || bad "n: ничего не меняется"
out=$(echo y | run --vpn-remove)
[ -L "$T/opt/bin/keenkit" ] && ok "y: keenkit снова симлинк" || bad "y: keenkit снова симлинк"
eq "y: симлинк на /opt/keenkit.sh" "$(readlink "$T/opt/bin/keenkit")" "/opt/keenkit.sh"
[ ! -e "$T/opt/lib/keenkit-vpn" ] && [ ! -e "$T/opt/etc/keenkit-vpn.conf" ] && [ ! -e "$T/tmp/keenkit-vpn.iface" ] &&
  ok "y: обёртка, настройки и состояние удалены" || bad "y: обёртка, настройки и состояние удалены"
eq "y: KeenKit.conf сохранён" "$(cat "$T/opt/etc/KeenKit.conf")" 'domain="x"'
teardown

echo "== install.sh"
inst_setup() {
  setup
  rm -f "$T/opt/bin/keenkit"
  ln -s /opt/keenkit.sh "$T/opt/bin/keenkit"
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
  cp "$LAUNCHER" "$T/src"
}
inst() { KEENKIT_VPN_ROOT="$T" $SH "$INSTALL" "$@" 2>&1; }

inst_setup; echo ok >"$T/mode"
out=$(inst); rc=$?
eq "установка: rc=0" "$rc" 0
has "установка: сообщение" "$out" "keenkit-vpn $VER установлен"
[ -f "$T/opt/bin/keenkit" ] && [ ! -L "$T/opt/bin/keenkit" ] && ok "симлинк заменён лаунчером" || bad "симлинк заменён лаунчером"
cmp -s "$T/opt/bin/keenkit" "$LAUNCHER" && ok "файл идентичен" || bad "файл идентичен"
[ -x "$T/opt/bin/keenkit" ] && ok "исполняемый" || bad "исполняемый"
[ -f "$T/opt/keenkit.sh" ] && ok "KeenKit не тронут" || bad "KeenKit не тронут"
hasnt "без --interface по умолчанию" "$(cat "$T/curl.log")" "--interface"
out=$(inst); has "повтор: обновление" "$out" "keenkit-vpn обновлён: $VER -> $VER"
: >"$T/curl.log"; inst nwg0 >/dev/null
has "через интерфейс" "$(cat "$T/curl.log")" "--interface nwg0"
out=$(inst nwg9); rc=$?; eq "нет интерфейса: rc=1" "$rc" 1
out=$(inst 'nwg0;id'); rc=$?; eq "инъекция в интерфейс: rc=1" "$rc" 1
teardown

for mode in html broken fail; do
  inst_setup; echo "$mode" >"$T/mode"
  out=$(inst); rc=$?
  eq "$mode: rc=1" "$rc" 1
  [ -L "$T/opt/bin/keenkit" ] && ok "$mode: симлинк keenkit не тронут" || bad "$mode: симлинк keenkit не тронут"
  n=0; for f in "$T"/opt/bin/*.new.*; do [ -e "$f" ] && n=$((n + 1)); done
  eq "$mode: временных файлов нет" "$n" 0
  teardown
done

inst_setup; echo ok >"$T/mode"
mkdir -p "$T/opt/lib/kvn"; touch "$T/opt/bin/kvn" "$T/opt/bin/keenkit-vpn"
printf 'IFACES="nwg1"\n' >"$T/opt/etc/kvn.conf"
printf 'IFACES="nwg0 nwg1 nwg2"\n' >"$T/opt/etc/keenkit-vpn.conf"
inst >/dev/null
eq "переход с kvn: настройки kvn.conf" "$(cat "$T/opt/etc/keenkit-vpn.conf")" 'IFACES="nwg1"'
[ ! -e "$T/opt/bin/kvn" ] && [ ! -e "$T/opt/lib/kvn" ] && [ ! -e "$T/opt/bin/keenkit-vpn" ] && [ ! -e "$T/opt/etc/kvn.conf" ] &&
  ok "переход с kvn: старые файлы удалены" || bad "переход с kvn: старые файлы удалены"
teardown

inst_setup; echo ok >"$T/mode"
rm -f "$T/opt/bin/keenkit"; echo "#!/bin/sh" >"$T/opt/bin/keenkit"; echo "echo foreign" >>"$T/opt/bin/keenkit"
out=$(inst)
has "чужой файл keenkit сохраняется" "$out" "сохранён: $T/opt/bin/keenkit.orig-"
n=0; for f in "$T"/opt/bin/keenkit.orig-*; do [ -f "$f" ] && grep -q foreign "$f" && n=$((n + 1)); done
eq "копия чужого файла" "$n" 1
teardown

inst_setup; echo ok >"$T/mode"
rm -f "$T/opt/keenkit.sh"
out=$(inst); rc=$?
eq "без KeenKit: rc=1" "$rc" 1
has "без KeenKit: причина" "$out" "KeenKit не установлен"
[ -L "$T/opt/bin/keenkit" ] && ok "без KeenKit: ничего не изменено" || bad "без KeenKit: ничего не изменено"
teardown

echo
echo "Итого: $PASS ok, $FAIL fail"
[ "$FAIL" -eq 0 ]
