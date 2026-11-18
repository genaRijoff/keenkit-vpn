#!/bin/sh
# shellcheck shell=dash  # целевой shell — BusyBox ash (Keenetic/Entware)
# athena-patch — KeenKit: п.8 «KeenBOOT OTA Update» ставит загрузчик Athena (Project Athens)
# на роутерах MT7981 (aarch64). Прочие архитектуры и п.5 работают как в оригинале.
#
# Использование:
#   athena-patch.sh            применить (то же, что apply)
#   athena-patch.sh apply      применить / обновить патч
#   athena-patch.sh revert     вернуть оригинальный KeenKit из резервной копии
#   athena-patch.sh status     состояние патча
#   athena-patch.sh diff       показать изменения, ничего не меняя
#
# Что меняется в KeenKit:
#   - п.8 на aarch64: каталог /files/athena вместо /files/keenboot/aarch64
#   - вход в единственную вложенную папку модели (Cudy_TR3000/r41/)
#   - защита: папка не совпадает с моделью роутера -> нужно ввести YES
#     (CMCC RAX3000Me = папка CMCC_RAX3000M, как в wiki Athena)
#   - шапка: «Загрузчик: Athena r41 (2.14.0)»
# После «99. Обновить скрипт» в KeenKit патч нужно применить заново.

set -u

PATCH_VERSION="0.0.3"
TESTED_KEENKIT="2.9.5"

# ATHENA_ROOT — только для тестов, на роутере пусто.
ROOT="${ATHENA_ROOT:-}"
LINK="$ROOT/opt/bin/keenkit"
DEFAULT_TARGET="$ROOT/opt/keenkit.sh"
CONF="$ROOT/opt/etc/KeenKit.conf"
V1_BACKUP="$ROOT/opt/bin/keenkit.before-athena"
FW_DOMAIN="https://osvault.project-athens.com"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[1;31m' GREEN='\033[1;32m' CYAN='\033[0;36m' YELLOW='\033[1;33m' NC='\033[0m'
else
  RED='' GREEN='' CYAN='' YELLOW='' NC=''
fi

TMP_DIR=""
LOCK=""
cleanup() {
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
  [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

info() { printf '%b%s%b\n' "$CYAN" "$*" "$NC"; }
ok() { printf '%b%s%b\n' "$GREEN" "$*" "$NC"; }
warn() { printf '%b%s%b\n' "$YELLOW" "$*" "$NC" >&2; }
die() {
  printf '%b%s%b\n' "$RED" "$*" "$NC" >&2
  exit 1
}

require() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Не найдена команда: $c"
  done
}

# ---------- состояние KeenKit ----------

resolve_target() {
  if [ -L "$LINK" ]; then
    readlink -f "$LINK"
  else
    echo "$DEFAULT_TARGET"
  fi
}

kk_version() {
  sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1
}

patch_version() {
  sed -n 's/^ATHENA_PATCH="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1
}

# Патч v1 (без метки): ota_path заменён на /files/athena
is_v1_patched() {
  grep -q 'ota_path="/files/athena"' "$1" && [ -z "$(patch_version "$1")" ]
}

is_clean() {
  [ -z "$(patch_version "$1")" ] && ! grep -q 'ota_path="/files/athena"' "$1"
}

# ---------- построение патча ----------

write_snippets() {
  cat >"$TMP_DIR/s_marker" <<EOF
ATHENA_PATCH="$PATCH_VERSION"
EOF

  cat >"$TMP_DIR/s_path" <<'EOF'
    [ "$arch" != "aarch64" ] || ota_path="/files/athena" # athena-patch
EOF

  cat >"$TMP_DIR/s_guard" <<'EOF'
  # athena-patch: защита от записи загрузчика другой модели
  if [ "$ota_mode" = "keenboot" ] && [ "$ota_path" = "/files/athena" ]; then
    athena_dir=$(echo "$DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[_-]/ /g')
    athena_dev=$(echo "$current_device_model" | tr '[:upper:]' '[:lower:]' | sed 's/[_-]/ /g')
    case "$athena_dev" in
    rax3000me) athena_alias="rax3000m" ;; # wiki Athena: один файл для CMCC RAX3000M/Me
    *) athena_alias="" ;;
    esac
    athena_match=0
    if [ -n "$athena_dev" ]; then
      case "$athena_dir" in *"$athena_dev"*) athena_match=1 ;; esac
      if [ -n "$athena_alias" ]; then
        case "$athena_dir" in *"$athena_alias"*) athena_match=1 ;; esac
      fi
    fi
    if [ "$athena_match" -ne 1 ]; then
      print_message "Папка $(printf '%s' "$DIR" | sed 's/%/%%/g') не совпадает с моделью роутера: $(printf '%s' "${current_device_model:-неизвестна}" | sed 's/%/%%/g')" "$RED"
      if ! read -r -p "Записать загрузчик для другой модели? Введите YES для продолжения: " athena_confirm; then
        echo ""
        exit 0
      fi
      [ "$athena_confirm" = "YES" ] || { exit_function; return 1; }
    fi
  fi
EOF

  cat >"$TMP_DIR/s_subdir" <<'EOF'
  # athena-patch: единственная вложенная папка (Модель/r41/)
  if [ -z "$BIN_FILES" ]; then
    athena_sub=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep -E '^[^/?#]+/$' | grep -vE '^\.\.?/$' | sed 's|/$||')
    if [ -n "$athena_sub" ] && [ "$(echo "$athena_sub" | wc -l)" -eq 1 ]; then
      DIR_ENCODED="$DIR_ENCODED/$athena_sub"
      DIR="$DIR/$(echo "$athena_sub" | sed 's|%20| |g')"
      REQUEST=$(ota_request "$osvault/$DIR_ENCODED/") || { exit_function; return 1; }
      BIN_FILES=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep '\.bin$' | sed 's|%20| |g')
    fi
  fi
EOF

  cat >"$TMP_DIR/s_parse" <<'EOF'
    found=$(echo "$strings" | grep -m1 -oE '[0-9][0-9.]*_athena-r[0-9]+') # athena-patch
    [ -n "$found" ] && {
        echo "Athena ${found##*_athena-} (${found%%_athena-*})"
        return
    }
EOF
}

# Вставка фрагментов после строк-якорей. Каждый якорь обязан встретиться ровно один раз.
# Якоря передаются через окружение: awk -v обрабатывает «\», а в якорях есть «\.».
build_patched() {
  src="$1" dst="$2"
  A1='SCRIPT_VERSION="'"$(kk_version "$src")"'"' \
  A2='    ota_path="/files/keenboot/$arch"' \
  A3="  DIR_ENCODED=\$(echo \"\$DIR\" | sed 's/ /%20/g')" \
  A4="  BIN_FILES=\$(echo \"\$REQUEST\" | grep -o 'href=\"[^\"]*\"' | cut -d'\"' -f2 | grep '\\.bin\$' | sed 's|%20| |g')" \
  A5='    local strings="$1" pattern found' \
  S1="$TMP_DIR/s_marker" S2="$TMP_DIR/s_path" S3="$TMP_DIR/s_guard" S4="$TMP_DIR/s_subdir" S5="$TMP_DIR/s_parse" \
    awk '
      function emit(f,   line) {
        while ((getline line < f) > 0) print line
        close(f)
      }
      {
        print
        for (i = 1; i <= 5; i++) {
          if ($0 == ENVIRON["A" i]) { hits[i]++; emit(ENVIRON["S" i]) }
        }
      }
      END {
        bad = 0
        for (i = 1; i <= 5; i++) {
          if (hits[i] != 1) { printf "якорь %d найден %d раз(а)\n", i, hits[i] + 0 > "/dev/stderr"; bad = 1 }
        }
        exit bad
      }
    ' "$src" >"$dst"
}

verify_patched() {
  f="$1"
  [ "$(patch_version "$f")" = "$PATCH_VERSION" ] || return 1
  [ "$(grep -c '# athena-patch' "$f")" -eq 4 ] || return 1
  # shellcheck disable=SC2016  # литерал $arch из KeenKit
  grep -q '^    ota_path="/files/keenboot/\$arch"$' "$f" || return 1
  sh -n "$f"
}

# Атомарная замена: работающий KeenKit продолжает читать старый файл.
install_atomic() {
  src="$1" target="$2"
  tmp="$target.athena.$$"
  if ! { cp "$src" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$target"; }; then
    rm -f "$tmp"
    die "Не удалось записать $target"
  fi
}

lock() {
  LOCK="$1.athena.lock"
  mkdir "$LOCK" 2>/dev/null || {
    LOCK=""
    die "Патч уже выполняется (или остался $1.athena.lock — удали его вручную)"
  }
}

# Источник оригинального KeenKit для текущей версии; создаёт/обновляет резервную копию.
original_source() {
  target="$1" ver="$2" backup="$3"
  if is_clean "$target"; then
    if [ ! -f "$backup" ] || ! cmp -s "$target" "$backup"; then
      cp "$target" "$backup" || die "Не удалось создать копию $backup"
    fi
  elif [ -f "$backup" ] && is_clean "$backup" && [ "$(kk_version "$backup")" = "$ver" ]; then
    : # уже пропатчен; оригинал в копии
  elif is_v1_patched "$target" && [ -f "$V1_BACKUP" ] && is_clean "$V1_BACKUP" &&
    [ "$(kk_version "$V1_BACKUP")" = "$ver" ]; then
    cp "$V1_BACKUP" "$backup" || die "Не удалось создать копию $backup"
    info "Найден патч v1, оригинал взят из $V1_BACKUP" >&2
  else
    die "KeenKit уже изменён, а оригинала версии $ver нет. Переустанови KeenKit (п.99) и запусти патч снова"
  fi
  echo "$backup"
}

set_domain() {
  [ "$(sed -n 's/^domain="\(.*\)"$/\1/p' "$CONF" 2>/dev/null | head -n 1)" = "$FW_DOMAIN" ] && return 0
  if ! { mkdir -p "${CONF%/*}" && printf 'domain="%s"\n' "$FW_DOMAIN" >"$CONF"; }; then
    die "Не удалось записать $CONF"
  fi
  info "Домен OTA: $FW_DOMAIN"
}

# ---------- команды ----------

prepare() {
  TARGET=$(resolve_target)
  [ -f "$TARGET" ] || die "KeenKit не найден: $TARGET"
  VER=$(kk_version "$TARGET")
  [ -n "$VER" ] || die "Не удалось определить версию KeenKit в $TARGET"
  BACKUP="$TARGET.$VER.orig"
  TMP_DIR=$(mktemp -d) || die "Не удалось создать временный каталог"
}

cmd_apply() {
  prepare
  lock "$TARGET"
  if [ "$(patch_version "$TARGET")" = "$PATCH_VERSION" ] && verify_patched "$TARGET"; then
    set_domain
    ok "Патч $PATCH_VERSION уже применён к KeenKit $VER"
    return 0
  fi
  case " $TESTED_KEENKIT " in
  *" $VER "*) ;;
  *) warn "KeenKit $VER не проверялся с патчем (проверен: $TESTED_KEENKIT); применяю, если структура совпадёт" ;;
  esac
  src=$(original_source "$TARGET" "$VER" "$BACKUP") || exit 1
  write_snippets
  build_patched "$src" "$TMP_DIR/patched" ||
    die "Структура KeenKit $VER не совпадает с ожидаемой. KeenKit не изменён"
  verify_patched "$TMP_DIR/patched" || die "Проверка патча не прошла. KeenKit не изменён"
  install_atomic "$TMP_DIR/patched" "$TARGET"
  set_domain
  ok "Патч $PATCH_VERSION применён к KeenKit $VER"
  echo "  п.5 прошивки:  $FW_DOMAIN/osvault"
  echo "  п.8 KeenBOOT:  $FW_DOMAIN/files/athena (aarch64), остальные — как в KeenKit"
  echo "  копия:         $BACKUP"
  echo "  откат:         sh $0 revert"
}

cmd_revert() {
  prepare
  lock "$TARGET"
  if is_clean "$TARGET"; then
    ok "KeenKit $VER не изменён — откатывать нечего"
    return 0
  fi
  if [ -f "$BACKUP" ] && is_clean "$BACKUP"; then
    src="$BACKUP"
  elif is_v1_patched "$TARGET" && [ -f "$V1_BACKUP" ] && [ "$(kk_version "$V1_BACKUP")" = "$VER" ]; then
    src="$V1_BACKUP"
  else
    die "Нет оригинала KeenKit $VER. Восстанови через KeenKit: п.99 «Обновить скрипт»"
  fi
  sh -n "$src" || die "Копия $src повреждена"
  install_atomic "$src" "$TARGET"
  ok "Оригинальный KeenKit $VER восстановлен из $src"
}

cmd_status() {
  prepare
  printf 'athena-patch %s\n' "$PATCH_VERSION"
  printf 'KeenKit:  %s (%s)\n' "$VER" "$TARGET"
  pv=$(patch_version "$TARGET")
  if [ -n "$pv" ]; then
    printf 'Патч:     %b%s%b\n' "$GREEN" "$pv" "$NC"
  elif is_v1_patched "$TARGET"; then
    printf 'Патч:     %bv1 (без метки) — выполни apply для обновления%b\n' "$YELLOW" "$NC"
  else
    printf 'Патч:     %bне применён%b\n' "$YELLOW" "$NC"
  fi
  if [ -f "$BACKUP" ]; then
    printf 'Копия:    %s\n' "$BACKUP"
  else
    printf 'Копия:    нет\n'
  fi
  printf 'Домен:    %s\n' "$(sed -n 's/^domain="\(.*\)"$/\1/p' "$CONF" 2>/dev/null | head -n 1)"
}

cmd_diff() {
  prepare
  if is_clean "$TARGET"; then
    src="$TARGET"
  elif [ -f "$BACKUP" ] && is_clean "$BACKUP"; then
    src="$BACKUP"
  elif is_v1_patched "$TARGET" && [ -f "$V1_BACKUP" ]; then
    src="$V1_BACKUP"
  else
    die "Нет оригинала KeenKit $VER для сравнения"
  fi
  write_snippets
  build_patched "$src" "$TMP_DIR/patched" || die "Структура KeenKit $VER не совпадает с ожидаемой"
  diff -u "$src" "$TMP_DIR/patched"
  return 0
}

require sed grep awk head cat cp mv rm chmod mkdir mktemp readlink cmp diff tr wc

case "${1:-apply}" in
apply) cmd_apply ;;
revert) cmd_revert ;;
status) cmd_status ;;
diff) cmd_diff ;;
-V | --version) echo "$PATCH_VERSION" ;;
-h | --help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//' ;;
*) die "Неизвестная команда: $1 (--help)" ;;
esac
