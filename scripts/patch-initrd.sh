#!/usr/bin/env bash

set -euo pipefail

INPUT="${1:-initrd}"
OUTPUT="${2:-initrd.timezone}"

echo "============================================================"
echo " Generic Live Initrd Timezone Patcher"
echo "============================================================"
echo
echo "Input  : $INPUT"
echo "Output : $OUTPUT"
echo

# ============================================================
# Voraussetzungen
# ============================================================

for cmd in cpio zstd file find grep sed awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FEHLER: '$cmd' wurde nicht gefunden."
        exit 1
    fi
done

if [ ! -f "$INPUT" ]; then
    echo "FEHLER: Input-Initrd nicht gefunden: $INPUT"
    exit 1
fi

# ============================================================
# Original prüfen
# ============================================================

echo "==> Prüfe Original-Initrd ..."

file "$INPUT"

# ============================================================
# Temporäres Arbeitsverzeichnis
# ============================================================

WORKDIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORKDIR"
}

trap cleanup EXIT

ROOT="$WORKDIR/root"

mkdir -p "$ROOT"

# ============================================================
# Initrd entpacken
# ============================================================

echo
echo "==> Entpacke Initrd ..."

cd "$ROOT"

zstd -d -c "$OLDPWD/$INPUT" | cpio -idm --quiet

cd - >/dev/null

# ============================================================
# Live-System erkennen
# ============================================================

echo
echo "==> Erkenne Live-System ..."

CASPER=0
LIVE_BOOT=0

if [ -d "$ROOT/scripts/casper-bottom" ]; then
    CASPER=1
    echo "OK: casper erkannt."
fi

if [ -d "$ROOT/usr/lib/live/boot" ]; then
    LIVE_BOOT=1
    echo "OK: live-boot erkannt."
fi

if [ "$CASPER" -eq 0 ] && [ "$LIVE_BOOT" -eq 0 ]; then
    echo
    echo "FEHLER: Weder casper noch live-boot erkannt."
    exit 1
fi

# ============================================================
# Timezone-Hook
# ============================================================

create_timezone_hook() {

    local target="$1"

    mkdir -p "$(dirname "$target")"

    cat > "$target" <<'EOF'
#!/bin/sh

# ============================================================
# Generic Live timezone hook
#
# Die Zeitzone wird ausschließlich aus /proc/cmdline gelesen.
#
# Erwartet:
#
#     timezone=Europe/Berlin
#
# Kein Fallback.
# ============================================================

CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"

TIMEZONE=""

for ARG in $CMDLINE; do
    case "$ARG" in
        timezone=*)
            TIMEZONE="${ARG#timezone=}"
            ;;
    esac
done

# Keine timezone= Angabe -> nichts tun.
if [ -z "$TIMEZONE" ]; then
    exit 0
fi

# Keine Shell-Metazeichen / Whitespaces akzeptieren.
case "$TIMEZONE" in
    *[!A-Za-z0-9_./+-]*)
        echo "timezone: ungültiger Wert: $TIMEZONE"
        exit 0
        ;;
esac

ZONEINFO="/usr/share/zoneinfo/$TIMEZONE"

# Zoneinfo muss existieren.
if [ ! -f "/root$ZONEINFO" ]; then
    echo "timezone: Zone nicht gefunden: $TIMEZONE"
    exit 0
fi

echo "timezone: setze $TIMEZONE"

# /etc/timezone
printf '%s\n' "$TIMEZONE" > /root/etc/timezone

# /etc/localtime
rm -f /root/etc/localtime

ln -s "$ZONEINFO" /root/etc/localtime

exit 0
EOF

    chmod 0755 "$target"
}

# ============================================================
# Casper
# ============================================================

if [ "$CASPER" -eq 1 ]; then

    echo
    echo "==> Erzeuge casper Timezone-Hook ..."

    HOOK="$ROOT/scripts/casper-bottom/23timezone"

    create_timezone_hook "$HOOK"

    # --------------------------------------------------------
    # ORDER
    # --------------------------------------------------------

    ORDER="$ROOT/scripts/casper-bottom/ORDER"

    echo
    echo "==> Aktualisiere casper-bottom/ORDER ..."

    if [ ! -f "$ORDER" ]; then
        echo "FEHLER: ORDER nicht gefunden."
        exit 1
    fi

    # Vorhandenen Eintrag entfernen.
    sed -i \
        '\|/scripts/casper-bottom/23timezone "\$@"|d' \
        "$ORDER"

    # Vor 25configure_init einfügen.
    if grep -q \
        '/scripts/casper-bottom/25configure_init "\$@"' \
        "$ORDER"
    then

        sed -i \
            '/\/scripts\/casper-bottom\/25configure_init "\$@"/i /scripts/casper-bottom/23timezone "$@"' \
            "$ORDER"

    else

        echo
        echo "WARNING: 25configure_init nicht gefunden."

        printf '%s\n' \
            '/scripts/casper-bottom/23timezone "$@"' \
            >> "$ORDER"
    fi

    echo
    echo "==> Relevanter Abschnitt von ORDER:"

    grep -n -A2 -B2 \
        '23timezone\|25configure_init' \
        "$ORDER" || true

fi

# ============================================================
# live-boot
# ============================================================

if [ "$LIVE_BOOT" -eq 1 ]; then

    echo
    echo "==> Erzeuge live-boot Timezone-Hook ..."

    HOOK="$ROOT/usr/lib/live/boot/0100-timezone.sh"

    create_timezone_hook "$HOOK"

    echo
    echo "OK: live-boot Hook:"
    echo "    $HOOK"

fi

# ============================================================
# Inhalt prüfen
# ============================================================

echo
echo "==> Prüfe eingebauten Hook ..."

if [ "$CASPER" -eq 1 ]; then

    test -f \
        "$ROOT/scripts/casper-bottom/23timezone"

    echo "OK: casper Hook vorhanden."

fi

if [ "$LIVE_BOOT" -eq 1 ]; then

    test -f \
        "$ROOT/usr/lib/live/boot/0100-timezone.sh"

    echo "OK: live-boot Hook vorhanden."

fi

# ============================================================
# Neue Initrd erzeugen
# ============================================================

echo
echo "==> Erzeuge neue Zstandard-Initrd ..."

cd "$ROOT"

find . \
    -print \
    -depth \
    | cpio -o -H newc --quiet \
    | zstd -T0 -19 -o "$OLDPWD/$OUTPUT"

cd - >/dev/null

# ============================================================
# Ergebnis prüfen
# ============================================================

echo
echo "==> Prüfe erzeugte Initrd ..."

if [ ! -s "$OUTPUT" ]; then
    echo "FEHLER: Output-Initrd wurde nicht erzeugt."
    exit 1
fi

file "$OUTPUT"

ls -lh "$OUTPUT"

# ============================================================
# Initrd erneut auslesen
# ============================================================

echo
echo "==> Prüfe Inhalt der neuen Initrd ..."

VERIFY="$WORKDIR/verify"

mkdir -p "$VERIFY"

cd "$VERIFY"

zstd -d -c "$OLDPWD/$OUTPUT" \
    | cpio -it --quiet \
    > "$WORKDIR/filelist"

cd - >/dev/null

if [ "$CASPER" -eq 1 ]; then

    if grep -Eq \
        '(^|/)scripts/casper-bottom/23timezone$' \
        "$WORKDIR/filelist"
    then
        echo "OK: casper Timezone-Hook ist in der neuen Initrd."
    else
        echo "FEHLER: casper Timezone-Hook fehlt."
        echo
        echo "Gefundene Timezone-Einträge:"
        grep -E 'timezone|localtime' "$WORKDIR/filelist" || true
        exit 1
    fi


fi

if [ "$LIVE_BOOT" -eq 1 ]; then

    if grep -Eq \
        '(^|/)usr/lib/live/boot/0100-timezone\.sh$' \
        "$WORKDIR/filelist"
    then
        echo "OK: live-boot Timezone-Hook ist in der neuen Initrd."
    else
        echo "FEHLER: live-boot Timezone-Hook fehlt."
        echo
        echo "Gefundene Timezone-Einträge:"
        grep -E 'timezone|localtime' "$WORKDIR/filelist" || true
        exit 1
    fi


fi

echo
echo "============================================================"
echo " ERFOLG"
echo "============================================================"
echo
echo "Timezone-Hook erfolgreich eingebaut."
echo
echo "Output:"
echo "  $OUTPUT"
echo
