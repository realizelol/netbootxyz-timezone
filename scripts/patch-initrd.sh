#!/usr/bin/env bash

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PATCH_FILE="${REPO_ROOT}/patches/0023-timezone"

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

require_command()
{
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: Required command '$1' not found." >&2
        exit 1
    }
}

echo "==> Prüfe benötigte Werkzeuge ..."

require_command file
require_command cpio
require_command zstd
require_command gzip
require_command xz
require_command bzip2
require_command lz4
require_command lzop

if [[ ! -f "${INPUT}" ]]; then
    echo "ERROR: Input-Datei nicht gefunden: ${INPUT}" >&2
    exit 1
fi

if [[ ! -f "${PATCH_FILE}" ]]; then
    echo "ERROR: Patch-Datei nicht gefunden: ${PATCH_FILE}" >&2
    exit 1
fi

echo
echo "==> Prüfe Input ..."
file "${INPUT}"

mkdir -p "${ROOT}"

detect_compression()
{
    local info

    info="$(file -b "${INPUT}")"

    case "${info}" in
        *"Zstandard compressed data"*)
            echo "zstd"
            ;;
        *"gzip compressed data"*)
            echo "gzip"
            ;;
        *"XZ compressed data"*)
            echo "xz"
            ;;
        *"bzip2 compressed data"*)
            echo "bzip2"
            ;;
        *"LZ4 compressed data"*)
            echo "lz4"
            ;;
        *"LZO compressed data"*)
            echo "lzo"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

COMPRESSION="$(detect_compression)"

echo "Compression: ${COMPRESSION}"

echo
echo "==> Entpacke Initrd ..."

case "${COMPRESSION}" in
    zstd)
        zstd -q -d -c "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idm --no-absolute-filenames
            )
        ;;
    gzip)
        gzip -dc "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idm --no-absolute-filenames
            )
        ;;
    xz)
        xz -dc "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idm --no-absolute-filenames
            )
        ;;
    bzip2)
        bzip2 -dc "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idm --no-absolute-filenames
            )
        ;;
    lz4)
        lz4 -dc "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idm --no-absolute-filenames
            )
        ;;
    lzo)
        lzop -dc "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idm --no-absolute-filenames
            )
        ;;
    *)
        echo "ERROR: Unbekannte Initrd-Kompression." >&2
        exit 1
        ;;
esac

echo
echo "==> Erkenne Live-System ..."

SYSTEM="unknown"

#
# Kali / Debian live-boot
#
if [[ -f "${ROOT}/usr/bin/live-boot" ]] &&
   [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]]; then

    SYSTEM="live-boot"

#
# Ubuntu / Linux Mint / casper
#
elif [[ -f "${ROOT}/etc/casper.conf" ]] ||
     [[ -d "${ROOT}/scripts/casper-bottom" ]] ||
     [[ -f "${ROOT}/scripts/casper" ]]; then

    SYSTEM="casper"

fi

case "${SYSTEM}" in

    live-boot)

        echo "OK: live-boot erkannt."

        MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"
        HOOK="${ROOT}/usr/lib/live/boot/0023-timezone"

        echo
        echo "==> Installiere Timezone-Hook ..."
        echo "    ${HOOK}"

        install -D -m 0755 \
            "${PATCH_FILE}" \
            "${HOOK}"

        echo
        echo "==> Prüfe installierten Timezone-Hook ..."

        if ! grep -q '^timezone_setup()' "${HOOK}"; then
            echo "ERROR: timezone_setup() wurde nicht installiert." >&2
            exit 1
        fi

        echo "OK."

        echo
        echo "==> Prüfe live-boot Loader ..."

        LOADER="${ROOT}/usr/bin/live-boot"

        if ! grep -q '/lib/live/boot/????-\*' "${LOADER}"; then
            echo "ERROR: live-boot lädt /lib/live/boot/????-* nicht." >&2
            exit 1
        fi

        echo "OK."

        echo
        echo "==> Entferne alte timezone_setup-Aufrufe ..."

        sed -i \
            '/^[[:space:]]*timezone_setup[[:space:]]*$/d' \
            "${MAIN}"

        echo
        echo "==> Füge timezone_setup am Ende von 9990-main.sh ein ..."

        cat >> "${MAIN}" <<'EOF'

# Apply kernel-command-line timezone after the live rootfs
# has been mounted and constructed.
timezone_setup
EOF

        echo "OK."

        echo
        echo "==> Prüfe Ergebnis ..."

        echo
        echo "--- 0023-timezone ---"
        grep -n -A12 -B2 \
            'timezone_setup' \
            "${HOOK}"

        echo
        echo "--- Ende 9990-main.sh ---"
        tail -20 "${MAIN}"

        ;;

    casper)

        echo "OK: casper erkannt."

        #
        # Wichtig:
        # Mint/Casper hat keine live-boot-Struktur.
        # Deshalb darf hier NICHT nach
        # /usr/lib/live/boot/9990-main.sh
        # gesucht werden.
        #

        CASPER_HOOK_DIR="${ROOT}/scripts/casper-bottom"
        CASPER_HOOK="${CASPER_HOOK_DIR}/99timezone"

        echo
        echo "==> Installiere Casper Timezone-Hook ..."
        echo "    ${CASPER_HOOK}"

        mkdir -p "${CASPER_HOOK_DIR}"

        cat > "${CASPER_HOOK}" <<'EOF'
#!/bin/sh

timezone_setup()
{
    local tz=""
    local arg

    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            timezone=*)
                tz="${arg#timezone=}"
                ;;
        esac
    done

    if [ -z "$tz" ]; then
        return 0
    fi

    case "$tz" in
        /*|*..*|*" "*)
            echo "timezone: invalid timezone: ${tz}" >&2
            return 0
            ;;
    esac

    if [ -z "${rootmnt}" ]; then
        echo "timezone: rootmnt is not set" >&2
        return 0
    fi

    if [ ! -f "${rootmnt}/usr/share/zoneinfo/${tz}" ]; then
        echo "timezone: unknown timezone: ${tz}" >&2
        return 0
    fi

    echo "timezone: rootmnt=${rootmnt}"
    echo "timezone: setting timezone to ${tz}"

    echo "timezone: BEFORE:"
    ls -l "${rootmnt}/etc/localtime" 2>&1 || true
    cat "${rootmnt}/etc/timezone" 2>&1 || true

    rm -f "${rootmnt}/etc/localtime"

    ln -s \
        "/usr/share/zoneinfo/${tz}" \
        "${rootmnt}/etc/localtime"

    printf '%s\n' "${tz}" > \
        "${rootmnt}/etc/timezone"

    echo "timezone: AFTER:"
    ls -l "${rootmnt}/etc/localtime" 2>&1 || true
    cat "${rootmnt}/etc/timezone" 2>&1 || true
}

timezone_setup
EOF

        chmod 0755 "${CASPER_HOOK}"

        echo
        echo "==> Prüfe installierten Casper-Hook ..."

        if [[ ! -x "${CASPER_HOOK}" ]]; then
            echo "ERROR: Casper Hook wurde nicht installiert." >&2
            exit 1
        fi

        if ! grep -q '^timezone_setup()' "${CASPER_HOOK}"; then
            echo "ERROR: timezone_setup() fehlt im Casper Hook." >&2
            exit 1
        fi

        if ! grep -q '^timezone_setup$' "${CASPER_HOOK}"; then
            echo "ERROR: timezone_setup-Aufruf fehlt im Casper Hook." >&2
            exit 1
        fi

        echo "OK."

        echo
        echo "==> Casper-Hook:"
        sed -n '1,140p' "${CASPER_HOOK}"

        ;;

    *)

        echo "ERROR: Kein unterstütztes Live-System erkannt."
        echo
        echo "Vorhandene Live-Dateien:"

        find "${ROOT}" \
            -type f \
            \( \
                -path '*/casper*' \
                -o -path '*/live*' \
                -o -name '9990-main.sh' \
                -o -name 'live-boot' \
            \) \
            -print \
            2>/dev/null |
            head -100

        exit 1
        ;;

esac

echo
echo "==> Packe Initrd ..."

TMP_OUTPUT="${OUTPUT}.tmp"

rm -f "${TMP_OUTPUT}"

(
    cd "${ROOT}"

    find . -print0 |
        cpio --null -o -H newc
) |
case "${COMPRESSION}" in
    zstd)
        zstd -q -T0 -19 -c
        ;;
    gzip)
        gzip -c -9
        ;;
    xz)
        xz -c -9
        ;;
    bzip2)
        bzip2 -c -9
        ;;
    lz4)
        lz4 -c
        ;;
    lzo)
        lzop -c
        ;;
esac > "${TMP_OUTPUT}"

chmod --reference="${INPUT}" \
    "${TMP_OUTPUT}" \
    2>/dev/null || true

mv -f "${TMP_OUTPUT}" "${OUTPUT}"

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
echo
echo "Output: ${OUTPUT}"
echo
file "${OUTPUT}"
echo
echo "Größe:"
ls -lh "${OUTPUT}"
