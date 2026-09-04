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
require_command gzip
require_command zstd
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
        zstd -q -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    gzip)
        gzip -dc "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    xz)
        xz -dc "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    bzip2)
        bzip2 -dc "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    lz4)
        lz4 -dc "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    lzo)
        lzop -dc "${INPUT}" | (
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

LIVE_BOOT="no"

if [[ -f "${ROOT}/usr/bin/live-boot" ]]; then
    LIVE_BOOT="yes"
fi

if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]]; then
    LIVE_BOOT="yes"
fi

if [[ "${LIVE_BOOT}" != "yes" ]]; then
    echo "ERROR: live-boot nicht erkannt."
    echo
    echo "Vorhandene relevante Dateien:"
    find "${ROOT}" \
        -type f \
        \( \
            -path '*/live-boot*' -o \
            -path '*/usr/lib/live/*' \
            -o -name '9990-main.sh' \
        \) \
        -print \
        2>/dev/null | head -100

    exit 1
fi

echo "OK: live-boot erkannt."

MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"
HOOK="${ROOT}/usr/lib/live/boot/0023-timezone"

if [[ ! -f "${MAIN}" ]]; then
    echo "ERROR: ${MAIN} nicht gefunden." >&2
    exit 1
fi

echo
echo "==> Installiere Timezone-Hook ..."
echo "    ${HOOK}"

install -m 0755 "${PATCH_FILE}" "${HOOK}"

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

if [[ ! -f "${LOADER}" ]]; then
    echo "ERROR: ${LOADER} nicht gefunden." >&2
    exit 1
fi

if ! grep -q '/lib/live/boot/????-\*' "${LOADER}"; then
    echo "ERROR: live-boot lädt /lib/live/boot/????-* nicht." >&2
    echo
    echo "Auszug:"
    sed -n '1,30p' "${LOADER}"
    exit 1
fi

echo "OK."

echo
echo "==> Prüfe Symlink-Struktur ..."

if [[ -L "${ROOT}/lib" ]]; then
    echo "    lib -> $(readlink "${ROOT}/lib")"
fi

if [[ -L "${ROOT}/lib/live" ]]; then
    echo "    lib/live -> $(readlink "${ROOT}/lib/live")"
fi

echo
echo "==> Entferne eventuell vorhandenen Timezone-Aufruf ..."

sed -i '/^[[:space:]]*timezone_setup[[:space:]]*$/d' "${MAIN}"

echo
echo "==> Füge timezone_setup() am Ende von 9990-main.sh ein ..."

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
grep -n -A12 -B2 'timezone_setup' "${HOOK}"

echo
echo "--- Ende 9990-main.sh ---"
tail -20 "${MAIN}"

echo
echo "==> Prüfe, dass timezone_setup nur einmal aufgerufen wird ..."

CALL_COUNT="$(
    grep -c \
        '^[[:space:]]*timezone_setup[[:space:]]*$' \
        "${MAIN}" || true
)"

if [[ "${CALL_COUNT}" != "1" ]]; then
    echo "ERROR: Erwarteter timezone_setup-Aufruf fehlt oder ist mehrfach vorhanden." >&2
    exit 1
fi

echo "OK."

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

chmod --reference="${INPUT}" "${TMP_OUTPUT}" 2>/dev/null || true

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
