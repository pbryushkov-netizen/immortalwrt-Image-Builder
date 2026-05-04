#!/bin/sh
# Downloads subscription URL and updates UCI server config.
# Supports: single vless:// key, plain list, or base64-encoded list.
. /lib/functions.sh

# Must wait for internet — subscription script starts BEFORE WAN is fully up
wait_net() {
    local N=0
    while ! ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 \
       && ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; do
        N=$((N+1))
        [ "$N" -ge 30 ] && return 1
        sleep 3
    done
    return 0
}

SUB_URL=$(uci get vpn.settings.subscription_url 2>/dev/null)
[ -z "$SUB_URL" ] && exit 0

# Strip URL fragment (#alias text) — servers never see it, only confuses curl
SUB_URL="${SUB_URL%%#*}"
[ -z "$SUB_URL" ] && exit 0

wait_net || { logger -t "VPN" "Subscription: no internet, skipping"; exit 1; }

logger -t "VPN" "Updating subscription from $SUB_URL"

TMPFILE=$(mktemp)
# Mimic a common VPN client UA; some panels reject default curl UA
HTTP_CODE=$(curl -sL \
    -A "v2rayNG/1.8.8" \
    --connect-timeout 15 \
    --max-time 60 \
    -w "%{http_code}" \
    -o "$TMPFILE" \
    "$SUB_URL" 2>/dev/null)

if [ $? -ne 0 ] || [ "$HTTP_CODE" != "200" ]; then
    logger -t "VPN" "Subscription failed (HTTP $HTTP_CODE)"
    rm -f "$TMPFILE"
    exit 1
fi

CONTENT=$(cat "$TMPFILE")
rm -f "$TMPFILE"

# Detect format and extract vless:// keys
if printf '%s' "$CONTENT" | grep -q "vless://"; then
    # Plain list (one key per line or space/comma separated)
    KEYS=$(printf '%s' "$CONTENT" | grep -o 'vless://[^[:space:]]*')
else
    # Try base64 decode (convert URL-safe chars first)
    CLEAN=$(printf '%s' "$CONTENT" | tr -d '\r\n ' | tr -- '-_' '+/')
    KEYS=$(printf '%s' "$CLEAN" | base64 -d 2>/dev/null | grep -o 'vless://[^[:space:]]*')
fi

if [ -z "$KEYS" ]; then
    logger -t "VPN" "No vless:// keys found in subscription response"
    exit 1
fi

# Remove previously imported subscription servers (keep manually added 'main')
for SEC in $(uci show vpn | grep "=server" | cut -d. -f2 | cut -d= -f1); do
    case "$SEC" in main) continue ;; esac
    uci delete "vpn.$SEC" 2>/dev/null
done

IDX=0
printf '%s\n' "$KEYS" | while IFS= read -r KEY; do
    KEY=$(printf '%s' "$KEY" | tr -d '\r\n ')
    [ -z "$KEY" ] && continue
    IDX=$((IDX + 1))
    SECNAME="sub_${IDX}"

    # Parse the vless:// URI
    eval "$(vless-parse.sh "$KEY" 2>/dev/null)"
    [ -z "$server" ] && continue

    uci set "vpn.${SECNAME}=server"
    uci set "vpn.${SECNAME}.alias=${alias:-Server $IDX}"
    uci set "vpn.${SECNAME}.server=$server"
    uci set "vpn.${SECNAME}.port=${port:-443}"
    uci set "vpn.${SECNAME}.uuid=$uuid"
    uci set "vpn.${SECNAME}.transport=${transport:-xhttp}"
    uci set "vpn.${SECNAME}.sni=$sni"
    uci set "vpn.${SECNAME}.pbk=$pbk"
    uci set "vpn.${SECNAME}.sid=$sid"
    # Activate first server
    [ "$IDX" = "1" ] && uci set "vpn.${SECNAME}.active=1" \
                     || uci set "vpn.${SECNAME}.active=0"
done

uci commit vpn
logger -t "VPN" "Subscription updated (${IDX} servers)"
