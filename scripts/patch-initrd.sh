#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CASPER_PATCH="$REPO_ROOT/patches/23timezone"
LIVE_PATCH="$REPO_ROOT/patches/0100-timezone.sh"

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

for cmd in zstd cpio file lsinitramfs sha256sum awk sed grep; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required command not found: $cmd"
done

WORK="$(mktemp -d -t timezone-patch-XXXXXXXX)"

cleanup()
{
    rm -rf "$WORK"
}

trap cleanup EXIT


ROOT="$WORK/root"
VERIFY="$WORK/verify"

mkdir -p "$ROOT" "$VERIFY"


echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
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

zstd -dc "$INPUT" | sudo cpio -idm --quiet

cd - >/dev/null


# ============================================================
# Detect live system
# ============================================================

echo
echo "==> Erkenne Live-System ..."

CASPER=0
LIVE_BOOT=0


if [[ -d "$ROOT/scripts/casper-bottom" ]] &&
   [[ -f "$ROOT/scripts/casper-bottom/ORDER" ]]
then
    CASPER=1
    echo "OK: casper erkannt."
fi


if [[ -d "$ROOT/usr/lib/live/boot" ]]
then
    LIVE_BOOT=1
    echo "OK: live-boot erkannt."
fi


if (( CASPER == 0 && LIVE_BOOT == 0 )); then
    die "Weder casper noch live-boot erkannt."
fi

# ============================================================
# Prüfe benötigte Patch-Dateien
# ============================================================

if (( CASPER == 1 )); then
    [[ -f "$CASPER_PATCH" ]] \
        || die "Casper timezone hook not found: $CASPER_PATCH"
fi

if (( LIVE_BOOT == 1 )); then
    [[ -f "$LIVE_PATCH" ]] \
        || die "live-boot timezone hook not found: $LIVE_PATCH"
fi


# ============================================================
# Casper
# ============================================================

if (( CASPER == 1 )); then

    echo
    echo "==> Installiere casper Timezone-Hook ..."

    install -m 0755 \
        "$CASPER_PATCH" \
        "$ROOT/scripts/casper-bottom/23timezone"


    echo "==> Aktualisiere casper-bottom/ORDER ..."

    ORDER="$ROOT/scripts/casper-bottom/ORDER"


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

fi


# ============================================================
# live-boot
# ============================================================

if (( LIVE_BOOT == 1 )); then

    echo
    echo "==> Installiere live-boot Timezone-Hook ..."

    install -m 0755 \
        "$LIVE_PATCH" \
        "$ROOT/usr/lib/live/boot/0100-timezone.sh"


    echo
    echo "OK: live-boot Hook installiert."

fi


# ============================================================
# Verify before packing
# ============================================================

echo
echo "==> Prüfe eingebauten Hook ..."


if (( CASPER == 1 )); then

    [[ -f "$ROOT/scripts/casper-bottom/23timezone" ]] \
        || die "Casper Timezone-Hook fehlt."

    echo "OK: casper Hook vorhanden."

fi


if (( LIVE_BOOT == 1 )); then

    [[ -f "$ROOT/usr/lib/live/boot/0100-timezone.sh" ]] \
        || die "live-boot Timezone-Hook fehlt."

    echo "OK: live-boot Hook vorhanden."

fi


# ============================================================
# Repack
# ============================================================

echo
echo "==> Erzeuge neue Zstandard-Initrd ..."
echo

rm -f "$OUTPUT"

cd "$ROOT"

sudo find . -print0 \
    | sudo cpio --null -o -H newc --quiet \
    | zstd -T0 -19 -o "$OUTPUT"

cd - >/dev/null


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


if (( CASPER == 1 )); then

    grep -Fq \
        'scripts/casper-bottom/23timezone' \
        "$LISTING" \
        || die "Casper Timezone-Hook fehlt in der neuen Initrd."

    echo "OK: casper Timezone-Hook vorhanden."

fi


if (( LIVE_BOOT == 1 )); then

    grep -Fq \
        'usr/lib/live/boot/0100-timezone.sh' \
        "$LISTING" \
        || die "live-boot Timezone-Hook fehlt in der neuen Initrd."

    echo "OK: live-boot Timezone-Hook vorhanden."

fi


# ============================================================
# Extract and verify resulting ORDER
# ============================================================

if (( CASPER == 1 )); then

    echo
    echo "==> Prüfe ORDER der neuen Initrd ..."

    rm -rf "$VERIFY"
    mkdir -p "$VERIFY"

    cd "$VERIFY"

    zstd -dc "$OUTPUT" | cpio -idm --quiet

    cd - >/dev/null

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

fi


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
