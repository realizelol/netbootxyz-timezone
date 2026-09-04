#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Generic Live Initrd Timezone Patcher
#
# Supports:
#   - Debian/Kali live-boot
#   - Ubuntu/Mint casper
#
# Installs:
#   - usr/lib/live/boot/0023-timezone
#   - usr/lib/live/config/9999-timezone
#
# The first hook handles the initramfs/live-boot phase.
# The second hook runs as the final live-config component and therefore
# restores the requested timezone after live-config/tzdata has run.
###############################################################################

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PATCH_DIR="${REPO_ROOT}/patches"

TIMEZONE_HOOK="${PATCH_DIR}/0023-timezone"
FINAL_TIMEZONE_HOOK="${PATCH_DIR}/9999-timezone"

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

WORKDIR="$(mktemp -d /tmp/timezone-patch-XXXXXXXX)"
ROOT="${WORKDIR}/root"

COMPRESSION=""

cleanup()
{
    rm -rf "${WORKDIR}"
}

trap cleanup EXIT

###############################################################################
# Helper functions
###############################################################################

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command '$1' not found."
}

###############################################################################
# Header
###############################################################################

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"
echo

###############################################################################
# Check required tools
###############################################################################

echo "==> Prüfe benötigte Werkzeuge ..."
echo

require_cmd file
require_cmd cpio
require_cmd gzip
require_cmd xz
require_cmd bzip2
require_cmd zstd
require_cmd lz4
require_cmd lzop

###############################################################################
# Check input
###############################################################################

echo "==> Prüfe Input ..."

[[ -f "${INPUT}" ]] ||
    die "Input initrd '${INPUT}' nicht gefunden."

FILE_INFO="$(file "${INPUT}")"

echo "${FILE_INFO}"

###############################################################################
# Detect compression
###############################################################################

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
        die "Unbekannte Initrd-Kompression."
        ;;
esac

echo "Compression: ${COMPRESSION}"
echo

###############################################################################
# Validate patch files
###############################################################################

[[ -f "${TIMEZONE_HOOK}" ]] ||
    die "Timezone hook nicht gefunden: ${TIMEZONE_HOOK}"

[[ -f "${FINAL_TIMEZONE_HOOK}" ]] ||
    die "Final timezone hook nicht gefunden: ${FINAL_TIMEZONE_HOOK}"

###############################################################################
# Extract initrd
###############################################################################

echo "==> Entpacke Initrd ..."

mkdir -p "${ROOT}"

case "${COMPRESSION}" in
    zstd)
        zstd -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idmu --quiet
        )
        ;;

    gzip)
        gzip -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idmu --quiet
        )
        ;;

    xz)
        xz -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idmu --quiet
        )
        ;;

    bzip2)
        bzip2 -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idmu --quiet
        )
        ;;

    lz4)
        lz4 -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idmu --quiet
        )
        ;;

    lzo)
        lzop -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idmu --quiet
        )
        ;;
esac

echo

###############################################################################
# Detect live system
###############################################################################

echo "==> Erkenne Live-System ..."

LIVE_TYPE=""

if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]]; then
    LIVE_TYPE="live-boot"
    echo "OK: live-boot erkannt."
elif [[ -f "${ROOT}/scripts/live" ]] &&
     [[ -f "${ROOT}/scripts/casper" ]]; then
    LIVE_TYPE="casper"
    echo "OK: casper erkannt."
else
    echo "ERROR: Kein unterstütztes Live-System erkannt."
    echo
    echo "Vorhandene relevante Dateien:"

    find "${ROOT}" \
        -type f \
        \( \
            -path '*/live/*' -o \
            -path '*/casper*' \
        \) \
        -print \
        2>/dev/null \
        | head -100

    exit 1
fi

echo

###############################################################################
# Install initrd timezone hook
###############################################################################

echo "==> Installiere Timezone-Hook ..."

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    mkdir -p "${ROOT}/usr/lib/live/boot"

    echo "    ${ROOT}/usr/lib/live/boot/0023-timezone"

    cp -f \
        "${TIMEZONE_HOOK}" \
        "${ROOT}/usr/lib/live/boot/0023-timezone"

    chmod 0755 \
        "${ROOT}/usr/lib/live/boot/0023-timezone"

else

    echo "    Initrd-Hook für casper wird nicht benötigt."
    echo "    Casper bleibt unverändert."
fi

###############################################################################
# Install final live-config timezone hook
###############################################################################

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    echo
    echo "==> Installiere finalen live-config Timezone-Hook ..."

    mkdir -p "${ROOT}/usr/lib/live/config"

    echo "    ${ROOT}/usr/lib/live/config/9999-timezone"

    cp -f \
        "${FINAL_TIMEZONE_HOOK}" \
        "${ROOT}/usr/lib/live/config/9999-timezone"

    chmod 0755 \
        "${ROOT}/usr/lib/live/config/9999-timezone"

fi

###############################################################################
# Patch live-boot 9990-main.sh
###############################################################################

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"

    [[ -f "${MAIN}" ]] ||
        die "9990-main.sh nicht gefunden."

    echo
    echo "==> Patch 9990-main.sh ..."

    # Remove previous timezone_setup calls.
    sed -i \
        '/^[[:space:]]*timezone_setup[[:space:]]*$/d' \
        "${MAIN}"

    # Remove previous timezone comments that this script may have inserted.
    sed -i \
        '/^[[:space:]]*# Apply kernel-command-line timezone/d' \
        "${MAIN}"

    sed -i \
        '/^[[:space:]]*# after the Live root filesystem and swap setup are complete\./d' \
        "${MAIN}"

    # Insert after the Swap line.
    if grep -qE '^[[:space:]]*Swap[[:space:]]*$' "${MAIN}"; then

        sed -i \
            '/^[[:space:]]*Swap[[:space:]]*$/a\
\
\t# Apply kernel-command-line timezone as late as possible,\
\t# after the Live root filesystem and swap setup are complete.\
\ttimezone_setup' \
            "${MAIN}"

        echo "    timezone_setup eingefügt: direkt nach Swap."

    else
        echo "    WARNUNG: 'Swap' nicht gefunden."
        echo "    timezone_setup wird nicht in 9990-main.sh eingefügt."
    fi

    echo
    echo "==> Prüfe Position von timezone_setup ..."

    SWAP_LINE="$(
        grep -nE '^[[:space:]]*Swap[[:space:]]*$' "${MAIN}" |
        head -1 |
        cut -d: -f1
    )"

    TZ_LINE="$(
        grep -nE '^[[:space:]]*timezone_setup[[:space:]]*$' "${MAIN}" |
        head -1 |
        cut -d: -f1
    )"

    if [[ -n "${SWAP_LINE}" && -n "${TZ_LINE}" ]]; then

        echo "OK:"
        echo "    Swap            : Zeile ${SWAP_LINE}"
        echo "    timezone_setup  : Zeile ${TZ_LINE}"

        if (( TZ_LINE <= SWAP_LINE )); then
            die "timezone_setup steht nicht nach Swap."
        fi

    else
        echo "WARNUNG:"
        echo "    Swap            : ${SWAP_LINE:-nicht gefunden}"
        echo "    timezone_setup  : ${TZ_LINE:-nicht gefunden}"
    fi

    echo
    echo "==> Ergebnis 9990-main.sh:"

    if [[ -n "${TZ_LINE}" ]]; then
        START=$(( TZ_LINE - 8 ))
        END=$(( TZ_LINE + 8 ))

        (( START < 1 )) && START=1

        nl -ba "${MAIN}" |
            sed -n "${START},${END}p"
    fi

fi

###############################################################################
# Verify hooks
###############################################################################

echo
echo "==> Prüfe installierte Hooks ..."

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    [[ -x "${ROOT}/usr/lib/live/boot/0023-timezone" ]] ||
        die "0023-timezone wurde nicht korrekt installiert."

    echo "OK: usr/lib/live/boot/0023-timezone"

    [[ -x "${ROOT}/usr/lib/live/config/9999-timezone" ]] ||
        die "9999-timezone wurde nicht korrekt installiert."

    echo "OK: usr/lib/live/config/9999-timezone"

fi

###############################################################################
# Show live-config component ordering
###############################################################################

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    echo
    echo "==> Prüfe live-config Komponenten ..."

    if [[ -d "${ROOT}/usr/lib/live/config" ]]; then

        echo
        find "${ROOT}/usr/lib/live/config" \
            -maxdepth 1 \
            -type f \
            -printf '%f\n' |
            sort |
            tail -20

        if [[ -f "${ROOT}/usr/lib/live/config/9999-timezone" ]]; then
            echo
            echo "OK: 9999-timezone ist als finaler Hook vorhanden."
        fi

    fi
fi

###############################################################################
# Repack initrd
###############################################################################

echo
echo "==> Packe Initrd ..."

TMP_OUTPUT="${OUTPUT}.tmp"

rm -f "${TMP_OUTPUT}"

case "${COMPRESSION}" in

    zstd)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                zstd -T0 -19 -c
        ) > "${TMP_OUTPUT}"
        ;;

    gzip)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                gzip -9 -c
        ) > "${TMP_OUTPUT}"
        ;;

    xz)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                xz -c -9
        ) > "${TMP_OUTPUT}"
        ;;

    bzip2)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                bzip2 -9 -c
        ) > "${TMP_OUTPUT}"
        ;;

    lz4)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                lz4 -9 -c
        ) > "${TMP_OUTPUT}"
        ;;

    lzo)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                lzop -9 -c
        ) > "${TMP_OUTPUT}"
        ;;

esac

[[ -s "${TMP_OUTPUT}" ]] ||
    die "Erzeugte Initrd ist leer."

mv -f \
    "${TMP_OUTPUT}" \
    "${OUTPUT}"

chmod 0644 "${OUTPUT}"

###############################################################################
# Final verification
###############################################################################

echo
echo "==> Finale Prüfung ..."

[[ -f "${OUTPUT}" ]] ||
    die "Output-Datei wurde nicht erzeugt."

ls -lh "${OUTPUT}"

echo
echo "Kompression der erzeugten Initrd:"
file "${OUTPUT}"

echo
echo "============================================================"
echo " Fertig."
echo "============================================================"
echo
echo "Output: ${OUTPUT}"
