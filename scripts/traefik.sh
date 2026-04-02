#!/bin/bash
# Traefik monitoring & analytics

set -euo pipefail

# Auto-detect traefik container name
CONTAINER=$(docker ps --format '{{.Names}}' | grep -i traefik | head -1 || true)
if [ -z "$CONTAINER" ]; then
    echo "Error: no running Traefik container found." >&2
    exit 1
fi

LOG_PATH="/var/log/traefik/access.log"
ACME_PATH="/letsencrypt/acme.json"

# Load ipinfo token from .env
ENV_FILE="$HOME/.aux/.env"
IPINFO_TOKEN=""
if [ -f "$ENV_FILE" ]; then
    IPINFO_TOKEN=$(grep -E '^IPINFO_TOKEN=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' || true)
fi

# Resolve IP to "city, country" via ipinfo.io (cached per session)
declare -A _ip_cache
ip_lookup() {
    local ip="$1"
    if [ -z "$IPINFO_TOKEN" ]; then echo ""; return; fi
    if [[ -v _ip_cache["$ip"] ]]; then echo "${_ip_cache[$ip]}"; return; fi
    local json
    json=$(curl -s --max-time 2 "https://ipinfo.io/$ip/json?token=$IPINFO_TOKEN" 2>/dev/null || true)
    local info=""
    if [ -n "$json" ]; then
        info=$(echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    parts = [p for p in [d.get('city',''), d.get('country','')] if p]
    org = d.get('org','')
    if org: parts.append(org)
    print(', '.join(parts))
except: pass
" 2>/dev/null || true)
    fi
    _ip_cache["$ip"]="$info"
    echo "$info"
}

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  --log [options]       Live access log with filtering
    -n <lines>            Number of lines (default: 50, 0 = follow)
    --ip <IP>             Filter by IP
    --status <code>       Filter by status code (e.g. 502, 4xx, 5xx)
    --path <path>         Filter by URL path

  --certs               Show SSL certificates and expiry dates

  --top [options]       Access log analytics
    --ip                  Top IPs (default)
    --url                 Top URLs
    --status              Status code breakdown
    --ip-status <code>    Top IPs by status code (e.g. 403, 5xx)
    -n <lines>            Number of results (default: 20)
    --since <time>        Time window: 1h, 24h, 7d (default: 24h)

Examples:
  $0 --log -n 100 --status 5xx
  $0 --log -n 0 --ip 91.72.145.186
  $0 --certs
  $0 --top --ip -n 10 --since 1h
  $0 --top --url --since 24h
  $0 --top --ip-status 403
EOF
    exit 1
}

# ─── LOG ──────────────────────────────────────────────────────────────────────

cmd_log() {
    local lines=50
    local filter_ip=""
    local filter_status=""
    local filter_path=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -n)           lines="$2"; shift 2 ;;
            --ip)         filter_ip="$2"; shift 2 ;;
            --status)     filter_status="$2"; shift 2 ;;
            --path)       filter_path="$2"; shift 2 ;;
            *)            shift ;;
        esac
    done

    # Build awk filter
    local awk_cond="1"
    [ -n "$filter_ip" ] && awk_cond="$awk_cond && \$1 == \"$filter_ip\""
    if [ -n "$filter_path" ]; then
        awk_cond="$awk_cond && index(\$7, \"$filter_path\") > 0"
    fi
    if [ -n "$filter_status" ]; then
        case "$filter_status" in
            4xx) awk_cond="$awk_cond && \$9 >= 400 && \$9 < 500" ;;
            5xx) awk_cond="$awk_cond && \$9 >= 500 && \$9 < 600" ;;
            *)   awk_cond="$awk_cond && \$9 == $filter_status" ;;
        esac
    fi

    # Colorize output: red for 5xx, yellow for 4xx, green for 2xx
    local colorize='
    {
        status = $9
        if (status >= 500)      printf "\033[31m%s\033[0m\n", $0
        else if (status >= 400) printf "\033[33m%s\033[0m\n", $0
        else if (status >= 200 && status < 300) printf "\033[32m%s\033[0m\n", $0
        else print $0
    }'

    # Show IP geo info when filtering by specific IP
    if [ -n "$filter_ip" ] && [ -n "$IPINFO_TOKEN" ]; then
        local geo
        geo=$(ip_lookup "$filter_ip")
        if [ -n "$geo" ]; then
            echo -e "IP: $filter_ip  (\033[36m$geo\033[0m)"
            echo "─────────────────────────────────────────"
        fi
    fi

    if [ "$lines" = "0" ]; then
        echo "Following $CONTAINER access log (Ctrl+C to stop)..."
        docker exec "$CONTAINER" tail -f "$LOG_PATH" 2>/dev/null | awk "$awk_cond" | awk "$colorize"
    else
        docker exec "$CONTAINER" tail -n "$lines" "$LOG_PATH" 2>/dev/null | awk "$awk_cond" | awk "$colorize"
    fi
}

# ─── CERTS ────────────────────────────────────────────────────────────────────

cmd_certs() {
    docker exec "$CONTAINER" cat "$ACME_PATH" 2>/dev/null | python3 -c "
import sys, json, base64, subprocess, tempfile, os
from datetime import datetime, timezone

data = json.load(sys.stdin)
now = datetime.now(timezone.utc).replace(tzinfo=None)

for resolver, rdata in data.items():
    certs = rdata.get('Certificates', [])
    if not certs:
        continue
    for c in certs:
        domain = c.get('domain', {}).get('main', '?')
        sans = c.get('domain', {}).get('sans', [])
        cert_pem = base64.b64decode(c['certificate']).decode()

        # Write cert to temp file and parse with openssl
        with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as f:
            f.write(cert_pem)
            tmp = f.name
        try:
            out = subprocess.check_output(
                ['openssl', 'x509', '-in', tmp, '-noout', '-enddate', '-startdate'],
                stderr=subprocess.DEVNULL
            ).decode()
        finally:
            os.unlink(tmp)

        not_after = not_before = ''
        for line in out.strip().split('\n'):
            if 'notAfter' in line:
                not_after = line.split('=', 1)[1].strip()
            elif 'notBefore' in line:
                not_before = line.split('=', 1)[1].strip()

        # Parse expiry
        try:
            expiry = datetime.strptime(not_after, '%b %d %H:%M:%S %Y %Z')
            days_left = (expiry - now).days
            if days_left < 7:
                status = f'\033[31m{days_left}d left !!!\033[0m'
            elif days_left < 30:
                status = f'\033[33m{days_left}d left\033[0m'
            else:
                status = f'\033[32m{days_left}d left\033[0m'
        except:
            status = 'unknown'

        print(f'Resolver: {resolver}')
        print(f'  Domain:  {domain}')
        if sans:
            print(f'  SANs:    {', '.join(sans)}')
        print(f'  From:    {not_before}')
        print(f'  Until:   {not_after}  ({status})')
        print()
"
}

# ─── TOP ──────────────────────────────────────────────────────────────────────

cmd_top() {
    local mode="ip"
    local lines=20
    local since="24h"
    local status_filter=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --ip)         mode="ip"; shift ;;
            --url)        mode="url"; shift ;;
            --status)     mode="status"; shift ;;
            --ip-status)  mode="ip-status"; status_filter="$2"; shift 2 ;;
            -n)           lines="$2"; shift 2 ;;
            --since)      since="$2"; shift 2 ;;
            *)            shift ;;
        esac
    done

    # Convert since to seconds
    local seconds
    case "$since" in
        *h) seconds=$(( ${since%h} * 3600 )) ;;
        *d) seconds=$(( ${since%d} * 86400 )) ;;
        *m) seconds=$(( ${since%m} * 60 )) ;;
        *)  seconds=86400 ;;
    esac

    local log_data
    log_data=$(docker exec "$CONTAINER" cat "$LOG_PATH" 2>/dev/null)

    echo "$log_data" | python3 -c "
import sys, json, urllib.request
from datetime import datetime, timedelta, timezone

lines_limit = $lines
seconds = $seconds
mode = '$mode'
status_filter = '$status_filter'
ipinfo_token = '$IPINFO_TOKEN'

cutoff = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(seconds=seconds)
counts = {}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split()
    if len(parts) < 10:
        continue

    ip = parts[0]
    # Parse timestamp [05/Mar/2026:12:58:59 +0000]
    try:
        ts_str = parts[3].lstrip('[')
        ts = datetime.strptime(ts_str, '%d/%b/%Y:%H:%M:%S')
    except:
        continue

    if ts < cutoff:
        continue

    status = parts[8]
    url = parts[6] if len(parts) > 6 else '-'

    if mode == 'ip':
        key = ip
    elif mode == 'url':
        key = url
    elif mode == 'status':
        key = status
    elif mode == 'ip-status':
        if status_filter.endswith('xx'):
            prefix = status_filter[0]
            if not status.startswith(prefix):
                continue
        elif status != status_filter:
            continue
        key = ip
    else:
        key = ip

    counts[key] = counts.get(key, 0) + 1

sorted_items = sorted(counts.items(), key=lambda x: -x[1])[:lines_limit]

if not sorted_items:
    print('No data for the specified time window.')
    sys.exit(0)

# Resolve IPs via ipinfo.io (batch)
geo_cache = {}
def ip_geo(ip):
    if ip in geo_cache:
        return geo_cache[ip]
    if not ipinfo_token:
        geo_cache[ip] = ''
        return ''
    try:
        req = urllib.request.urlopen(
            f'https://ipinfo.io/{ip}/json?token={ipinfo_token}', timeout=2)
        d = json.loads(req.read())
        parts = [p for p in [d.get('city',''), d.get('country','')] if p]
        org = d.get('org','')
        if org: parts.append(org)
        info = ', '.join(parts)
    except:
        info = ''
    geo_cache[ip] = info
    return info

# Check if keys are IPs (for geo enrichment)
show_geo = ipinfo_token and mode in ('ip', 'ip-status')

max_count = sorted_items[0][1] if sorted_items else 1
max_key_len = max(len(k) for k, _ in sorted_items)
bar_max = 30 if show_geo else 40

header = mode.upper().replace('IP-STATUS', f'IP (status {status_filter})')
print(f'Top {header} (last $since):')
print(f'{\"\":-<{max_key_len + 70}}')

for key, count in sorted_items:
    bar_len = int(count / max_count * bar_max)
    bar = '█' * bar_len
    if show_geo:
        geo = ip_geo(key)
        geo_str = f'  \033[36m{geo}\033[0m' if geo else ''
        print(f'  {key:<{max_key_len}}  {count:>6}  {bar}{geo_str}')
    else:
        print(f'  {key:<{max_key_len}}  {count:>6}  {bar}')
"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────

[ $# -eq 0 ] && usage

case "$1" in
    --log)    shift; cmd_log "$@" ;;
    --certs)  shift; cmd_certs "$@" ;;
    --top)    shift; cmd_top "$@" ;;
    -h|--help) usage ;;
    *)        usage ;;
esac
