#!/bin/sh

# ============================================================
# Generic live-boot timezone hook
#
# Reads:
#   timezone=<Zone>
#
# exclusively from /proc/cmdline.
#
# No fallback timezone.
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

# No timezone= parameter -> do nothing.
[ -n "$TIMEZONE" ] || exit 0

# Basic validation.
case "$TIMEZONE" in
    *[!A-Za-z0-9_./+-]*)
        echo "timezone: invalid timezone value: $TIMEZONE"
        exit 0
        ;;
esac

ZONEINFO="/usr/share/zoneinfo/$TIMEZONE"

# Check whether the requested timezone exists
# in the mounted live filesystem.
if [ ! -f "/root$ZONEINFO" ]; then
    echo "timezone: zoneinfo not found: $TIMEZONE"
    exit 0
fi

echo "timezone: setting $TIMEZONE"

# /etc/timezone
printf '%s\n' "$TIMEZONE" > /root/etc/timezone

# /etc/localtime
rm -f /root/etc/localtime
ln -s "$ZONEINFO" /root/etc/localtime

exit 0
