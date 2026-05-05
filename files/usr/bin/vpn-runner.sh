#!/bin/sh
# VPN runner for OpenWrt (aarch64, Cudy WR3000 v1)
# Strategy:
#   1. Download sing-box binary to /tmp (RAM) if absent
#   2. Download subscription -> /tmp/sing-box-sub.json
#   3. Patch legacy dns.servers string format -> object format (sing-box >=1.10)
#   4. exec sing-box run  -- no "check" gate (check is too strict: exits 1 on warnings)
#   5. Fallback: build config from UCI manually-configured server

REPO="GITHUB_REPO_PLACEHOLDER"
SBOX=/tmp/sing-box
SBOX_MIN_SIZE=5000000    # 5 MB -- rejects HTML 404 error pages
SUB_JSON=/tmp/sing-box-sub.json

log() { logger -t "VPN" "$*"; }

# -- Binary download ----------------------------------------------------------
dl_sbox() {
    local URL SZ TGZ MIRROR

    # Primary: CI-compiled binary from this repo's release (has with_xhttp tag)
    URL="https://github.com/${REPO}/releases/download/vpn-core/sing-box"
    for MIRROR in "" "https://mirror.ghproxy.com/" "https://ghp.ci/"; do
        log "Downloading sing-box..."
        rm -f "$SBOX"
        curl -sfL --connect-timeout 20 --max-time 180 \
            -o "$SBOX" "${MIRROR}${URL}" 2>/dev/null
        SZ=$([ -f "$SBOX" ] && wc -c <"$SBOX" 2>/dev/null || echo 0)
        if [ "$SZ" -ge "$SBOX_MIN_SIZE" ]; then
            chmod +x "$SBOX"
            return 0
        fi
    done

    # Fallback: official SagerNet arm64 tarball
    # Version resolved at CI build time; runner also tries latest via API
    local VER
    VER=$(curl -sfL --connect-timeout 10 --max-time 15 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | grep -o '"tag_name":"[^"]*"' | head -1 | sed 's/"tag_name":"v//;s/"//')
    VER="${VER:-1.11.0}"   # paranoid fallback -- 1.11.0 definitely exists and has xhttp

    TGZ=/tmp/sb.tgz
    URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-arm64.tar.gz"
    for MIRROR in "" "https://mirror.ghproxy.com/" "https://ghp.ci/"; do
        log "Fallback: SagerNet v${VER}..."
        rm -f "$TGZ"
        curl -sfL --connect-timeout 20 --max-time 180 \
            -o "$TGZ" "${MIRROR}${URL}" 2>/dev/null
        SZ=$([ -f "$TGZ" ] && wc -c <"$TGZ" 2>/dev/null || echo 0)
        if [ "$SZ" -ge "$SBOX_MIN_SIZE" ]; then
            rm -rf /tmp/sb_ext; mkdir -p /tmp/sb_ext
            tar -C /tmp/sb_ext -xzf "$TGZ" 2>/dev/null
            if mv /tmp/sb_ext/*/sing-box "$SBOX" 2>/dev/null; then
                chmod +x "$SBOX"
                rm -f "$TGZ"; rm -rf /tmp/sb_ext
                return 0
            fi
            rm -rf /tmp/sb_ext
        fi
        rm -f "$TGZ"
    done
    return 1
}

# -- Network wait -------------------------------------------------------------
wait_net() {
    log "Waiting for internet..."
    local N=0
    while ! ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 \
       && ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; do
        N=$((N+1))
        [ $N -ge 40 ] && log "No internet after 120s" && return 1
        sleep 3
    done
    log "Internet OK"
}

# -- DNS format patch (best-effort) -------------------------------------------
# Converts legacy dns.servers string array ["1.1.1.1"] ->
# object array [{"address":"1.1.1.1"}] required by sing-box >=1.10.
# Non-fatal: if Lua is absent or patch fails, sing-box handles the deprecation.
patch_dns_servers() {
    local f="$1"
    [ -f "$f" ] || return
    lua - "$f" 2>/dev/null << 'LUAEOF'
local path = arg[1]
local fh = io.open(path, "r")
if not fh then return end
local s = fh:read("*a"); fh:close()
-- Patch only plain-string entries inside "servers":[...] arrays
s = s:gsub('"servers"%s*:%s*(%[.-%])', function(arr)
    if arr:find('[{]') then return '"servers":' .. arr end
    return '"servers":' .. arr:gsub('"([^"]+)"', '{"address":"%1"}')
end)
local wh = io.open(path, "w")
if wh then wh:write(s); wh:close() end
LUAEOF
}

# -- UCI config builder (manual server fallback) ------------------------------
build_uci_config() {
    local sec="$1"
    local active server port uuid transport sni pbk sid
    config_get active    "$sec" active    "0"; [ "$active" != "1" ] && return
    config_get server    "$sec" server    ""
    config_get port      "$sec" port      443
    config_get uuid      "$sec" uuid      ""
    config_get transport "$sec" transport "tcp"
    config_get sni       "$sec" sni       ""
    config_get pbk       "$sec" pbk       ""
    config_get sid       "$sec" sid       ""
    [ -z "$server" ] || [ -z "$uuid" ] && return

    local TRANSPORT_BLOCK="" FLOW_BLOCK=""
    case "$transport" in
        xhttp|splithttp) TRANSPORT_BLOCK='"transport":{"type":"xhttp","path":"/"},' ;;
        *)               FLOW_BLOCK='"flow":"xtls-rprx-vision",' ;;
    esac

    cat > /tmp/sing-box-uci.json << EOF
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
      $FLOW_BLOCK
      $TRANSPORT_BLOCK
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
EOF
    UCI_FOUND=1
}

# ==============================================================================
#  MAIN
# ==============================================================================

wait_net || exit 1

# -- 1. Ensure usable binary ---------------------------------------------------
SBOX_SZ=$([ -f "$SBOX" ] && wc -c <"$SBOX" 2>/dev/null || echo 0)
if [ ! -x "$SBOX" ] || [ "$SBOX_SZ" -lt "$SBOX_MIN_SIZE" ]; then
    log "Downloading sing-box binary to RAM..."
    dl_sbox || { log "ERROR: All download mirrors failed"; exit 1; }
fi

# Sanity-check: binary must at least run --version
if ! "$SBOX" version >/dev/null 2>&1; then
    log "Binary unusable (wrong arch or corrupt) -- re-downloading..."
    rm -f "$SBOX"
    dl_sbox || { log "ERROR: Re-download failed"; exit 1; }
fi

log "Using $("$SBOX" version 2>/dev/null | head -1)"

# -- 2. Fetch subscription ----------------------------------------------------
SUB_URL=$(uci get vpn.settings.subscription_url 2>/dev/null)
if [ -n "$SUB_URL" ]; then
    rm -f "$SUB_JSON"
    vpn-subscription.sh
fi

# -- 3. Run with subscription config (primary path) ---------------------------
if [ -f "$SUB_JSON" ]; then
    patch_dns_servers "$SUB_JSON"
    log "Starting sing-box with subscription config..."
    exec "$SBOX" run -c "$SUB_JSON"
    log "ERROR: exec failed on subscription config"
fi

# -- 4. Fallback: UCI manually-configured server ------------------------------
. /lib/functions.sh
config_load vpn
UCI_FOUND=0
config_foreach build_uci_config server

if [ "$UCI_FOUND" = "0" ]; then
    log "No active server configured -- VPN not started"
    exit 0
fi

log "Starting sing-box with UCI config..."
exec "$SBOX" run -c /tmp/sing-box-uci.json
log "ERROR: exec failed on UCI config"
exit 1