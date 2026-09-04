#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Generic Live Initrd Timezone Patcher
# ============================================================

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

PATCH_FILE="${REPO_ROOT}/patches/0023-timezone"

WORKDIR="$(mktemp -d)"
ROOT="${WORKDIR}/root"

cleanup() {
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

die() {
    echo "Error: $*" >&2
    exit 1
}

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"

# ------------------------------------------------------------
# Checks
# ------------------------------------------------------------

[[ -f "${INPUT}" ]] ||
    die "Input initrd not found: ${INPUT}"

[[ -f "${PATCH_FILE}" ]] ||
    die "Timezone patch not found: ${PATCH_FILE}"

command -v file >/dev/null 2>&1 ||
    die "Required command 'file' not found."

command -v cpio >/dev/null 2>&1 ||
    die "Required command 'cpio' not found."

command -v zstd >/dev/null 2>&1 ||
    die "Required command 'zstd' not found."

command -v gzip >/dev/null 2>&1 ||
    die "Required command 'gzip' not found."

mkdir -p "${ROOT}"

# ------------------------------------------------------------
# Detect compression
# ------------------------------------------------------------

echo
echo "==> Prüfe Input ..."

FILE_INFO="$(file -b "${INPUT}")"
echo "${INPUT}: ${FILE_INFO}"

COMPRESSION=""

if [[ "${FILE_INFO}" == *"Zstandard compressed data"* ]]; then
    COMPRESSION="zstd"
elif [[ "${FILE_INFO}" == *"gzip compressed data"* ]]; then
    COMPRESSION="gzip"
elif [[ "${FILE_INFO}" == *"cpio archive"* ]]; then
    COMPRESSION="none"
else
    die "Unsupported initrd compression: ${FILE_INFO}"
fi

# ------------------------------------------------------------
# Extract initrd
# ------------------------------------------------------------

echo
echo "==> Entpacke Initrd ..."

case "${COMPRESSION}" in
    zstd)
        zstd -q -d -c "${INPUT}" |
            (cd "${ROOT}" && cpio -idm --quiet)
        ;;

    gzip)
        gzip -dc "${INPUT}" |
            (cd "${ROOT}" && cpio -idm --quiet)
        ;;

    none)
        (cd "${ROOT}" && cpio -idm --quiet) < "${INPUT}"
        ;;
esac

[[ -f "${ROOT}/init" ]] ||
    die "Extracted initrd does not contain init."

# ------------------------------------------------------------
# Detect live system
# ------------------------------------------------------------

echo
echo "==> Erkenne Live-System ..."

LIVE_BOOT=false
CASPER=false

if [[ -f "${ROOT}/usr/bin/live-boot" ||
      -d "${ROOT}/usr/lib/live/boot" ]]; then
    LIVE_BOOT=true
    echo "OK: live-boot erkannt."
fi

if [[ -f "${ROOT}/scripts/casper" ||
      -d "${ROOT}/scripts/casper-bottom" ||
      -d "${ROOT}/casper" ]]; then
    CASPER=true
    echo "OK: casper erkannt."
fi

if [[ "${LIVE_BOOT}" == false && "${CASPER}" == false ]]; then
    die "Kein live-boot oder casper erkannt."
fi

# ------------------------------------------------------------
# Install timezone hook
# ------------------------------------------------------------

echo
echo "==> Installiere Timezone-Hook ..."

if [[ "${LIVE_BOOT}" == true ]]; then

    LIVE_BOOT_DIR="${ROOT}/usr/lib/live/boot"

    mkdir -p "${LIVE_BOOT_DIR}"

    # Remove previous versions of our hook.
    rm -f \
        "${LIVE_BOOT_DIR}/023-timezone" \
        "${LIVE_BOOT_DIR}/0023-timezone"

    cp "${PATCH_FILE}" "${LIVE_BOOT_DIR}/0023-timezone"
    chmod 0755 "${LIVE_BOOT_DIR}/0023-timezone"

    echo "    ${LIVE_BOOT_DIR}/0023-timezone"

    [[ -f "${LIVE_BOOT_DIR}/0023-timezone" ]] ||
        die "Timezone hook was not installed."

    grep -q '^timezone_setup()' \
        "${LIVE_BOOT_DIR}/0023-timezone" ||
        die "timezone_setup() not found in installed hook."

    echo "OK."

    # --------------------------------------------------------
    # Remove old timezone_setup call from 9990-main.sh
    # --------------------------------------------------------

    MAIN="${LIVE_BOOT_DIR}/9990-main.sh"

    if [[ -f "${MAIN}" ]]; then
        MAIN_TMP="${WORKDIR}/9990-main.sh"

        sed \
            '/^[[:space:]]*timezone_setup[[:space:]]*$/d' \
            "${MAIN}" > "${MAIN_TMP}"

        cp "${MAIN_TMP}" "${MAIN}"
        chmod 0755 "${MAIN}"
    fi

    # --------------------------------------------------------
    # Patch /init
    #
    # timezone_setup must run after the final live rootfs
    # exists and immediately before run-init.
    # --------------------------------------------------------

    echo
    echo "==> Patch /init ..."

    INIT="${ROOT}/init"

    if grep -q '^[[:space:]]*timezone_setup[[:space:]]*$' "${INIT}"; then
        echo "    timezone_setup bereits vorhanden."
    else
        INIT_TMP="${WORKDIR}/init"

        awk '
        BEGIN {
            inserted = 0
        }

        /^[[:space:]]*exec run-init/ && inserted == 0 {
            print ""
            print "# Apply kernel-command-line timezone to the final live rootfs."
            print "timezone_setup"
            print ""
            inserted = 1
        }

        {
            print
        }

        END {
            if (inserted == 0) {
                exit 1
            }
        }
        ' "${INIT}" > "${INIT_TMP}" ||
            die "Konnte timezone_setup nicht in init einfügen."

        cp "${INIT_TMP}" "${INIT}"
        chmod 0755 "${INIT}"

        echo "    timezone_setup eingefügt."
    fi

    # --------------------------------------------------------
    # Verify
    # --------------------------------------------------------

    echo
    echo "==> Prüfe gepatchtes /init ..."

    grep -n -A8 -B8 \
        'timezone_setup' \
        "${INIT}" || true

    grep -q \
        '^[[:space:]]*timezone_setup[[:space:]]*$' \
        "${INIT}" ||
        die "timezone_setup fehlt in init."

    echo "OK."

elif [[ "${CASPER}" == true ]]; then

    # --------------------------------------------------------
    # Casper / Mint
    #
    # Keep the existing working integration model.
    # The patch is installed under scripts/casper-bottom.
    # --------------------------------------------------------

    CASPER_DIR="${ROOT}/scripts/casper-bottom"

    mkdir -p "${CASPER_DIR}"

    rm -f \
        "${CASPER_DIR}/023-timezone" \
        "${CASPER_DIR}/0023-timezone"

    cp "${PATCH_FILE}" "${CASPER_DIR}/0023-timezone"
    chmod 0755 "${CASPER_DIR}/0023-timezone"

    echo "    ${CASPER_DIR}/0023-timezone"

    [[ -f "${CASPER_DIR}/0023-timezone" ]] ||
        die "Casper timezone hook was not installed."

    grep -q '^timezone_setup()' \
        "${CASPER_DIR}/0023-timezone" ||
        die "timezone_setup() not found in Casper hook."

    # Casper executes bottom scripts with the root mount
    # available as ${rootmnt}. The function itself is not
    # automatically called merely by being sourced, so append
    # the call.
    if ! tail -n 1 "${CASPER_DIR}/0023-timezone" |
        grep -q '^timezone_setup$'; then

        printf '\n%s\n' 'timezone_setup' \
            >> "${CASPER_DIR}/0023-timezone"
    fi

    echo "OK."

fi

# ------------------------------------------------------------
# Repack
# ------------------------------------------------------------

echo
echo "==> Packe Initrd ..."

OUTPUT_DIR="$(dirname -- "${OUTPUT}")"

if [[ "${OUTPUT_DIR}" != "." ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi

OUTPUT_ABS="$(cd -- "${OUTPUT_DIR}" && pwd)/$(basename -- "${OUTPUT}")"
TMP_OUTPUT="${OUTPUT_ABS}.tmp"

rm -f "${TMP_OUTPUT}"

case "${COMPRESSION}" in

    zstd)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet |
                zstd -q -T0 -c
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

    none)
        (
            cd "${ROOT}"
            find . -print0 |
                cpio --null -o -H newc --quiet
        ) > "${TMP_OUTPUT}"
        ;;

esac

mv -f "${TMP_OUTPUT}" "${OUTPUT_ABS}"

chmod 0644 "${OUTPUT_ABS}"

echo
echo "==> Ergebnis ..."

ls -lh "${OUTPUT_ABS}"
file "${OUTPUT_ABS}"

echo
echo "============================================================"
echo " Fertig."
echo "============================================================"
