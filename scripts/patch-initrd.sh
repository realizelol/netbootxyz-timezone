#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Generic Live Initrd Timezone Patcher
#
# Supports:
#   - Ubuntu/Mint/casper based initrds
#   - Debian/Kali/live-boot based initrds
#
# Adds:
#   timezone=Europe/Berlin
#
# The timezone hook is executed as the FINAL initramfs action immediately
# before the final "exec run-init".
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

INPUT="${1:-${REPO_ROOT}/initrd}"
OUTPUT="${2:-${REPO_ROOT}/initrd.timezone}"

PATCH_FILE="${REPO_ROOT}/patches/0023-timezone"

WORKDIR=""
ROOT=""

###############################################################################
# Root privileges
###############################################################################

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

###############################################################################
# Cleanup
###############################################################################

cleanup()
{
    if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        rm -rf "${WORKDIR}"
    fi
}

trap cleanup EXIT
trap 'echo "ERROR: patch-initrd.sh failed at line ${LINENO}." >&2' ERR

###############################################################################
# Helpers
###############################################################################

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

info()
{
    echo
    echo "==> $*"
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

###############################################################################
# Check dependencies
###############################################################################

command -v file >/dev/null 2>&1 ||
    die "Required command 'file' not found."

command -v cpio >/dev/null 2>&1 ||
    die "Required command 'cpio' not found."

command -v zstd >/dev/null 2>&1 ||
    die "Required command 'zstd' not found."

command -v gzip >/dev/null 2>&1 ||
    die "Required command 'gzip' not found."

command -v xz >/dev/null 2>&1 ||
    die "Required command 'xz' not found."

command -v bzip2 >/dev/null 2>&1 ||
    die "Required command 'bzip2' not found."

command -v lz4 >/dev/null 2>&1 ||
    die "Required command 'lz4' not found."

command -v lzop >/dev/null 2>&1 ||
    die "Required command 'lzop' not found."

command -v python3 >/dev/null 2>&1 ||
    die "Required command 'python3' not found."

[[ -f "${INPUT}" ]] ||
    die "Input initrd does not exist: ${INPUT}"

[[ -f "${PATCH_FILE}" ]] ||
    die "Timezone patch does not exist: ${PATCH_FILE}"

###############################################################################
# Determine compression
###############################################################################

info "Prüfe Input ..."

FILE_INFO="$(file -b "${INPUT}")"
echo "${INPUT}: ${FILE_INFO}"

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
        COMPRESSION="lzop"
        ;;
    *"ASCII cpio archive"*)
        COMPRESSION="none"
        ;;
    *"cpio archive"*)
        COMPRESSION="none"
        ;;
    *)
        die "Unsupported initrd format: ${FILE_INFO}"
        ;;
esac

###############################################################################
# Create temporary workspace
###############################################################################

WORKDIR="$(mktemp -d -t timezone-patch-XXXXXXXXXX)"
ROOT="${WORKDIR}/root"

mkdir -p "${ROOT}"

###############################################################################
# Extract initrd
###############################################################################

info "Entpacke Initrd ..."

case "${COMPRESSION}" in
    zstd)
        zstd -q -d -c "${INPUT}" |
            (cd "${ROOT}" && cpio -idm --no-absolute-filenames)
        ;;
    gzip)
        gzip -dc "${INPUT}" |
            (cd "${ROOT}" && cpio -idm --no-absolute-filenames)
        ;;
    xz)
        xz -dc "${INPUT}" |
            (cd "${ROOT}" && cpio -idm --no-absolute-filenames)
        ;;
    bzip2)
        bzip2 -dc "${INPUT}" |
            (cd "${ROOT}" && cpio -idm --no-absolute-filenames)
        ;;
    lz4)
        lz4 -dc "${INPUT}" |
            (cd "${ROOT}" && cpio -idm --no-absolute-filenames)
        ;;
    lzop)
        lzop -dc "${INPUT}" |
            (cd "${ROOT}" && cpio -idm --no-absolute-filenames)
        ;;
    none)
        (cd "${ROOT}" && cpio -idm --no-absolute-filenames < "${INPUT}")
        ;;
esac

###############################################################################
# Detect live system
###############################################################################

info "Erkenne Live-System ..."

IS_CASPER=0
IS_LIVE_BOOT=0

if [[ -d "${ROOT}/casper" ||
      -d "${ROOT}/usr/share/initramfs-tools/scripts/casper" ||
      -f "${ROOT}/scripts/casper" ||
      -f "${ROOT}/scripts/casper-bottom/ORDER" ||
      -d "${ROOT}/scripts/casper-bottom" ]]; then
    IS_CASPER=1
    echo "OK: casper erkannt."
fi

if [[ -d "${ROOT}/usr/lib/live/boot" ||
      -d "${ROOT}/lib/live/boot" ||
      -f "${ROOT}/usr/bin/live-boot" ||
      -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]]; then
    IS_LIVE_BOOT=1
    echo "OK: live-boot erkannt."
fi

if [[ ${IS_CASPER} -eq 0 && ${IS_LIVE_BOOT} -eq 0 ]]; then
    die "Kein unterstütztes Live-System erkannt."
fi

###############################################################################
# Validate init
###############################################################################

[[ -f "${ROOT}/init" ]] ||
    die "Initrd does not contain /init."

###############################################################################
# Install timezone hook
###############################################################################

info "Installiere Timezone-Hook ..."

mkdir -p "${ROOT}/usr/lib/live/boot"

cp "${PATCH_FILE}" \
   "${ROOT}/usr/lib/live/boot/0023-timezone"

chmod 0755 \
    "${ROOT}/usr/lib/live/boot/0023-timezone"

echo "    ${ROOT}/usr/lib/live/boot/0023-timezone"

###############################################################################
# Verify timezone hook
###############################################################################

info "Prüfe installierten Timezone-Hook ..."

if [[ ! -x "${ROOT}/usr/lib/live/boot/0023-timezone" ]]; then
    die "Timezone-Hook wurde nicht korrekt installiert."
fi

if ! grep -q '^timezone_setup()' \
    "${ROOT}/usr/lib/live/boot/0023-timezone"; then
    die "timezone_setup() wurde im Hook nicht gefunden."
fi

echo "OK."

###############################################################################
# Remove old timezone calls from live-boot main
###############################################################################

if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]]; then
    info "Entferne alten timezone_setup-Aufruf aus 9990-main.sh ..."

    sed -i \
        '/^[[:space:]]*timezone_setup[[:space:]]*$/d' \
        "${ROOT}/usr/lib/live/boot/9990-main.sh"

    echo "OK."
fi

###############################################################################
# Make timezone_setup available from /init
#
# We explicitly source the hook from init.
#
# This avoids depending on live-boot's component loader and guarantees that
# the function exists when we call it at the very end of initramfs execution.
###############################################################################

info "Installiere Timezone-Hook in /init ..."

python3 - "${ROOT}/init" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

source_line = '. /usr/lib/live/boot/0023-timezone'

# Remove previous copies of our source line.
lines = text.splitlines()
lines = [
    line for line in lines
    if line.strip() != source_line
]
text = "\n".join(lines) + "\n"

# Find a safe location after the initial shell setup.
#
# We insert immediately after the rootmnt export if present.
marker = 'export rootmnt=/root'

if marker in text:
    replacement = (
        marker
        + '\n\n'
        + '# Load timezone hook.\n'
        + source_line
    )

    if text.count(marker) != 1:
        raise SystemExit(
            "ERROR: expected exactly one 'export rootmnt=/root' marker."
        )

    text = text.replace(marker, replacement, 1)

else:
    # Fallback: insert after the shebang.
    lines = text.splitlines()
    insert_at = 1 if lines and lines[0].startswith("#!") else 0

    lines[insert_at:insert_at] = [
        "",
        "# Load timezone hook.",
        source_line,
        ""
    ]

    text = "\n".join(lines) + "\n"

path.write_text(text)
PY

###############################################################################
# Patch final initramfs action
###############################################################################

info "Patch finalen initramfs-Schritt ..."

python3 - "${ROOT}/init" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = 'exec run-init ${drop_caps} "${rootmnt}" "${init}"'

if marker not in text:
    raise SystemExit(
        "ERROR: final 'exec run-init' marker not found in init."
    )

if text.count(marker) != 1:
    raise SystemExit(
        "ERROR: expected exactly one final 'exec run-init' marker."
    )

# Remove any previous timezone_setup invocation.
lines = text.splitlines()
lines = [
    line for line in lines
    if line.strip() != "timezone_setup"
]
text = "\n".join(lines) + "\n"

# Insert immediately before the final exec run-init.
needle = marker

replacement = (
    "# Apply kernel-command-line timezone as the final initramfs action.\n"
    "timezone_setup\n\n"
    "# Chain to real filesystem\n"
    + needle
)

if text.count(needle) != 1:
    raise SystemExit(
        "ERROR: final run-init marker disappeared or is no longer unique."
    )

text = text.replace(needle, replacement, 1)

path.write_text(text)
PY

###############################################################################
# Verify init
###############################################################################

info "Prüfe gepatchtes init ..."

if ! grep -q '^timezone_setup$' "${ROOT}/init"; then
    die "timezone_setup-Aufruf fehlt in /init."
fi

TIMEZONE_CALLS="$(
    grep -c '^timezone_setup$' "${ROOT}/init" || true
)"

if [[ "${TIMEZONE_CALLS}" -ne 1 ]]; then
    die "Erwartet genau einen timezone_setup-Aufruf in /init, gefunden: ${TIMEZONE_CALLS}"
fi

if ! grep -q \
    'exec run-init ${drop_caps} "${rootmnt}" "${init}"' \
    "${ROOT}/init"; then
    die "Finales exec run-init fehlt in /init."
fi

echo "OK."

###############################################################################
# Verify ordering
###############################################################################

info "Prüfe Reihenfolge ..."

python3 - "${ROOT}/init" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()

timezone_pos = text.find("\ntimezone_setup\n")
run_init_pos = text.find(
    'exec run-init ${drop_caps} "${rootmnt}" "${init}"'
)

if timezone_pos == -1:
    raise SystemExit(
        "ERROR: timezone_setup not found."
    )

if run_init_pos == -1:
    raise SystemExit(
        "ERROR: final exec run-init not found."
    )

if timezone_pos >= run_init_pos:
    raise SystemExit(
        "ERROR: timezone_setup does not occur before exec run-init."
    )

print("OK: timezone_setup steht unmittelbar vor dem finalen exec run-init.")
PY

###############################################################################
# Show relevant result
###############################################################################

echo
echo "==> Ergebnis /init:"
echo

grep -n -A12 -B8 \
    'timezone_setup' \
    "${ROOT}/init" || true

echo
echo "==> Ergebnis Timezone-Hook:"
echo

sed -n '1,140p' \
    "${ROOT}/usr/lib/live/boot/0023-timezone"

###############################################################################
# Repack initrd
###############################################################################

info "Packe Initrd ..."

rm -f "${OUTPUT}"

case "${COMPRESSION}" in
    zstd)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc
        ) |
            zstd -q -T0 -19 -c > "${OUTPUT}"
        ;;
    gzip)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc
        ) |
            gzip -c > "${OUTPUT}"
        ;;
    xz)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc
        ) |
            xz -c -T0 > "${OUTPUT}"
        ;;
    bzip2)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc
        ) |
            bzip2 -c > "${OUTPUT}"
        ;;
    lz4)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc
        ) |
            lz4 -c > "${OUTPUT}"
        ;;
    lzop)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc
        ) |
            lzop -c > "${OUTPUT}"
        ;;
    none)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc
        ) > "${OUTPUT}"
        ;;
esac

###############################################################################
# Permissions
###############################################################################

chmod 0644 "${OUTPUT}"

###############################################################################
# Final verification
###############################################################################

info "Prüfe Ergebnis ..."

[[ -s "${OUTPUT}" ]] ||
    die "Output initrd wurde nicht erstellt oder ist leer."

OUTPUT_INFO="$(file -b "${OUTPUT}")"

echo "${OUTPUT}: ${OUTPUT_INFO}"

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"
echo
