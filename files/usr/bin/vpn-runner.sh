#!/bin/sh
# VPN runner: downloads GeoIP to RAM, builds sing-box config, starts tunnel.
# sing-box binary is downloaded to /tmp on first start (too large for 16MB Flash).
# GeoIP databases (~2-3 MB) are downloaded to RAM on every start.

REPO="GITHUB_REPO_PLACEHOLDER"
SBOX=/tmp/sing-box
SBOX_URL="https://github.com/${REPO}/releases/download/vpn-core/sing-box"
GEOIP_URL="https://github.com/savely-krasovsky/ru-routing/releases/latest/download/geoip.srs"
GEOSITE_URL="https://github.com/savely-krasovsky/ru-routing/releases/latest/download/geosite.srs"

log() { logger -t "VPN" "$1"; }

dl() {
    local FILE=$1 URL=$2
    log "Downloading $FILE..."
    curl -sfL -4 --connect-timeout 20 --retry 3 --retry-delay 5 -o "$FILE" "$URL" && return 0
    curl -sfL -4 --connect-timeout 20 --retry 2 -o "$FILE" "https://mirror.ghproxy.com/$URL" && return 0
    curl -sfL -4 --connect-timeout 15 --retry 2 -o "$FILE" "https://ghp.ci/$URL"
}

wait_net() {
    local TRIES=0
    log "Waiting for internet..."
    while ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && ! ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
        TRIES=$((TRIES+1))
        [ "$TRIES" -ge 40 ] && log "No internet after 120s" && return 1
        sleep 3
    done
    return 0
}

build_config() {
    local sec="$1"
    local active; config_get active "$sec" active "0"
    [ "$active" != "1" ] && return

    local server port uuid transport sni pbk sid
    config_get server    "$sec" server
    config_get port      "$sec" port 443
    config_get uuid      "$sec" uuid
    config_get transport "$sec" transport xhttp
    config_get sni       "$sec" sni
    config_get pbk       "$sec" pbk
    config_get sid       "$sec" sid

    [ -z "$server" ] || [ -z "$uuid" ] && return

    local FLOW="" TRANS=""
    if [ "$transport" = "xhttp" ]; then
        TRANS='"transport": {"type": "xhttp", "method": "GET"},'
    else
        FLOW='"flow": "xtls-rprx-vision",'
    fi

    local GEO_RULES="" GEO_SETS=""
    if [ -s /tmp/geo/geoip-ru.srs ] && [ -s /tmp/geo/geosite-ru.srs ]; then
        GEO_SETS='"rule_set": [{"tag": "geoip-ru","type": "local","format": "binary","path": "/tmp/geo/geoip-ru.srs"},{"tag": "geosite-ru","type": "local","format": "binary","path": "/tmp/geo/geosite-ru.srs"}],'
        GEO_RULES='{"rule_set": ["geoip-ru", "geosite-ru"], "outbound": "direct"},'
    fi

    cat > /tmp/sing-box.json << JSON
{
  "log": {"level": "warn"},
  "dns": {
    "servers": [
      {"tag": "remote", "address": "https://1.1.1.1/dns-query", "detour": "vless-out"},
      {"tag": "local",  "address": "223.5.5.5", "detour": "direct"}
    ],
    "rules": [
      {"rule_set": ["geosite-ru"], "server": "local"},
      {"domain_suffix": [".ru", ".su", ".xn--p1ai"], "server": "local"}
    ],
    "final": "remote",
    "independent_cache": true
  },
  "inbounds": [{
    "type": "tun", "tag": "tun-in",
    "interface_name": "tun0",
    "inet4_address": "172.19.0.1/30",
    "auto_route": true,
    "strict_route": false,
    "sniff": true
  }],
  "outbounds": [
    {
      "type": "vless", "tag": "vless-out",
      "server": "$server", "server_port": $port, "uuid": "$uuid",
      $FLOW $TRANS
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
    $GEO_SETS
    "rules": [
      {"protocol": "dns", "action": "hijack-dns"},
      $GEO_RULES
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

mkdir -p /tmp/geo

wait_net || exit 1
log "Internet OK"

# Download sing-box binary to RAM if not present
if [ ! -x "$SBOX" ]; then
    log "Downloading sing-box binary to RAM..."
    dl "$SBOX" "$SBOX_URL"
    chmod +x "$SBOX" 2>/dev/null
fi
if [ ! -x "$SBOX" ]; then
    log "ERROR: Failed to download sing-box binary"
    exit 1
fi

# Download GeoIP databases to RAM (not Flash)
ATTEMPT=0
while [ $ATTEMPT -lt 5 ]; do
    ATTEMPT=$((ATTEMPT+1))
    [ -s /tmp/geo/geoip-ru.srs ]   || dl "/tmp/geo/geoip-ru.srs"   "$GEOIP_URL"
    [ -s /tmp/geo/geosite-ru.srs ] || dl "/tmp/geo/geosite-ru.srs" "$GEOSITE_URL"
    [ -s /tmp/geo/geoip-ru.srs ] && [ -s /tmp/geo/geosite-ru.srs ] && break
    log "GeoIP attempt $ATTEMPT/5 failed, retry in 15s..."
    rm -f /tmp/geo/geoip-ru.srs /tmp/geo/geosite-ru.srs
    sleep 15
done
[ ! -s /tmp/geo/geoip-ru.srs ] && log "GeoIP unavailable — domain-only routing"

# Find active server and build config
. /lib/functions.sh
config_load vpn
FOUND=0
config_foreach build_config server

if [ "$FOUND" = "0" ]; then
    log "No active server configured — VPN not started"
    exit 0
fi

log "Starting sing-box tunnel..."
exec "$SBOX" run -c /tmp/sing-box.json
