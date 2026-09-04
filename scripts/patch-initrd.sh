#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Generic Live Initrd Timezone Patcher
#
# Supports:
#   - Debian/Ubuntu/Mint casper initrds
#   - Debian/Kali live-boot initrds
#   - gzip
#   - xz
#   - zstd
#   - lz4
#   - lzop
#
# The timezone is read from:
#
#     timezone=Europe/Berlin
#
# and applied as the FINAL initramfs action immediately before:
#
#     exec run-init ...
#
# This is intentional: live-boot/casper may modify /etc/localtime while
# constructing the final live root. By applying the timezone immediately
# before run-init, the final live root is modified after those operations.
###############################################################################

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

INPUT="${1:-${REPO_ROOT}/initrd}"
OUTPUT="${2:-${REPO_ROOT}/initrd.timezone}"

WORK="$(mktemp -d -t timezone-patch-XXXXXXXXXX)"
ROOT="${WORK}/root"

cleanup()
{
    rm -rf "${WORK}"
}

trap cleanup EXIT

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
    echo "==> $*"
}

require_cmd()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command '$1' not found."
}

###############################################################################
# Validate arguments
###############################################################################

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"

[[ -f "${INPUT}" ]] ||
    die "Input initrd not found: ${INPUT}"

mkdir -p "${ROOT}"

###############################################################################
# Detect compression
###############################################################################

info "Prüfe Input ..."

FILE_INFO="$(file -b "${INPUT}")"

echo "${INPUT}: ${FILE_INFO}"

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
    *)
        # Uncompressed cpio archives are also valid initrds.
        if cpio -it < "${INPUT}" >/dev/null 2>&1; then
            COMPRESSION="none"
        else
            die "Unsupported initrd format: ${FILE_INFO}"
        fi
        ;;
esac

echo "Compression: ${COMPRESSION}"

###############################################################################
# Required tools
###############################################################################

require_cmd file
require_cmd cpio

case "${COMPRESSION}" in
    zstd)
        require_cmd zstd
        ;;
    xz)
        require_cmd xz
        ;;
    gzip)
        require_cmd gzip
        ;;
    lz4)
        require_cmd lz4
        ;;
    lzop)
        require_cmd lzop
        ;;
    none)
        ;;
esac

###############################################################################
# Extract initrd
###############################################################################

info "Entpacke Initrd ..."

case "${COMPRESSION}" in
    zstd)
        zstd -q -d -c "${INPUT}" | (
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
    gzip)
        gzip -d -c "${INPUT}" | (
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
    lzop)
        lzop -d -c "${INPUT}" | (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames
        )
        ;;
    none)
        (
            cd "${ROOT}"
            cpio -idm --no-absolute-filenames < "${INPUT}"
        )
        ;;
esac

###############################################################################
# Detect live system
###############################################################################

info "Erkenne Live-System ..."

LIVE_BOOT=0
CASPER=0

###############################################################################
# live-boot detection
###############################################################################

if [[ -f "${ROOT}/usr/bin/live-boot" ]] ||
   [[ -d "${ROOT}/usr/lib/live/boot" ]] ||
   [[ -d "${ROOT}/lib/live/boot" ]]; then

    LIVE_BOOT=1

    echo "OK: live-boot erkannt."
fi

###############################################################################
# casper / Ubuntu / Mint detection
#
# Casper versions differ considerably between releases. Do not rely on a
# single directory existing.
###############################################################################

if [[ -d "${ROOT}/scripts" ]]; then

    if find "${ROOT}/scripts" -maxdepth 2 -type f \
        \( \
            -name 'casper*' \
            -o -name '*casper*' \
        \) \
        -print -quit 2>/dev/null |
        grep -q .; then

        CASPER=1
        echo "OK: casper erkannt."
    fi
fi

###############################################################################
# Additional Mint/Ubuntu live-initrd detection
#
# Some Mint initrds don't contain an obvious casper directory, but still
# contain the live filesystem handling scripts.
###############################################################################

if [[ ${CASPER} -eq 0 ]]; then

    if find "${ROOT}/scripts" -maxdepth 2 -type f \
        \( \
            -name 'live' \
            -o -name 'live-*' \
            -o -name 'local' \
        \) \
        -print -quit 2>/dev/null |
        grep -q .; then

        if grep -R -q \
            -E 'filesystem\.squashfs|/run/live|live-media|casper' \
            "${ROOT}/scripts" \
            2>/dev/null; then

            CASPER=1
            echo "OK: Ubuntu/Mint Live-Initrd erkannt."
        fi
    fi
fi

###############################################################################
# Generic live-initrd fallback
#
# If the initrd contains filesystem.squashfs/live-media handling, it is
# sufficient for our purpose: we only need to patch the final init.
###############################################################################

if [[ ${LIVE_BOOT} -eq 0 && ${CASPER} -eq 0 ]]; then

    if grep -R -q \
        -E 'filesystem\.squashfs|/run/live|live-media|casper|mount_images_in_directory' \
        "${ROOT}/scripts" \
        "${ROOT}/usr" \
        2>/dev/null; then

        CASPER=1
        echo "OK: generisches Live-Initrd erkannt."
    fi
fi

if [[ ${LIVE_BOOT} -eq 0 && ${CASPER} -eq 0 ]]; then

    echo
    echo "ERROR: Kein unterstütztes Live-System erkannt."
    echo
    echo "Vorhandene initramfs scripts:"
    find "${ROOT}/scripts" -maxdepth 2 -type f \
        -print 2>/dev/null |
        sort |
        head -100
    echo

    die "Kein unterstütztes Live-System erkannt."
fi


###############################################################################
# Create final timezone code
###############################################################################

TIMEZONE_CODE="${WORK}/timezone-final.sh"

cat > "${TIMEZONE_CODE}" <<'EOF'
# Apply kernel-command-line timezone as the FINAL initramfs action.
#
# This must run immediately before exec run-init.
#
# The final live root is already mounted/constructed at this point.

timezone_setup_final()
{
    tz=""

    for arg in $(cat /proc/cmdline); do
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
            echo "timezone-final: invalid timezone: $tz" >&2
            return 0
            ;;
    esac

    # rootmnt is the final live root.
    if [ -z "${rootmnt:-}" ]; then
        echo "timezone-final: rootmnt is not set" >&2
        return 0
    fi

    # The timezone database belongs to the final root filesystem.
    if [ ! -f "${rootmnt}/usr/share/zoneinfo/${tz}" ]; then
        echo "timezone-final: unknown timezone: ${tz}" >&2
        return 0
    fi

    echo "timezone-final: rootmnt=${rootmnt}"
    echo "timezone-final: setting timezone to ${tz}"

    echo "timezone-final: BEFORE:"
    ls -l "${rootmnt}/etc/localtime" 2>&1 || true
    cat "${rootmnt}/etc/timezone" 2>&1 || true

    # Remove whatever the live system currently has.
    rm -f "${rootmnt}/etc/localtime"

    # Create the conventional absolute symlink used by Debian-family
    # systems. Because rootmnt is the target root, the link itself must
    # contain /usr/share/zoneinfo/... rather than rootmnt-prefixed paths.
    ln -s \
        "/usr/share/zoneinfo/${tz}" \
        "${rootmnt}/etc/localtime"

    # Debian/Mint/Kali commonly use /etc/timezone as well.
    printf '%s\n' "${tz}" > "${rootmnt}/etc/timezone"

    echo "timezone-final: AFTER:"
    ls -l "${rootmnt}/etc/localtime" 2>&1 || true
    cat "${rootmnt}/etc/timezone" 2>&1 || true
}

timezone_setup_final

EOF

###############################################################################
# Patch init
###############################################################################

info "Patch init ..."

INIT_FILE="${ROOT}/init"

[[ -f "${INIT_FILE}" ]] ||
    die "Init file not found: ${INIT_FILE}"

###############################################################################
# Remove previous versions of our final timezone patch.
#
# This makes the script idempotent and avoids duplicate functions when the
# same initrd is patched more than once.
###############################################################################

python3 - "${INIT_FILE}" "${TIMEZONE_CODE}" <<'PY'
import sys
from pathlib import Path

init_path = Path(sys.argv[1])
timezone_path = Path(sys.argv[2])

text = init_path.read_text()

begin_marker = "# BEGIN NETBOOTXYZ TIMEZONE FINAL PATCH"
end_marker = "# END NETBOOTXYZ TIMEZONE FINAL PATCH"

begin = text.find(begin_marker)
if begin != -1:
    end = text.find(end_marker, begin)

    if end == -1:
        raise SystemExit(
            "ERROR: Existing timezone patch has BEGIN marker but no END marker."
        )

    end += len(end_marker)

    # Remove trailing newline belonging to the old patch.
    if end < len(text) and text[end] == "\n":
        end += 1

    text = text[:begin] + text[end:]

timezone_code = timezone_path.read_text().rstrip()

patch = (
    begin_marker
    + "\n"
    + timezone_code
    + "\n"
    + end_marker
    + "\n"
)

# We want the patch immediately before the final exec run-init.
lines = text.splitlines(keepends=True)

exec_index = None

for i, line in enumerate(lines):
    stripped = line.strip()

    if (
        stripped.startswith("exec run-init ")
        and "${rootmnt}" in stripped
        and "${init}" in stripped
    ):
        exec_index = i
        break

if exec_index is None:
    raise SystemExit(
        "ERROR: Could not find final 'exec run-init ...' in init."
    )

lines.insert(exec_index, "\n" + patch)

init_path.write_text("".join(lines))
PY

echo "    timezone_setup_final eingefügt."

###############################################################################
# Verify init patch
###############################################################################

info "Prüfe finalen init-Patch ..."

grep -n -A8 -B5 \
    "BEGIN NETBOOTXYZ TIMEZONE FINAL PATCH" \
    "${INIT_FILE}" || die "Timezone patch not found in init."

grep -n \
    "timezone_setup_final" \
    "${INIT_FILE}" || die "timezone_setup_final not found in init."

###############################################################################
# Verify ordering
###############################################################################

python3 - "${INIT_FILE}" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()

patch_pos = text.find("# BEGIN NETBOOTXYZ TIMEZONE FINAL PATCH")
exec_pos = text.find("exec run-init ")

if patch_pos == -1:
    raise SystemExit("ERROR: timezone patch marker missing.")

if exec_pos == -1:
    raise SystemExit("ERROR: final exec run-init missing.")

if patch_pos > exec_pos:
    raise SystemExit(
        "ERROR: timezone patch appears AFTER exec run-init."
    )

print("OK: timezone patch appears before final exec run-init.")
PY

###############################################################################
# Remove old live-boot timezone hooks if they belong to our previous patch.
#
# We deliberately do NOT touch distribution-provided files.
###############################################################################

info "Entferne alte eigene Timezone-Hooks ..."

for old_hook in \
    "${ROOT}/usr/lib/live/boot/023-timezone" \
    "${ROOT}/usr/lib/live/boot/0023-timezone" \
    "${ROOT}/lib/live/boot/023-timezone" \
    "${ROOT}/lib/live/boot/0023-timezone"
do
    if [[ -f "${old_hook}" ]]; then
        rm -f "${old_hook}"
        echo "    entfernt: ${old_hook}"
    fi
done

###############################################################################
# Remove previous timezone_setup call from 9990-main.sh if it exists.
#
# This is cleanup for earlier versions of the patcher. We only remove the
# exact call, not distribution code.
###############################################################################

for main_file in \
    "${ROOT}/usr/lib/live/boot/9990-main.sh" \
    "${ROOT}/lib/live/boot/9990-main.sh"
do
    if [[ -f "${main_file}" ]]; then
        sed -i \
            '/^[[:space:]]*timezone_setup[[:space:]]*$/d' \
            "${main_file}"
    fi
done

###############################################################################
# Check shell syntax of init
###############################################################################

info "Prüfe Shell-Syntax ..."

bash -n "${INIT_FILE}" ||
    die "Syntaxfehler in gepatchtem init."

###############################################################################
# Repack initrd
###############################################################################

info "Packe Initrd ..."

mkdir -p "$(dirname -- "${OUTPUT}")"

TMP_OUTPUT="${WORK}/initrd.output"

(
    cd "${ROOT}"

    find . -print0 |
        cpio --null -o -H newc
) | case "${COMPRESSION}" in
    zstd)
        zstd -q -T0 -c
        ;;
    xz)
        xz -c
        ;;
    gzip)
        gzip -c
        ;;
    lz4)
        lz4 -c
        ;;
    lzop)
        lzop -c
        ;;
    none)
        cat
        ;;
esac > "${TMP_OUTPUT}"

mv -f "${TMP_OUTPUT}" "${OUTPUT}"

chmod 0644 "${OUTPUT}"

###############################################################################
# Verify output
###############################################################################

info "Prüfe erzeugtes Initrd ..."

[[ -s "${OUTPUT}" ]] ||
    die "Output initrd is empty."

file "${OUTPUT}"

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
echo
echo "Output: ${OUTPUT}"
echo
echo "Timezone wird beim Booten aus:"
echo
echo "    timezone=Europe/Berlin"
echo
echo "gelesen und unmittelbar vor run-init auf das finale Live-Root"
echo "angewendet."
echo
