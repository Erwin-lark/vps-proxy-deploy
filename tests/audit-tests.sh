#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2016
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../vps-deploy.sh
source "$REPO_ROOT/vps-deploy.sh"
trap - EXIT INT TERM HUP

pass_count=0
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS: %s\n' "$*"
}
assert_contains() {
    local file=$1 pattern=$2 label=$3
    grep -Fq -- "$pattern" "$file" || fail "$label"
    pass "$label"
}
assert_not_contains() {
    local file=$1 pattern=$2 label=$3
    if grep -Fq -- "$pattern" "$file"; then
        fail "$label"
    fi
    pass "$label"
}

valid_domain node.example.com || fail "valid domain rejected"
! valid_domain 'node.example.com;touch /tmp/pwn' || fail "injection domain accepted"
valid_email admin@example.com || fail "valid email rejected"
! valid_email 'bad@example' || fail "invalid email accepted"
valid_uuid '00000000-0000-4000-8000-000000000001' || fail "canonical UUID rejected"
! valid_uuid '000000000000-4000-8000-000000000001' || fail "malformed UUID accepted"
valid_xhttp_path '/00112233-xhttp' || fail "safe XHTTP path rejected"
! valid_xhttp_path '/../xhttp' || fail "unsafe XHTTP path accepted"
valid_ws_path '/44556677-ws' || fail "safe WebSocket path rejected"
! valid_ws_path '/bad?path' || fail "unsafe WebSocket path accepted"
valid_short_id '0011223344556677' || fail "valid Reality short ID rejected"
! valid_short_id '001' || fail "odd-length Reality short ID accepted"
pass "input validators"
[[ $(dns_record_status 6 '2001:db8::1' '2001:0db8:0:0:0:0:0:1') == "match" ]] || \
    fail "equivalent IPv6 DNS address rejected"
[[ $(dns_record_status 4 '192.0.2.10' $'192.0.2.10\n192.0.2.11') == "mismatch" ]] || \
    fail "stale DNS address accepted"
pass "DNS address normalization and stale-record rejection"

test_root=$(mktemp -d /tmp/vps-proxy-tests.XXXXXX)
test_pids=()
cleanup_tests() {
    local pid
    for pid in "${test_pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf -- "$test_root"
}
trap cleanup_tests EXIT
SUB_ROOT="$test_root/subscription"
SUB_TOKEN="0123456789abcdef0123456789abcdef0123"
ENABLE_CDN=true
NODE_PREFIX="🇯🇵 JP TEST"
DOMAIN="node.example.com"
CDN_DOMAIN="cdn.node.example.com"
REALITY_PORT=443
HY2_PORT=443
VR_CLASH_UUID="00000000-0000-4000-8000-000000000001"
VR_LOON_UUID="00000000-0000-4000-8000-000000000002"
XHTTP_UUID="00000000-0000-4000-8000-000000000003"
WS_UUID="00000000-0000-4000-8000-000000000004"
HY2_PASS="0123456789abcdef0123456789abcdef"
REALITY_SNI="www.nic.ad.jp"
REALITY_PUBKEY="0WLDJHaOLiK1sj1q-yDCao1ARBWyN8zPlvdbI6Qd13A"
REALITY_SHORTID="0011223344556677"
XHTTP_PATH="/00112233-xhttp"
WS_PATH="/44556677-ws"
WS_PORT=10002

# 文件尾部会用同名无副作用替身模拟 main；此处调用的是脚本中已 source 的实现。
# shellcheck disable=SC2218
write_subscriptions
clash_file="$SUB_ROOT/$SUB_TOKEN/clash.yaml"
loon_file="$SUB_ROOT/$SUB_TOKEN/loon.conf"

assert_contains "$clash_file" 'server: cdn.node.example.com' "XHTTP uses the CDN hostname"
assert_contains "$clash_file" 'port: 443' "CDN client uses TLS port 443"
assert_contains "$clash_file" 'mode: packet-up' "XHTTP uses the most compatible CDN mode"
assert_contains "$clash_file" 'name: "🇯🇵 JP TEST VW"' "Clash includes the WebSocket CDN node"
assert_contains "$clash_file" 'network: ws' "Clash WebSocket node uses a supported transport"
assert_not_contains "$clash_file" 'smux:' "nested client mux removed"
assert_contains "$clash_file" 'proxy-groups:' "Clash profile has a selectable proxy group"
assert_contains "$clash_file" 'MATCH,PROXY' "Clash profile routes traffic through the selected node"
assert_not_contains "$loon_file" 'transport=xhttp' "unsupported Loon XHTTP omitted"
assert_contains "$loon_file" 'Hysteria2,node.example.com,443' "Loon Hysteria2 retained"
assert_contains "$loon_file" 'VW = VLESS,cdn.node.example.com,443' "Loon includes the WebSocket CDN node"
assert_contains "$loon_file" 'transport=ws,path=/44556677-ws,host=cdn.node.example.com' "Loon WebSocket syntax follows the official format"

assert_contains "$REPO_ROOT/vps-deploy.sh" 'cloudflare_api_token:' "official Hysteria Cloudflare key"
assert_not_contains "$REPO_ROOT/vps-deploy.sh" 'auth_token:' "obsolete Hysteria token key absent"
assert_contains "$REPO_ROOT/vps-deploy.sh" 'x25519 -i "$REALITY_PRIVKEY"' "Reality public key derives from an argument"
assert_not_contains "$REPO_ROOT/vps-deploy.sh" 'ufw --force reset' "firewall rules are never reset"
assert_not_contains "$REPO_ROOT/vps-deploy.sh" 'userdel ' "installer never deletes login users"
assert_not_contains "$REPO_ROOT/vps-deploy.sh" 'PasswordAuthentication no' "proxy installer does not alter SSH authentication"
assert_contains "$REPO_ROOT/vps-deploy.sh" 'User=xray' "Xray has a dedicated service identity"
assert_contains "$REPO_ROOT/vps-deploy.sh" 'install -m 0640 -o root -g xray' "Xray config remains readable after reboot"
assert_contains "$REPO_ROOT/vps-deploy.sh" 'chown root:caddy "$SUB_ROOT"' "Caddy can traverse the subscription root"
assert_not_contains "$REPO_ROOT/vps-deploy.sh" '$failed && die' "successful checks do not return a false status"
assert_contains "$REPO_ROOT/vps-deploy.sh" 'managed_listener "$expected"' "same-name listeners are trusted only with ownership evidence"
assert_not_contains "$REPO_ROOT/vps-deploy.sh" 'cloudflared service install "$CF_TOKEN"' "Tunnel token is not passed in a process argument"
assert_contains "$REPO_ROOT/vps-deploy.sh" 'install -m 0600 -o root -g root "$temp_dir/tunnel-token" /etc/cloudflared/token' "Tunnel token is installed with root-only permissions"
assert_contains "$REPO_ROOT/vps-deploy.sh" 'tunnel run --token-file /etc/cloudflared/token' "cloudflared reads its token from the protected file"

BACKUP_ROOT="$test_root/backups"
printf '%s\n' old > "$test_root/rollback.conf"
backup_file "$test_root/rollback.conf"
rollback_copy=$BACKUP_FILE_PATH
printf '%s\n' broken > "$test_root/rollback.conf"
systemctl() { return 0; }
rollback_config "$test_root/rollback.conf" "$rollback_copy" dummy.service
[[ $(<"$test_root/rollback.conf") == "old" ]] || fail "configuration rollback did not restore the backup"
pass "failed service updates can restore the previous configuration"

if [[ -n "${CADDY_BIN:-}" ]]; then
    CADDY_ORIGIN_PORT=$(free_local_tcp_port)
    render_caddy_config "$test_root/Caddyfile"
    "$CADDY_BIN" validate --config "$test_root/Caddyfile" --adapter caddyfile >/dev/null
    pass "Caddy accepts generated origin configuration"
    "$CADDY_BIN" run --config "$test_root/Caddyfile" --adapter caddyfile \
        >"$test_root/caddy.log" 2>&1 &
    caddy_pid=$!
    test_pids+=("$caddy_pid")
    caddy_body=""
    for _ in $(seq 1 30); do
        caddy_body=$(curl -fsS -H 'Host: cdn.node.example.com' \
            "http://127.0.0.1:${CADDY_ORIGIN_PORT}/${SUB_TOKEN}/clash.yaml" 2>/dev/null || true)
        [[ "$caddy_body" == *'server: cdn.node.example.com'* ]] && break
        sleep 0.1
    done
    [[ "$caddy_body" == *'server: cdn.node.example.com'* ]] || {
        sed -n '1,100p' "$test_root/caddy.log" >&2
        fail "Caddy origin does not accept the Cloudflare Host header"
    }
    kill "$caddy_pid"
    wait "$caddy_pid" 2>/dev/null || true
    test_pids=()
    pass "Caddy serves subscriptions with the Cloudflare Host header"
fi

if [[ -n "${MIHOMO_BIN:-}" ]]; then
    "$MIHOMO_BIN" -t -d "$test_root/mihomo" -f "$clash_file" >/dev/null
    pass "Mihomo accepts generated Clash configuration"
fi

if [[ -n "${XRAY_BIN:-}" && -n "${XRAY_ASSET_DIR:-}" ]]; then
    keypair=$($XRAY_BIN x25519)
    REALITY_PRIVKEY=$(awk -F': ' '/^PrivateKey:/ {print $2}' <<<"$keypair")
    REALITY_PUBKEY=$(awk -F': ' '/PublicKey/ {print $2}' <<<"$keypair")
    REALITY_TARGET="www.nic.ad.jp:443"
    render_xray_config "$test_root/xray-server.json"
    XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" \
        "$XRAY_BIN" run -test -config "$test_root/xray-server.json" >/dev/null
    pass "Xray accepts generated Reality + XHTTP + WebSocket server configuration"
    render_reality_client_config "$test_root/reality-client.json" 18980
    "$XRAY_BIN" run -test -config "$test_root/reality-client.json" >/dev/null
    pass "Xray accepts generated Reality self-test client configuration"
    render_xhttp_client_config "$test_root/xhttp-client.json" 18982
    "$XRAY_BIN" run -test -config "$test_root/xhttp-client.json" >/dev/null
    pass "Xray accepts generated XHTTP self-test client configuration"
    render_ws_client_config "$test_root/ws-client.json" 18983
    "$XRAY_BIN" run -test -config "$test_root/ws-client.json" >/dev/null
    pass "Xray accepts generated WebSocket self-test client configuration"
fi

if [[ -n "${XRAY_BIN:-}" && -n "${CADDY_BIN:-}" ]]; then
    e2e_origin_port=$(free_local_tcp_port)
    e2e_xhttp_port=$(free_local_tcp_port)
    e2e_ws_port=$(free_local_tcp_port)
    e2e_socks_port=$(free_local_tcp_port)
    e2e_ws_socks_port=$(free_local_tcp_port)
    e2e_target_port=$(free_local_tcp_port)
    CADDY_ORIGIN_PORT=$e2e_origin_port
    XHTTP_PORT=$e2e_xhttp_port
    WS_PORT=$e2e_ws_port

    mkdir -p "$test_root/e2e-target"
    printf '%s\n' 'xhttp-caddy-e2e-ok' > "$test_root/e2e-target/index.html"
    python3 -m http.server "$e2e_target_port" --bind 127.0.0.1 \
        --directory "$test_root/e2e-target" >"$test_root/e2e-target.log" 2>&1 &
    target_pid=$!
    test_pids+=("$target_pid")

    cat > "$test_root/e2e-server.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "127.0.0.1", "port": ${e2e_xhttp_port}, "protocol": "vless",
      "settings": {"clients": [{"id": "${XHTTP_UUID}"}], "decryption": "none"},
      "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": {"path": "${XHTTP_PATH}"}}
    },
    {
      "listen": "127.0.0.1", "port": ${e2e_ws_port}, "protocol": "vless",
      "settings": {"clients": [{"id": "${WS_UUID}"}], "decryption": "none"},
      "streamSettings": {"network": "websocket", "security": "none", "wsSettings": {"path": "${WS_PATH}"}}
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    "$XRAY_BIN" run -test -config "$test_root/e2e-server.json" >/dev/null
    "$XRAY_BIN" run -config "$test_root/e2e-server.json" >"$test_root/e2e-server.log" 2>&1 &
    e2e_server_pid=$!
    test_pids+=("$e2e_server_pid")

    render_caddy_config "$test_root/e2e-Caddyfile"
    "$CADDY_BIN" run --config "$test_root/e2e-Caddyfile" --adapter caddyfile \
        >"$test_root/e2e-caddy.log" 2>&1 &
    e2e_caddy_pid=$!
    test_pids+=("$e2e_caddy_pid")

    cat > "$test_root/e2e-client.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": ${e2e_socks_port}, "protocol": "socks"}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": ${e2e_origin_port}, "users": [{"id": "${XHTTP_UUID}", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "xhttp", "security": "none",
      "xhttpSettings": {"host": "${CDN_DOMAIN}", "path": "${XHTTP_PATH}", "mode": "packet-up"}
    }
  }]
}
EOF
    "$XRAY_BIN" run -test -config "$test_root/e2e-client.json" >/dev/null
    "$XRAY_BIN" run -config "$test_root/e2e-client.json" >"$test_root/e2e-client.log" 2>&1 &
    e2e_client_pid=$!
    test_pids+=("$e2e_client_pid")

    e2e_body=""
    for _ in $(seq 1 50); do
        e2e_body=$(curl -fsS --noproxy '' --socks5-hostname "127.0.0.1:${e2e_socks_port}" \
            "http://127.0.0.1:${e2e_target_port}/" 2>/dev/null || true)
        [[ "$e2e_body" == *'xhttp-caddy-e2e-ok'* ]] && break
        sleep 0.1
    done
    [[ "$e2e_body" == *'xhttp-caddy-e2e-ok'* ]] || {
        sed -n '1,80p' "$test_root/e2e-client.log" >&2
        sed -n '1,80p' "$test_root/e2e-caddy.log" >&2
        sed -n '1,80p' "$test_root/e2e-server.log" >&2
        fail "XHTTP packet-up does not traverse Caddy"
    }

    cat > "$test_root/e2e-ws-client.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": ${e2e_ws_socks_port}, "protocol": "socks"}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": ${e2e_origin_port}, "users": [{"id": "${WS_UUID}", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "websocket", "security": "none",
      "wsSettings": {"host": "${CDN_DOMAIN}", "path": "${WS_PATH}"}
    }
  }]
}
EOF
    "$XRAY_BIN" run -test -config "$test_root/e2e-ws-client.json" >/dev/null
    "$XRAY_BIN" run -config "$test_root/e2e-ws-client.json" >"$test_root/e2e-ws-client.log" 2>&1 &
    e2e_ws_client_pid=$!
    test_pids+=("$e2e_ws_client_pid")

    e2e_ws_body=""
    for _ in $(seq 1 50); do
        e2e_ws_body=$(curl -fsS --noproxy '' --socks5-hostname "127.0.0.1:${e2e_ws_socks_port}" \
            "http://127.0.0.1:${e2e_target_port}/" 2>/dev/null || true)
        [[ "$e2e_ws_body" == *'xhttp-caddy-e2e-ok'* ]] && break
        sleep 0.1
    done
    [[ "$e2e_ws_body" == *'xhttp-caddy-e2e-ok'* ]] || {
        sed -n '1,80p' "$test_root/e2e-ws-client.log" >&2
        sed -n '1,80p' "$test_root/e2e-caddy.log" >&2
        sed -n '1,80p' "$test_root/e2e-server.log" >&2
        fail "WebSocket does not traverse Caddy"
    }

    for pid in "$e2e_ws_client_pid" "$e2e_client_pid" "$e2e_caddy_pid" "$e2e_server_pid" "$target_pid"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    test_pids=()
    pass "XHTTP packet-up traverses Caddy end to end"
    pass "WebSocket traverses Caddy end to end"
fi

if [[ -n "${HYSTERIA_BIN:-}" ]]; then
    hysteria_test_port=$(python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$test_root/hysteria.key" -out "$test_root/hysteria.crt" \
        -subj '/CN=test.example.com' -days 1 >/dev/null 2>&1
    cat > "$test_root/hysteria-test.yaml" <<EOF
listen: 127.0.0.1:${hysteria_test_port}
tls:
  cert: $test_root/hysteria.crt
  key: $test_root/hysteria.key
auth:
  type: password
  password: test-password
congestion:
  type: bbr
  bbrProfile: standard
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 16777216
  maxConnReceiveWindow: 33554432
  maxIdleTimeout: 60s
udpIdleTimeout: 60s
masquerade:
  type: string
  string:
    content: ok
EOF
    "$HYSTERIA_BIN" server -c "$test_root/hysteria-test.yaml" >"$test_root/hysteria.log" 2>&1 &
    hysteria_pid=$!
    test_pids+=("$hysteria_pid")
    sleep 1
    kill -0 "$hysteria_pid" 2>/dev/null || {
        sed -n '1,80p' "$test_root/hysteria.log" >&2
        fail "Hysteria rejects generated tuning fields"
    }
    kill "$hysteria_pid"
    wait "$hysteria_pid" 2>/dev/null || true
    test_pids=()
    pass "Hysteria accepts generated tuning fields"
fi

# 用无副作用替身走完 main，确认三参数非交互模式不会停在提示或成功检查。
main_calls=()
record_main_call() { main_calls+=("$1"); }
require_platform() { record_main_call platform; }
install_dependencies() { record_main_call dependencies; }
load_state() { record_main_call state; }
configure_inputs() {
    DOMAIN=node.example.com
    PROVIDER=TEST
    EMAIL=admin@example.com
    ACME_MODE=http
    CDN_DOMAIN=
    ENABLE_CDN=false
    MANAGE_UFW=1
    SKIP_DNS_CHECK=0
    record_main_call inputs
}
verify_direct_dns() { XRAY_LISTEN=0.0.0.0; XRAY_TEST_ADDRESS=127.0.0.1; record_main_call dns; }
listener_conflict() { return 0; }
optimize_system() { record_main_call sysctl; }
setup_firewall() { record_main_call firewall; }
install_xray_binary() { record_main_call xray_binary; }
install_hysteria_binary() { record_main_call hysteria_binary; }
ensure_service_users() { record_main_call users; }
ensure_secrets() { record_main_call secrets; }
probe_reality_target() { record_main_call target; }
write_xray_config() { record_main_call xray_config; }
write_hysteria_config() { record_main_call hysteria_config; }
install_caddy() { record_main_call caddy; }
write_state() { record_main_call write_state; }
write_subscriptions() { record_main_call subscriptions; }
install_traffic_dashboard() { record_main_call traffic; }
install_cloudflared() { record_main_call cloudflared; }
setup_fail2ban() { record_main_call fail2ban; }
health_check() { record_main_call health; }
print_summary() { record_main_call summary; }
MODE=install
NON_INTERACTIVE=false
COUNTRY_ENV=JP
REALITY_TARGET_ENV=www.nic.ad.jp:443
ACME_MODE_ENV=http
CDN_DOMAIN_ENV=
unset STATE_DOMAIN STATE_PROVIDER STATE_EMAIL STATE_ACME_MODE STATE_CDN_DOMAIN
main node.example.com TEST admin@example.com
[[ " ${main_calls[*]} " == *' health summary '* ]] || fail "non-interactive main did not reach successful handoff"
[[ " ${main_calls[*]} " == *' platform state inputs dependencies '* ]] || \
    fail "input validation did not run before package installation"
pass "non-interactive main reaches health check and summary without prompting"

printf '\n%d audit tests passed\n' "$pass_count"
