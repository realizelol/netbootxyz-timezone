#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Generic Live Initrd Timezone Patcher
#
# Kali / Debian live-boot:
#   - patches usr/lib/live/boot/9990-main.sh
#   - installs usr/lib/live/boot/0023-timezone
#
# Ubuntu / Mint casper:
#   - detects casper
#   - does NOT modify the initrd yet
#   - repacks it unchanged so the workflow continues
#
# Usage:
#   ./scripts/patch-initrd.sh input-initrd output-initrd
#
###############################################################################

###############################################################################
# Root / sudo handling
###############################################################################

if [[ ${EUID} -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

###############################################################################
# Arguments
###############################################################################

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

###############################################################################
# Configuration
###############################################################################

TIMEZONE_HOOK="patches/0023-timezone"

WORKDIR=""
ROOT=""

###############################################################################
# Logging
###############################################################################

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"
echo

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

###############################################################################
# Error helper
###############################################################################

die()
{
    echo
    echo "ERROR: $*" >&2
    exit 1
}

###############################################################################
# Check commands
###############################################################################

echo "==> Prüfe benötigte Werkzeuge ..."
echo

for cmd in file cpio find grep sed awk zstd gzip xz bzip2; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "Required command '${cmd}' not found."
    fi
done

###############################################################################
# Input checks
###############################################################################

echo "==> Prüfe Input ..."

[[ -f "${INPUT}" ]] || die "Input-Datei '${INPUT}' nicht gefunden."

FILE_INFO="$(file "${INPUT}")"

echo "${FILE_INFO}"

###############################################################################
# Detect compression
###############################################################################

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
    *"ASCII cpio archive"*|*"cpio archive"*)
        COMPRESSION="none"
        ;;
    *)
        die "Unbekanntes Initrd-Kompressionsformat."
        ;;
esac

echo "Compression: ${COMPRESSION}"
echo

###############################################################################
# Create temporary working directory
###############################################################################

WORKDIR="$(mktemp -d -t timezone-patch-XXXXXXXX)"
ROOT="${WORKDIR}/root"

mkdir -p "${ROOT}"

###############################################################################
# Extract initrd
###############################################################################

echo "==> Entpacke Initrd ..."
echo

cd "${ROOT}"

case "${COMPRESSION}" in

    zstd)
        zstd -q -d --stdout "${OLDPWD}/${INPUT}" | cpio -idm --no-absolute-filenames
        ;;

    gzip)
        gzip -dc "${OLDPWD}/${INPUT}" | cpio -idm --no-absolute-filenames
        ;;

    xz)
        xz -dc "${OLDPWD}/${INPUT}" | cpio -idm --no-absolute-filenames
        ;;

    bzip2)
        bzip2 -dc "${OLDPWD}/${INPUT}" | cpio -idm --no-absolute-filenames
        ;;

    none)
        cpio -idm --no-absolute-filenames < "${OLDPWD}/${INPUT}"
        ;;

esac

cd "${OLDPWD}"

echo

###############################################################################
# Detect live system
###############################################################################

echo "==> Erkenne Live-System ..."

LIVE_BOOT=0
CASPER=0

if [[ -f "${ROOT}/usr/lib/live/boot/9990-main.sh" ]] ||
   [[ -d "${ROOT}/usr/lib/live/boot" ]] ||
   [[ -f "${ROOT}/scripts/live" ]]; then

    LIVE_BOOT=1
    echo "OK: live-boot erkannt."

elif [[ -f "${ROOT}/scripts/casper" ]] ||
     [[ -f "${ROOT}/scripts/casper-functions" ]] ||
     [[ -f "${ROOT}/etc/casper.conf" ]]; then

    CASPER=1
    echo "OK: casper erkannt."

else

    echo
    echo "ERROR: Kein unterstütztes Live-System erkannt."
    echo
    echo "Vorhandene relevante Dateien:"

    find "${ROOT}" \
        -type f \
        \( \
            -path "*/live/*" -o \
            -path "*/casper/*" -o \
            -name "9990-main.sh" -o \
            -name "casper" -o \
            -name "casper-functions" -o \
            -name "casper.conf" \
        \) \
        -print \
        2>/dev/null \
        | sort \
        | head -200 || true

    exit 1
fi

echo

###############################################################################
# Kali / Debian live-boot
###############################################################################

if [[ ${LIVE_BOOT} -eq 1 ]]; then

    echo "==> Live-System: live-boot"
    echo

    MAIN="${ROOT}/usr/lib/live/boot/9990-main.sh"

    [[ -f "${MAIN}" ]] || die \
        "live-boot erkannt, aber ${MAIN} fehlt."

    [[ -f "${OLDPWD}/${TIMEZONE_HOOK}" ]] || die \
        "Timezone-Hook '${TIMEZONE_HOOK}' nicht gefunden."

    ###########################################################################
    # Install timezone hook
    ###########################################################################

    echo "==> Installiere Timezone-Hook ..."
    echo "    ${ROOT}/usr/lib/live/boot/0023-timezone"

    mkdir -p "${ROOT}/usr/lib/live/boot"

    cp "${OLDPWD}/${TIMEZONE_HOOK}" \
       "${ROOT}/usr/lib/live/boot/0023-timezone"

    chmod 0755 "${ROOT}/usr/lib/live/boot/0023-timezone"

    ###########################################################################
    # Remove older timezone hooks
    ###########################################################################

    echo "==> Entferne alte Timezone-Hooks ..."

    find "${ROOT}/usr/lib/live/boot" \
        -type f \
        -name '*timezone*' \
        ! -name '0023-timezone' \
        -delete \
        2>/dev/null || true

    ###########################################################################
    # Verify hook
    ###########################################################################

    echo
    echo "==> Prüfe installierten Timezone-Hook ..."

    if [[ ! -x "${ROOT}/usr/lib/live/boot/0023-timezone" ]]; then
        die "Timezone-Hook wurde nicht korrekt installiert."
    fi

    echo "OK."

    ###########################################################################
    # Patch 9990-main.sh
    #
    # We intentionally execute timezone_setup AFTER Swap and immediately
    # BEFORE the stdout/stderr redirection is closed.
    ###########################################################################

    echo
    echo "==> Patch 9990-main.sh ..."

    # Remove previous timezone_setup calls inserted by earlier versions.
    sed -i '/^[[:space:]]*timezone_setup[[:space:]]*$/d' "${MAIN}"

    # Remove previous comments inserted by this patcher.
    sed -i \
        '/Apply kernel-command-line timezone as late as possible,/d' \
        "${MAIN}"

    sed -i \
        '/after the Live root filesystem and swap setup are complete\./d' \
        "${MAIN}"

    ###########################################################################
    # Find the Swap line
    ###########################################################################

    SWAP_LINE="$(
        grep -n -m1 -E '^[[:space:]]*Swap[[:space:]]*$' "${MAIN}" \
        | cut -d: -f1 || true
    )"

    [[ -n "${SWAP_LINE}" ]] || die \
        "Konnte 'Swap' in ${MAIN} nicht finden."

    ###########################################################################
    # Insert timezone_setup directly after Swap
    ###########################################################################

    sed -i \
        "${SWAP_LINE}a\\
\\
        # Apply kernel-command-line timezone as late as possible,\\
        # after the Live root filesystem and swap setup are complete.\\
        timezone_setup" \
        "${MAIN}"

    echo "    timezone_setup eingefügt: direkt nach Swap."

    ###########################################################################
    # Verify position
    ###########################################################################

    echo
    echo "==> Prüfe Position von timezone_setup ..."

    NEW_SWAP_LINE="$(
        grep -n -m1 -E '^[[:space:]]*Swap[[:space:]]*$' "${MAIN}" \
        | cut -d: -f1
    )"

    TIMEZONE_LINE="$(
        grep -n -m1 -E '^[[:space:]]*timezone_setup[[:space:]]*$' "${MAIN}" \
        | cut -d: -f1 || true
    )"

    if [[ -z "${TIMEZONE_LINE}" ]]; then
        die "timezone_setup wurde nicht eingefügt."
    fi

    if (( TIMEZONE_LINE != NEW_SWAP_LINE + 4 )); then
        die \
            "timezone_setup steht nicht an der erwarteten Position. " \
            "Swap=${NEW_SWAP_LINE}, timezone_setup=${TIMEZONE_LINE}"
    fi

    echo "OK:"
    echo "    Swap            : Zeile ${NEW_SWAP_LINE}"
    echo "    timezone_setup  : Zeile ${TIMEZONE_LINE}"

    ###########################################################################
    # Show relevant section
    ###########################################################################

    echo
    echo "==> Ergebnis 9990-main.sh:"

    sed -n \
        "$((NEW_SWAP_LINE - 4)),$((TIMEZONE_LINE + 7))p" \
        "${MAIN}"

    ###########################################################################
    # Final verification
    ###########################################################################

    echo
    echo "==> Finale Prüfung ..."

    grep -q \
        '^[[:space:]]*timezone_setup[[:space:]]*$' \
        "${MAIN}" \
        || die "timezone_setup fehlt."

    grep -q \
        'exec 1>&6 6>&-' \
        "${MAIN}" \
        || die "stdout cleanup nicht gefunden."

    grep -q \
        'exec 2>&7 7>&-' \
        "${MAIN}" \
        || die "stderr cleanup nicht gefunden."

    echo "OK."

###############################################################################
# Mint / Ubuntu casper
###############################################################################

elif [[ ${CASPER} -eq 1 ]]; then

    echo "==> Live-System: casper"
    echo
    echo "INFO: Casper wird aktuell NICHT verändert."
    echo "      Die Initrd wird unverändert wieder gepackt."
    echo
    echo "      Dadurch bleibt Mint vorerst unangetastet und"
    echo "      der Workflow kann erfolgreich durchlaufen."

fi

###############################################################################
# Repack initrd
###############################################################################

echo
echo "==> Packe Initrd ..."

TMP_OUTPUT="${OUTPUT}.tmp"

rm -f "${TMP_OUTPUT}"

cd "${ROOT}"

case "${COMPRESSION}" in

    zstd)

        # cpio -> zstd -> output
        #
        # Wichtig:
        # Nicht 'zstd ... -o initrd.timezone.tmp' verwenden, weil
        # zstd bei bestimmten Aufrufen/Versionen den Dateinamen anders
        # behandelt. Wir schreiben explizit nach stdout und leiten um.

        find . -print0 \
            | cpio --null -o -H newc \
            | zstd -q -T0 -c \
            > "${OLDPWD}/${TMP_OUTPUT}"

        ;;

    gzip)

        find . -print0 \
            | cpio --null -o -H newc \
            | gzip -c \
            > "${OLDPWD}/${TMP_OUTPUT}"

        ;;

    xz)

        find . -print0 \
            | cpio --null -o -H newc \
            | xz -c \
            > "${OLDPWD}/${TMP_OUTPUT}"

        ;;

    bzip2)

        find . -print0 \
            | cpio --null -o -H newc \
            | bzip2 -c \
            > "${OLDPWD}/${TMP_OUTPUT}"

        ;;

    none)

        find . -print0 \
            | cpio --null -o -H newc \
            > "${OLDPWD}/${TMP_OUTPUT}"

        ;;

esac

cd "${OLDPWD}"

###############################################################################
# Verify output
###############################################################################

echo

if [[ ! -s "${TMP_OUTPUT}" ]]; then
    die "Ausgabe-Initrd wurde nicht erzeugt."
fi

mv -f "${TMP_OUTPUT}" "${OUTPUT}"

echo "OK: Initrd erfolgreich erzeugt."
echo

echo "Output:"
ls -lh "${OUTPUT}"

echo
echo "Dateityp:"
file "${OUTPUT}"

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
