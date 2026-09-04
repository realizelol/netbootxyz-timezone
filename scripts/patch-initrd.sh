#!/usr/bin/env bash

set -Eeuo pipefail


# ============================================================
# Re-run as root
# ============================================================

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi


# ============================================================
# Paths
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PATCH_FILE="$REPO_ROOT/patches/0023-timezone"


# ============================================================
# Usage / error handling
# ============================================================

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


# ============================================================
# Required commands
# ============================================================

for cmd in zstd cpio file lsinitramfs sha256sum install sed awk grep find; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required command not found: $cmd"
done


# ============================================================
# Temporary workspace
# ============================================================

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
echo

file "$INPUT"

echo


# ============================================================
# Extract initrd
# ============================================================

echo "==> Entpacke Initrd ..."
echo

cd "$ROOT"

zstd -dc "$INPUT" | cpio -idm --quiet


# ============================================================
# Detect live system
# ============================================================

echo "==> Erkenne Live-System ..."

IS_CASPER=false
IS_LIVE_BOOT=false


if [[ -d "$ROOT/scripts/casper-bottom" ]] && \
   [[ -f "$ROOT/scripts/casper-bottom/ORDER" ]]; then

    IS_CASPER=true

    echo "OK: casper erkannt."

fi


if [[ -f "$ROOT/usr/bin/live-boot" ]] && \
   [[ -d "$ROOT/usr/lib/live/boot" ]]; then

    IS_LIVE_BOOT=true

    echo "OK: live-boot erkannt."

fi


if [[ "$IS_CASPER" == false && "$IS_LIVE_BOOT" == false ]]; then
    die "Weder casper noch live-boot erkannt."
fi


# ============================================================
# Install timezone hook
# ============================================================

if [[ "$IS_CASPER" == true ]]; then

    echo
    echo "==> Installiere casper Timezone-Hook ..."

    install -m 0755 \
        "$PATCH_FILE" \
        "$ROOT/scripts/casper-bottom/23timezone"

fi


if [[ "$IS_LIVE_BOOT" == true ]]; then

    echo
    echo "==> Installiere live-boot Timezone-Hook ..."

    install -m 0755 \
        "$PATCH_FILE" \
        "$ROOT/usr/lib/live/boot/0023-timezone"

fi


# ============================================================
# Configure casper
# ============================================================

if [[ "$IS_CASPER" == true ]]; then

    echo
    echo "==> Konfiguriere casper-bottom/ORDER ..."

    ORDER="$ROOT/scripts/casper-bottom/ORDER"

    [[ -f "$ORDER" ]] \
        || die "casper-bottom/ORDER fehlt."


    # Remove previous entry
    sed -i \
        '\#/scripts/casper-bottom/23timezone#d' \
        "$ORDER"


    TMP_ORDER="$WORK/ORDER.new"


    # Insert timezone hook before configure_init.
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
    echo "==> Prüfe casper ORDER ..."
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
        || die "23timezone fehlt in casper-bottom/ORDER."


    [[ -n "$CONFIG_LINE" ]] \
        || die "25configure_init fehlt in casper-bottom/ORDER."


    if (( TZ_LINE >= CONFIG_LINE )); then
        die "23timezone steht nicht vor 25configure_init."
    fi


    echo
    echo "OK: 23timezone steht vor 25configure_init."

fi


# ============================================================
# Configure live-boot
# ============================================================

if [[ "$IS_LIVE_BOOT" == true ]]; then

    echo
    echo "==> Konfiguriere live-boot ..."


    MAIN="$ROOT/usr/lib/live/boot/9990-main.sh"

    [[ -f "$MAIN" ]] \
        || die "usr/lib/live/boot/9990-main.sh fehlt."


    # --------------------------------------------------------
    # Add timezone_setup call
    # --------------------------------------------------------

    if grep -qE '^[[:space:]]*timezone_setup[[:space:]]*$' "$MAIN"; then

        echo "OK: timezone_setup ist bereits in 9990-main.sh vorhanden."

    else

        echo "==> Füge timezone_setup in 9990-main.sh ein ..."

        TMP_MAIN="$WORK/9990-main.sh.new"


        awk '
        {
            if ($0 == "\tlog_end_msg") {
                print "\ttimezone_setup"
                print ""
            }

            print
        }
        ' "$MAIN" > "$TMP_MAIN"


        mv "$TMP_MAIN" "$MAIN"

        chmod 0755 "$MAIN"

    fi


    # --------------------------------------------------------
    # Verify live-boot component
    # --------------------------------------------------------

    echo
    echo "==> Prüfe live-boot Komponenten ..."
    echo


    LIVE_BOOT_HOOK="$ROOT/usr/lib/live/boot/0023-timezone"


    [[ -x "$LIVE_BOOT_HOOK" ]] \
        || die "usr/lib/live/boot/0023-timezone fehlt."


    echo "OK: 0023-timezone vorhanden."


    # live-boot loads exactly:
    #
    #   /lib/live/boot/????-*
    #
    # Verify our filename matches that convention.

    BASENAME="$(basename "$LIVE_BOOT_HOOK")"


    if [[ ! "$BASENAME" =~ ^[0-9]{4}- ]]; then
        die "live-boot Hook hat keinen gültigen Namen: $BASENAME"
    fi


    echo "OK: $BASENAME entspricht dem live-boot Component-Format."


    # --------------------------------------------------------
    # Verify timezone_setup definition
    # --------------------------------------------------------

    grep -qE '^[[:space:]]*timezone_setup[[:space:]]*\(\)' \
        "$LIVE_BOOT_HOOK" \
        || die "timezone_setup() fehlt in 0023-timezone."


    echo "OK: timezone_setup() gefunden."


    # --------------------------------------------------------
    # Verify timezone_setup call
    # --------------------------------------------------------

    grep -qE '^[[:space:]]*timezone_setup[[:space:]]*$' \
        "$MAIN" \
        || die "timezone_setup-Aufruf fehlt in 9990-main.sh."


    echo "OK: timezone_setup-Aufruf in 9990-main.sh gefunden."

fi


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


# ============================================================
# Verify contents with lsinitramfs
# ============================================================

echo
echo "==> Prüfe Timezone-Hook in neuer Initrd ..."
echo

LISTING="$WORK/listing"

lsinitramfs "$OUTPUT" > "$LISTING"


if [[ "$IS_CASPER" == true ]]; then

    grep -Fq \
        'scripts/casper-bottom/23timezone' \
        "$LISTING" \
        || die "Casper Timezone-Hook fehlt in neuer Initrd."

    echo "OK: scripts/casper-bottom/23timezone vorhanden."

fi


if [[ "$IS_LIVE_BOOT" == true ]]; then

    grep -Fq \
        'usr/lib/live/boot/0023-timezone' \
        "$LISTING" \
        || die "live-boot Timezone-Hook fehlt in neuer Initrd."

    echo "OK: usr/lib/live/boot/0023-timezone vorhanden."

fi


# ============================================================
# Extract resulting initrd again for final verification
# ============================================================

echo
echo "==> Extrahiere neue Initrd zur Abschlussprüfung ..."
echo


rm -rf "$VERIFY"

mkdir -p "$VERIFY"

cd "$VERIFY"

zstd -dc "$OUTPUT" | cpio -idm --quiet


# ============================================================
# Final casper verification
# ============================================================

if [[ "$IS_CASPER" == true ]]; then

    echo
    echo "==> Prüfe Casper-Konfiguration ..."
    echo

    NEW_ORDER="$VERIFY/scripts/casper-bottom/ORDER"


    [[ -f "$NEW_ORDER" ]] \
        || die "ORDER fehlt in neuer Initrd."


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
    echo "OK: Casper ORDER ist korrekt."

fi


# ============================================================
# Final live-boot verification
# ============================================================

if [[ "$IS_LIVE_BOOT" == true ]]; then

    echo
    echo "==> Prüfe live-boot-Konfiguration ..."
    echo


    NEW_HOOK="$VERIFY/usr/lib/live/boot/0023-timezone"

    NEW_MAIN="$VERIFY/usr/lib/live/boot/9990-main.sh"


    [[ -f "$NEW_HOOK" ]] \
        || die "0023-timezone fehlt in neuer Initrd."


    [[ -f "$NEW_MAIN" ]] \
        || die "9990-main.sh fehlt in neuer Initrd."


    grep -qE \
        '^[[:space:]]*timezone_setup[[:space:]]*\(\)' \
        "$NEW_HOOK" \
        || die "timezone_setup() fehlt in 0023-timezone der neuen Initrd."


    grep -qE \
        '^[[:space:]]*timezone_setup[[:space:]]*$' \
        "$NEW_MAIN" \
        || die "timezone_setup-Aufruf fehlt in 9990-main.sh der neuen Initrd."


    echo "OK: timezone_setup() vorhanden."

    echo "OK: timezone_setup wird von 9990-main.sh aufgerufen."

fi


# ============================================================
# SHA256
# ============================================================

echo
echo "==> SHA256 ..."
echo

sha256sum "$OUTPUT"


# ============================================================
# Done
# ============================================================

echo
echo "============================================================"
echo " Patch erfolgreich"
echo "============================================================"
echo
