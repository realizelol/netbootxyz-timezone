#!/usr/bin/env bash

set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

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
# Extract initrd
# ============================================================

echo "==> Entpacke Initrd ..."

cd "$ROOT"

zstd -dc "$INPUT" | cpio -idm --quiet


# ============================================================
# Detect live system
# ============================================================

echo "==> Erkenne Live-System ..."

CASPER=false
LIVE_BOOT=false


if [[ -d "$ROOT/scripts/casper-bottom" ]] &&
   [[ -f "$ROOT/scripts/casper-bottom/ORDER" ]]; then

    CASPER=true

    echo "OK: casper erkannt."

elif [[ -f "$ROOT/usr/bin/live-boot" ]] &&
     [[ -d "$ROOT/usr/lib/live/boot" ]]; then

    LIVE_BOOT=true

    echo "OK: live-boot erkannt."

else

    die "Weder casper noch live-boot erkannt."

fi


# ============================================================
# Install timezone hook
# ============================================================

if [[ "$CASPER" == true ]]; then

    echo
    echo "==> Erzeuge casper Timezone-Hook ..."

    install -D -m 0755 \
        "$PATCH_FILE" \
        "$ROOT/scripts/casper-bottom/23timezone"

    ORDER="$ROOT/scripts/casper-bottom/ORDER"


    # --------------------------------------------------------
    # Remove existing timezone entry
    # --------------------------------------------------------

    sed -i \
        '\#/scripts/casper-bottom/23timezone#d' \
        "$ORDER"


    # --------------------------------------------------------
    # Insert timezone hook immediately before configure_init
    # --------------------------------------------------------

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


    # --------------------------------------------------------
    # Verify ORDER
    # --------------------------------------------------------

    echo
    echo "==> Aktualisiere casper-bottom/ORDER ..."
    echo
    echo "==> Relevanter Abschnitt von ORDER:"

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
    echo "OK: casper Timezone-Hook vorhanden."
    echo "OK: 23timezone steht vor 25configure_init."


elif [[ "$LIVE_BOOT" == true ]]; then

    echo
    echo "==> Erzeuge live-boot Timezone-Hook ..."


    LIVE_BOOT_HOOK="$ROOT/usr/lib/live/boot/0100-timezone.sh"


    install -D -m 0755 \
        "$PATCH_FILE" \
        "$LIVE_BOOT_HOOK"


    echo
    echo "OK: live-boot Hook:"
    echo "    $LIVE_BOOT_HOOK"

fi


# ============================================================
# Verify hook before packing
# ============================================================

echo
echo "==> Prüfe eingebauten Hook ..."


if [[ "$CASPER" == true ]]; then

    [[ -x "$ROOT/scripts/casper-bottom/23timezone" ]] \
        || die "casper Timezone-Hook fehlt."

    echo "OK: casper Hook vorhanden."


elif [[ "$LIVE_BOOT" == true ]]; then

    [[ -x "$ROOT/usr/lib/live/boot/0100-timezone.sh" ]] \
        || die "live-boot Timezone-Hook fehlt."

    echo "OK: live-boot Hook vorhanden."

fi


# ============================================================
# Repack initrd
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


# ============================================================
# Verify hook inside resulting initrd
# ============================================================

echo
echo "==> Prüfe Inhalt der neuen Initrd ..."
echo


LISTING="$WORK/listing"

lsinitramfs "$OUTPUT" > "$LISTING"


if [[ "$CASPER" == true ]]; then

    grep -Fq \
        'scripts/casper-bottom/23timezone' \
        "$LISTING" \
        || die "casper Timezone-Hook fehlt."


    echo "OK: casper Timezone-Hook vorhanden."


elif [[ "$LIVE_BOOT" == true ]]; then

    grep -Fq \
        'usr/lib/live/boot/0100-timezone.sh' \
        "$LISTING" \
        || die "live-boot Timezone-Hook fehlt."


    echo "OK: live-boot Timezone-Hook vorhanden."

fi


# ============================================================
# Extract resulting initrd for deeper verification
# ============================================================

echo
echo "==> Prüfe Struktur der neuen Initrd ..."
echo


mkdir -p "$VERIFY"

cd "$VERIFY"


zstd -dc "$OUTPUT" | cpio -idm --quiet


# ============================================================
# Casper verification
# ============================================================

if [[ "$CASPER" == true ]]; then

    NEW_HOOK="$VERIFY/scripts/casper-bottom/23timezone"
    NEW_ORDER="$VERIFY/scripts/casper-bottom/ORDER"


    [[ -x "$NEW_HOOK" ]] \
        || die "23timezone fehlt in der neuen Initrd."


    [[ -f "$NEW_ORDER" ]] \
        || die "casper-bottom/ORDER fehlt in der neuen Initrd."


    echo
    echo "==> Prüfe casper ORDER ..."
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
    echo "OK: casper ORDER der neuen Initrd ist korrekt."

fi


# ============================================================
# live-boot verification
# ============================================================

if [[ "$LIVE_BOOT" == true ]]; then

    NEW_HOOK="$VERIFY/usr/lib/live/boot/0100-timezone.sh"


    [[ -x "$NEW_HOOK" ]] \
        || die "0100-timezone.sh fehlt in der neuen Initrd."


    echo
    echo "OK: live-boot Timezone-Hook ist korrekt eingebaut."

fi


# ============================================================
# SHA256
# ============================================================

echo
echo "==> SHA256 ..."
echo


sha256sum "$OUTPUT"


echo
echo "============================================================"
echo " Patch erfolgreich"
echo "============================================================"
echo
