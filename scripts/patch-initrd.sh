#!/usr/bin/env bash

set -euo pipefail

INPUT="${1:?Input initrd fehlt}"
OUTPUT="${2:?Output initrd fehlt}"

WORKDIR="$(mktemp -d)"
ROOT="${WORKDIR}/root"

cleanup() {
    rm -rf "${WORKDIR}"
}

trap cleanup EXIT

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input  : ${INPUT}"
echo "Output : ${OUTPUT}"
echo

echo "==> Prüfe Original-Initrd ..."

test -s "${INPUT}"
file "${INPUT}"

mkdir -p "${ROOT}"

echo
echo "==> Entpacke Initrd ..."

unzstd -c "${INPUT}" | (
    cd "${ROOT}"
    cpio -id --quiet
)

echo
echo "==> Erkenne Live-System ..."

if [[ -d "${ROOT}/scripts/casper-bottom" ]]; then

    TYPE="casper"

    echo "OK: casper erkannt."

elif [[ -d "${ROOT}/scripts/live" ||
        -d "${ROOT}/usr/lib/live/boot" ]]; then

    TYPE="live-boot"

    echo "OK: live-boot erkannt."

else

    echo
    echo "FEHLER: Kein unterstütztes Live-System erkannt."
    echo
    echo "Erwartet wurde entweder:"
    echo "  scripts/casper-bottom"
    echo "oder:"
    echo "  scripts/live"
    echo "  usr/lib/live/boot"
    exit 1

fi

echo
echo "==> Erzeuge Timezone-Hook ..."

case "${TYPE}" in

    casper)

        HOOK="${ROOT}/scripts/casper-bottom/23timezone"

        cat > "${HOOK}" <<'EOF'
#!/bin/sh

PREREQ=""

prereqs()
{
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

TZ=""

for param in $(cat /proc/cmdline); do
    case "$param" in
        timezone=*)
            TZ="${param#timezone=}"
            ;;
    esac
done

# Keine timezone auf der Kernel-Commandline:
# nichts verändern.
[ -z "$TZ" ] && exit 0

# Prüfen, ob die angegebene Zeitzone existiert.
if [ ! -e "/root/usr/share/zoneinfo/$TZ" ]; then
    echo "WARNING: Timezone '$TZ' not found."
    exit 0
fi

echo "Setting timezone to $TZ"

mkdir -p /root/etc

echo "$TZ" > /root/etc/timezone

rm -f /root/etc/localtime
ln -s "/usr/share/zoneinfo/$TZ" /root/etc/localtime

exit 0
EOF

        chmod 0755 "${HOOK}"

        ORDER="${ROOT}/scripts/casper-bottom/ORDER"

        echo
        echo "==> Aktualisiere casper-bottom/ORDER ..."

        if ! grep -q \
            '/scripts/casper-bottom/23timezone' \
            "${ORDER}"
        then

            awk '
                /25configure_init/ {
                    print "/scripts/casper-bottom/23timezone \"$@\""
                }
                {
                    print
                }
            ' "${ORDER}" > "${ORDER}.new"

            mv "${ORDER}.new" "${ORDER}"

        fi

        echo
        echo "==> Relevanter Abschnitt von ORDER:"

        grep -n -A1 -B1 \
            '/scripts/casper-bottom/23timezone\|/scripts/casper-bottom/25configure_init' \
            "${ORDER}" || true

        ;;

    live-boot)

        HOOK="${ROOT}/scripts/live/23timezone"

        cat > "${HOOK}" <<'EOF'
#!/bin/sh

PREREQ=""

prereqs()
{
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

TZ=""

for param in $(cat /proc/cmdline); do
    case "$param" in
        timezone=*)
            TZ="${param#timezone=}"
            ;;
    esac
done

# Keine timezone auf der Kernel-Commandline:
# nichts verändern.
[ -z "$TZ" ] && exit 0

# Prüfen, ob die angegebene Zeitzone existiert.
if [ ! -e "/root/usr/share/zoneinfo/$TZ" ]; then
    echo "WARNING: Timezone '$TZ' not found."
    exit 0
fi

echo "Setting timezone to $TZ"

mkdir -p /root/etc

echo "$TZ" > /root/etc/timezone

rm -f /root/etc/localtime
ln -s "/usr/share/zoneinfo/$TZ" /root/etc/localtime

exit 0
EOF

        chmod 0755 "${HOOK}"

        echo
        echo "OK: live-boot Timezone-Hook:"
        echo "    scripts/live/23timezone"

        ;;

esac

echo
echo "==> Erzeuge neue Zstandard-Initrd ..."

(
    cd "${ROOT}"

    find . -print0 |
        cpio --null -o -H newc --quiet |
        zstd -T0 -19 -o "${OUTPUT}"
)

echo
echo "==> Prüfe erzeugte Initrd ..."

test -s "${OUTPUT}"

file "${OUTPUT}"
ls -lh "${OUTPUT}"

echo
echo "==> Prüfe Timezone-Hook ..."

case "${TYPE}" in

    casper)
        test -f "${ROOT}/scripts/casper-bottom/23timezone"
        echo "OK: Casper Timezone-Hook ist vorhanden."
        ;;

    live-boot)
        test -f "${ROOT}/scripts/live/23timezone"
        echo "OK: live-boot Timezone-Hook ist vorhanden."
        ;;

esac

echo
echo "============================================================"
echo " Fertig"
echo "============================================================"
