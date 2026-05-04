#!/bin/sh
# VPN runner — downloads sing-box to RAM on first start, builds config, starts tunnel.
# sing-box (~10 MB) cannot fit in 16 MB Flash — we keep it in /tmp (256 MB RAM).
# Routing: .ru/.su/.xn--p1ai domains → direct, everything else → VLESS tunnel.
# If VPN fails: strict_route=false → traffic falls through to direct (no breakage).

REPO="GITHUB_REPO_PLACEHOLDER"
SBOX=/tmp/sing-box
SBOX_URL="https://github.com/${REPO}/releases/download/vpn-core/sing-box"
SBOX_MIN_SIZE=5000000   # 5 MB — guards against downloading an HTML 404 page

log() { logger -t "VPN" "$1"; }

# Download with 3-mirror fallback and minimum-size check
dl() {
    local FILE=$1 URL=$2 MIN=${3:-1}
    for MIRROR in "" "https://mirror.ghproxy.com/" "https://ghp.ci/"; do
        log "Downloading ${FILE##*/}..."
        rm -f "$FILE"
        curl -sfL --connect-timeout 20 --max-time 180 \
            -o "$FILE" "${MIRROR}${URL}" 2>/dev/null
        local SZ
        SZ=$(wc -c < "$FILE" 2>/dev/null || echo 0)
        [ "$SZ" -ge "$MIN" ] && return 0
    done
    rm -f "$FILE"
    return 1
}

wait_net() {
    log "Waiting for internet..."
    local N=0
    while ! ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 \
       && ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; do
        N=$((N+1))
        [ "$N" -ge 40 ] && log "No internet after 120s" && return 1
        sleep 3
    done
    log "Internet OK"
}

build_config() {
    local sec="$1"
    local active; config_get active "$sec" active "0"
    [ "$active" != "1" ] && return

    local server port uuid transport sni pbk sid
    config_get server    "$sec" server    ""
    config_get port      "$sec" port     443
    config_get uuid      "$sec" uuid     ""
    config_get transport "$sec" transport xhttp
    config_get sni       "$sec" sni      ""
    config_get pbk       "$sec" pbk      ""
    config_get sid       "$sec" sid      ""

    [ -z "$server" ] || [ -z "$uuid" ] && return

    # Normalize: subscription URIs often use 'splithttp', sing-box 1.13+ uses 'xhttp'
    case "$transport" in
        xhttp|splithttp|split-http) transport="xhttp" ;;
        *) transport="tcp" ;;
    esac

    local FLOW="" TRANS=""
    if [ "$transport" = "xhttp" ]; then
        TRANS='"transport":{"type":"xhttp","path":"/"},'
    else
        FLOW='"flow":"xtls-rprx-vision",'
    fi

    # Generate sing-box config (v1.13.x format — no legacy dns section)
    # Routing via TLS SNI sniffing: .ru/.su/.xn--p1ai → direct, rest → VLESS
    cat > /tmp/sing-box.json << JSON
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "tun",
    "tag": "tun-in",
    "interface_name": "tun0",
    "address": "172.19.0.1/30",
    "auto_route": true,
    "strict_route": false,
    "sniff": true,
    "sniff_override_destination": false
  }],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "$server",
      "server_port": $port,
      "uuid": "$uuid",
      $FLOW
      $TRANS
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {"enabled": true, "public_key": "$pbk", "short_id": "$sid"}
      },
      "packet_encoding": "xudp"
    },
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "rules": [
      {"domain_suffix": [".ru", ".su", ".xn--p1ai"], "outbound": "direct"},
      {"ip_is_private": true, "outbound": "direct"}
    ],
    "final": "vless-out",
    "auto_detect_interface": true
  }
}
JSON
    FOUND=1
}

# ── MAIN ────────────────────────────────────────────────────────────────────

wait_net || exit 1

# Download sing-box binary if missing or suspiciously small (HTML 404 guard)
SBOX_SZ=0
[ -f "$SBOX" ] && SBOX_SZ=$(wc -c < "$SBOX" 2>/dev/null || echo 0)
if [ ! -x "$SBOX" ] || [ "$SBOX_SZ" -lt "$SBOX_MIN_SIZE" ]; then
    log "Downloading sing-box binary to RAM..."
    if ! dl "$SBOX" "$SBOX_URL" "$SBOX_MIN_SIZE"; then
        log "ERROR: Failed to download sing-box binary (all mirrors failed)"
        exit 1
    fi
    chmod +x "$SBOX"
fi

# Verify binary is actually executable (catches wrong-arch or corrupt downloads)
if ! "$SBOX" version >/dev/null 2>&1; then
    log "Binary corrupt/wrong arch — re-downloading..."
    rm -f "$SBOX"
    dl "$SBOX" "$SBOX_URL" "$SBOX_MIN_SIZE" && chmod +x "$SBOX" || {
        log "ERROR: Re-download also failed"
        exit 1
    }
fi

# Build sing-box config from UCI active server
. /lib/functions.sh
config_load vpn
FOUND=0
config_foreach build_config server

if [ "$FOUND" = "0" ]; then
    log "No active server configured — VPN not started"
    exit 0
fi

# Validate generated config before launching
if ! "$SBOX" check -c /tmp/sing-box.json >/dev/null 2>&1; then
    log "Config validation failed: $("$SBOX" check -c /tmp/sing-box.json 2>&1 | head -1)"
    exit 1
fi

log "Starting sing-box tunnel..."
exec "$SBOX" run -c /tmp/sing-box.json
