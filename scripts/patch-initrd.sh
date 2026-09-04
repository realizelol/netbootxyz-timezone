#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Generic Live Initrd Timezone Patcher
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INPUT="${1:-}"
OUTPUT="${2:-}"

if [[ -z "${INPUT}" || -z "${OUTPUT}" ]]; then
    echo "Usage: $0 <input-initrd> <output-initrd>"
    exit 1
fi

# Make paths absolute before changing directories later.
INPUT="$(realpath "${INPUT}")"
OUTPUT="$(realpath -m "${OUTPUT}")"

# ============================================================
# Must run as root
# ============================================================

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"
echo

# ============================================================
# Dependencies
# ============================================================

for cmd in file cpio gzip zstd find install grep python3 realpath; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: required command not found: ${cmd}" >&2
        exit 1
    fi
done

# ============================================================
# Check input
# ============================================================

echo "==> Prüfe Input ..."

if [[ ! -f "${INPUT}" ]]; then
    echo "ERROR: Input initrd does not exist:"
    echo "       ${INPUT}"
    exit 1
fi

file "${INPUT}"

# ============================================================
# Temporary working directory
# ============================================================

WORKDIR="$(mktemp -d -t timezone-patch-XXXXXXXX)"
ROOT="${WORKDIR}/root"

cleanup()
{
    rm -rf "${WORKDIR}"
}

trap cleanup EXIT

mkdir -p "${ROOT}"

# ============================================================
# Detect compression
# ============================================================

COMPRESSION=""

if file "${INPUT}" | grep -qi 'Zstandard compressed'; then
    COMPRESSION="zstd"
elif file "${INPUT}" | grep -qi 'gzip compressed'; then
    COMPRESSION="gzip"
else
    echo "ERROR: unsupported initrd compression."
    file "${INPUT}"
    exit 1
fi

# ============================================================
# Extract initrd
# ============================================================

echo
echo "==> Entpacke Initrd ..."

case "${COMPRESSION}" in
    zstd)
        zstd -dc "${INPUT}" |
            cpio -idm --quiet -D "${ROOT}"
        ;;

    gzip)
        gzip -dc "${INPUT}" |
            cpio -idm --quiet -D "${ROOT}"
        ;;
esac

# ============================================================
# Detect live system
# ============================================================

echo
echo "==> Erkenne Live-System ..."

LIVE_TYPE=""

if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]]; then
    LIVE_TYPE="live-boot"
    echo "OK: live-boot erkannt."

elif [[ -d "${ROOT}/scripts/casper-bottom" ]]; then
    LIVE_TYPE="casper"
    echo "OK: casper erkannt."

else
    echo "ERROR: Weder casper noch live-boot erkannt." >&2
    exit 1
fi

# ============================================================
# Timezone patch source
# ============================================================

TIMEZONE_PATCH="${REPO_ROOT}/patches/0023-timezone"

if [[ ! -f "${TIMEZONE_PATCH}" ]]; then
    echo
    echo "ERROR: timezone patch not found:"
    echo "       ${TIMEZONE_PATCH}"
    exit 1
fi

# ============================================================
# Remove old timezone hooks
# ============================================================

echo
echo "==> Entferne alte Timezone-Hooks ..."

rm -f \
    "${ROOT}/usr/lib/live/boot/0023-timezone" \
    "${ROOT}/usr/lib/live/boot/023-timezone" \
    "${ROOT}/usr/lib/live/boot/023timezone" \
    "${ROOT}/usr/lib/live/boot/0100-timezone.sh"

rm -f \
    "${ROOT}/scripts/casper-bottom/0023timezone" \
    "${ROOT}/scripts/casper-bottom/023timezone" \
    "${ROOT}/scripts/casper-bottom/023-timezone" \
    "${ROOT}/scripts/casper-bottom/0100-timezone.sh"

# ============================================================
# Install timezone hook
# ============================================================

echo
echo "==> Installiere Timezone-Hook ..."

case "${LIVE_TYPE}" in

    live-boot)
        TARGET="${ROOT}/usr/lib/live/boot/0023-timezone"

        install -m 0755 \
            "${TIMEZONE_PATCH}" \
            "${TARGET}"

        echo "    ${TARGET}"
        ;;

    casper)
        TARGET="${ROOT}/scripts/casper-bottom/0023timezone"

        install -m 0755 \
            "${TIMEZONE_PATCH}" \
            "${TARGET}"

        echo "    ${TARGET}"
        ;;

esac

# ============================================================
# Patch live-boot
# ============================================================

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"

    echo
    echo "==> Patch 9990-main.sh ..."

    if [[ ! -f "${MAIN}" ]]; then
        echo "ERROR: ${MAIN} not found." >&2
        exit 1
    fi

    # --------------------------------------------------------
    # Remove an existing timezone_setup call first.
    # This makes the script idempotent.
    # --------------------------------------------------------

    python3 - "${MAIN}" <<'PY'
from pathlib import Path
import sys
import re

path = Path(sys.argv[1])
text = path.read_text()

text = re.sub(
    r'^[ \t]*#[^\n]*timezone[^\n]*\n'
    r'^[ \t]*timezone_setup[ \t]*\n',
    '',
    text,
    flags=re.MULTILINE | re.IGNORECASE
)

text = re.sub(
    r'^[ \t]*timezone_setup[ \t]*\n',
    '',
    text,
    flags=re.MULTILINE
)

path.write_text(text)
PY

    # --------------------------------------------------------
    # Insert timezone_setup immediately after the live rootfs
    # has been constructed.
    # --------------------------------------------------------

    python3 - "${MAIN}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = """\tif [ -n "${MODULETORAMFILE}" ] || [ -n "${PLAIN_ROOT}" ]
\tthen
\t\tsetup_unionfs "${livefs_root}" "${rootmnt?}"
\telse
\t\tmac="$(get_mac)"
\t\tmac="$(echo "${mac}" | sed 's/-//g')"
\t\tmount_images_in_directory "${livefs_root}" "${rootmnt}" "${mac}"
\tfi
"""

new = old + """
\t# Apply kernel-command-line timezone after the live rootfs
\t# has been mounted/constructed.
\ttimezone_setup
"""

if old not in text:
    print(
        "ERROR: Could not find rootfs mount block in 9990-main.sh.",
        file=sys.stderr
    )
    sys.exit(1)

text = text.replace(old, new, 1)

path.write_text(text)
PY

    echo "    timezone_setup eingefügt."

fi

# ============================================================
# Validate
# ============================================================

echo
echo "==> Prüfe installierten Timezone-Hook ..."

case "${LIVE_TYPE}" in

    live-boot)
        test -x "${ROOT}/usr/lib/live/boot/0023-timezone"
        ;;

    casper)
        test -x "${ROOT}/scripts/casper-bottom/0023timezone"
        ;;

esac

echo "OK."

# ============================================================
# Show result
# ============================================================

if [[ "${LIVE_TYPE}" == "live-boot" ]]; then

    echo
    echo "==> Ergebnis 9990-main.sh:"
    echo

    grep -n -A12 -B8 'timezone_setup' \
        "${ROOT}/usr/lib/live/boot/9990-main.sh"

fi

# ============================================================
# Create output directory
# ============================================================

mkdir -p "$(dirname "${OUTPUT}")"

rm -f "${OUTPUT}"

# ============================================================
# Repack initrd
# ============================================================

echo
echo "==> Packe Initrd ..."

case "${COMPRESSION}" in

    zstd)
        (
            cd "${ROOT}"

            find . -print0 |
                cpio --null -o -H newc --quiet |
                zstd -T0 -19 -o "${OUTPUT}"
        )
        ;;

    gzip)
        (
            cd "${ROOT}"

            find . -print0 |
                cpio --null -o -H newc --quiet |
                gzip -9 > "${OUTPUT}"
        )
        ;;

esac

# ============================================================
# Final verification
# ============================================================

if [[ ! -f "${OUTPUT}" ]]; then
    echo "ERROR: Output initrd was not created:"
    echo "       ${OUTPUT}"
    exit 1
fi

chmod 0644 "${OUTPUT}"

echo
echo "==> Prüfe Output ..."
file "${OUTPUT}"

echo
echo "============================================================"
echo " Fertig."
echo "============================================================"
echo
echo "Output:"
echo "  ${OUTPUT}"
echo
