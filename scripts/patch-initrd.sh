#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Generic Live Initrd Timezone Patcher
#
# Kernel command line:
#   timezone=Europe/Berlin
#
# Supported:
#   - Debian/Kali live-boot
#   - Ubuntu/Mint casper
#
# Kali/live-boot:
#   timezone_setup is executed as the LAST initramfs action immediately before
#   handing control to the real init via run-init.
#
# Casper:
#   Existing Casper-specific timezone hook is installed so the build/action
#   pipeline remains functional. Casper is deliberately not used for Kali.
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
# Extract initrd
###############################################################################

echo
echo "==> Entpacke Initrd ..."

mkdir -p "${ROOT}"

case "${COMPRESSION}" in
    zstd)
        zstd -q -d -c "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idmu --quiet
            )
        ;;
    lzop)
        lzop -d -c "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idmu --quiet
            )
        ;;
    gzip)
        gzip -d -c "${INPUT}" |
            (
                cd "${ROOT}"
                cpio -idmu --quiet
            )
        ;;
    xz)
        xz -d -c "${INPUT}" |
            (
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

# Kali / Debian / live-boot
#
# IMPORTANT:
# This branch is deliberately independent from Casper.
if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]] &&
   [[ -d "${ROOT}/usr/lib/live/boot" ]] &&
   [[ -f "${ROOT}/usr/bin/live-boot" ]]; then

    LIVE_SYSTEM="live-boot"

# Ubuntu / Mint / Casper
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
# Repository patches
###############################################################################

LIVE_BOOT_PATCH="${REPO_ROOT}/patches/0023-timezone"
CASPER_PATCH="${REPO_ROOT}/patches/casper-bottom-99timezone"

###############################################################################
# Remove old timezone hooks
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
# Kali / Debian live-boot
###############################################################################

if [[ "${LIVE_SYSTEM}" == "live-boot" ]]; then

    echo
    echo "==> Installiere live-boot Timezone-Hook ..."

    [[ -f "${LIVE_BOOT_PATCH}" ]] ||
        die "Patch-Datei fehlt: ${LIVE_BOOT_PATCH}"

    mkdir -p "${ROOT}/usr/lib/live/boot"

    install -m 0755 \
        "${LIVE_BOOT_PATCH}" \
        "${ROOT}/usr/lib/live/boot/0023-timezone"

    echo "    ${ROOT}/usr/lib/live/boot/0023-timezone"

    ###########################################################################
    # Patch the top-level init.
    #
    # Do NOT patch 9990-main.sh.
    #
    # timezone_setup must execute immediately before run-init so that all
    # live-boot root/overlay construction has already completed.
    ###########################################################################

    INIT="${ROOT}/init"

    [[ -f "${INIT}" ]] ||
        die "Top-level init nicht gefunden."

    echo
    echo "==> Patch init ..."

    if grep -q '^[[:space:]]*timezone_setup[[:space:]]*$' "${INIT}"; then

        echo "    timezone_setup bereits vorhanden."

    else

        python3 - "${INIT}" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

needle = (
    'exec run-init ${drop_caps} "${rootmnt}" "${init}" "$@" '
    '<"${rootmnt}/dev/console" >"${rootmnt}/dev/console" 2>&1'
)

if needle not in data:
    raise SystemExit(
        "exec run-init-Zeile in init nicht gefunden."
    )

insert = (
    '# Apply kernel-command-line timezone after the final live root\n'
    '# filesystem and all virtual filesystems have been prepared.\n'
    'timezone_setup\n'
    '\n'
)

data = data.replace(
    needle,
    insert + needle,
    1
)

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

        echo "    timezone_setup unmittelbar vor exec run-init eingefügt."

    fi

    ###########################################################################
    # Verify Kali hook
    ###########################################################################

    echo
    echo "==> Prüfe installierten live-boot Timezone-Hook ..."

    [[ -x "${ROOT}/usr/lib/live/boot/0023-timezone" ]] ||
        die "Timezone-Hook wurde nicht korrekt installiert."

    grep -q 'timezone_setup' \
        "${ROOT}/usr/lib/live/boot/0023-timezone" ||
        die "timezone_setup fehlt im Timezone-Hook."

    grep -q 'timezone=' \
        "${ROOT}/usr/lib/live/boot/0023-timezone" ||
        die "timezone= Unterstützung fehlt."

    echo "OK."

    ###########################################################################
    # Verify init patch
    ###########################################################################

    echo
    echo "==> Prüfe timezone_setup in init ..."

    grep -q '^[[:space:]]*timezone_setup[[:space:]]*$' \
        "${INIT}" ||
        die "timezone_setup wurde nicht in init eingefügt."

    python3 - "${INIT}" <<'PY'
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    data = f.read()

tz = data.find("\ntimezone_setup\n")
run = data.find(
    'exec run-init ${drop_caps} "${rootmnt}" "${init}" "$@" '
    '<"${rootmnt}/dev/console" >"${rootmnt}/dev/console" 2>&1'
)

if tz == -1:
    raise SystemExit("timezone_setup nicht gefunden.")

if run == -1:
    raise SystemExit("exec run-init nicht gefunden.")

if tz > run:
    raise SystemExit(
        "timezone_setup steht NICHT vor exec run-init."
    )
PY

    echo "OK."

    echo
    echo "==> Ergebnis init:"

    grep -n -A8 -B8 \
        'timezone_setup' \
        "${INIT}" || true

fi

###############################################################################
# Mint / Ubuntu Casper
###############################################################################

if [[ "${LIVE_SYSTEM}" == "casper" ]]; then

    echo
    echo "==> Installiere Casper Timezone-Hook ..."

    [[ -f "${CASPER_PATCH}" ]] ||
        die "Patch-Datei fehlt: ${CASPER_PATCH}"

    mkdir -p "${ROOT}/scripts/casper-bottom"

    install -m 0755 \
        "${CASPER_PATCH}" \
        "${ROOT}/scripts/casper-bottom/99timezone"

    echo "    ${ROOT}/scripts/casper-bottom/99timezone"

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
