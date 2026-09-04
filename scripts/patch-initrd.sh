#!/usr/bin/env bash

set -Eeuo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PATCH_FILE="$REPO_ROOT/patches/23timezone"


usage()
{
    echo "Usage:"
    echo
    echo "  $0 INPUT_INITRD OUTPUT_INITRD"
    echo
    exit 1
}


die()
{
    echo
    echo "ERROR: $*" >&2
    exit 1
}


[[ $# -eq 2 ]] || usage


INPUT="$(realpath "$1")"
OUTPUT="$(realpath "$2")"


[[ -f "$INPUT" ]] \
    || die "Input initrd not found: $INPUT"

[[ -f "$PATCH_FILE" ]] \
    || die "Timezone hook not found: $PATCH_FILE"


for cmd in zstd cpio file lsinitramfs sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required command not found: $cmd"
done


WORK="$(mktemp -d -t mint-timezone-patch-XXXXXXXX)"

cleanup()
{
    rm -rf "$WORK"
}

trap cleanup EXIT


ROOT="$WORK/root"
VERIFY="$WORK/verify"

mkdir -p "$ROOT" "$VERIFY"


echo "============================================================"
echo " Casper Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : $INPUT"
echo "Output: $OUTPUT"
echo


# ============================================================
# Check input
# ============================================================

echo "==> Prüfe Input ..."

file "$INPUT"

echo


# ============================================================
# Extract
# ============================================================

echo "==> Entpacke Initrd ..."

cd "$ROOT"

zstd -dc "$INPUT" | cpio -idm --quiet


# ============================================================
# Verify Casper
# ============================================================

echo "==> Prüfe Casper ..."

[[ -d "$ROOT/scripts/casper-bottom" ]] \
    || die "scripts/casper-bottom fehlt."

[[ -f "$ROOT/scripts/casper-bottom/ORDER" ]] \
    || die "scripts/casper-bottom/ORDER fehlt."


# ============================================================
# Install timezone hook
# ============================================================

echo "==> Installiere Timezone-Hook ..."

install -m 0755 \
    "$PATCH_FILE" \
    "$ROOT/scripts/casper-bottom/23timezone"


# ============================================================
# Modify ORDER
# ============================================================

echo "==> Aktualisiere casper-bottom/ORDER ..."

ORDER="$ROOT/scripts/casper-bottom/ORDER"

# Vorhandenen Eintrag entfernen, falls vorhanden.
sed -i \
    '\#/scripts/casper-bottom/23timezone#d' \
    "$ORDER"


TMP_ORDER="$WORK/ORDER.new"

awk '
{
    if ($0 ~ /\/scripts\/casper-bottom\/25configure_init/) {
        print "/scripts/casper-bottom/23timezone \"$@\""
    }

    print
}
' "$ORDER" > "$TMP_ORDER"

mv "$TMP_ORDER" "$ORDER"


# ============================================================
# Verify ORDER before packing
# ============================================================

echo
echo "==> Prüfe ORDER ..."
echo

grep -n -E \
    '/scripts/casper-bottom/(23timezone|25configure_init)' \
    "$ORDER" \
    || true


TZ_LINE="$(
    grep -n \
        '/scripts/casper-bottom/23timezone' \
        "$ORDER" \
        | head -n1 \
        | cut -d: -f1 \
        || true
)"

CONFIG_LINE="$(
    grep -n \
        '/scripts/casper-bottom/25configure_init' \
        "$ORDER" \
        | head -n1 \
        | cut -d: -f1 \
        || true
)"


[[ -n "$TZ_LINE" ]] \
    || die "23timezone fehlt in ORDER."

[[ -n "$CONFIG_LINE" ]] \
    || die "25configure_init fehlt in ORDER."


if (( TZ_LINE >= CONFIG_LINE )); then
    die "23timezone steht nicht vor 25configure_init."
fi


echo
echo "OK: 23timezone steht vor 25configure_init."


# ============================================================
# Repack
# ============================================================

echo
echo "==> Erzeuge neue Zstandard-Initrd ..."
echo

rm -f "$OUTPUT"

cd "$ROOT"

find . -print0 \
    | cpio --null -o -H newc --quiet \
    | zstd -T0 -19 -o "$OUTPUT"


[[ -s "$OUTPUT" ]] \
    || die "Output wurde nicht erzeugt."


# ============================================================
# Verify resulting initrd
# ============================================================

echo
echo "==> Prüfe erzeugte Initrd ..."
echo

file "$OUTPUT"

ls -lh "$OUTPUT"


echo
echo "==> Prüfe Timezone-Hook ..."

LISTING="$WORK/listing"

lsinitramfs "$OUTPUT" > "$LISTING"


grep -Fq \
    'scripts/casper-bottom/23timezone' \
    "$LISTING" \
    || die "Timezone-Hook fehlt in der neuen Initrd."


echo "OK: Timezone-Hook vorhanden."


# ============================================================
# Extract and verify ORDER from NEW initrd
# ============================================================

echo
echo "==> Prüfe ORDER der neuen Initrd ..."

mkdir -p "$VERIFY"

cd "$VERIFY"

zstd -dc "$OUTPUT" | cpio -idm --quiet

NEW_ORDER="$VERIFY/scripts/casper-bottom/ORDER"

[[ -f "$NEW_ORDER" ]] \
    || die "ORDER fehlt in der neuen Initrd."


echo
grep -n -E \
    '/scripts/casper-bottom/(23timezone|25configure_init)' \
    "$NEW_ORDER" \
    || true


TZ_LINE="$(
    grep -n \
        '/scripts/casper-bottom/23timezone' \
        "$NEW_ORDER" \
        | head -n1 \
        | cut -d: -f1 \
        || true
)"

CONFIG_LINE="$(
    grep -n \
        '/scripts/casper-bottom/25configure_init' \
        "$NEW_ORDER" \
        | head -n1 \
        | cut -d: -f1 \
        || true
)"


[[ -n "$TZ_LINE" ]] \
    || die "23timezone fehlt in ORDER der neuen Initrd."

[[ -n "$CONFIG_LINE" ]] \
    || die "25configure_init fehlt in ORDER der neuen Initrd."


if (( TZ_LINE >= CONFIG_LINE )); then
    die "23timezone steht in der neuen Initrd nicht vor 25configure_init."
fi


echo
echo "OK: ORDER der neuen Initrd ist korrekt."


# ============================================================
# SHA256
# ============================================================

echo
echo "==> SHA256 ..."

sha256sum "$OUTPUT"


echo
echo "============================================================"
echo " Patch erfolgreich"
echo "============================================================"
echo
