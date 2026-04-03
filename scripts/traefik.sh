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

# Detect log format: json or clf
detect_format() {
    local sample
    sample=$(docker exec "$CONTAINER" head -1 "$LOG_PATH" 2>/dev/null || true)
    if echo "$sample" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "json"
    else
        echo "clf"
    fi
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

  --version             Show Traefik version

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

    local fmt
    fmt=$(detect_format)

    # Show IP geo info when filtering by specific IP
    if [ -n "$filter_ip" ] && [ -n "$IPINFO_TOKEN" ]; then
        local geo
        geo=$(ip_lookup "$filter_ip")
        if [ -n "$geo" ]; then
            echo -e "IP: $filter_ip  (\033[36m$geo\033[0m)"
            echo "─────────────────────────────────────────"
        fi
    fi

    if [ "$fmt" = "json" ]; then
        cmd_log_json "$lines" "$filter_ip" "$filter_status" "$filter_path"
    else
        cmd_log_clf "$lines" "$filter_ip" "$filter_status" "$filter_path"
    fi
}

cmd_log_json() {
    local lines="$1" filter_ip="$2" filter_status="$3" filter_path="$4"

    local py_script='
import sys, json

filter_ip = "'"$filter_ip"'"
filter_status = "'"$filter_status"'"
filter_path = "'"$filter_path"'"

RED = "\033[31m"
YELLOW = "\033[33m"
GREEN = "\033[32m"
RESET = "\033[0m"

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except:
        continue

    ip = e.get("ClientHost", e.get("ClientAddr", "-")).split(":")[0]
    status = int(e.get("DownstreamStatus", e.get("OriginStatus", 0)))
    method = e.get("RequestMethod", "-")
    path = e.get("RequestPath", "-")
    router = e.get("RouterName", "-")
    duration = e.get("Duration", 0)
    ts = e.get("StartUTC", e.get("time", "-"))
    if isinstance(ts, str) and "T" in ts:
        ts = ts.split("T")[1][:8]

    # Filters
    if filter_ip and ip != filter_ip:
        continue
    if filter_status:
        if filter_status == "4xx" and not (400 <= status < 500): continue
        elif filter_status == "5xx" and not (500 <= status < 600): continue
        elif filter_status not in ("4xx", "5xx") and status != int(filter_status): continue
    if filter_path and filter_path not in path:
        continue

    # Duration
    if isinstance(duration, (int, float)):
        if duration > 1_000_000_000:
            dur_str = f"{duration/1_000_000_000:.0f}s"
        elif duration > 1_000_000:
            dur_str = f"{duration/1_000_000:.0f}ms"
        else:
            dur_str = f"{duration/1_000:.0f}us"
    else:
        dur_str = str(duration)

    out = f"{ts}  {ip:<15}  {status}  {method:<6} {path:<40} {dur_str:>8}  {router}"

    if status >= 500:
        print(f"{RED}{out}{RESET}")
    elif status >= 400:
        print(f"{YELLOW}{out}{RESET}")
    elif 200 <= status < 300:
        print(f"{GREEN}{out}{RESET}")
    else:
        print(out)
'

    if [ "$lines" = "0" ]; then
        echo "Following $CONTAINER access log [json] (Ctrl+C to stop)..."
        docker exec "$CONTAINER" tail -f "$LOG_PATH" 2>/dev/null | python3 -c "$py_script"
    else
        docker exec "$CONTAINER" tail -n "$lines" "$LOG_PATH" 2>/dev/null | python3 -c "$py_script"
    fi
}

cmd_log_clf() {
    local lines="$1" filter_ip="$2" filter_status="$3" filter_path="$4"

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

    local colorize='
    {
        status = $9
        if (status >= 500)      printf "\033[31m%s\033[0m\n", $0
        else if (status >= 400) printf "\033[33m%s\033[0m\n", $0
        else if (status >= 200 && status < 300) printf "\033[32m%s\033[0m\n", $0
        else print $0
    }'

    if [ "$lines" = "0" ]; then
        echo "Following $CONTAINER access log [clf] (Ctrl+C to stop)..."
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

    local fmt
    fmt=$(detect_format)

    # Aggregate data — "count key" lines
    local agg_data

    if [ "$fmt" = "clf" ]; then
        # CLF: aggregate inside container with awk (fast, no pipe of full log)
        local cutoff
        cutoff=$(date -u -d "-${seconds} seconds" '+%d/%b/%Y:%H:%M:%S')

        local awk_field='$1'
        local awk_status_filter=""
        case "$mode" in
            ip)        awk_field='$1' ;;
            url)       awk_field='$7' ;;
            status)    awk_field='$9' ;;
            ip-status)
                awk_field='$1'
                if [[ "$status_filter" == *xx ]]; then
                    local prefix="${status_filter:0:1}"
                    awk_status_filter="substr(\$9,1,1)!=\"$prefix\"{next}"
                else
                    awk_status_filter="\$9!=\"$status_filter\"{next}"
                fi
                ;;
        esac

        agg_data=$(docker exec "$CONTAINER" sh -c "
            awk '
                {
                    ts=substr(\$4,2)
                    if (ts < \"$cutoff\") next
                    $awk_status_filter
                    key=$awk_field
                    c[key]++
                }
                END { for(k in c) print c[k], k }
            ' \"$LOG_PATH\" | sort -rn | head -n $lines
        " 2>/dev/null)
    else
        # JSON: aggregate with python inside container
        agg_data=$(docker exec "$CONTAINER" python3 -c "
import json, sys
from datetime import datetime, timedelta, timezone

cutoff = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(seconds=$seconds)
mode = '$mode'
status_filter = '$status_filter'
counts = {}

for line in open('$LOG_PATH'):
    line = line.strip()
    if not line: continue
    try:
        e = json.loads(line)
    except: continue
    ip = e.get('ClientHost', e.get('ClientAddr', '-')).split(':')[0]
    status = str(e.get('DownstreamStatus', e.get('OriginStatus', 0)))
    path = e.get('RequestPath', '-')
    ts_str = e.get('StartUTC', e.get('time', ''))
    try:
        ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00')).replace(tzinfo=None)
    except: continue
    if ts < cutoff: continue

    if mode == 'ip': key = ip
    elif mode == 'url': key = path
    elif mode == 'status': key = status
    elif mode == 'ip-status':
        if status_filter.endswith('xx'):
            if not status.startswith(status_filter[0]): continue
        elif status != status_filter: continue
        key = ip
    else: key = ip
    counts[key] = counts.get(key, 0) + 1

for k, v in sorted(counts.items(), key=lambda x: -x[1])[:$lines]:
    print(v, k)
" 2>/dev/null)
    fi

    if [ -z "$agg_data" ]; then
        echo "No data for the specified time window."
        return
    fi

    # Pretty-print + geo lookup (only ~20 lines come through)
    echo "$agg_data" | python3 -c "
import sys, json, urllib.request

mode = '$mode'
since = '$since'
log_format = '$fmt'
status_filter = '$status_filter'
ipinfo_token = '$IPINFO_TOKEN'

items = []
for line in sys.stdin:
    parts = line.strip().split(None, 1)
    if len(parts) == 2:
        items.append((parts[1], int(parts[0])))

if not items:
    print('No data for the specified time window.')
    sys.exit(0)

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

show_geo = ipinfo_token and mode in ('ip', 'ip-status')

max_count = items[0][1] if items else 1
max_key_len = max(len(k) for k, _ in items)
bar_max = 30 if show_geo else 40

header = mode.upper().replace('IP-STATUS', f'IP (status {status_filter})')
print(f'Top {header} (last {since}) [{log_format}]:')
print(f'{\"\":-<{max_key_len + 70}}')

for key, count in items:
    bar_len = int(count / max_count * bar_max)
    bar = chr(9608) * bar_len
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
    --log)     shift; cmd_log "$@" ;;
    --version) docker exec "$CONTAINER" traefik version ;;
    --certs)   shift; cmd_certs "$@" ;;
    --top)     shift; cmd_top "$@" ;;
    -h|--help) usage ;;
    *)        usage ;;
esac
