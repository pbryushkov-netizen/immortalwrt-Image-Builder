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
CONTENT_LEN=$(wc -c < "$TMPFILE" 2>/dev/null || echo 0)
rm -f "$TMPFILE"

logger -t "VPN" "Subscription response: ${CONTENT_LEN} bytes"

# Detect format and extract vless:// keys
if printf '%s' "$CONTENT" | grep -q "vless://"; then
    # Plain list
    KEYS=$(printf '%s' "$CONTENT" | grep -o 'vless://[^[:space:]"]*')
    logger -t "VPN" "Subscription format: plain vless://"
else
    # Try standard base64 and URL-safe base64
    CLEAN=$(printf '%s' "$CONTENT" | tr -d '\r\n \t')
    # Add padding if needed
    PAD=$(( ${#CLEAN} % 4 ))
    [ "$PAD" -eq 2 ] && CLEAN="${CLEAN}=="
    [ "$PAD" -eq 3 ] && CLEAN="${CLEAN}="
    # Try standard first, then URL-safe
    DECODED=$(printf '%s' "$CLEAN" | base64 -d 2>/dev/null)
    [ -z "$DECODED" ] && DECODED=$(printf '%s' "$CLEAN" | tr -- '-_' '+/' | base64 -d 2>/dev/null)
    if printf '%s' "$DECODED" | grep -q "vless://"; then
        KEYS=$(printf '%s' "$DECODED" | grep -o 'vless://[^[:space:]"]*')
        logger -t "VPN" "Subscription format: base64-encoded"
    else
        # Log first 80 chars to help diagnose unknown format
        PREVIEW=$(printf '%s' "$CONTENT" | head -c 80 | tr -d '\000-\037')
        logger -t "VPN" "Subscription unknown format, preview: $PREVIEW"
    fi
fi

[ -z "$KEYS" ] && exit 1

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
