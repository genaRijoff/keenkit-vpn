#!/bin/sh
# KeenKit 2.9.5 — Project Athens OTA patch
# Configures Firmware OTA (menu 5) and KeenBOOT OTA (menu 8).

set -u

FILE="/opt/bin/keenkit"
CONFIG="/opt/etc/KeenKit.conf"
BACKUP="/opt/bin/keenkit.before-athena"
TMP="/tmp/keenkit.athena.new"
SUBDIR_BLOCK="/tmp/keenboot-subdir.block"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[ -f "$FILE" ] || fail "KeenKit script not found: $FILE"

echo "[1/6] Creating backup..."
if [ ! -f "$BACKUP" ]; then
    cp "$FILE" "$BACKUP" || fail "Cannot create backup: $BACKUP"
else
    echo "Backup already exists; leaving it unchanged: $BACKUP"
fi

echo "[2/6] Setting Athens domain..."
mkdir -p /opt/etc || fail "Cannot create /opt/etc"
if [ -f "$CONFIG" ] && grep -q '^domain=' "$CONFIG"; then
    sed 's|^domain=.*|domain="https://osvault.project-athens.com"|' "$CONFIG" > "${CONFIG}.tmp" ||
        fail "Cannot update config"
    mv "${CONFIG}.tmp" "$CONFIG" || fail "Cannot install config"
else
    printf 'domain="https://osvault.project-athens.com"\n' > "$CONFIG" ||
        fail "Cannot write config"
fi

echo "[3/6] Setting KeenBOOT OTA path..."
sed 's|ota_path="/files/keenboot/\$arch"|ota_path="/files/athena"|' "$FILE" > "$TMP" ||
    fail "Cannot prepare KeenBOOT path change"

# If already patched, keep the existing nested-directory support.
if grep -q 'Найдена вложенная папка' "$TMP"; then
    echo "[4/6] Nested-directory support already present."
else
    cat > "$SUBDIR_BLOCK" <<'EOF'
  if [ -z "$BIN_FILES" ]; then
    SUBDIRS=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep -E '^[^/?#]+/$' | grep -vE '^\.\.?/$' | sed 's|/$||' | sed 's|%20| |g')
    if [ -n "$SUBDIRS" ]; then
      SUBDIR_COUNT=$(printf '%s\n' "$SUBDIRS" | wc -l)
      if [ "$SUBDIR_COUNT" -eq 1 ]; then
        SUBDIR="$SUBDIRS"
        SUBDIR_ENCODED=$(printf '%s' "$SUBDIR" | sed 's| |%20|g')
        DIR_ENCODED="$DIR_ENCODED/$SUBDIR_ENCODED"
        REQUEST=$(ota_request "$osvault/$DIR_ENCODED/") || { exit_function; return 1; }
        BIN_FILES=$(echo "$REQUEST" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep '\.bin$' | sed 's|%20| |g')
        [ -z "$BIN_FILES" ] || print_message "Найдена вложенная папка: $SUBDIR" "$GREEN"
      fi
    fi
  fi
EOF

    awk '
    /  if \[ -z "\$BIN_FILES" \]; then/ {
        while ((getline line < "/tmp/keenboot-subdir.block") > 0) print line
        close("/tmp/keenboot-subdir.block")
    }
    { print }
    ' "$TMP" > "${TMP}.inserted" || fail "Could not insert nested-directory logic"

    if ! grep -q 'Найдена вложенная папка' "${TMP}.inserted"; then
        rm -f "${TMP}.inserted"
        fail "Insertion point not found; original script was not changed"
    fi
    mv "${TMP}.inserted" "$TMP" || fail "Cannot prepare patched script"
fi

echo "[5/6] Checking shell syntax..."
sh -n "$TMP" || fail "Syntax check failed; original script remains unchanged"

echo "[6/6] Installing patched script..."
cp "$TMP" "$FILE" || fail "Could not install patched script"
chmod 755 "$FILE" || fail "Could not set executable permission"

echo
echo "PATCH APPLIED."
echo "Firmware OTA: https://osvault.project-athens.com/osvault"
echo "KeenBOOT OTA: https://osvault.project-athens.com/files/athena"
echo "Backup: $BACKUP"
echo
grep -nE 'ota_path=|Найдена вложенная папка' "$FILE"
echo
cat "$CONFIG"
echo
echo "Syntax: OK"
