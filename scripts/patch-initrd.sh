#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Generic Live Initrd Timezone Patcher
#
# Supports:
#   - Debian/Ubuntu/Mint live-boot
#   - Ubuntu/Mint casper
#
# Kernel command line:
#   timezone=Europe/Berlin
#
# The timezone is applied to the final live root filesystem after it has
# been mounted.
###############################################################################

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INPUT="${1:-${REPO_ROOT}/initrd}"
OUTPUT="${2:-${REPO_ROOT}/initrd.timezone}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/timezone-patch-XXXXXXXX")"
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

###############################################################################
# Helpers
###############################################################################

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

need_cmd()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command '$1' not found."
}

###############################################################################
# Validate input
###############################################################################

echo
echo "==> Prüfe Input ..."

[[ -f "${INPUT}" ]] ||
    die "Input-Datei nicht gefunden: ${INPUT}"

file "${INPUT}"

###############################################################################
# Detect compression
###############################################################################

COMPRESSION=""

if file "${INPUT}" | grep -qi 'Zstandard compressed'; then
    COMPRESSION="zstd"
elif file "${INPUT}" | grep -qi 'LZOP compressed'; then
    COMPRESSION="lzop"
elif file "${INPUT}" | grep -qi 'gzip compressed'; then
    COMPRESSION="gzip"
elif file "${INPUT}" | grep -qi 'XZ compressed'; then
    COMPRESSION="xz"
elif file "${INPUT}" | grep -qi 'ASCII cpio archive'; then
    COMPRESSION="none"
elif file "${INPUT}" | grep -qi 'cpio archive'; then
    COMPRESSION="none"
else
    die "Unbekannte Initrd-Kompression."
fi

echo "Compression: ${COMPRESSION}"

case "${COMPRESSION}" in
    zstd)
        need_cmd zstd
        need_cmd cpio
        ;;
    lzop)
        need_cmd lzop
        need_cmd cpio
        ;;
    gzip)
        need_cmd gzip
        need_cmd cpio
        ;;
    xz)
        need_cmd xz
        need_cmd cpio
        ;;
    none)
        need_cmd cpio
        ;;
esac

###############################################################################
# Extract
###############################################################################

echo
echo "==> Entpacke Initrd ..."

mkdir -p "${ROOT}"

case "${COMPRESSION}" in
    zstd)
        zstd -q -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idmu --quiet
        )
        ;;
    lzop)
        lzop -d -c "${INPUT}" | (
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
    none)
        (
            cd "${ROOT}"
            cpio -idmu --quiet < "${INPUT}"
        )
        ;;
esac

###############################################################################
# Detect live system
###############################################################################

echo
echo "==> Erkenne Live-System ..."

LIVE_SYSTEM=""

# Debian/Ubuntu/Mint live-boot
if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]] &&
   [[ -d "${ROOT}/usr/lib/live/boot" ]]; then

    LIVE_SYSTEM="live-boot"

# Casper (Ubuntu/Mint)
elif [[ -f "${ROOT}/etc/casper.conf" ]] &&
     [[ -f "${ROOT}/scripts/casper" ]] &&
     [[ -f "${ROOT}/scripts/casper-functions" ]]; then

    LIVE_SYSTEM="casper"

else
    echo "ERROR: Kein unterstütztes Live-System erkannt."
    echo
    echo "Vorhandene Live-Dateien:"
    find "${ROOT}" \
        \( -path '*/live/*' -o \
           -path '*/casper*' -o \
           -path '*/casper/*' \) \
        -print 2>/dev/null | head -100
    exit 1
fi

echo "OK: ${LIVE_SYSTEM} erkannt."

###############################################################################
# Repository patch files
###############################################################################

LIVE_BOOT_PATCH="${REPO_ROOT}/patches/0023-timezone"
CASPER_PATCH="${REPO_ROOT}/patches/casper-bottom-99timezone"

###############################################################################
# Validate repository patches
###############################################################################

case "${LIVE_SYSTEM}" in

    live-boot)
        [[ -f "${LIVE_BOOT_PATCH}" ]] ||
            die "Patch-Datei fehlt: ${LIVE_BOOT_PATCH}"
        ;;

    casper)
        [[ -f "${CASPER_PATCH}" ]] ||
            die "Patch-Datei fehlt: ${CASPER_PATCH}"
        ;;

esac

###############################################################################
# Remove previous versions
###############################################################################

echo
echo "==> Entferne alte Timezone-Hooks ..."

rm -f \
    "${ROOT}/usr/lib/live/boot/0023-timezone" \
    "${ROOT}/usr/lib/live/boot/023-timezone" \
    "${ROOT}/lib/live/boot/0023-timezone" \
    "${ROOT}/lib/live/boot/023-timezone" \
    "${ROOT}/scripts/casper-bottom/99timezone"

###############################################################################
# Install live-boot patch
###############################################################################

if [[ "${LIVE_SYSTEM}" == "live-boot" ]]; then

    echo
    echo "==> Installiere live-boot Timezone-Hook ..."

    mkdir -p "${ROOT}/usr/lib/live/boot"

    install -m 0755 \
        "${LIVE_BOOT_PATCH}" \
        "${ROOT}/usr/lib/live/boot/0023-timezone"

    echo "    ${ROOT}/usr/lib/live/boot/0023-timezone"

    ###########################################################################
    # Patch 9990-main.sh
    #
    # Important:
    # timezone_setup must run AFTER mount_images_in_directory(), because only
    # then ${rootmnt} represents the actual live root filesystem.
    ###########################################################################

    MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"

    [[ -f "${MAIN}" ]] ||
        die "9990-main.sh nicht gefunden."

    if grep -q '^[[:space:]]*timezone_setup[[:space:]]*$' "${MAIN}"; then
        echo "    timezone_setup bereits vorhanden."
    else

        echo "==> Patch 9990-main.sh ..."

        python3 - "${MAIN}" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

needle = 'mount_images_in_directory "${livefs_root}" "${rootmnt}" "${mac}"'

pos = data.find(needle)

if pos == -1:
    raise SystemExit(
        "mount_images_in_directory-Aufruf in 9990-main.sh nicht gefunden."
    )

# Find end of the containing line.
line_end = data.find("\n", pos)

if line_end == -1:
    line_end = len(data)

insert = (
    "\n"
    "\t# Apply kernel-command-line timezone after the live rootfs "
    "has been mounted/constructed.\n"
    "\ttimezone_setup\n"
)

data = data[:line_end + 1] + insert + data[line_end + 1:]

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

        echo "    timezone_setup eingefügt."

    fi

    ###########################################################################
    # Verify live-boot patch
    ###########################################################################

    echo
    echo "==> Prüfe installierten Timezone-Hook ..."

    [[ -x "${ROOT}/usr/lib/live/boot/0023-timezone" ]] ||
        die "Timezone-Hook wurde nicht korrekt installiert."

    grep -q 'timezone_setup' \
        "${ROOT}/usr/lib/live/boot/0023-timezone" ||
        die "timezone_setup fehlt im Timezone-Hook."

    grep -q 'timezone=' \
        "${ROOT}/usr/lib/live/boot/0023-timezone" ||
        die "timezone= Unterstützung fehlt."

    echo "OK."

    echo
    echo "==> Ergebnis 9990-main.sh:"

    grep -n -A8 -B5 \
        'timezone_setup' \
        "${MAIN}" || true

fi

###############################################################################
# Install casper patch
###############################################################################

if [[ "${LIVE_SYSTEM}" == "casper" ]]; then

    echo
    echo "==> Installiere Casper Timezone-Hook ..."

    mkdir -p "${ROOT}/scripts/casper-bottom"

    install -m 0755 \
        "${CASPER_PATCH}" \
        "${ROOT}/scripts/casper-bottom/99timezone"

    echo "    ${ROOT}/scripts/casper-bottom/99timezone"

    ###########################################################################
    # Verify Casper patch
    ###########################################################################

    echo
    echo "==> Prüfe installierten Casper Timezone-Hook ..."

    [[ -x "${ROOT}/scripts/casper-bottom/99timezone" ]] ||
        die "Casper Timezone-Hook wurde nicht korrekt installiert."

    grep -q 'timezone=' \
        "${ROOT}/scripts/casper-bottom/99timezone" ||
        die "timezone= Unterstützung fehlt."

    grep -q '/etc/localtime' \
        "${ROOT}/scripts/casper-bottom/99timezone" ||
        die "/etc/localtime Behandlung fehlt."

    echo "OK."

fi

###############################################################################
# Pack initrd
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
                zstd -T0 -q -c
        ) > "${TMP_OUTPUT}"
        ;;

    lzop)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                lzop -c
        ) > "${TMP_OUTPUT}"
        ;;

    gzip)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                gzip -c
        ) > "${TMP_OUTPUT}"
        ;;

    xz)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                xz -c
        ) > "${TMP_OUTPUT}"
        ;;

    none)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet
        ) > "${TMP_OUTPUT}"
        ;;

esac

mv "${TMP_OUTPUT}" "${OUTPUT}"

chmod 0644 "${OUTPUT}"

###############################################################################
# Final verification
###############################################################################

echo
echo "==> Prüfe erzeugte Initrd ..."

[[ -s "${OUTPUT}" ]] ||
    die "Output-Datei wurde nicht erzeugt."

file "${OUTPUT}"

echo
echo "============================================================"
echo " Fertig."
echo "============================================================"
echo
echo "Output: ${OUTPUT}"
