#!/bin/bash
# CrowdSec whitelist management (parsers/s02-enrich/whitelists.yaml inside container)

CONTAINER=$(docker ps --format '{{.Names}}' | grep -i crowdsec | head -1)
if [ -z "$CONTAINER" ]; then
    echo "Error: no running CrowdSec container found." >&2
    exit 1
fi

WHL_FILE="/etc/crowdsec/parsers/s02-enrich/whitelists.yaml"

usage() {
    echo "Usage: $0 --list | --add <IP> | --remove <IP>"
    exit 1
}

reload_crowdsec() {
    docker exec "$CONTAINER" kill -SIGHUP 1 2>/dev/null
    echo "CrowdSec config reloaded."
}

do_list() {
    echo "Current whitelist IPs:"
    docker exec "$CONTAINER" cat "$WHL_FILE" 2>/dev/null | grep -E '^\s+-\s+"' | grep -v '#' | sed 's/.*"\(.*\)".*/  \1/'
}

do_add() {
    local ip="$1"
    # Check if already in whitelist
    if docker exec "$CONTAINER" grep -q "\"$ip\"" "$WHL_FILE" 2>/dev/null; then
        echo "IP $ip is already in the whitelist."
        exit 0
    fi
    # Add after the "ip:" line
    docker exec "$CONTAINER" sed -i "/^  ip:/a\\    - \"$ip\"" "$WHL_FILE"
    if [ $? -eq 0 ]; then
        echo "IP $ip added to whitelist."
        reload_crowdsec
    else
        echo "Error adding IP $ip." >&2
        exit 1
    fi
}

do_remove() {
    local ip="$1"
    if ! docker exec "$CONTAINER" grep -q "\"$ip\"" "$WHL_FILE" 2>/dev/null; then
        echo "IP $ip is not in the whitelist."
        exit 0
    fi
    docker exec "$CONTAINER" sed -i "/\"$ip\"/d" "$WHL_FILE"
    if [ $? -eq 0 ]; then
        echo "IP $ip removed from whitelist."
        reload_crowdsec
    else
        echo "Error removing IP $ip." >&2
        exit 1
    fi
}

case "${1}" in
    --list)   do_list ;;
    --add)    [ -z "$2" ] && usage; do_add "$2" ;;
    --remove) [ -z "$2" ] && usage; do_remove "$2" ;;
    *)        usage ;;
esac
