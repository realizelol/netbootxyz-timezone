#!/usr/bin/env bash

set -e

# ============================================================
# Generic Live Initrd Timezone Patcher
#
# Supports:
#   - Debian/Kali live-boot
#   - Ubuntu/Linux Mint casper/live initramfs
#
# Kernel command line:
#   timezone=Europe/Berlin
#
# The timezone setup is injected into live-boot's/casper's
# main live boot script, after the live root filesystem has
# been mounted/constructed.
# ============================================================

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

WORKDIR="$(mktemp -d -t timezone-patch-XXXXXXXX)"
ROOT="${WORKDIR}/root"

cleanup()
{
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

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
require_command python3

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
# Unpack
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

echo
echo "==> Erkenne Live-System ..."

LIVE_MAIN=""

# Prefer usr/lib/live/boot because /lib may be a symlink.
if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]]; then
    LIVE_MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"
    LIVE_SYSTEM="live-boot"
elif [[ -f "${ROOT}/lib/live/boot/9990-main.sh" ]]; then
    LIVE_MAIN="${ROOT}/lib/live/boot/9990-main.sh"
    LIVE_SYSTEM="live-boot"
else
    LIVE_SYSTEM="casper"

    # Casper versions can have different main script locations.
    for candidate in \
        "${ROOT}/usr/share/initramfs-tools/scripts/casper-bottom/9990-main" \
        "${ROOT}/usr/share/initramfs-tools/scripts/casper-bottom/9990-main.sh" \
        "${ROOT}/scripts/casper-bottom/9990-main" \
        "${ROOT}/scripts/casper-bottom/9990-main.sh"
    do
        if [[ -f "${candidate}" ]]; then
            LIVE_MAIN="${candidate}"
            break
        fi
    done
fi

if [[ -n "${LIVE_MAIN}" ]]; then
    echo "OK: ${LIVE_SYSTEM} erkannt."
    echo "    Main script: ${LIVE_MAIN#${ROOT}}"
else
    echo "ERROR: Kein unterstütztes Live-System erkannt." >&2
    echo
    echo "Vorhandene Live-Dateien:"
    find "${ROOT}" \
        -type f \
        \( -name '9990-main*' -o -name '9990-*' -o -name '*casper*' \) \
        -print \
        2>/dev/null \
        | head -100 || true
    exit 1
fi

# ------------------------------------------------------------
# Remove old timezone patches
# ------------------------------------------------------------

echo
echo "==> Entferne alte Timezone-Patches ..."

rm -f "${ROOT}/usr/lib/live/boot/0023-timezone"
rm -f "${ROOT}/lib/live/boot/0023-timezone"

python3 - "${LIVE_MAIN}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

# Remove previous injected block.
text = re.sub(
    r'\n?# BEGIN NETBOOTXYZ TIMEZONE SETUP\n.*?\n# END NETBOOTXYZ TIMEZONE SETUP\n',
    '\n',
    text,
    flags=re.DOTALL,
)

# Remove previous call.
text = text.replace(
    '\n# NETBOOTXYZ TIMEZONE SETUP\nnetbootxyz_timezone_setup\n',
    '\n',
)

path.write_text(text)
PY

# ------------------------------------------------------------
# Inject timezone function
# ------------------------------------------------------------

echo
echo "==> Installiere Timezone-Funktion ..."

python3 - "${LIVE_MAIN}" <<'PY'
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

    # No timezone= parameter.
    if [ -z "$tz" ]; then
        return 0
    fi

    # Basic path traversal / malformed value protection.
    case "$tz" in
        /*|*..*|*" "*)
            echo "timezone: invalid timezone: ${tz}" >&2
            return 0
            ;;
    esac

    # live-boot/casper normally exports rootmnt.
    if [ -z "${rootmnt}" ]; then
        echo "timezone: ERROR: rootmnt is not set" >&2
        return 0
    fi

    log_begin_msg "Setting timezone to ${tz}"

    echo "timezone: rootmnt=${rootmnt}"
    echo "timezone: setting timezone to ${tz}"

    echo "timezone: BEFORE:"

    ls -l "${rootmnt}/etc/localtime" 2>&1 || true

    if [ -f "${rootmnt}/etc/timezone" ]; then
        cat "${rootmnt}/etc/timezone" 2>&1 || true
    else
        echo "timezone: /etc/timezone does not exist"
    fi

    # The live root filesystem must contain tzdata.
    if [ ! -f "${rootmnt}/usr/share/zoneinfo/${tz}" ]; then
        echo "timezone: unknown timezone: ${tz}" >&2
        log_end_msg
        return 0
    fi

    echo "timezone: zoneinfo exists:"
    ls -l "${rootmnt}/usr/share/zoneinfo/${tz}" 2>&1 || true

    # Make sure /etc exists.
    mkdir -p "${rootmnt}/etc"

    # Replace existing file/symlink.
    rm -f "${rootmnt}/etc/localtime"

    # Use the normal absolute timezone symlink.
    ln -s \
        "/usr/share/zoneinfo/${tz}" \
        "${rootmnt}/etc/localtime"

    # Debian/Kali/Mint use this file as well.
    printf '%s\n' "${tz}" > "${rootmnt}/etc/timezone"

    echo "timezone: AFTER:"

    ls -l "${rootmnt}/etc/localtime" 2>&1 || true
    readlink "${rootmnt}/etc/localtime" 2>&1 || true
    cat "${rootmnt}/etc/timezone" 2>&1 || true

    log_end_msg
}

# END NETBOOTXYZ TIMEZONE SETUP
'''

if marker_start in text:
    raise SystemExit("ERROR: Timezone block bereits vorhanden.")

# Put the function near the beginning of the main script.
# It must be defined before the invocation we add below.
lines = text.splitlines(keepends=True)

insert_at = 0

# Keep the shebang first if present.
if lines and lines[0].startswith("#!"):
    insert_at = 1

lines.insert(insert_at, timezone_function + "\n")

path.write_text("".join(lines))
PY

# ------------------------------------------------------------
# Find the correct final root-mount point
# ------------------------------------------------------------

echo
echo "==> Suche passenden Aufrufpunkt ..."

python3 - "${LIVE_MAIN}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

call = """
# NETBOOTXYZ TIMEZONE SETUP
netbootxyz_timezone_setup
"""

if "mount_images_in_directory" in text:
    needle = "\tmount_images_in_directory"
    idx = text.find(needle)

    if idx != -1:
        # Find end of containing line.
        end = text.find("\n", idx)

        if end != -1:
            text = text[:end + 1] + call + text[end + 1:]
            path.write_text(text)
            print("    timezone_setup nach mount_images_in_directory eingefügt.")
            sys.exit(0)

# Fallback:
# Find the last function-like block ending in log_end_msg.
#
# We deliberately place the call before the last log_end_msg,
# but only if no more specific live-root mount point was found.

needle = "\tlog_end_msg"

positions = []
start = 0

while True:
    pos = text.find(needle, start)

    if pos == -1:
        break

    positions.append(pos)
    start = pos + 1

if positions:
    pos = positions[-1]
    text = text[:pos] + call + "\n" + text[pos:]
    path.write_text(text)
    print("    timezone_setup vor dem letzten log_end_msg eingefügt.")
    sys.exit(0)

raise SystemExit(
    "ERROR: Konnte keinen geeigneten Aufrufpunkt in 9990-main.sh finden."
)
PY

# ------------------------------------------------------------
# Verify function and call
# ------------------------------------------------------------

echo
echo "==> Prüfe installierten Timezone-Code ..."

if ! grep -q "BEGIN NETBOOTXYZ TIMEZONE SETUP" "${LIVE_MAIN}"; then
    echo "ERROR: Timezone-Funktion fehlt." >&2
    exit 1
fi

if ! grep -q "netbootxyz_timezone_setup" "${LIVE_MAIN}"; then
    echo "ERROR: Timezone-Aufruf fehlt." >&2
    exit 1
fi

echo "OK."

# ------------------------------------------------------------
# Show relevant section
# ------------------------------------------------------------

echo
echo "==> Ergebnis ${LIVE_MAIN#${ROOT}}:"

grep -n -A15 -B8 \
    "netbootxyz_timezone_setup" \
    "${LIVE_MAIN}" || true

# ------------------------------------------------------------
# Repack
# ------------------------------------------------------------

echo
echo "==> Packe Initrd ..."

TEMP_OUTPUT="${WORKDIR}/initrd.new"

case "${COMPRESSION}" in
    zstd)
        (
            cd "${ROOT}"
            find . -print0 | cpio --null -o -H newc
        ) | zstd -T0 -q -c > "${TEMP_OUTPUT}"
        ;;
    gzip)
        (
            cd "${ROOT}"
            find . -print0 | cpio --null -o -H newc
        ) | gzip -c > "${TEMP_OUTPUT}"
        ;;
    xz)
        (
            cd "${ROOT}"
            find . -print0 | cpio --null -o -H newc
        ) | xz -c > "${TEMP_OUTPUT}"
        ;;
    lz4)
        (
            cd "${ROOT}"
            find . -print0 | cpio --null -o -H newc
        ) | lz4 -z -c > "${TEMP_OUTPUT}"
        ;;
    lzo)
        (
            cd "${ROOT}"
            find . -print0 | cpio --null -o -H newc
        ) | lzop -c > "${TEMP_OUTPUT}"
        ;;
esac

mv -f "${TEMP_OUTPUT}" "${OUTPUT}"

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
echo "Timezone wird über timezone= aus /proc/cmdline gelesen."
echo "Der Hook wird innerhalb des Live-Main-Skripts ausgeführt."
echo
echo "Output: ${OUTPUT}"
