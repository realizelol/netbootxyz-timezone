#!/bin/bash

set -e

# ============================================================
# Generic Live Initrd Timezone Patcher
#
# Kali / Debian live-boot:
#   - install 0023-timezone
#   - patch 9990-main.sh
#   - call timezone_setup directly after Swap
#
# Ubuntu / Mint casper:
#   - currently NOT patched
#   - initrd is simply copied to the output
#
# Unknown initrd:
#   - abort
# ============================================================

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT_ABS="$(realpath "${INPUT}")"
OUTPUT_ABS="$(realpath -m "${OUTPUT}")"

WORKDIR="$(mktemp -d /tmp/timezone-patch-XXXXXX)"
ROOT="${WORKDIR}/root"

cleanup()
{
    rm -rf "${WORKDIR}"
}

trap cleanup EXIT

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"
echo

# ------------------------------------------------------------
# Required tools
# ------------------------------------------------------------

echo "==> Prüfe benötigte Werkzeuge ..."

for cmd in file cpio gzip zstd xz bzip2 lz4 lzop realpath; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: Required command '${cmd}' not found."
        exit 1
    fi
done

echo

# ------------------------------------------------------------
# Check input
# ------------------------------------------------------------

echo "==> Prüfe Input ..."

if [[ ! -f "${INPUT_ABS}" ]]; then
    echo "ERROR: Input-Datei nicht gefunden:"
    echo "       ${INPUT_ABS}"
    exit 1
fi

FILE_INFO="$(file "${INPUT_ABS}")"

echo "${FILE_INFO}"

# ------------------------------------------------------------
# Detect compression
# ------------------------------------------------------------

COMPRESSION=""

case "${FILE_INFO}" in
    *"Zstandard compressed data"*)
        COMPRESSION="zstd"
        ;;
    *"gzip compressed data"*)
        COMPRESSION="gzip"
        ;;
    *"XZ compressed data"*)
        COMPRESSION="xz"
        ;;
    *"bzip2 compressed data"*)
        COMPRESSION="bzip2"
        ;;
    *"LZ4 compressed data"*)
        COMPRESSION="lz4"
        ;;
    *"LZO compressed data"*)
        COMPRESSION="lzo"
        ;;
    *)
        echo
        echo "ERROR: Nicht unterstützte Initrd-Kompression."
        echo
        echo "file-Ausgabe:"
        echo "${FILE_INFO}"
        exit 1
        ;;
esac

echo "Compression: ${COMPRESSION}"
echo

# ------------------------------------------------------------
# Extract initrd
# ------------------------------------------------------------

echo "==> Entpacke Initrd ..."

mkdir -p "${ROOT}"

case "${COMPRESSION}" in
    zstd)
        zstd -dc "${INPUT_ABS}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;

    gzip)
        gzip -dc "${INPUT_ABS}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;

    xz)
        xz -dc "${INPUT_ABS}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;

    bzip2)
        bzip2 -dc "${INPUT_ABS}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;

    lz4)
        lz4 -dc "${INPUT_ABS}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;

    lzo)
        lzop -dc "${INPUT_ABS}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
esac

echo

# ------------------------------------------------------------
# Detect live system
# ------------------------------------------------------------

echo "==> Erkenne Live-System ..."

LIVE_BOOT_MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"
LIVE_BOOT_DIR="${ROOT}/usr/lib/live/boot"

CASPER_CONF="${ROOT}/etc/casper.conf"
CASPER_SCRIPT="${ROOT}/scripts/casper"

# ------------------------------------------------------------
# Kali / Debian live-boot
# ------------------------------------------------------------

if [[ -f "${LIVE_BOOT_MAIN}" ]] &&
   grep -q 'mount_images_in_directory' "${LIVE_BOOT_MAIN}" 2>/dev/null
then

    LIVE_SYSTEM="live-boot"

    echo "OK: live-boot erkannt."
    echo

    # --------------------------------------------------------
    # Timezone hook
    # --------------------------------------------------------

    PATCH_FILE="${SCRIPT_DIR}/../patches/0023-timezone"

    if [[ ! -f "${PATCH_FILE}" ]]; then
        echo "ERROR: Timezone-Hook nicht gefunden:"
        echo "       ${PATCH_FILE}"
        exit 1
    fi

    echo "==> Installiere Timezone-Hook ..."

    mkdir -p "${LIVE_BOOT_DIR}"

    install -m 0755 \
        "${PATCH_FILE}" \
        "${LIVE_BOOT_DIR}/0023-timezone"

    echo "    ${LIVE_BOOT_DIR}/0023-timezone"

    # --------------------------------------------------------
    # Remove old timezone hooks
    # --------------------------------------------------------

    echo "==> Entferne alte Timezone-Hooks ..."

    find "${LIVE_BOOT_DIR}" \
        -maxdepth 1 \
        -type f \
        \( -name '*timezone*' -o -name '023-timezone' \) \
        ! -name '0023-timezone' \
        -print \
        -delete 2>/dev/null || true

    echo

    # --------------------------------------------------------
    # Verify installed hook
    # --------------------------------------------------------

    echo "==> Prüfe installierten Timezone-Hook ..."

    if ! grep -q '^timezone_setup()' \
        "${LIVE_BOOT_DIR}/0023-timezone"
    then
        echo "ERROR: timezone_setup() wurde nicht gefunden."
        exit 1
    fi

    if ! grep -q '/usr/share/zoneinfo/' \
        "${LIVE_BOOT_DIR}/0023-timezone"
    then
        echo "ERROR: zoneinfo-Pfad fehlt im Timezone-Hook."
        exit 1
    fi

    echo "OK."
    echo

    # --------------------------------------------------------
    # Patch 9990-main.sh
    #
    # Remove every existing invocation first.
    # This makes the patch idempotent.
    # --------------------------------------------------------

    echo "==> Patch 9990-main.sh ..."

    MAIN="${LIVE_BOOT_MAIN}"

    sed -i \
        '/^[[:space:]]*timezone_setup[[:space:]]*$/d' \
        "${MAIN}"

    MAIN_TMP="${MAIN}.tmp"

    awk '
    BEGIN {
        inserted = 0
    }

    {
        if (!inserted && $0 ~ /^[[:space:]]*Swap[[:space:]]*$/) {
            print $0
            print ""
            print "\t# Apply kernel-command-line timezone as late as possible,"
            print "\t# after the Live root filesystem and swap setup are complete."
            print "\ttimezone_setup"
            inserted = 1
            next
        }

        print $0
    }

    END {
        if (!inserted) {
            exit 42
        }
    }
    ' "${MAIN}" > "${MAIN_TMP}" || {

        rc=$?

        rm -f "${MAIN_TMP}"

        if [[ ${rc} -eq 42 ]]; then
            echo "ERROR: 'Swap' konnte in 9990-main.sh nicht gefunden werden."
        else
            echo "ERROR: Patch von 9990-main.sh fehlgeschlagen."
        fi

        exit 1
    }

    mv "${MAIN_TMP}" "${MAIN}"

    echo "    timezone_setup eingefügt: direkt nach Swap."
    echo

    # --------------------------------------------------------
    # Verify placement
    # --------------------------------------------------------

    echo "==> Prüfe Position von timezone_setup ..."

    TIMEZONE_COUNT="$(
        grep -c \
            '^[[:space:]]*timezone_setup[[:space:]]*$' \
            "${MAIN}" || true
    )"

    if [[ "${TIMEZONE_COUNT}" != "1" ]]; then
        echo "ERROR: Erwartet genau einen timezone_setup-Aufruf."
        echo "       Gefunden: ${TIMEZONE_COUNT}"
        exit 1
    fi

    SWAP_LINE="$(
        grep -n -m1 \
            '^[[:space:]]*Swap[[:space:]]*$' \
            "${MAIN}" |
        cut -d: -f1
    )"

    TIMEZONE_LINE="$(
        grep -n -m1 \
            '^[[:space:]]*timezone_setup[[:space:]]*$' \
            "${MAIN}" |
        cut -d: -f1
    )"

    if [[ -z "${SWAP_LINE}" || -z "${TIMEZONE_LINE}" ]]; then
        echo "ERROR: Swap/timezone_setup konnte nicht geprüft werden."
        exit 1
    fi

    if (( TIMEZONE_LINE <= SWAP_LINE )); then
        echo "ERROR: timezone_setup steht nicht nach Swap."
        exit 1
    fi

    echo "OK:"
    echo "    Swap            : Zeile ${SWAP_LINE}"
    echo "    timezone_setup  : Zeile ${TIMEZONE_LINE}"
    echo

    # --------------------------------------------------------
    # Show result
    # --------------------------------------------------------

    echo "==> Ergebnis 9990-main.sh:"

    START=$((TIMEZONE_LINE - 8))
    END=$((TIMEZONE_LINE + 12))

    if (( START < 1 )); then
        START=1
    fi

    sed -n "${START},${END}p" "${MAIN}" |
        nl -ba -v "${START}"

    echo

    # --------------------------------------------------------
    # Final verification
    # --------------------------------------------------------

    echo "==> Finale Prüfung ..."

    if [[ ! -x "${LIVE_BOOT_DIR}/0023-timezone" ]]; then
        echo "ERROR: Timezone-Hook ist nicht ausführbar."
        exit 1
    fi

    if ! grep -q '^timezone_setup()' \
        "${LIVE_BOOT_DIR}/0023-timezone"
    then
        echo "ERROR: timezone_setup() fehlt."
        exit 1
    fi

    if ! grep -q \
        '^[[:space:]]*timezone_setup[[:space:]]*$' \
        "${MAIN}"
    then
        echo "ERROR: timezone_setup-Aufruf fehlt."
        exit 1
    fi

    echo "OK."

# ------------------------------------------------------------
# Ubuntu / Mint casper
#
# Do NOT modify it yet.
# Just pass the original initrd through.
# ------------------------------------------------------------

elif [[ -f "${CASPER_CONF}" ]] ||
     [[ -f "${CASPER_SCRIPT}" ]]
then

    LIVE_SYSTEM="casper"

    echo "OK: casper erkannt."
    echo
    echo "==> Mint/Ubuntu-casper wird derzeit nicht gepatcht."
    echo "    Initrd wird unverändert übernommen."
    echo

    cp -f "${INPUT_ABS}" "${OUTPUT_ABS}"

    chmod 0644 "${OUTPUT_ABS}"

    echo "============================================================"
    echo " Fertig"
    echo "============================================================"
    echo
    echo "Output: ${OUTPUT}"
    echo
    file "${OUTPUT_ABS}"

    exit 0

# ------------------------------------------------------------
# Unknown
# ------------------------------------------------------------

else

    echo "ERROR: Kein unterstütztes Live-System erkannt."
    echo
    echo "Vorhandene relevante Dateien:"

    find "${ROOT}" \
        \( \
            -path '*/live/*' \
            -o -path '*/casper*' \
            -o -name '9990-main.sh' \
            -o -name 'casper.conf' \
        \) \
        -type f \
        -print 2>/dev/null |
        head -100

    exit 1
fi

# ------------------------------------------------------------
# Repack initrd
# ------------------------------------------------------------

echo
echo "==> Packe Initrd ..."

# IMPORTANT:
# Always use an absolute temporary output path.
# Otherwise a 'cd "${ROOT}"' subshell changes the output location.

TMP_OUTPUT="${OUTPUT_ABS}.tmp"

rm -f "${TMP_OUTPUT}"

case "${COMPRESSION}" in

    zstd)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc |
                zstd -T0 -19 -o "${TMP_OUTPUT}"
        )
        ;;

    gzip)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc |
                gzip -9 > "${TMP_OUTPUT}"
        )
        ;;

    xz)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc |
                xz -T0 -9 > "${TMP_OUTPUT}"
        )
        ;;

    bzip2)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc |
                bzip2 -9 > "${TMP_OUTPUT}"
        )
        ;;

    lz4)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc |
                lz4 -z > "${TMP_OUTPUT}"
        )
        ;;

    lzo)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc |
                lzop -9 > "${TMP_OUTPUT}"
        )
        ;;

esac

if [[ ! -f "${TMP_OUTPUT}" ]]; then
    echo "ERROR: Initrd wurde nicht erzeugt:"
    echo "       ${TMP_OUTPUT}"
    exit 1
fi

mv -f "${TMP_OUTPUT}" "${OUTPUT_ABS}"

chmod 0644 "${OUTPUT_ABS}"

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
echo
echo "Output: ${OUTPUT}"
echo
file "${OUTPUT_ABS}"
echo
