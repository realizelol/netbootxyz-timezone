#!/usr/bin/env bash

set -euo pipefail


# ============================================================
# Root check
# ============================================================

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi


# ============================================================
# Configuration
# ============================================================

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PATCH="$REPO_ROOT/patches/0023-timezone"

WORK="$(mktemp -d /tmp/timezone-patch-XXXXXXXX)"
ROOT="$WORK/root"

mkdir -p "$ROOT"


# ============================================================
# Cleanup
# ============================================================

cleanup()
{
    rm -rf "$WORK"
}

trap cleanup EXIT


# ============================================================
# Helpers
# ============================================================

die()
{
    echo
    echo "ERROR: $*" >&2
    exit 1
}


have()
{
    command -v "$1" >/dev/null 2>&1
}


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
# Check required tools
# ============================================================

echo "==> Prüfe benötigte Werkzeuge ..."
echo

for cmd in file cpio awk sed grep install find; do
    have "$cmd" || die "Required command '$cmd' not found."
done

echo "OK."


# ============================================================
# Check input
# ============================================================

echo
echo "==> Prüfe Input ..."

[[ -f "$INPUT" ]] || die "Input-Datei '$INPUT' nicht gefunden."

FILE_INFO="$(file "$INPUT")"

echo "$FILE_INFO"
echo


# ============================================================
# Detect compression
# ============================================================

COMPRESSION=""

case "$FILE_INFO" in
    *Zstandard*)
        COMPRESSION="zstd"
        ;;
    *gzip*)
        COMPRESSION="gzip"
        ;;
    *XZ*)
        COMPRESSION="xz"
        ;;
    *bzip2*)
        COMPRESSION="bzip2"
        ;;
    *LZ4*)
        COMPRESSION="lz4"
        ;;
    *LZO*)
        COMPRESSION="lzop"
        ;;
    *)
        die "Nicht unterstützte Initrd-Kompression."
        ;;
esac

echo "Compression: $COMPRESSION"
echo


# ============================================================
# Check decompressor
# ============================================================

case "$COMPRESSION" in
    zstd)
        have zstd || die "Required command 'zstd' not found."
        ;;
    gzip)
        have gzip || die "Required command 'gzip' not found."
        ;;
    xz)
        have xz || die "Required command 'xz' not found."
        ;;
    bzip2)
        have bzip2 || die "Required command 'bzip2' not found."
        ;;
    lz4)
        have lz4 || die "Required command 'lz4' not found."
        ;;
    lzop)
        have lzop || die "Required command 'lzop' not found."
        ;;
esac


# ============================================================
# Extract initrd
# ============================================================

echo "==> Entpacke Initrd ..."
echo

case "$COMPRESSION" in
    zstd)
        zstd -d -c "$INPUT" | (
            cd "$ROOT"
            cpio -idmu
        )
        ;;
    gzip)
        gzip -d -c "$INPUT" | (
            cd "$ROOT"
            cpio -idmu
        )
        ;;
    xz)
        xz -d -c "$INPUT" | (
            cd "$ROOT"
            cpio -idmu
        )
        ;;
    bzip2)
        bzip2 -d -c "$INPUT" | (
            cd "$ROOT"
            cpio -idmu
        )
        ;;
    lz4)
        lz4 -d -c "$INPUT" | (
            cd "$ROOT"
            cpio -idmu
        )
        ;;
    lzop)
        lzop -d -c "$INPUT" | (
            cd "$ROOT"
            cpio -idmu
        )
        ;;
esac

echo


# ============================================================
# Check patch
# ============================================================

[[ -f "$PATCH" ]] ||
    die "Timezone-Hook '$PATCH' nicht gefunden."

echo "Timezone hook:"
echo "$PATCH"
echo


# ============================================================
# Detect live system
# ============================================================

echo "==> Erkenne Live-System ..."

LIVE_BOOT=0
CASPER=0


# ------------------------------------------------------------
# Debian live-boot
# ------------------------------------------------------------

if [[ -f "$ROOT/usr/lib/live/boot/9990-main.sh" ]] ||
   [[ -d "$ROOT/usr/lib/live/boot" ]]; then

    LIVE_BOOT=1

    echo "OK: live-boot erkannt."

fi


# ------------------------------------------------------------
# Ubuntu casper
# ------------------------------------------------------------

if [[ -d "$ROOT/scripts/casper-bottom" ]] &&
   [[ -f "$ROOT/scripts/casper" ]]; then

    CASPER=1

    echo "OK: casper erkannt."

fi


# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

if (( LIVE_BOOT == 0 && CASPER == 0 )); then

    echo
    echo "ERROR: Kein unterstütztes Live-System erkannt."
    echo

    echo "Relevante Dateien:"

    find "$ROOT" \
        -type f \
        \( \
            -path "*/scripts/casper*" \
            -o \
            -path "*/usr/lib/live/*" \
        \) \
        -print \
        2>/dev/null | sort | head -200

    exit 1

fi

echo

if (( LIVE_BOOT == 1 && CASPER == 1 )); then
    echo "Live-System: live-boot + casper"
elif (( LIVE_BOOT == 1 )); then
    echo "Live-System: live-boot"
else
    echo "Live-System: casper"
fi

echo


# ============================================================
# ============================================================
# LIVE-BOOT
# ============================================================
# ============================================================

if (( LIVE_BOOT == 1 )); then

    MAIN="$ROOT/usr/lib/live/boot/9990-main.sh"

    [[ -f "$MAIN" ]] || die "live-boot 9990-main.sh nicht gefunden."

    echo "============================================================"
    echo " Patching live-boot"
    echo "============================================================"
    echo

    install -m 0755 \
        "$PATCH" \
        "$ROOT/usr/lib/live/boot/0023-timezone"

    echo "Installed:"
    echo "  $ROOT/usr/lib/live/boot/0023-timezone"

    # --------------------------------------------------------
    # Insert after Swap
    # --------------------------------------------------------

    TMP_MAIN="$WORK/9990-main.sh.new"

    awk '
    {
        print

        if ($0 ~ /^[[:space:]]*Swap[[:space:]]*$/) {
            print ""
            print "\t# Apply kernel-command-line timezone."
            print "\t# The root filesystem is available at this point."
            print "\ttimezone_setup"
        }
    }
    ' "$MAIN" > "$TMP_MAIN"
    mv "$TMP_MAIN" "$MAIN"

    # --------------------------------------------------------
    # Verify
    # --------------------------------------------------------

    SWAP_LINE="$(
        grep -n \
            -E '^[[:space:]]*Swap[[:space:]]*$' \
            "$MAIN" | tail -n1 | cut -d: -f1 || true
    )"

    TZ_LINE="$(
        grep -n \
            -E '^[[:space:]]*timezone_setup[[:space:]]*$' \
            "$MAIN" | tail -n1 | cut -d: -f1 || true
    )"

    [[ -n "$SWAP_LINE" ]] || die "Swap-Zeile in 9990-main.sh nicht gefunden."

    [[ -n "$TZ_LINE" ]] || die "timezone_setup konnte nicht eingefügt werden."

    if (( TZ_LINE <= SWAP_LINE )); then
        die "timezone_setup steht nicht nach Swap."
    fi

    echo
    echo "OK:"
    echo "  Swap           : Zeile $SWAP_LINE"
    echo "  timezone_setup : Zeile $TZ_LINE"

    echo
    echo "Ausschnitt:"
    echo

    START=$(( SWAP_LINE > 4 ? SWAP_LINE - 4 : 1 ))
    END=$(( TZ_LINE + 8 ))
    sed -n "${START},${END}p" "$MAIN"

    [[ -s "$ROOT/usr/lib/live/boot/0023-timezone" ]] || die "live-boot Timezone-Hook fehlt."

    echo
    echo "live-boot patch erfolgreich."

fi


# ============================================================
# ============================================================
# CASPER
# ============================================================
# ============================================================

if (( CASPER == 1 )); then

    echo
    echo "============================================================"
    echo " Patching casper"
    echo "============================================================"
    echo

    CASPER_DIR="$ROOT/scripts/casper-bottom"
    ORDER="$CASPER_DIR/ORDER"

    [[ -d "$CASPER_DIR" ]] || die "casper-bottom Verzeichnis nicht gefunden."

    [[ -f "$ORDER" ]] || die "casper-bottom/ORDER nicht gefunden."

    # --------------------------------------------------------
    # Install hook
    # --------------------------------------------------------

    sed -e '1{/^timezone_setup()/d}' -e '{/^}/d}' -e 's/\breturn 0\b/exit 0/g' -e 's/\blocal \b//g' "$PATCH" > "$CASPER_DIR/23timezone"
    chmod 755 "$CASPER_DIR/23timezone"

    echo "Installed:"
    echo "  $CASPER_DIR/23timezone"
    # --------------------------------------------------------
    # Show original ORDER
    # --------------------------------------------------------
    echo
    echo "Original casper-bottom/ORDER:"
    echo "------------------------------------------------------------"
    cat "$ORDER"
    echo "------------------------------------------------------------"

    # --------------------------------------------------------
    # Remove previous timezone entries
    # --------------------------------------------------------

    TMP_ORDER="$WORK/ORDER.new"
    awk '
    $0 !~ /\/scripts\/casper-bottom\/23timezone([[:space:]]|$)/ {
        print
    }
    ' "$ORDER" > "$TMP_ORDER"
    mv "$TMP_ORDER" "$ORDER"

    # --------------------------------------------------------
    # Find configure_init
    # --------------------------------------------------------

    CONFIG_LINE="$(
        grep -n \
            -E '/scripts/casper-bottom/25configure_init([[:space:]]|$)' \
            "$ORDER" | head -n1 | cut -d: -f1 || true
    )"

    if [[ -z "$CONFIG_LINE" ]]; then
        echo
        echo "WARNING: 25configure_init nicht gefunden."
        echo
        echo "Casper ORDER:"
        cat "$ORDER"
        echo
        die "Kein geeigneter Einhängepunkt für 23timezone gefunden."
    fi

    # --------------------------------------------------------
    # Insert immediately before 25configure_init
    #
    # IMPORTANT:
    # ORDER contains hook paths, not shell commands.
    # --------------------------------------------------------

    TMP_ORDER="$WORK/ORDER.new"
    awk '
    {
        if ($0 ~ /\/scripts\/casper-bottom\/25configure_init([[:space:]]|$)/) {
            print "/scripts/casper-bottom/23timezone \"$@\""
        }

        print
    }
    ' "$ORDER" > "$TMP_ORDER"

    mv "$TMP_ORDER" "$ORDER"

    # --------------------------------------------------------
    # Verify timezone entry
    # --------------------------------------------------------

    TZ_LINE="$(
        grep -n \
            -E '/scripts/casper-bottom/23timezone([[:space:]]|$)' \
            "$ORDER" | head -n1 | cut -d: -f1 || true
    )"

    CONFIG_LINE="$(
        grep -n \
            -E '/scripts/casper-bottom/25configure_init([[:space:]]|$)' \
            "$ORDER" | head -n1 | cut -d: -f1 || true
    )"

    [[ -n "$TZ_LINE" ]] || die "23timezone fehlt in ORDER."

    [[ -n "$CONFIG_LINE" ]] || die "25configure_init fehlt in ORDER."

    if (( TZ_LINE >= CONFIG_LINE )); then
        die "23timezone steht nicht vor 25configure_init."
    fi

    # --------------------------------------------------------
    # Verify hook
    # --------------------------------------------------------

    [[ -s "$CASPER_DIR/23timezone" ]] || die "Casper Timezone-Hook fehlt."

    # --------------------------------------------------------
    # Show result
    # --------------------------------------------------------
    echo
    echo "============================================================"
    echo " Casper ORDER"
    echo "============================================================"
    echo
    cat "$ORDER"
    echo
    echo "============================================================"
    echo " Casper timezone position"
    echo "============================================================"
    echo
    echo "23timezone       : Zeile $TZ_LINE"
    echo "25configure_init : Zeile $CONFIG_LINE"
    echo

    START=$(( TZ_LINE > 4 ? TZ_LINE - 4 : 1 ))
    END=$(( CONFIG_LINE + 4 ))
    echo "Ausschnitt:"
    echo
    sed -n "${START},${END}p" "$ORDER"
    echo
    echo "OK: 23timezone steht vor 25configure_init."
fi


# ============================================================
# Final verification
# ============================================================

echo
echo "============================================================"
echo " Finale Prüfung"
echo "============================================================"
echo

if (( LIVE_BOOT == 1 )); then
    [[ -f "$ROOT/usr/lib/live/boot/0023-timezone" ]] || die "live-boot Hook fehlt."
    echo "OK: live-boot Hook"
fi

if (( CASPER == 1 )); then
    [[ -f "$ROOT/scripts/casper-bottom/23timezone" ]] || die "Casper Hook fehlt."
    echo "OK: Casper Hook"
fi


# ============================================================
# Repack
# ============================================================

echo
echo "============================================================"
echo " Repack Initrd"
echo "============================================================"
echo

TMP_OUTPUT="${OUTPUT}.tmp"

rm -f "$TMP_OUTPUT"

case "$COMPRESSION" in

    zstd)
        (
            cd "$ROOT"

            find . -print0 |
                cpio \
                    --null \
                    -o \
                    -H newc \
                    --quiet
        ) |
            zstd -T0 -19 -c \
            > "$TMP_OUTPUT"
        ;;

    gzip)
        (
            cd "$ROOT"
            find . -print0 |
                cpio \
                    --null \
                    -o \
                    -H newc \
                    --quiet
        ) |
            gzip -c \
            > "$TMP_OUTPUT"
        ;;

    xz)
        (
            cd "$ROOT"
            ffind . -print0 | cpio --null -o -H newc --quiet
        ) | xz -c > "$TMP_OUTPUT"
        ;;

    bzip2)
        (
            cd "$ROOT"
            find . -print0 | cpio --null -o -H newc --quiet
        ) | bzip2 -c > "$TMP_OUTPUT"
        ;;

    lz4)
        (
            cd "$ROOT"
            find . -print0 | cpio --null -o -H newc --quiet
        ) | lz4 -z -c > "$TMP_OUTPUT"
        ;;

    lzop)
        (
            cd "$ROOT"
            find . -print0 | cpio --null -o -H newc --quiet
        ) | lzop -c > "$TMP_OUTPUT"
        ;;

    *)
        rm -f "$TMP_OUTPUT"
        die "Unbekannte Kompression: $COMPRESSION"
        ;;

esac


[[ -s "$TMP_OUTPUT" ]] || die "Erzeugte Initrd ist leer."

mv "$TMP_OUTPUT" "$OUTPUT"


# ============================================================
# Final result
# ============================================================

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
echo
echo "Input : $INPUT"
echo "Output: $OUTPUT"
echo
echo "Gepatchte Systeme:"
if (( LIVE_BOOT == 1 )); then
    echo "  - live-boot"
fi
if (( CASPER == 1 )); then
    echo "  - casper"
fi
echo
echo "Timezone wird über den Kernel-Parameter"
echo
echo "    timezone=Europe/Berlin"
echo
echo "gesetzt."
echo
echo "Für live-config/tzdata weiterhin verwenden:"
echo
echo "    nocomponents=tzdata"
echo
echo "============================================================"
