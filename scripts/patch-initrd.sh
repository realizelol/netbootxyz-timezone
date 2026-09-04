#!/usr/bin/env bash

set -e

# ------------------------------------------------------------
# Generic Live Initrd Timezone Patcher
#
# Supports:
#   - Debian/Ubuntu/Mint casper
#   - Debian/Kali live-boot
#
# Kernel command line:
#   timezone=Europe/Berlin
#
# The timezone setup is injected directly into the init script
# and executed immediately before the final run-init.
# ------------------------------------------------------------

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

WORKDIR="$(mktemp -d -t timezone-patch-XXXXXXXX)"

cleanup()
{
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

ROOT="${WORKDIR}/root"

mkdir -p "${ROOT}"

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"

# ------------------------------------------------------------
# Required commands
# ------------------------------------------------------------

require_command()
{
    local cmd="$1"

    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: Required command '${cmd}' not found." >&2
        exit 1
    fi
}

require_command file
require_command cpio

# ------------------------------------------------------------
# Validate input
# ------------------------------------------------------------

echo "==> Prüfe Input ..."

if [[ ! -f "${INPUT}" ]]; then
    echo "ERROR: Input '${INPUT}' nicht gefunden." >&2
    exit 1
fi

file "${INPUT}"

# ------------------------------------------------------------
# Detect compression
# ------------------------------------------------------------

FILE_INFO="$(file -b "${INPUT}")"

COMPRESSION=""

case "${FILE_INFO}" in
    *"Zstandard compressed data"*)
        COMPRESSION="zstd"
        require_command zstd
        ;;
    *"gzip compressed data"*)
        COMPRESSION="gzip"
        require_command gzip
        ;;
    *"XZ compressed data"*)
        COMPRESSION="xz"
        require_command xz
        ;;
    *"LZ4 compressed data"*)
        COMPRESSION="lz4"
        require_command lz4
        ;;
    *"LZO compressed data"*)
        COMPRESSION="lzo"
        require_command lzop
        ;;
    *)
        echo "ERROR: Unbekanntes Initrd-Kompressionsformat:" >&2
        echo "       ${FILE_INFO}" >&2
        exit 1
        ;;
esac

echo "Compression: ${COMPRESSION}"

# ------------------------------------------------------------
# Unpack initrd
# ------------------------------------------------------------

echo "==> Entpacke Initrd ..."

case "${COMPRESSION}" in
    zstd)
        zstd -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    gzip)
        gzip -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    xz)
        xz -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    lz4)
        lz4 -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    lzo)
        lzop -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
esac

# ------------------------------------------------------------
# Detect live system
# ------------------------------------------------------------

echo "==> Erkenne Live-System ..."

LIVE_SYSTEM=""

if [[ -d "${ROOT}/usr/lib/live/boot" ]]; then
    LIVE_SYSTEM="live-boot"
elif [[ -d "${ROOT}/lib/live/boot" ]]; then
    LIVE_SYSTEM="live-boot"
elif [[ -d "${ROOT}/casper" ]] || \
     [[ -d "${ROOT}/usr/share/initramfs-tools" ]] || \
     [[ -f "${ROOT}/scripts/casper" ]]; then
    LIVE_SYSTEM="casper"
fi

if [[ -z "${LIVE_SYSTEM}" ]]; then
    echo "ERROR: Kein unterstütztes Live-System erkannt." >&2
    exit 1
fi

echo "OK: ${LIVE_SYSTEM} erkannt."

# ------------------------------------------------------------
# Make sure init exists
# ------------------------------------------------------------

if [[ ! -f "${ROOT}/init" ]]; then
    echo "ERROR: '${ROOT}/init' nicht gefunden." >&2
    exit 1
fi

# ------------------------------------------------------------
# Remove previous timezone patches
# ------------------------------------------------------------

echo "==> Entferne alte Timezone-Patches ..."

# Remove our external hook if it exists.
rm -f "${ROOT}/usr/lib/live/boot/0023-timezone"
rm -f "${ROOT}/lib/live/boot/0023-timezone"

# Remove possible previous injected timezone function/call.
#
# We use unique markers so that repeated GitHub Actions runs do
# not accumulate multiple copies.

python3 - "${ROOT}/init" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])

text = path.read_text()

# Remove everything between our function markers.
text = re.sub(
    r'\n?# BEGIN NETBOOTXYZ TIMEZONE SETUP\n.*?\n# END NETBOOTXYZ TIMEZONE SETUP\n',
    '\n',
    text,
    flags=re.DOTALL,
)

# Remove previous invocation.
text = text.replace(
    '\n# NETBOOTXYZ TIMEZONE SETUP\nnetbootxyz_timezone_setup\n',
    '\n',
)

path.write_text(text)
PY

# ------------------------------------------------------------
# Inject timezone function directly into init
# ------------------------------------------------------------

echo "==> Installiere Timezone-Funktion direkt in init ..."

python3 - "${ROOT}/init" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker_start = "# BEGIN NETBOOTXYZ TIMEZONE SETUP"
marker_end = "# END NETBOOTXYZ TIMEZONE SETUP"

timezone_function = r'''
# BEGIN NETBOOTXYZ TIMEZONE SETUP

netbootxyz_timezone_setup()
{
    local tz
    local arg

    tz=""

    # Read timezone= directly from the kernel command line.
    for arg in $(cat /proc/cmdline 2>/dev/null); do
        case "$arg" in
            timezone=*)
                tz="${arg#timezone=}"
                ;;
        esac
    done

    # No timezone= parameter: nothing to do.
    if [ -z "$tz" ]; then
        return 0
    fi

    # Basic path traversal / malformed-value protection.
    case "$tz" in
        /*|*..*|*" "*)
            echo "timezone: invalid timezone: $tz" >&2
            return 0
            ;;
    esac

    # rootmnt is the real/live root filesystem.
    if [ -z "${rootmnt}" ]; then
        echo "timezone: rootmnt is not set" >&2
        return 0
    fi

    # The zoneinfo file must exist in the final root filesystem.
    if [ ! -f "${rootmnt}/usr/share/zoneinfo/${tz}" ]; then
        echo "timezone: unknown timezone: ${tz}" >&2
        return 0
    fi

    echo "timezone: rootmnt=${rootmnt}"
    echo "timezone: setting timezone to ${tz}"

    echo "timezone: BEFORE:"
    ls -l "${rootmnt}/etc/localtime" 2>&1 || true
    cat "${rootmnt}/etc/timezone" 2>&1 || true

    # Make sure /etc exists.
    mkdir -p "${rootmnt}/etc"

    # Remove whatever the distribution currently has there.
    rm -f "${rootmnt}/etc/localtime"

    # Use the conventional absolute target.
    ln -s \
        "/usr/share/zoneinfo/${tz}" \
        "${rootmnt}/etc/localtime"

    # Debian/Mint/Kali may use /etc/timezone as well.
    printf '%s\n' "${tz}" > "${rootmnt}/etc/timezone"

    echo "timezone: AFTER:"
    ls -l "${rootmnt}/etc/localtime" 2>&1 || true
    cat "${rootmnt}/etc/timezone" 2>&1 || true
}

# END NETBOOTXYZ TIMEZONE SETUP
'''

# Insert the function immediately before the first occurrence
# of validate_init(). This keeps it available until the final
# exec run-init.
needle = "validate_init()"

if needle not in text:
    raise SystemExit("ERROR: validate_init() nicht in init gefunden.")

text = text.replace(
    needle,
    timezone_function + "\n" + needle,
    1,
)

path.write_text(text)
PY

# ------------------------------------------------------------
# Insert the call immediately before final run-init
# ------------------------------------------------------------

echo "==> Platziere timezone_setup unmittelbar vor run-init ..."

python3 - "${ROOT}/init" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

call = """
# NETBOOTXYZ TIMEZONE SETUP
netbootxyz_timezone_setup
"""

# Find the final exec run-init line.
lines = text.splitlines(keepends=True)

target_index = None

for i, line in enumerate(lines):
    if line.startswith("exec run-init "):
        target_index = i

if target_index is None:
    raise SystemExit(
        "ERROR: Finales 'exec run-init' nicht in init gefunden."
    )

lines.insert(target_index, call)

path.write_text("".join(lines))
PY

# ------------------------------------------------------------
# Verify init patch
# ------------------------------------------------------------

echo "==> Prüfe gepatchtes init ..."

if ! grep -q "BEGIN NETBOOTXYZ TIMEZONE SETUP" "${ROOT}/init"; then
    echo "ERROR: Timezone-Funktion wurde nicht in init eingefügt." >&2
    exit 1
fi

if ! grep -q "netbootxyz_timezone_setup" "${ROOT}/init"; then
    echo "ERROR: Timezone-Aufruf wurde nicht in init eingefügt." >&2
    exit 1
fi

echo "OK: Timezone-Funktion in init vorhanden."

echo
echo "==> Relevanter Bereich von init:"

grep -n -A12 -B5 \
    "netbootxyz_timezone_setup" \
    "${ROOT}/init" || true

echo
echo "==> Letzte Zeilen von init:"

tail -n 30 "${ROOT}/init"

# ------------------------------------------------------------
# Repack initrd
# ------------------------------------------------------------

echo
echo "==> Packe Initrd ..."

TEMP_OUTPUT="${WORKDIR}/initrd.new"

case "${COMPRESSION}" in
    zstd)
        (
            cd "${ROOT}"
            find . -print0 \
                | cpio --null -o -H newc
        ) | zstd -T0 -q -c > "${TEMP_OUTPUT}"
        ;;
    gzip)
        (
            cd "${ROOT}"
            find . -print0 \
                | cpio --null -o -H newc
        ) | gzip -c > "${TEMP_OUTPUT}"
        ;;
    xz)
        (
            cd "${ROOT}"
            find . -print0 \
                | cpio --null -o -H newc
        ) | xz -c > "${TEMP_OUTPUT}"
        ;;
    lz4)
        (
            cd "${ROOT}"
            find . -print0 \
                | cpio --null -o -H newc
        ) | lz4 -z -c > "${TEMP_OUTPUT}"
        ;;
    lzo)
        (
            cd "${ROOT}"
            find . -print0 \
                | cpio --null -o -H newc
        ) | lzop -c > "${TEMP_OUTPUT}"
        ;;
esac

mv -f "${TEMP_OUTPUT}" "${OUTPUT}"

# ------------------------------------------------------------
# Permissions
# ------------------------------------------------------------

chmod 0644 "${OUTPUT}"

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

echo
echo "==> Prüfe erzeugte Initrd ..."

file "${OUTPUT}"

if [[ ! -s "${OUTPUT}" ]]; then
    echo "ERROR: Erzeugte Initrd ist leer." >&2
    exit 1
fi

echo
echo "============================================================"
echo " OK"
echo "============================================================"
echo
echo "Timezone wird beim Booten aus"
echo
echo "    timezone=Europe/Berlin"
echo
echo "gelesen und unmittelbar vor dem finalen run-init auf"
echo
echo "    ${ROOT}/etc/localtime"
echo
echo "angewendet."
echo
echo "Output: ${OUTPUT}"
