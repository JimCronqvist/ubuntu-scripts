#!/usr/bin/env bash

TARGET=""
PORT=""
FLAGS=()
USER_FLAGS=()

ALL=false
FAST=false
DEBUG=false
TIMEOUT=5

OK="OK"
FAIL="FAILED"
MISS="NOT INSTALLED"
WARN="WARN"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

HTTP_PORTS=(80 443 3000 3443 8080 8888 9000)

show_help() {
cat <<EOF
Usage:
  ./check.sh [target] [port] [options]

Options:
  --help, -h
  --all
  --fast
  --timeout=SEC (default: 10)
  --debug

Checks:
  --local
  --internet
  --interface
  --icmp
  --ping
  --dns-server
  --dns
  --nslookup
  --http
  --tcp
  --telnet
  --tls
  --route
  --routes
  --gateway
  --public-ip
  --reverse-dns
  --mtu
  --tailscale

Notes:
  tcp/telnet are skipped unless a port is provided.
  http/tls are skipped for non-http ports unless explicitly requested.

HTTP-like ports:
  80, 443, 3000, 3443, 8080, 8888, 9000
EOF
}

print_status() {
    local name="$1"
    local status="$2"
    local msg="$3"

    case "$status" in
        "$OK") color=$GREEN ;;
        "$FAIL") color=$RED ;;
        "$MISS") color=$YELLOW ;;
        "$WARN") color=$YELLOW ;;
        *) color=$NC ;;
    esac

    printf "%-15s [%b%s%b] %s\n" "$name" "$color" "$status" "$NC" "$msg"
}

print_env() {
    printf "%-15s %s\n" "$1" "$2"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

is_http_port() {
    for p in "${HTTP_PORTS[@]}"; do
        [[ "$PORT" == "$p" ]] && return 0
    done

    return 1
}

flag_requested() {
    local wanted="$1"

    for flag in "${USER_FLAGS[@]}"; do
        [[ "$flag" == "$wanted" ]] && return 0
    done

    return 1
}

classify_mtu() {
    local mtu="$1"

    if (( mtu >= 1500 )); then
        print_status "mtu" "$OK" "$mtu"
    elif (( mtu >= 1400 )); then
        print_status "mtu" "$WARN" "<1500 ($mtu)"
    else
        print_status "mtu" "$WARN" "<1400 ($mtu)"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --all)
            ALL=true
            ;;
        --fast)
            FAST=true
            ;;
        --debug)
            DEBUG=true
            ;;
        --timeout=*)
            TIMEOUT="${1#*=}"
            ;;
        --*)
            FLAGS+=("$1")
            USER_FLAGS+=("$1")
            ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$1"
            elif [[ -z "$PORT" ]]; then
                PORT="$1"
            fi
            ;;
    esac

    shift
done

DEFAULT_LOCAL=(--local --internet)
DEFAULT_TARGET=(--icmp --dns --http --tcp --tls)
DEFAULT_FAST=(--icmp --dns --http)

ALL_CHECKS=(
    --local
    --internet
    --interface
    --route
    --routes
    --gateway
    --dns-server
    --public-ip
    --icmp
    --ping
    --dns
    --nslookup
    --http
    --tcp
    --telnet
    --tls
    --reverse-dns
    --mtu
    --tailscale
)

if [[ ${#FLAGS[@]} -eq 0 ]]; then
    if [[ "$ALL" == true ]]; then
        FLAGS=("${ALL_CHECKS[@]}")
    elif [[ "$FAST" == true ]]; then
        if [[ -z "$TARGET" ]]; then
            FLAGS=("${DEFAULT_LOCAL[@]}")
        else
            FLAGS=("${DEFAULT_FAST[@]}")
        fi
    else
        if [[ -z "$TARGET" ]]; then
            FLAGS=("${DEFAULT_LOCAL[@]}")
        else
            FLAGS=("${DEFAULT_TARGET[@]}")
        fi
    fi
fi

grep -qa docker /proc/1/cgroup 2>/dev/null && \
    print_env "Container" "Yes (docker)" || \
    print_env "Container" "No"

[[ -n "$KUBERNETES_SERVICE_HOST" ]] && \
    print_env "Kubernetes" "Yes" || \
    print_env "Kubernetes" "No"

if has_cmd tailscale && tailscale status >/dev/null 2>&1; then
    ts_ip=$(tailscale ip -4 2>/dev/null | head -1)
    print_env "Tailscale" "Yes${ts_ip:+ ($ts_ip)}"
    print_env "VPN" "Yes"
else
    print_env "Tailscale" "No"

    if ip link 2>/dev/null | grep -qE 'wg|tun|tap'; then
        print_env "VPN" "Yes"
    else
        print_env "VPN" "No"
    fi
fi

echo ""
echo ""

check_local() {
    print_status "hostname" "$OK" "$(hostname)"

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    print_status "local-ip" "$OK" "${ip:-unknown}"
}

check_internet() {
    has_cmd ping || { print_status "internet" "$MISS" ""; return; }

    timeout "$TIMEOUT" ping -c 1 8.8.8.8 >/dev/null 2>&1 && \
        print_status "internet" "$OK" "reachable" || \
        print_status "internet" "$FAIL" ""
}

check_interface() {
    if has_cmd ip; then
        local default_if
        local default_ip
        local output
        local msg

        default_if=$(ip route 2>/dev/null | awk '/default/ {print $5}' | head -1)
        default_ip=$(ip -brief addr show "$default_if" 2>/dev/null | awk '{print $3}')
        output=$(ip -brief addr 2>/dev/null | grep -v lo)

        if [[ -n "$default_if" ]]; then
            msg="$default_if"
            [[ -n "$default_ip" ]] && msg="$default_if $default_ip"

            print_status "interface" "$OK" "$msg"
        elif [[ -n "$output" ]]; then
            print_status "interface" "$OK" "interfaces found"
        else
            print_status "interface" "$FAIL" ""
        fi

        [[ "$DEBUG" == true ]] && echo "$output" | sed 's/^/  -> /'

    elif has_cmd ifconfig; then
        print_status "interface" "$OK" "ifconfig"

        [[ "$DEBUG" == true ]] && ifconfig | sed 's/^/  -> /'
    else
        print_status "interface" "$MISS" ""
    fi
}

check_icmp() {
    has_cmd ping || { print_status "icmp" "$MISS" ""; return; }
    [[ -z "$TARGET" ]] && { print_status "icmp" "$FAIL" "no target"; return; }

    timeout "$TIMEOUT" ping -c 1 "$TARGET" >/dev/null 2>&1 && \
        print_status "icmp" "$OK" "reachable" || \
        print_status "icmp" "$FAIL" ""
}

check_ping() {
    has_cmd ping || { print_status "ping" "$MISS" ""; return; }
    [[ -z "$TARGET" ]] && { print_status "ping" "$FAIL" "no target"; return; }

    local output
    local avg

    output=$(timeout "$TIMEOUT" ping -c 3 "$TARGET" 2>&1)

    if [[ $? -eq 0 ]]; then
        avg=$(echo "$output" | awk -F'/' '/^rtt|round-trip/ {print $5}')
        print_status "ping" "$OK" "avg ${avg} ms"
    else
        print_status "ping" "$FAIL" ""
    fi

    [[ "$DEBUG" == true ]] && echo "$output" | sed 's/^/  -> /'
}

check_dns_server() {
    if [[ -f /etc/resolv.conf ]]; then
        local servers
        servers=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd "," -)

        [[ -n "$servers" ]] && \
            print_status "dns-server" "$OK" "$servers" || \
            print_status "dns-server" "$FAIL" ""
    else
        print_status "dns-server" "$MISS" ""
    fi
}

check_dns() {
    [[ -z "$TARGET" ]] && { print_status "dns" "$FAIL" "no target"; return; }

    local cname ip result

    if has_cmd dig; then
        cname=$(dig "$TARGET" +short 2>/dev/null | head -1)

        # If cname is already an IP, just use it
        if [[ "$cname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            result="$cname"
        else
            ip=$(dig "$cname" +short 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
            [[ -n "$ip" ]] && result="$cname -> $ip" || result="$cname"
        fi

    elif has_cmd nslookup; then
        cname=$(nslookup "$TARGET" 2>/dev/null | awk '/name = / {print $4}' | head -1)
        ip=$(nslookup "$TARGET" 2>/dev/null | awk '/Address: / {print $2}' | tail -1)

        if [[ -n "$cname" && -n "$ip" ]]; then
            result="$cname -> $ip"
        else
            result="$ip"
        fi
    else
        print_status "dns" "$MISS" ""
        return
    fi

    [[ -n "$result" ]] && \
        print_status "dns" "$OK" "$result" || \
        print_status "dns" "$FAIL" ""

    if [[ "$DEBUG" == true ]]; then
        if has_cmd dig; then
            dig "$TARGET" +short | sed 's/^/  -> /'
        else
            nslookup "$TARGET" 2>/dev/null | sed 's/^/  -> /'
        fi
    fi
}

check_nslookup() {
    has_cmd nslookup || { print_status "nslookup" "$MISS" ""; return; }
    [[ -z "$TARGET" ]] && { print_status "nslookup" "$FAIL" "no target"; return; }

    local output ipv4 ipv6 result

    output=$(nslookup "$TARGET" 2>/dev/null)

    # Extract IPv4
    ipv4=$(echo "$output" | awk '/^Address: / {print $2}' | grep -E '^[0-9]+\.' | paste -sd "," -)

    # Extract IPv6
    ipv6=$(echo "$output" | awk '/^Address: / {print $2}' | grep ':' | paste -sd "," -)

    if [[ -n "$ipv4" ]]; then
        result="$ipv4"
    else
        result="$ipv6"
    fi

    [[ -n "$result" ]] && \
        print_status "nslookup" "$OK" "$result" || \
        print_status "nslookup" "$FAIL" ""

    [[ "$DEBUG" == true ]] && echo "$output" | sed 's/^/  -> /'
}

check_http() {
    has_cmd curl || { print_status "http" "$MISS" ""; return; }
    [[ -z "$TARGET" ]] && { print_status "http" "$FAIL" "no target"; return; }

    local url
    local code

    if [[ -n "$PORT" ]]; then
        if [[ "$PORT" == "443" || "$PORT" == "3443" ]]; then
            url="https://$TARGET:$PORT"
        else
            url="http://$TARGET:$PORT"
        fi
    else
        url="https://$TARGET"
    fi

    code=$(curl -s --max-time "$TIMEOUT" -o /dev/null -w "%{http_code}" "$url")

    [[ "$code" != "000" ]] && \
        print_status "http" "$OK" "$code" || \
        print_status "http" "$FAIL" ""

    if [[ "$DEBUG" == true ]]; then
        curl -I --max-time "$TIMEOUT" "$url" 2>/dev/null | sed 's/^/  -> /'
    fi
}

check_tcp() {
    [[ -z "$PORT" ]] && return
    [[ -z "$TARGET" ]] && { print_status "tcp" "$FAIL" "no target"; return; }

    if has_cmd nc; then
        nc -z -w "$TIMEOUT" "$TARGET" "$PORT" >/dev/null 2>&1 && \
            print_status "tcp:$PORT" "$OK" "connected" || \
            print_status "tcp:$PORT" "$FAIL" ""
    else
        timeout "$TIMEOUT" bash -c "echo > /dev/tcp/$TARGET/$PORT" >/dev/null 2>&1 && \
            print_status "tcp:$PORT" "$OK" "connected" || \
            print_status "tcp:$PORT" "$FAIL" ""
    fi
}

check_telnet() {
    [[ -z "$PORT" ]] && return
    [[ -z "$TARGET" ]] && { print_status "telnet" "$FAIL" "no target"; return; }

    if has_cmd telnet; then
        timeout "$TIMEOUT" bash -c "echo > /dev/tcp/$TARGET/$PORT" >/dev/null 2>&1 && \
            print_status "telnet" "$OK" "connected" || \
            print_status "telnet" "$FAIL" ""
    else
        print_status "telnet" "$MISS" ""
    fi
}

check_tls() {
    has_cmd openssl || { print_status "tls" "$MISS" ""; return; }
    [[ -z "$TARGET" ]] && { print_status "tls" "$FAIL" "no target"; return; }

    local tls_port
    local output
    local status
    local version

    tls_port="${PORT:-443}"

    output=$(timeout "$TIMEOUT" bash -c "echo | openssl s_client -connect '$TARGET:$tls_port' -servername '$TARGET'" 2>/dev/null)
    status=$?

    if [[ $status -ne 0 ]]; then
        print_status "tls" "$FAIL" ""
        return
    fi

    version=$(echo "$output" | grep -i "Protocol" | head -1 | sed 's/.*Protocol *: *//I')

    if [[ -z "$version" ]]; then
        version=$(echo "$output" | grep -oE 'TLSv[0-9]+\.[0-9]+' | head -1)
    fi

    [[ -z "$version" ]] && version="connected"

    print_status "tls" "$OK" "$version"

    if [[ "$DEBUG" == true ]]; then
        echo "$output" | grep -E "Protocol|Cipher|Verify return code|subject=|issuer=|New," | sed 's/^/  -> /'
    fi
}

check_route() {
    if has_cmd ip; then
        local route
        route=$(ip route 2>/dev/null | grep default | head -1)

        [[ -n "$route" ]] && \
            print_status "route" "$OK" "$route" || \
            print_status "route" "$FAIL" ""
    else
        print_status "route" "$MISS" ""
    fi
}

check_routes() {
    if has_cmd ip; then
        local output
        local count

        output=$(ip route 2>/dev/null)
        count=$(echo "$output" | grep -c .)

        [[ -n "$output" ]] && \
            print_status "routes" "$OK" "${count} routes" || \
            print_status "routes" "$FAIL" ""

        [[ "$DEBUG" == true ]] && echo "$output" | sed 's/^/  -> /'
    else
        print_status "routes" "$MISS" ""
    fi
}

check_gateway() {
    has_cmd ip || { print_status "gateway" "$MISS" ""; return; }
    has_cmd ping || { print_status "gateway" "$MISS" "ping"; return; }

    local gw
    gw=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -1)

    [[ -z "$gw" ]] && { print_status "gateway" "$FAIL" "no gateway"; return; }

    timeout "$TIMEOUT" ping -c 1 "$gw" >/dev/null 2>&1 && \
        print_status "gateway" "$OK" "$gw" || \
        print_status "gateway" "$FAIL" "$gw"
}

check_public_ip() {
    has_cmd curl || { print_status "public-ip" "$MISS" ""; return; }

    local ip
    ip=$(curl -s --max-time "$TIMEOUT" ifconfig.me)

    [[ -n "$ip" ]] && \
        print_status "public-ip" "$OK" "$ip" || \
        print_status "public-ip" "$FAIL" ""
}

check_reverse_dns() {
    has_cmd dig || { print_status "reverse-dns" "$MISS" ""; return; }
    [[ -z "$TARGET" ]] && { print_status "reverse-dns" "$FAIL" "no target"; return; }

    local ip
    local ptr

    ip=$(dig +short "$TARGET" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

    if [[ -z "$ip" ]]; then
        print_status "reverse-dns" "$FAIL" "no valid ip"
        return
    fi

    ptr=$(dig +short -x "$ip" 2>/dev/null)

    [[ -n "$ptr" ]] && \
        print_status "reverse-dns" "$OK" "$ptr" || \
        print_status "reverse-dns" "$FAIL" ""

    if [[ "$DEBUG" == true ]]; then
        echo "  -> ip: $ip"
        [[ -n "$ptr" ]] && echo "$ptr" | sed 's/^/  -> /'
    fi
}

check_mtu() {
    has_cmd ping || { print_status "mtu" "$MISS" ""; return; }

    local output
    local mtu

    if timeout "$TIMEOUT" ping -M do -s 1472 -c 1 8.8.8.8 >/dev/null 2>&1; then
        print_status "mtu" "$OK" "1500"
        return
    fi

    output=$(timeout "$TIMEOUT" ping -M do -s 1472 -c 1 8.8.8.8 2>&1)
    mtu=$(echo "$output" | grep -oE 'mtu=[0-9]+' | head -1 | cut -d= -f2)

    if [[ -z "$mtu" ]]; then
        output=$(timeout "$TIMEOUT" ping -M do -s 1400 -c 1 8.8.8.8 2>&1)
        mtu=$(echo "$output" | grep -oE 'mtu=[0-9]+' | head -1 | cut -d= -f2)
    fi

    if [[ -z "$mtu" ]]; then
        output=$(timeout "$TIMEOUT" ping -M do -s 1200 -c 1 8.8.8.8 2>&1)
        mtu=$(echo "$output" | grep -oE 'mtu=[0-9]+' | head -1 | cut -d= -f2)
    fi

    if [[ -n "$mtu" ]]; then
        classify_mtu "$mtu"
        [[ "$DEBUG" == true ]] && echo "$output" | sed 's/^/  -> /'
        return
    fi

    if timeout "$TIMEOUT" ping -M do -s 1400 -c 1 8.8.8.8 >/dev/null 2>&1; then
        print_status "mtu" "$WARN" "<1500 (>1428)"
        return
    fi

    if timeout "$TIMEOUT" ping -M do -s 1200 -c 1 8.8.8.8 >/dev/null 2>&1; then
        print_status "mtu" "$WARN" "<1400 (>1228)"
        return
    fi

    print_status "mtu" "$FAIL" "unknown"
}

check_tailscale() {
    has_cmd tailscale || { print_status "tailscale-ping" "$MISS" ""; return; }
    [[ -z "$TARGET" ]] && { print_status "tailscale-ping" "$FAIL" "no target"; return; }

    local output
    local status

    output=$(timeout "$TIMEOUT" tailscale ping -c 1 "$TARGET" 2>&1)
    status=$?

    if [[ $status -ne 0 ]]; then
        print_status "tailscale-ping" "$FAIL" ""
        [[ "$DEBUG" == true ]] && echo "$output" | sed 's/^/  -> /'
        return
    fi

    if echo "$output" | grep -qi "via DERP"; then
        print_status "tailscale-ping" "$WARN" "derp"
    else
        print_status "tailscale-ping" "$OK" "direct"
    fi

    [[ "$DEBUG" == true ]] && echo "$output" | sed 's/^/  -> /'
}

RUN_HTTP=true
RUN_TLS=true

if [[ -n "$PORT" ]]; then
    if ! is_http_port && ! flag_requested "--http"; then
        RUN_HTTP=false
    fi

    if ! is_http_port && ! flag_requested "--tls"; then
        RUN_TLS=false
    fi
fi

for flag in "${FLAGS[@]}"; do
    case "$flag" in
        --local) check_local ;;
        --internet) check_internet ;;
        --interface) check_interface ;;
        --icmp) check_icmp ;;
        --ping) check_ping ;;
        --dns-server) check_dns_server ;;
        --dns) check_dns ;;
        --nslookup) check_nslookup ;;
        --http) [[ "$RUN_HTTP" == true ]] && check_http ;;
        --tcp) check_tcp ;;
        --telnet) check_telnet ;;
        --tls) [[ "$RUN_TLS" == true ]] && check_tls ;;
        --route) check_route ;;
        --routes) check_routes ;;
        --gateway) check_gateway ;;
        --public-ip) check_public_ip ;;
        --reverse-dns) check_reverse_dns ;;
        --mtu) check_mtu ;;
        --tailscale) check_tailscale ;;
        *) print_status "$flag" "$FAIL" "unknown flag" ;;
    esac
done