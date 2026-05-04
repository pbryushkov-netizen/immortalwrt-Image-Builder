#!/bin/sh
# Parses vless://UUID@host:port?params#alias
# Usage: vless-parse.sh "vless://..."
# Outputs: shell variables server port uuid transport sni pbk sid alias
KEY="$1"
[ -z "$KEY" ] && exit 1

BODY="${KEY#vless://}"
ALIAS="${BODY##*#}"
BODY="${BODY%%#*}"

UUID="${BODY%%@*}"
HOSTPORT="${BODY#*@}"
HOSTPORT="${HOSTPORT%%\?*}"
PARAMS="${BODY#*\?}"
[ "$PARAMS" = "$BODY" ] && PARAMS=""

SERVER="${HOSTPORT%%:*}"
PORT="${HOSTPORT##*:}"

urldecode() {
    printf '%b' "$(echo "$1" | sed 's/+/ /g; s/%\(..\)/\\x\1/g')"
}

get_param() {
    echo "$PARAMS" | tr '&' '\n' | grep "^${1}=" | head -1 | cut -d= -f2-
}

TRANSPORT=$(get_param "type")
[ -z "$TRANSPORT" ] && TRANSPORT="tcp"
SNI=$(urldecode "$(get_param "sni")")
[ -z "$SNI" ] && SNI=$(get_param "peer")
PBK=$(get_param "pbk")
SID=$(get_param "sid")

echo "server=$SERVER"
echo "port=$PORT"
echo "uuid=$UUID"
echo "transport=$TRANSPORT"
echo "sni=$SNI"
echo "pbk=$PBK"
echo "sid=$SID"
echo "alias=${ALIAS:-$SERVER}"
