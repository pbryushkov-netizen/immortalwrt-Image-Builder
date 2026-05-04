#!/bin/sh
# Downloads subscription and updates UCI server config
. /lib/functions.sh

SUB_URL=$(uci get vpn.settings.subscription_url 2>/dev/null)
[ -z "$SUB_URL" ] && exit 0

logger -t "VPN" "Updating subscription from $SUB_URL"

TMPFILE=$(mktemp)
if ! curl -sfL --connect-timeout 15 --max-time 30 -o "$TMPFILE" "$SUB_URL"; then
    logger -t "VPN" "Subscription download failed"
    rm -f "$TMPFILE"
    exit 1
fi

CONTENT=$(cat "$TMPFILE")
rm -f "$TMPFILE"

# Support: single vless:// key or base64-encoded list
if echo "$CONTENT" | grep -q "^vless://"; then
    KEYS="$CONTENT"
else
    KEYS=$(echo "$CONTENT" | base64 -d 2>/dev/null | grep "^vless://")
fi

[ -z "$KEYS" ] && logger -t "VPN" "No vless:// keys in subscription" && exit 1

# Remove old subscription servers (keep manually-added 'main')
for sec in $(uci show vpn | grep "=server" | cut -d. -f2 | cut -d= -f1); do
    [ "$sec" = "main" ] || uci delete "vpn.$sec"
done

IDX=0
echo "$KEYS" | while IFS= read -r KEY; do
    KEY=$(echo "$KEY" | tr -d '\r\n ')
    [ -z "$KEY" ] && continue
    IDX=$((IDX+1))
    SECNAME="sub_$IDX"
    eval "$(vless-parse.sh "$KEY")"
    uci set "vpn.$SECNAME=server"
    uci set "vpn.$SECNAME.alias=${alias:-server $IDX}"
    uci set "vpn.$SECNAME.server=$server"
    uci set "vpn.$SECNAME.port=${port:-443}"
    uci set "vpn.$SECNAME.uuid=$uuid"
    uci set "vpn.$SECNAME.transport=${transport:-xhttp}"
    uci set "vpn.$SECNAME.sni=$sni"
    uci set "vpn.$SECNAME.pbk=$pbk"
    uci set "vpn.$SECNAME.sid=$sid"
    uci set "vpn.$SECNAME.active=0"
    [ "$IDX" = "1" ] && uci set "vpn.$SECNAME.active=1"
done

uci commit vpn
logger -t "VPN" "Subscription updated"
