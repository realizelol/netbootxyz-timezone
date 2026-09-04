#!/bin/sh

set -eu

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"

PATCH_FILE="${REPO_ROOT}/patches/0023-timezone"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/timezone-patch-XXXXXX")"
ROOT="${WORK}/root"

cleanup()
{
    rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

echo
echo "Input : ${INPUT}"
echo "Output: ${OUTPUT}"

# ------------------------------------------------------------
# Requirements
# ------------------------------------------------------------

command -v file >/dev/null 2>&1 ||
    die "file not found"

command -v cpio >/dev/null 2>&1 ||
    die "cpio not found"

command -v gzip >/dev/null 2>&1 ||
    die "gzip not found"

command -v zstd >/dev/null 2>&1 ||
    die "zstd not found"

[ -f "${INPUT}" ] ||
    die "Input initrd not found: ${INPUT}"

[ -f "${PATCH_FILE}" ] ||
    die "Timezone patch not found: ${PATCH_FILE}"

# ------------------------------------------------------------
# Detect compression
# ------------------------------------------------------------

echo
echo "==> Prüfe Input ..."

FILE_TYPE="$(file -b "${INPUT}")"
echo "${INPUT}: ${FILE_TYPE}"

case "${FILE_TYPE}" in
    *"Zstandard compressed data"*)
        COMPRESSION="zstd"
        ;;
    *"gzip compressed data"*)
        COMPRESSION="gzip"
        ;;
    *"ASCII cpio archive"*|*"cpio archive"*)
        COMPRESSION="none"
        ;;
    *)
        die "Unsupported initrd format: ${FILE_TYPE}"
        ;;
esac

# ------------------------------------------------------------
# Extract
# ------------------------------------------------------------

echo
echo "==> Entpacke Initrd ..."

mkdir -p "${ROOT}"

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

[ -f "${ROOT}/init" ] ||
    die "Extracted initrd does not contain /init"

# ------------------------------------------------------------
# Detect live system
# ------------------------------------------------------------

echo
echo "==> Erkenne Live-System ..."

LIVE_BOOT=0
CASPER=0

if [ -f "${ROOT}/usr/bin/live-boot" ] ||
   [ -d "${ROOT}/usr/lib/live/boot" ]; then
    LIVE_BOOT=1
    echo "OK: live-boot erkannt."
fi

if [ -f "${ROOT}/scripts/casper" ] ||
   [ -d "${ROOT}/casper" ] ||
   [ -d "${ROOT}/scripts/casper-bottom" ]; then
    CASPER=1
    echo "OK: casper erkannt."
fi

if [ "${LIVE_BOOT}" -eq 0 ] && [ "${CASPER}" -eq 0 ]; then
    die "Neither live-boot nor casper detected."
fi

# ------------------------------------------------------------
# Install timezone hook
# ------------------------------------------------------------

echo
echo "==> Installiere Timezone-Hook ..."

TIMEZONE_DIR="${ROOT}/usr/lib/live/boot"

if [ "${LIVE_BOOT}" -eq 1 ]; then
    mkdir -p "${TIMEZONE_DIR}"

    # Remove all old variants of our hook.
    rm -f \
        "${TIMEZONE_DIR}/023-timezone" \
        "${TIMEZONE_DIR}/0023-timezone" \
        "${ROOT}/lib/live/boot/023-timezone" \
        "${ROOT}/lib/live/boot/0023-timezone" \
        2>/dev/null || true

    cp "${PATCH_FILE}" "${TIMEZONE_DIR}/0023-timezone"
    chmod 0755 "${TIMEZONE_DIR}/0023-timezone"

    echo "    ${TIMEZONE_DIR}/0023-timezone"

    # Verify that lib/live/boot resolves to the same location.
    if [ -e "${ROOT}/lib/live/boot" ]; then
        :
    fi

    # --------------------------------------------------------
    # IMPORTANT:
    #
    # live-boot loads /lib/live/boot/????-*.
    #
    # Because /lib is normally a symlink to /usr/lib, installing
    # the hook in /usr/lib/live/boot is sufficient.
    # --------------------------------------------------------

    grep -q 'timezone_setup()' \
        "${TIMEZONE_DIR}/0023-timezone" ||
        die "Timezone hook was not installed correctly."

    echo "OK: Timezone hook installed."

    # --------------------------------------------------------
    # Remove old timezone_setup calls from 9990-main.sh.
    # --------------------------------------------------------

    MAIN="${TIMEZONE_DIR}/9990-main.sh"

    if [ -f "${MAIN}" ]; then
        TMP_MAIN="${WORK}/9990-main.sh"

        sed '/^[[:space:]]*timezone_setup[[:space:]]*$/d' \
            "${MAIN}" > "${TMP_MAIN}"

        mv "${TMP_MAIN}" "${MAIN}"
        chmod 0755 "${MAIN}"

        echo "==> Entferne alten timezone_setup-Aufruf aus 9990-main.sh ..."
    fi

    # --------------------------------------------------------
    # Patch /init.
    #
    # The timezone must be applied to the FINAL live rootfs,
    # immediately before run-init.
    # --------------------------------------------------------

    echo
    echo "==> Patch /init ..."

    INIT="${ROOT}/init"

    grep -q 'exec run-init' "${INIT}" ||
        die "Could not find exec run-init in init."

    # Do not patch twice.
    if grep -q 'timezone_setup' "${INIT}"; then
        echo "    timezone_setup ist bereits in init vorhanden."
    else
        INIT_TMP="${WORK}/init"

        awk '
        BEGIN {
            inserted = 0
        }

        /exec run-init/ && inserted == 0 {
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
            die "Failed to patch init."

        mv "${INIT_TMP}" "${INIT}"
        chmod 0755 "${INIT}"

        echo "    timezone_setup eingefügt."
    fi

    # --------------------------------------------------------
    # Verify init patch.
    # --------------------------------------------------------

    echo
    echo "==> Prüfe gepatchtes /init ..."

    grep -n -A8 -B8 'timezone_setup' "${INIT}" ||
        die "timezone_setup not found in patched init."

    grep -q 'timezone_setup' "${INIT}" ||
        die "Timezone setup call missing from init."

    echo "OK."

else
    # --------------------------------------------------------
    # Casper handling
    #
    # Casper does not use the live-boot 9990-main.sh mechanism.
    # The hook therefore gets installed as a normal casper-bottom
    # script.
    # --------------------------------------------------------

    echo "==> Installiere Casper-TimeZone-Hook ..."

    CASPER_BOTTOM="${ROOT}/scripts/casper-bottom"

    mkdir -p "${CASPER_BOTTOM}"

    # Remove old variants.
    rm -f \
        "${CASPER_BOTTOM}/023-timezone" \
        "${CASPER_BOTTOM}/0023-timezone" \
        "${CASPER_BOTTOM}/50timezone" \
        2>/dev/null || true

    # Casper executes bottom scripts in lexical order.
    #
    # 99-timezone is intentionally late so that the final root
    # filesystem already exists.
    CASPER_HOOK="${CASPER_BOTTOM}/99-timezone"

    cat > "${CASPER_HOOK}" <<'EOF'
#!/bin/sh

timezone_setup()
{
    tz=""

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
            echo "timezone: invalid timezone: $tz" >&2
            return 0
            ;;
    esac

    if [ -z "${rootmnt:-}" ]; then
        echo "timezone: rootmnt is not set" >&2
        return 0
    fi

    if [ ! -f "${rootmnt}/usr/share/zoneinfo/${tz}" ]; then
        echo "timezone: unknown timezone: ${tz}" >&2
        return 0
    fi

    echo "timezone: rootmnt=${rootmnt}"
    echo "timezone: setting timezone to ${tz}"

    rm -f "${rootmnt}/etc/localtime"

    ln -s \
        "/usr/share/zoneinfo/${tz}" \
        "${rootmnt}/etc/localtime"

    printf '%s\n' "${tz}" > "${rootmnt}/etc/timezone"
}

timezone_setup
EOF

    chmod 0755 "${CASPER_HOOK}"

    echo "    ${CASPER_HOOK}"

    grep -q 'timezone_setup()' "${CASPER_HOOK}" ||
        die "Casper timezone hook verification failed."

    echo "OK: Casper timezone hook installed."
fi

# ------------------------------------------------------------
# Final generic verification
# ------------------------------------------------------------

echo
echo "==> Prüfe installierten Timezone-Hook ..."

if [ "${LIVE_BOOT}" -eq 1 ]; then
    [ -f "${ROOT}/usr/lib/live/boot/0023-timezone" ] ||
        die "live-boot timezone hook missing."

    grep -q 'timezone_setup()' \
        "${ROOT}/usr/lib/live/boot/0023-timezone" ||
        die "live-boot timezone_setup() missing."

    grep -q 'timezone_setup' "${ROOT}/init" ||
        die "timezone_setup call missing from init."

    echo "OK."
fi

if [ "${CASPER}" -eq 1 ]; then
    [ -f "${ROOT}/scripts/casper-bottom/99-timezone" ] ||
        die "casper timezone hook missing."

    grep -q 'timezone_setup()' \
        "${ROOT}/scripts/casper-bottom/99-timezone" ||
        die "casper timezone_setup() missing."

    echo "OK."
fi

# ------------------------------------------------------------
# Repack
# ------------------------------------------------------------

echo
echo "==> Packe Initrd ..."

OUTPUT_DIR="$(dirname -- "${OUTPUT}")"

if [ "${OUTPUT_DIR}" != "." ]; then
    mkdir -p "${OUTPUT_DIR}"
fi

TMP_OUTPUT="${OUTPUT}.tmp"

rm -f "${TMP_OUTPUT}"

case "${COMPRESSION}" in
    zstd)
        (
            cd "${ROOT}"
            find . -print |
                cpio -o -H newc --quiet |
                zstd -q -T0 -c
        ) > "${TMP_OUTPUT}"
        ;;
    gzip)
        (
            cd "${ROOT}"
            find . -print |
                cpio -o -H newc --quiet |
                gzip -c
        ) > "${TMP_OUTPUT}"
        ;;
    none)
        (
            cd "${ROOT}"
            find . -print |
                cpio -o -H newc --quiet
        ) > "${TMP_OUTPUT}"
        ;;
esac

mv "${TMP_OUTPUT}" "${OUTPUT}"

chmod 0644 "${OUTPUT}"

# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

echo
echo "==> Ergebnis ..."

ls -lh "${OUTPUT}"
file "${OUTPUT}"

echo
echo "============================================================"
echo " Fertig."
echo "============================================================"
