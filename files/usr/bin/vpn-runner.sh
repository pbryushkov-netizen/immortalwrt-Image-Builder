#!/bin/sh
# VPN runner — downloads sing-box to RAM on first start, builds config, starts tunnel.
# sing-box (~10 MB) cannot fit in 16 MB Flash — we keep it in /tmp (256 MB RAM).
# Routing: .ru/.su/.xn--p1ai → direct, everything else → VLESS tunnel.
# Subscription is fetched synchronously before config build (no race condition).

# Custom-compiled binary published by this repo's CI (injected by build workflow)
REPO="GITHUB_REPO_PLACEHOLDER"
SBOX=/tmp/sing-box
SBOX_MIN_SIZE=5000000    # 5 MB — guards against HTML 404 error pages
SUB_CONFIG=/tmp/sing-box-sub.json

log() { logger -t "VPN" "$1"; }

# Download sing-box: try the CI-built binary first, fall back to SagerNet release
dl_sbox() {
    local SZ TARBALL

    # Primary: direct binary from this repo's GitHub Release (CI-compiled with xhttp tag)
    local CUSTOM_URL="https://github.com/${REPO}/releases/download/vpn-core/sing-box"
    for MIRROR in "" "https://mirror.ghproxy.com/" "https://ghp.ci/"; do
        log "Downloading sing-box..."
        rm -f "$SBOX"
        curl -sfL --connect-timeout 20 --max-time 180 \
            -o "$SBOX" "${MIRROR}${CUSTOM_URL}" 2>/dev/null
        SZ=$(wc -c < "$SBOX" 2>/dev/null || echo 0)
        if [ "$SZ" -ge "$SBOX_MIN_SIZE" ]; then
            chmod +x "$SBOX"
            return 0
        fi
    done

    # Fallback: official SagerNet arm64 release tarball
    local VER="1.13.11"
    TARBALL="/tmp/sing-box.tar.gz"
    local SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-arm64.tar.gz"
    for MIRROR in "" "https://mirror.ghproxy.com/" "https://ghp.ci/"; do
        log "Fallback: downloading sing-box v${VER} from SagerNet..."
        rm -f "$TARBALL"
        curl -sfL --connect-timeout 20 --max-time 180 \
            -o "$TARBALL" "${MIRROR}${SB_URL}" 2>/dev/null
        SZ=$(wc -c < "$TARBALL" 2>/dev/null || echo 0)
        if [ "$SZ" -ge "$SBOX_MIN_SIZE" ]; then
            rm -rf /tmp/sb_ext
            mkdir -p /tmp/sb_ext
            tar -C /tmp/sb_ext -xzf "$TARBALL" 2>/dev/null
            if mv /tmp/sb_ext/*/sing-box "$SBOX" 2>/dev/null; then
                chmod +x "$SBOX"
                rm -f "$TARBALL"
                rm -rf /tmp/sb_ext
                return 0
            fi
            rm -rf /tmp/sb_ext
        fi
    done
    rm -f "$TARBALL" "$SBOX"
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

# Validate config, try xhttp→splithttp fallback for older binaries, then exec sing-box.
# On successful exec this function never returns; on failure it returns 1.
launch_singbox() {
    local cfg="$1"
    if ! "$SBOX" check -c "$cfg" >/dev/null 2>&1; then
        local ERRMSG
        ERRMSG=$("$SBOX" check -c "$cfg" 2>&1 | head -1)
        if echo "$ERRMSG" | grep -q "xhttp"; then
            log "xhttp unsupported in this sing-box build — retrying with splithttp..."
            sed 's/"type":"xhttp"/"type":"splithttp"/g' "$cfg" > "${cfg}.tmp" \
                && mv "${cfg}.tmp" "$cfg"
            if ! "$SBOX" check -c "$cfg" >/dev/null 2>&1; then
                log "Config validation failed: $("$SBOX" check -c "$cfg" 2>&1 | head -1)"
                return 1
            fi
        else
            log "Config validation failed: $ERRMSG"
            return 1
        fi
    fi
    log "Starting sing-box tunnel..."
    exec "$SBOX" run -c "$cfg"
    # exec replaces this process; only reached if exec itself fails (e.g. permission)
    log "ERROR: exec sing-box failed"
    return 1
}

build_config() {
    local sec="$1"
    local active server port uuid transport sni pbk sid
    config_get active    "$sec" active    "0"
    [ "$active" != "1" ] && return

    config_get server    "$sec" server    ""
    config_get port      "$sec" port      443
    config_get uuid      "$sec" uuid      ""
    config_get transport "$sec" transport "xhttp"
    config_get sni       "$sec" sni       ""
    config_get pbk       "$sec" pbk       ""
    config_get sid       "$sec" sid       ""

    [ -z "$server" ] || [ -z "$uuid" ] && return

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

    cat > /tmp/sing-box.json << EOF
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
EOF
    FOUND=1
}

# ── MAIN ─────────────────────────────────────────────────────────────────────

wait_net || exit 1

# Download sing-box binary if missing or suspiciously small (HTML 404 guard)
SBOX_SZ=0
[ -f "$SBOX" ] && SBOX_SZ=$(wc -c < "$SBOX" 2>/dev/null || echo 0)
if [ ! -x "$SBOX" ] || [ "$SBOX_SZ" -lt "$SBOX_MIN_SIZE" ]; then
    log "Downloading sing-box binary to RAM..."
    if ! dl_sbox; then
        log "ERROR: Failed to download sing-box (all mirrors failed)"
        exit 1
    fi
fi

# Verify binary executes (catches wrong-arch or corrupt downloads)
if ! "$SBOX" version >/dev/null 2>&1; then
    log "Binary corrupt/wrong arch — re-downloading..."
    rm -f "$SBOX"
    if ! dl_sbox; then
        log "ERROR: Re-download failed"
        exit 1
    fi
fi

# Fetch subscription synchronously so config is ready before we build.
# (No race: runner owns the lifecycle; init.d no longer spawns subscription.)
SUB_URL=$(uci get vpn.settings.subscription_url 2>/dev/null)
if [ -n "$SUB_URL" ]; then
    rm -f "$SUB_CONFIG"
    vpn-subscription.sh
fi

# If subscription provided a full JSON config, validate and use it directly.
if [ -f "$SUB_CONFIG" ]; then
    log "Validating subscription JSON config..."
    if launch_singbox "$SUB_CONFIG"; then
        exit 0   # unreachable after successful exec
    fi
    log "Subscription config failed — falling back to UCI server config"
    rm -f "$SUB_CONFIG"
fi

# Build config from UCI active server entries
. /lib/functions.sh
config_load vpn
FOUND=0
config_foreach build_config server

if [ "$FOUND" = "0" ]; then
    log "No active server configured — VPN not started"
    exit 0
fi

launch_singbox /tmp/sing-box.json
