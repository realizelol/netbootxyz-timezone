#!/bin/bash

set -e

###############################################################################
# Generic Live Initrd Timezone Patcher
#
# Supported:
#   - Debian/Kali live-boot
#   - Ubuntu/Mint casper
#
# The timezone is supplied through the kernel command line:
#
#     timezone=Europe/Berlin
#
# live-config should additionally receive:
#
#     nocomponents=tzdata
#
###############################################################################

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PATCH="${REPO_ROOT}/patches/0023-timezone"

TMPDIR="$(mktemp -d -t timezone-patch-XXXXXXXX)"
ROOT="${TMPDIR}/root"

cleanup()
{
    rm -rf "${TMPDIR}"
}

trap cleanup EXIT

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"
echo

###############################################################################
# Required tools
###############################################################################

echo "==> Prüfe benötigte Werkzeuge ..."

required_commands=(
    file
    cpio
    gzip
    xz
    zstd
    lz4
    lzop
    bzip2
    find
    sed
    awk
    grep
    cp
    mv
    rm
    mkdir
)

for cmd in "${required_commands[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: Required command '${cmd}' not found." >&2
        exit 1
    fi
done

echo

###############################################################################
# Input validation
###############################################################################

if [[ ! -f "${INPUT}" ]]; then
    echo "ERROR: Input '${INPUT}' nicht gefunden." >&2
    exit 1
fi

if [[ ! -f "${PATCH}" ]]; then
    echo "ERROR: Timezone-Hook '${PATCH}' nicht gefunden." >&2
    exit 1
fi

echo "==> Prüfe Input ..."

FILE_INFO="$(file "${INPUT}")"
echo "${FILE_INFO}"

###############################################################################
# Detect compression
###############################################################################

COMPRESSION=""

case "${FILE_INFO}" in
    *"Zstandard compressed data"*)
        COMPRESSION="zstd"
        ;;
    *"XZ compressed data"*)
        COMPRESSION="xz"
        ;;
    *"gzip compressed data"*)
        COMPRESSION="gzip"
        ;;
    *"LZ4 compressed data"*)
        COMPRESSION="lz4"
        ;;
    *"LZO compressed data"*)
        COMPRESSION="lzop"
        ;;
    *"bzip2 compressed data"*)
        COMPRESSION="bzip2"
        ;;
    *"ASCII cpio archive"*|*"cpio archive"*)
        COMPRESSION="none"
        ;;
    *)
        echo "ERROR: Unbekanntes Initrd-Format." >&2
        exit 1
        ;;
esac

echo "Compression: ${COMPRESSION}"
echo

###############################################################################
# Extract initrd
###############################################################################

echo "==> Entpacke Initrd ..."

mkdir -p "${ROOT}"

cd "${ROOT}"

case "${COMPRESSION}" in
    zstd)
        zstd -dc "${REPO_ROOT}/${INPUT}" | cpio -idm --quiet
        ;;

    xz)
        xz -dc "${REPO_ROOT}/${INPUT}" | cpio -idm --quiet
        ;;

    gzip)
        gzip -dc "${REPO_ROOT}/${INPUT}" | cpio -idm --quiet
        ;;

    lz4)
        lz4 -dc "${REPO_ROOT}/${INPUT}" | cpio -idm --quiet
        ;;

    lzop)
        lzop -dc "${REPO_ROOT}/${INPUT}" | cpio -idm --quiet
        ;;

    bzip2)
        bzip2 -dc "${REPO_ROOT}/${INPUT}" | cpio -idm --quiet
        ;;

    none)
        cpio -idm --quiet < "${REPO_ROOT}/${INPUT}"
        ;;
esac

cd "${REPO_ROOT}"

echo

###############################################################################
# Detect live implementation
###############################################################################

echo "==> Erkenne Live-System ..."

LIVE_TYPE=""

#
# Debian/Kali live-boot
#
if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]] &&
   [[ -d "${ROOT}/usr/lib/live/boot" ]]; then

    LIVE_TYPE="live-boot"

#
# Ubuntu/Mint casper
#
elif [[ -f "${ROOT}/scripts/casper" ]] &&
     [[ -d "${ROOT}/scripts/casper-bottom" ]]; then

    LIVE_TYPE="casper"

fi

if [[ -z "${LIVE_TYPE}" ]]; then
    echo "ERROR: Kein unterstütztes Live-System erkannt."
    echo
    echo "Vorhandene relevante Dateien:"

    find "${ROOT}" \
        \( \
            -path "*/usr/lib/live/*" \
            -o -path "*/scripts/casper*" \
            -o -path "*/scripts/casper-bottom/*" \
        \) \
        -type f \
        -print 2>/dev/null | sort

    exit 1
fi

echo "OK: ${LIVE_TYPE} erkannt."
echo
echo "==> Live-System: ${LIVE_TYPE}"
echo

###############################################################################
# Install common timezone hook
###############################################################################

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    TARGET="${ROOT}/usr/lib/live/boot/0023-timezone"

    echo "==> Installiere Timezone-Hook ..."
    echo "    ${TARGET}"

    install -m 0755 "${PATCH}" "${TARGET}"

    echo
    echo "==> Entferne alte Timezone-Hooks ..."

    find "${ROOT}/usr/lib/live/boot" \
        -maxdepth 1 \
        -type f \
        -name '*timezone*' \
        ! -name '0023-timezone' \
        -delete

    echo
    echo "==> Patch 9990-main.sh ..."

    MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"

    #
    # Remove an already inserted timezone_setup.
    #
    sed -i \
        '/^[[:space:]]*timezone_setup[[:space:]]*$/d' \
        "${MAIN}"

    #
    # Insert directly after Swap.
    #
    awk '
    BEGIN {
        inserted = 0
    }

    {
        print

        if (!inserted && $0 ~ /^[[:space:]]*Swap[[:space:]]*$/) {
            print ""
            print "\t# Apply kernel-command-line timezone as late as possible."
            print "\t# This runs after the Live root filesystem and swap setup."
            print "\ttimezone_setup"
            inserted = 1
        }
    }

    END {
        if (!inserted) {
            exit 42
        }
    }
    ' "${MAIN}" > "${MAIN}.tmp"

    mv "${MAIN}.tmp" "${MAIN}"

    echo
    echo "==> Prüfe installierten Timezone-Hook ..."

    if [[ ! -x "${TARGET}" ]]; then
        chmod 0755 "${TARGET}"
    fi

    if ! grep -q 'timezone_setup' "${TARGET}"; then
        echo "ERROR: timezone_setup nicht im Hook gefunden." >&2
        exit 1
    fi

    echo "OK."

    echo
    echo "==> Prüfe Position von timezone_setup ..."

    SWAP_LINE="$(
        grep -n -m1 \
            -E '^[[:space:]]*Swap[[:space:]]*$' \
            "${MAIN}" |
        cut -d: -f1 || true
    )"

    TIMEZONE_LINE="$(
        grep -n -m1 \
            -E '^[[:space:]]*timezone_setup[[:space:]]*$' \
            "${MAIN}" |
        cut -d: -f1 || true
    )"

    if [[ -z "${SWAP_LINE}" || -z "${TIMEZONE_LINE}" ]]; then
        echo "ERROR: Position konnte nicht ermittelt werden." >&2
        exit 1
    fi

    echo "OK:"
    echo "    Swap            : Zeile ${SWAP_LINE}"
    echo "    timezone_setup  : Zeile ${TIMEZONE_LINE}"

    if (( TIMEZONE_LINE <= SWAP_LINE )); then
        echo "ERROR: timezone_setup steht nicht nach Swap." >&2
        exit 1
    fi

    echo
    echo "==> Ergebnis 9990-main.sh:"

    sed -n \
        "$((SWAP_LINE - 3)),$((TIMEZONE_LINE + 7))p" \
        "${MAIN}"

###############################################################################
# Casper
###############################################################################

elif [[ "${LIVE_TYPE}" == "casper" ]]; then

    TARGET="${ROOT}/scripts/casper-bottom/99timezone"

    echo "==> Installiere Timezone-Hook ..."
    echo "    ${TARGET}"

    install -m 0755 "${PATCH}" "${TARGET}"

    echo
    echo "==> Prüfe Casper-Hook ..."

    if [[ ! -x "${TARGET}" ]]; then
        chmod 0755 "${TARGET}"
    fi

    if ! grep -q 'timezone_setup' "${TARGET}"; then
        echo "ERROR: timezone_setup nicht im Casper-Hook gefunden." >&2
        exit 1
    fi

    echo "OK."

fi

###############################################################################
# Final verification
###############################################################################

echo
echo "==> Finale Prüfung ..."

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    [[ -x "${ROOT}/usr/lib/live/boot/0023-timezone" ]] || {
        echo "ERROR: live-boot Timezone-Hook fehlt." >&2
        exit 1
    }

    grep -q 'timezone_setup' \
        "${ROOT}/usr/lib/live/boot/0023-timezone" || {
        echo "ERROR: timezone_setup fehlt im live-boot Hook." >&2
        exit 1
    }

    grep -q 'timezone_setup' \
        "${ROOT}/usr/lib/live/boot/9990-main.sh" || {
        echo "ERROR: timezone_setup fehlt in 9990-main.sh." >&2
        exit 1
    }

elif [[ "${LIVE_TYPE}" == "casper" ]]; then

    [[ -x "${ROOT}/scripts/casper-bottom/99timezone" ]] || {
        echo "ERROR: Casper Timezone-Hook fehlt." >&2
        exit 1
    }

    grep -q 'timezone_setup' \
        "${ROOT}/scripts/casper-bottom/99timezone" || {
        echo "ERROR: timezone_setup fehlt im Casper-Hook." >&2
        exit 1
    }

fi

echo "OK."
echo

###############################################################################
# Repack
###############################################################################

echo "==> Packe Initrd ..."

rm -f "${REPO_ROOT}/${OUTPUT}"
rm -f "${REPO_ROOT}/${OUTPUT}.tmp"

cd "${ROOT}"

case "${COMPRESSION}" in

    zstd)
        find . -print0 |
            cpio --null -o -H newc |
            zstd -T0 -19 \
                -o "${REPO_ROOT}/${OUTPUT}.tmp"
        ;;

    xz)
        find . -print0 |
            cpio --null -o -H newc |
            xz -T0 -9e \
            > "${REPO_ROOT}/${OUTPUT}.tmp"
        ;;

    gzip)
        find . -print0 |
            cpio --null -o -H newc |
            gzip -9 \
            > "${REPO_ROOT}/${OUTPUT}.tmp"
        ;;

    lz4)
        find . -print0 |
            cpio --null -o -H newc |
            lz4 -9 \
            > "${REPO_ROOT}/${OUTPUT}.tmp"
        ;;

    lzop)
        find . -print0 |
            cpio --null -o -H newc |
            lzop -9 \
            > "${REPO_ROOT}/${OUTPUT}.tmp"
        ;;

    bzip2)
        find . -print0 |
            cpio --null -o -H newc |
            bzip2 -9 \
            > "${REPO_ROOT}/${OUTPUT}.tmp"
        ;;

    none)
        find . -print0 |
            cpio --null -o -H newc \
            > "${REPO_ROOT}/${OUTPUT}.tmp"
        ;;

esac

mv "${REPO_ROOT}/${OUTPUT}.tmp" \
   "${REPO_ROOT}/${OUTPUT}"

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
echo
echo "Live-System : ${LIVE_TYPE}"
echo "Compression : ${COMPRESSION}"
echo "Output      : ${OUTPUT}"
echo
echo "Timezone:"
echo "    timezone=Europe/Berlin"
echo
echo "live-config:"
echo "    nocomponents=tzdata"
echo
ls -lh "${REPO_ROOT}/${OUTPUT}"
echo
echo "OK."
