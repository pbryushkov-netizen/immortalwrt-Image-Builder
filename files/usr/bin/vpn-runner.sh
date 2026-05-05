#!/bin/sh
# VPN runner — Cudy WR3000 v1 (aarch64)
# Flow: wait_net -> ensure binary -> fetch subscription -> exec sing-box run
# Fallback: build config from UCI server if no subscription.

REPO="GITHUB_REPO_PLACEHOLDER"
SBOX=/tmp/sing-box
SBOX_MIN=5000000
SUB_JSON=/tmp/sing-box-sub.json

log() { logger -t VPN "$*"; }

# ── Wait for internet ──────────────────────────────────────────────────────────
wait_net() {
    local n=0
    log "Waiting for internet..."
    while ! ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 \
       && ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; do
        n=$((n+1))
        [ $n -ge 40 ] && log "No internet after 120s" && return 1
        sleep 3
    done
    log "Internet OK"
}

# ── Download sing-box binary ───────────────────────────────────────────────────
dl_sbox() {
    local url sz tgz mirror

    url="https://github.com/${REPO}/releases/download/vpn-core/sing-box"
    for mirror in "" "https://mirror.ghproxy.com/" "https://ghp.ci/"; do
        log "Downloading sing-box from ${mirror:-github.com}..."
        rm -f "$SBOX"
        curl -sfL --connect-timeout 20 --max-time 180 \
            -o "$SBOX" "${mirror}${url}" 2>/dev/null
        sz=$(wc -c <"$SBOX" 2>/dev/null || echo 0)
        if [ "${sz:-0}" -ge "$SBOX_MIN" ]; then
            chmod +x "$SBOX"
            log "sing-box ready (${sz} bytes)"
            return 0
        fi
        rm -f "$SBOX"
    done

    # Fallback: official SagerNet ARM64 tarball
    local ver
    ver=$(curl -sfL --connect-timeout 10 --max-time 15 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | grep -o '"tag_name":"[^"]*"' | head -1 | sed 's/"tag_name":"v//;s/"//')
    ver="${ver:-1.11.0}"

    tgz=/tmp/sb.tgz
    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-arm64.tar.gz"
    for mirror in "" "https://mirror.ghproxy.com/" "https://ghp.ci/"; do
        log "Fallback: SagerNet v${ver}..."
        rm -f "$tgz"
        curl -sfL --connect-timeout 20 --max-time 180 \
            -o "$tgz" "${mirror}${url}" 2>/dev/null
        sz=$(wc -c <"$tgz" 2>/dev/null || echo 0)
        if [ "${sz:-0}" -ge "$SBOX_MIN" ]; then
            rm -rf /tmp/sb_ext
            mkdir -p /tmp/sb_ext
            tar -C /tmp/sb_ext -xzf "$tgz" 2>/dev/null
            if mv /tmp/sb_ext/*/sing-box "$SBOX" 2>/dev/null; then
                chmod +x "$SBOX"
                rm -f "$tgz"
                rm -rf /tmp/sb_ext
                log "sing-box (fallback) ready"
                return 0
            fi
            rm -rf /tmp/sb_ext
        fi
        rm -f "$tgz"
    done
    return 1
}

# ── UCI fallback config ────────────────────────────────────────────────────────
build_uci_config() {
    local sec="$1"
    local active server port uuid transport sni pbk sid
    local transport_block flow_block

    config_get active    "$sec" active    "0"
    [ "$active" != "1" ] && return
    config_get server    "$sec" server    ""
    config_get port      "$sec" port      443
    config_get uuid      "$sec" uuid      ""
    config_get transport "$sec" transport "tcp"
    config_get sni       "$sec" sni       ""
    config_get pbk       "$sec" pbk       ""
    config_get sid       "$sec" sid       ""

    [ -z "$server" ] || [ -z "$uuid" ] && return

    transport_block=""
    flow_block=""
    case "$transport" in
        xhttp|splithttp|http)
            transport_block='"transport":{"type":"xhttp","path":"/"},' ;;
        *)
            flow_block='"flow":"xtls-rprx-vision",' ;;
    esac

    cat > /tmp/sing-box-uci.json << JSONEOF
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "tun", "tag": "tun-in",
    "interface_name": "tun0",
    "address": "172.19.0.1/30",
    "auto_route": true, "strict_route": false, "sniff": true
  }],
  "outbounds": [
    {
      "type": "vless", "tag": "vless-out",
      "server": "$server", "server_port": $port, "uuid": "$uuid",
      $flow_block
      $transport_block
      "tls": {
        "enabled": true, "server_name": "$sni",
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
JSONEOF
    UCI_FOUND=1
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

wait_net || exit 1

# 1. Ensure usable binary
sz=$(wc -c <"$SBOX" 2>/dev/null || echo 0)
if [ ! -x "$SBOX" ] || [ "${sz:-0}" -lt "$SBOX_MIN" ]; then
    log "Downloading sing-box to RAM..."
    dl_sbox || { log "ERROR: All download mirrors failed"; exit 1; }
fi
if ! "$SBOX" version >/dev/null 2>&1; then
    log "Binary unusable — re-downloading..."
    rm -f "$SBOX"
    dl_sbox || { log "ERROR: Re-download failed"; exit 1; }
fi
log "Using $("$SBOX" version 2>/dev/null | head -1)"

# 2. Fetch subscription
SUB_URL=$(uci get vpn.settings.subscription_url 2>/dev/null)
if [ -n "$SUB_URL" ]; then
    rm -f "$SUB_JSON"
    vpn-subscription.sh
fi

# 3. Run with subscription config (has smart routing: RU=direct, blocked=VPN)
if [ -f "$SUB_JSON" ]; then
    log "Starting sing-box with subscription config (smart routing)..."
    exec "$SBOX" run -c "$SUB_JSON"
fi

# 4. Fallback: UCI manually-configured server
. /lib/functions.sh
config_load vpn
UCI_FOUND=0
config_foreach build_uci_config server

if [ "$UCI_FOUND" = "0" ]; then
    log "No active server configured — VPN not started"
    exit 0
fi

log "Starting sing-box with UCI config..."
exec "$SBOX" run -c /tmp/sing-box-uci.json
exit 1