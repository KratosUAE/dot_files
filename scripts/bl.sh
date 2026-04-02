#!/bin/bash
# CrowdSec blocklist (decisions) management

CONTAINER="crowdsec"

usage() {
    echo "Usage: $0 --list | --add <IP> [--reason <reason>] [--duration <duration>] | --remove <IP>"
    echo ""
    echo "Examples:"
    echo "  $0 --list"
    echo "  $0 --add 1.2.3.4"
    echo "  $0 --add 1.2.3.4 --reason 'manual ban' --duration 24h"
    echo "  $0 --remove 1.2.3.4"
    exit 1
}

do_list() {
    docker exec "$CONTAINER" cscli decisions list 2>&1
}

do_add() {
    local ip="$1"
    shift
    local reason="manual ban"
    local duration="4h"

    while [ $# -gt 0 ]; do
        case "$1" in
            --reason)   reason="$2"; shift 2 ;;
            --duration) duration="$2"; shift 2 ;;
            *)          shift ;;
        esac
    done

    docker exec "$CONTAINER" cscli decisions add --ip "$ip" --reason "$reason" --duration "$duration" --type ban
    if [ $? -eq 0 ]; then
        echo "IP $ip banned (duration: $duration, reason: $reason)."
    else
        echo "Error banning IP $ip." >&2
        exit 1
    fi
}

do_remove() {
    local ip="$1"
    docker exec "$CONTAINER" cscli decisions delete --ip "$ip"
    if [ $? -eq 0 ]; then
        echo "IP $ip removed from blocklist."
    else
        echo "Error removing IP $ip." >&2
        exit 1
    fi
}

case "${1}" in
    --list)   do_list ;;
    --add)    [ -z "$2" ] && usage; shift; do_add "$@" ;;
    --remove) [ -z "$2" ] && usage; do_remove "$2" ;;
    *)        usage ;;
esac
