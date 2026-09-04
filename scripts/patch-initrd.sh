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

PATCH_FILE="$REPO_ROOT/patches/23timezone"


# ============================================================
# Functions
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


# ============================================================
# Arguments
# ============================================================

[[ $# -eq 2 ]] || usage


INPUT="$(realpath "$1")"
OUTPUT="$(realpath "$2")"


[[ -f "$INPUT" ]] \
    || die "Input initrd not found: $INPUT"

[[ -f "$PATCH_FILE" ]] \
    || die "Timezone hook not found: $PATCH_FILE"


# ============================================================
# Dependencies
# ============================================================

for cmd in zstd cpio file find grep sed awk lsinitramfs sha256sum install; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required command not found: $cmd"
done


# ============================================================
# Temporary directories
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


# ============================================================
# Header
# ============================================================

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

zstd -dc "$INPUT" | cpio -idm --quiet


# ============================================================
# Detect live system
# ============================================================

echo
echo "==> Erkenne Live-System ..."


SYSTEM=""

if [[ -d "$ROOT/scripts/casper-bottom" ]] &&
   [[ -f "$ROOT/scripts/casper-bottom/ORDER" ]]; then

    SYSTEM="casper"

    echo "OK: casper erkannt."

elif [[ -f "$ROOT/usr/bin/live-boot" ]] &&
     [[ -f "$ROOT/usr/lib/live/boot/9990-main.sh" ]]; then

    SYSTEM="live-boot"

    echo "OK: live-boot erkannt."

else

    die "Unbekanntes Live-System."

fi


# ============================================================
# Casper / Linux Mint
# ============================================================

patch_casper()
{
    echo
    echo "==> Erzeuge casper Timezone-Hook ..."

    local hook="$ROOT/scripts/casper-bottom/23timezone"
    local order="$ROOT/scripts/casper-bottom/ORDER"
    local tmp_order="$WORK/ORDER.new"

    # --------------------------------------------------------
    # Install hook
    # --------------------------------------------------------

    install -m 0755 \
        "$PATCH_FILE" \
        "$hook"


    # --------------------------------------------------------
    # Update ORDER
    # --------------------------------------------------------

    echo
    echo "==> Aktualisiere casper-bottom/ORDER ..."

    # Vorhandenen Eintrag entfernen.
    sed -i \
        '\#/scripts/casper-bottom/23timezone#d' \
        "$order"


    # Vor 25configure_init einfügen.
    awk '
    {
        if ($0 ~ /\/scripts\/casper-bottom\/25configure_init/) {
            print "/scripts/casper-bottom/23timezone \"$@\""
        }

        print
    }
    ' "$order" > "$tmp_order"

    mv "$tmp_order" "$order"


    # --------------------------------------------------------
    # Verify ORDER
    # --------------------------------------------------------

    echo
    echo "==> Relevanter Abschnitt von ORDER:"
    echo

    grep -n -E \
        '/scripts/casper-bottom/(23timezone|25configure_init)' \
        "$order" \
        || true


    local tz_line
    local config_line

    tz_line="$(
        grep -n \
            '/scripts/casper-bottom/23timezone' \
            "$order" \
            | head -n1 \
            | cut -d: -f1 \
            || true
    )"

    config_line="$(
        grep -n \
            '/scripts/casper-bottom/25configure_init' \
            "$order" \
            | head -n1 \
            | cut -d: -f1 \
            || true
    )"


    [[ -n "$tz_line" ]] \
        || die "23timezone fehlt in ORDER."

    [[ -n "$config_line" ]] \
        || die "25configure_init fehlt in ORDER."


    if (( tz_line >= config_line )); then
        die "23timezone steht nicht vor 25configure_init."
    fi


    echo
    echo "OK: 23timezone steht vor 25configure_init."


    # --------------------------------------------------------
    # Verify hook
    # --------------------------------------------------------

    echo
    echo "==> Prüfe eingebauten Hook ..."

    [[ -x "$hook" ]] \
        || die "casper Timezone-Hook fehlt."

    echo "OK: casper Hook vorhanden."
}


# ============================================================
# live-boot / Kali
# ============================================================

patch_live_boot()
{
    echo
    echo "==> Erzeuge live-boot Timezone-Hook ..."


    local component="$ROOT/usr/lib/live/boot/023-timezone"
    local main="$ROOT/usr/lib/live/boot/9990-main.sh"


    # --------------------------------------------------------
    # Create live-boot component
    # --------------------------------------------------------

    cat > "$component" <<EOF
#!/bin/sh

$(cat "$PATCH_FILE")
EOF

    chmod 0755 "$component"


    echo "OK: live-boot Hook:"
    echo "    $component"


    # --------------------------------------------------------
    # Verify component
    # --------------------------------------------------------

    [[ -x "$component" ]] \
        || die "live-boot timezone hook konnte nicht erstellt werden."


    # --------------------------------------------------------
    # Patch 9990-main.sh
    # --------------------------------------------------------

    echo
    echo "==> Patch 9990-main.sh ..."


    # Nicht mehrfach patchen.
    if grep -Fq \
        'timezone_setup' \
        "$main"; then

        echo "WARNUNG: timezone_setup ist bereits in 9990-main.sh vorhanden."

    else

        local tmp_main="$WORK/9990-main.sh.new"

        awk '
        {
            print

            if (
                !inserted &&
                $0 ~ /mount_images_in_directory "\$\{livefs_root\}" "\$\{rootmnt\}" "\$\{mac\}"/
            ) {
                print ""
                print "\t# Apply timezone from kernel command line after live rootfs is mounted."
                print "\ttimezone_setup"
                inserted=1
            }
        }

        END {
            if (!inserted) {
                exit 42
            }
        }
        ' "$main" > "$tmp_main" \
            || die "Konnte timezone_setup nicht in 9990-main.sh einfügen."

        mv "$tmp_main" "$main"

        chmod 0755 "$main"
    }


    # --------------------------------------------------------
    # Verify patch
    # --------------------------------------------------------

    echo
    echo "==> Prüfe 9990-main.sh ..."

    grep -n -C 4 \
        'timezone_setup' \
        "$main" \
        || die "timezone_setup fehlt in 9990-main.sh."

    echo
    echo "OK: live-boot wurde gepatcht."
}


# ============================================================
# Apply system-specific patch
# ============================================================

case "$SYSTEM" in

    casper)
        patch_casper
        ;;

    live-boot)
        patch_live_boot
        ;;

    *)
        die "Interner Fehler: unbekanntes System '$SYSTEM'."
        ;;

esac


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
# Verify content
# ============================================================

echo
echo "==> Prüfe Inhalt der neuen Initrd ..."
echo

LISTING="$WORK/listing"

lsinitramfs "$OUTPUT" > "$LISTING"


if [[ "$SYSTEM" == "casper" ]]; then

    grep -Fq \
        'scripts/casper-bottom/23timezone' \
        "$LISTING" \
        || die "casper Timezone-Hook fehlt."

    echo "OK: casper Timezone-Hook vorhanden."


elif [[ "$SYSTEM" == "live-boot" ]]; then

    grep -Fq \
        'usr/lib/live/boot/023-timezone' \
        "$LISTING" \
        || die "live-boot Timezone-Hook fehlt."

    grep -Fq \
        'usr/lib/live/boot/9990-main.sh' \
        "$LISTING" \
        || die "9990-main.sh fehlt."

    echo "OK: live-boot Timezone-Hook vorhanden."
fi


# ============================================================
# Extract resulting initrd for deeper verification
# ============================================================

echo
echo "==> Prüfe Dateien der neuen Initrd ..."
echo

rm -rf "$VERIFY"
mkdir -p "$VERIFY"

cd "$VERIFY"

zstd -dc "$OUTPUT" | cpio -idm --quiet


if [[ "$SYSTEM" == "casper" ]]; then

    NEW_HOOK="$VERIFY/scripts/casper-bottom/23timezone"
    NEW_ORDER="$VERIFY/scripts/casper-bottom/ORDER"


    [[ -f "$NEW_HOOK" ]] \
        || die "23timezone fehlt in der neuen Initrd."

    [[ -f "$NEW_ORDER" ]] \
        || die "ORDER fehlt in der neuen Initrd."


    grep -Fq \
        'timezone=' \
        "$NEW_HOOK" \
        || die "timezone= fehlt im Casper-Hook."


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


    echo "OK: Casper ORDER ist korrekt."


elif [[ "$SYSTEM" == "live-boot" ]]; then

    NEW_COMPONENT="$VERIFY/usr/lib/live/boot/023-timezone"
    NEW_MAIN="$VERIFY/usr/lib/live/boot/9990-main.sh"


    [[ -f "$NEW_COMPONENT" ]] \
        || die "023-timezone fehlt in der neuen Initrd."

    [[ -f "$NEW_MAIN" ]] \
        || die "9990-main.sh fehlt in der neuen Initrd."


    grep -Fq \
        'timezone_setup' \
        "$NEW_COMPONENT" \
        || die "timezone_setup fehlt in 023-timezone."

    grep -Fq \
        'timezone_setup' \
        "$NEW_MAIN" \
        || die "timezone_setup fehlt in 9990-main.sh."


    echo "OK: live-boot timezone_setup ist eingebaut."


    echo
    echo "==> Relevanter Abschnitt von 9990-main.sh:"
    echo

    grep -n -C 5 \
        'timezone_setup' \
        "$NEW_MAIN" \
        || true

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
