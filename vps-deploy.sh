#!/usr/bin/env bash
# VPS proxy deployment v4
# VLESS Reality + Hysteria 2, with optional VLESS XHTTP and WebSocket through Cloudflare Tunnel.

set -Eeuo pipefail
umask 027

SCRIPT_VERSION="4.1.3"
XRAY_VERSION="v26.3.27"
HYSTERIA_VERSION="app/v2.12.1"
CADDY_VERSION="v2.11.4"
CLOUDFLARED_VERSION="2026.7.3"

STATE_DIR="/etc/vps-proxy"
STATE_FILE="${STATE_DIR}/state.env"
PENDING_STATE_FILE="${STATE_DIR}/state.pending"
INSTALL_PHASE_FILE="${STATE_DIR}/install-phase"
LEGACY_STATE_FILE="${STATE_DIR}/subs.conf"
SUB_ROOT="/var/lib/subscription"
TRAFFIC_ROOT="/var/lib/traffic-monitor"
BACKUP_ROOT="/var/backups/vps-proxy"

REALITY_PORT=443
HY2_PORT=443
CADDY_ORIGIN_PORT=10000
XHTTP_PORT=10001
WS_PORT=10002

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
err() { printf '%b[ERR ]%b %s\n' "$RED" "$NC" "$*" >&2; }
die() { err "$*"; exit 1; }

TEMP_DIRS=()
CHILD_PIDS=()

cleanup() {
    local pid temp_dir
    for pid in "${CHILD_PIDS[@]:-}"; do
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    for temp_dir in "${TEMP_DIRS[@]:-}"; do
        if [[ "$temp_dir" == /tmp/vps-proxy.* ]] && [[ -d "$temp_dir" ]]; then
            rm -rf -- "$temp_dir"
        fi
    done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

unregister_child_pid() {
    local target=$1 pid remaining=()
    for pid in "${CHILD_PIDS[@]:-}"; do
        [[ "$pid" == "$target" ]] || remaining+=("$pid")
    done
    CHILD_PIDS=("${remaining[@]}")
}

new_temp_dir() {
    NEW_TEMP_DIR=$(mktemp -d /tmp/vps-proxy.XXXXXX)
    TEMP_DIRS+=("$NEW_TEMP_DIR")
}

usage() {
    cat <<'EOF'
VPS 代理部署脚本 v4

交互安装：
  sudo bash vps-deploy.sh

非交互安装：
  sudo bash vps-deploy.sh DOMAIN EMAIL

DNS-01（Cloudflare）：
  ACME_MODE_ENV=dns CF_DNS_TOKEN_ENV='...' \
    sudo --preserve-env=ACME_MODE_ENV,CF_DNS_TOKEN_ENV \
      bash vps-deploy.sh DOMAIN EMAIL

启用 Cloudflare Tunnel + XHTTP + WebSocket + HTTPS 订阅：
  CDN_DOMAIN_ENV=cdn.example.com CF_TOKEN_ENV='eyJ...' \
    sudo --preserve-env=CDN_DOMAIN_ENV,CF_TOKEN_ENV \
      bash vps-deploy.sh node.example.com EMAIL

只读验收：
  sudo bash vps-deploy.sh --check

可选环境变量：
  DOMAIN_ENV, EMAIL_ENV, COUNTRY_ENV, REALITY_TARGET_ENV
  ACME_MODE_ENV=http|dns, CF_DNS_TOKEN_ENV
  CDN_DOMAIN_ENV, CF_TOKEN_ENV
  MANAGE_UFW_ENV=0|1, SKIP_DNS_CHECK_ENV=0|1
EOF
}

MODE="install"
ARG_DOMAIN=""
ARG_EMAIL=""
NON_INTERACTIVE=false

parse_args() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi
    if [[ "${1:-}" == "--check" ]]; then
        MODE="check"
        shift
    fi
    [[ $# -le 2 ]] || die "参数过多；使用 --help 查看用法"
    ARG_DOMAIN="${1:-}"
    ARG_EMAIL="${2:-}"
    if [[ -n "$ARG_DOMAIN" || -n "${DOMAIN_ENV:-}" ]]; then
        NON_INTERACTIVE=true
    fi
}

require_platform() {
    [[ $(id -u) -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) die "仅支持使用 systemd 的 Ubuntu/Debian；当前为 ${ID:-unknown}" ;;
    esac
    command -v apt-get >/dev/null || die "缺少 apt-get"
    command -v systemctl >/dev/null || die "缺少 systemd/systemctl"
    [[ $(ps -p 1 -o comm=) == "systemd" ]] || die "PID 1 不是 systemd；不支持容器内直接部署"
    info "系统：${PRETTY_NAME:-$ID} / $(uname -m)"
}

install_dependencies() {
    local command missing=()
    for command in update-ca-certificates curl unzip openssl timeout sha256sum tar \
        ip ss dig python3 cron ufw modprobe useradd groupadd getent \
        fail2ban-client vnstat vnstati; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    if (( ${#missing[@]} == 0 )); then
        info "基础依赖已齐全，跳过 apt 更新"
        return
    fi
    info "安装缺失的基础依赖：${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        ca-certificates curl unzip openssl coreutils tar iproute2 dnsutils \
        python3 cron ufw kmod passwd fail2ban vnstat vnstati >/dev/null
}

state_file_is_safe() {
    local path=$1 owner mode
    [[ -f "$path" ]] || return 1
    owner=$(stat -c '%U' "$path" 2>/dev/null || true)
    mode=$(stat -c '%a' "$path" 2>/dev/null || true)
    [[ "$owner" == "root" ]] || return 1
    [[ "$mode" =~ ^[0-7]?[0-7][0-7]$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

report_incomplete_install() {
    local phase="unknown"
    if state_file_is_safe "$INSTALL_PHASE_FILE"; then
        phase=$(<"$INSTALL_PHASE_FILE")
        [[ "$phase" =~ ^[a-z0-9-]{1,48}$ ]] || phase="unknown"
        warn "检测到上次未完成的安装阶段：${phase}；本次会复用安全状态并继续"
    fi
}

mark_install_phase() {
    local phase=$1 temp_dir phase_file
    [[ "$phase" =~ ^[a-z0-9-]{1,48}$ ]] || die "内部安装阶段名称无效：$phase"
    install -d -m 0700 -o root -g root "$STATE_DIR"
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    phase_file="$temp_dir/install-phase"
    printf '%s\n' "$phase" > "$phase_file"
    install -m 0600 -o root -g root "$phase_file" "$INSTALL_PHASE_FILE"
}

clear_install_phase() {
    rm -f -- "$INSTALL_PHASE_FILE"
}

load_state() {
    report_incomplete_install
    if [[ -f "$STATE_FILE" ]]; then
        state_file_is_safe "$STATE_FILE" || die "状态文件权限不安全：$STATE_FILE"
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        info "已载入现有 v4 状态"
        return
    fi
    if [[ -f "$PENDING_STATE_FILE" ]]; then
        state_file_is_safe "$PENDING_STATE_FILE" || die "待提交状态文件权限不安全：$PENDING_STATE_FILE"
        # shellcheck disable=SC1090
        source "$PENDING_STATE_FILE"
        warn "已载入上次未完成安装的待提交状态；凭证不会重新生成"
        return
    fi
    migrate_legacy_state
}

legacy_value() {
    local key=$1 value
    value=$(sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "$LEGACY_STATE_FILE" 2>/dev/null | tail -n 1)
    printf '%s\n' "$value"
}

migrate_legacy_state() {
    [[ -f "$LEGACY_STATE_FILE" ]] || return 0
    state_file_is_safe "$LEGACY_STATE_FILE" || {
        warn "旧状态文件权限不安全，拒绝载入：$LEGACY_STATE_FILE"
        return 0
    }
    warn "检测到 v3 状态；只迁移经过格式验证的密钥，不 source 旧文件"
    local value
    value=$(legacy_value VL_UUIDS_0)
    valid_uuid "$value" && STATE_VR_CLASH_UUID="$value"
    value=$(legacy_value VL_UUIDS_2)
    valid_uuid "$value" && STATE_VR_LOON_UUID="$value"
    value=$(legacy_value HY2_PASS)
    [[ "$value" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] && STATE_HY2_PASS="$value"
    value=$(legacy_value XHTTP_UUID)
    valid_uuid "$value" && STATE_XHTTP_UUID="$value"
    value=$(legacy_value XHTTP_PATH)
    valid_xhttp_path "$value" && STATE_XHTTP_PATH="$value"
    value=$(legacy_value VMESS_UUID)
    valid_uuid "$value" && STATE_WS_UUID="$value"
    value=$(legacy_value VMESS_WS_PATH)
    valid_ws_path "$value" && STATE_WS_PATH="$value"
    value=$(legacy_value SUB_TOKEN)
    [[ "$value" =~ ^[a-f0-9]{24,64}$ ]] && STATE_SUB_TOKEN="$value"
    value=$(legacy_value VL_PUBKEY)
    [[ "$value" =~ ^[A-Za-z0-9_-]{40,64}$ ]] && STATE_REALITY_PUBKEY="$value"
    value=$(legacy_value VL_SHORTID)
    valid_short_id "$value" && STATE_REALITY_SHORTID="$value"

    if [[ -r /usr/local/etc/xray/config.json ]]; then
        value=$(python3 - <<'PY' 2>/dev/null || true
import json
with open('/usr/local/etc/xray/config.json', encoding='utf-8') as f:
    config = json.load(f)
for inbound in config.get('inbounds', []):
    if inbound.get('tag') == 'vless-reality':
        print(inbound.get('streamSettings', {}).get('realitySettings', {}).get('privateKey', ''))
        break
PY
)
        [[ "$value" =~ ^[A-Za-z0-9_-]{40,64}$ ]] && STATE_REALITY_PRIVKEY="$value"
    fi
}

normalize_domain() {
    local value=$1
    value=${value#http://}
    value=${value#https://}
    value=${value%/}
    printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

valid_domain() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

valid_xhttp_path() {
    [[ "$1" =~ ^/[A-Za-z0-9_-]{4,96}$ ]]
}

valid_ws_path() {
    [[ "$1" =~ ^/[A-Za-z0-9_-]{4,96}$ ]]
}

valid_short_id() {
    [[ "$1" =~ ^([a-fA-F0-9]{2}){1,8}$ ]]
}

prompt_value() {
    local prompt=$1 default=${2:-} value
    if [[ -n "$default" ]]; then
        read -r -p "${prompt} [${default}]: " value
        printf '%s' "${value:-$default}"
    else
        read -r -p "${prompt}: " value
        printf '%s' "$value"
    fi
}

configure_inputs() {
    DOMAIN=$(normalize_domain "${DOMAIN_ENV:-${ARG_DOMAIN:-${STATE_DOMAIN:-}}}")
    EMAIL="${EMAIL_ENV:-${ARG_EMAIL:-${STATE_EMAIL:-}}}"
    ACME_MODE="${ACME_MODE_ENV:-${STATE_ACME_MODE:-http}}"
    CF_DNS_TOKEN="${CF_DNS_TOKEN_ENV:-}"
    CDN_DOMAIN=$(normalize_domain "${CDN_DOMAIN_ENV:-${STATE_CDN_DOMAIN:-}}")
    CF_TOKEN="${CF_TOKEN_ENV:-}"
    MANAGE_UFW="${MANAGE_UFW_ENV:-1}"
    SKIP_DNS_CHECK="${SKIP_DNS_CHECK_ENV:-0}"

    if ! $NON_INTERACTIVE; then
        while ! valid_domain "$DOMAIN"; do
            DOMAIN=$(normalize_domain "$(prompt_value '直连节点域名（DNS only）' "$DOMAIN")")
        done
        while ! valid_email "$EMAIL"; do
            EMAIL=$(prompt_value "Let's Encrypt 联系邮箱" "$EMAIL")
        done
        ACME_MODE=$(prompt_value "ACME 模式 http/dns" "$ACME_MODE")
        if [[ "$ACME_MODE" == "dns" && -z "$CF_DNS_TOKEN" ]]; then
            read -r -s -p "Cloudflare DNS API Token: " CF_DNS_TOKEN
            printf '\n'
        fi
        if [[ -z "$CDN_DOMAIN" ]]; then
            CDN_DOMAIN=$(normalize_domain "$(prompt_value 'Cloudflare CDN 域名（留空禁用 CDN 节点/在线订阅）' '')")
        fi
        if [[ -n "$CDN_DOMAIN" && -z "$CF_TOKEN" ]] && ! systemctl cat cloudflared.service >/dev/null 2>&1; then
            read -r -s -p "Cloudflare Tunnel Token（eyJ...）: " CF_TOKEN
            printf '\n'
        fi
    fi

    valid_domain "$DOMAIN" || die "域名格式无效：$DOMAIN"
    valid_email "$EMAIL" || die "必须提供有效邮箱；非交互用第二个参数或 EMAIL_ENV"
    [[ "$ACME_MODE" == "http" || "$ACME_MODE" == "dns" ]] || die "ACME_MODE_ENV 只能是 http 或 dns"
    [[ "$MANAGE_UFW" == "0" || "$MANAGE_UFW" == "1" ]] || die "MANAGE_UFW_ENV 只能是 0 或 1"
    [[ "$SKIP_DNS_CHECK" == "0" || "$SKIP_DNS_CHECK" == "1" ]] || die "SKIP_DNS_CHECK_ENV 只能是 0 或 1"
    if [[ "$ACME_MODE" == "dns" ]]; then
        [[ -n "$CF_DNS_TOKEN" ]] || die "DNS-01 需要 CF_DNS_TOKEN_ENV"
        [[ "$CF_DNS_TOKEN" =~ ^[A-Za-z0-9_-]{20,128}$ ]] || die "Cloudflare DNS Token 格式异常"
    fi
    if [[ -n "$CDN_DOMAIN" ]]; then
        valid_domain "$CDN_DOMAIN" || die "CDN_DOMAIN_ENV 格式无效：$CDN_DOMAIN"
        [[ "$CDN_DOMAIN" != "$DOMAIN" ]] || die "CDN 域名必须与直连域名不同"
        ENABLE_CDN=true
        if ! systemctl cat cloudflared.service >/dev/null 2>&1; then
            [[ -n "$CF_TOKEN" ]] || die "新装 CDN 需要 CF_TOKEN_ENV"
        fi
    else
        ENABLE_CDN=false
    fi
    if [[ -n "$CF_TOKEN" ]]; then
        CF_TOKEN=$(grep -oE 'eyJ[A-Za-z0-9_+/=-]+' <<<"$CF_TOKEN" | head -n 1 || true)
        [[ -n "$CF_TOKEN" ]] || die "Cloudflare Tunnel Token 格式无效"
    fi
    info "直连域名：${DOMAIN}；ACME：${ACME_MODE}；CDN：${ENABLE_CDN}"
}

detect_region() {
    COUNTRY="${COUNTRY_ENV:-${STATE_COUNTRY:-}}"
    if [[ -z "$COUNTRY" ]]; then
        COUNTRY=$(curl -fsS --noproxy '*' --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
            awk -F= '$1 == "loc" {print $2; exit}' || true)
    fi
    COUNTRY=$(printf '%s' "$COUNTRY" | tr '[:lower:]' '[:upper:]')
    [[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || COUNTRY="XX"
    FLAG=$(python3 - "$COUNTRY" <<'PY'
import sys
code = sys.argv[1]
if len(code) == 2 and code.isalpha() and code != 'XX':
    print(''.join(chr(0x1F1E6 + ord(c) - ord('A')) for c in code))
else:
    print('🏳️')
PY
)
    NODE_PREFIX="${FLAG} ${COUNTRY}"

    REALITY_TARGET="${REALITY_TARGET_ENV:-${STATE_REALITY_TARGET:-}}"
    if [[ -z "$REALITY_TARGET" ]]; then
        case "$COUNTRY" in
            JP) REALITY_TARGET="www.nic.ad.jp:443" ;;
            HK) REALITY_TARGET="www.hku.hk:443" ;;
            SG) REALITY_TARGET="www.nus.edu.sg:443" ;;
            US) REALITY_TARGET="www.cisa.gov:443" ;;
            KR) REALITY_TARGET="www.snu.ac.kr:443" ;;
            DE) REALITY_TARGET="www.bund.de:443" ;;
            GB) REALITY_TARGET="www.gov.uk:443" ;;
            *) die "无法为国家 ${COUNTRY} 安全地自动选择 Reality target；请设置 REALITY_TARGET_ENV=host:443" ;;
        esac
    fi
    [[ "$REALITY_TARGET" == *:* ]] || REALITY_TARGET="${REALITY_TARGET}:443"
    local target_host target_port
    target_host=${REALITY_TARGET%:*}
    target_port=${REALITY_TARGET##*:}
    target_host=$(printf '%s' "$target_host" | tr '[:upper:]' '[:lower:]')
    valid_domain "$target_host" || die "REALITY_TARGET_ENV 主机名无效"
    if [[ ! "$target_port" =~ ^[0-9]{1,5}$ ]] || \
        (( 10#$target_port < 1 || 10#$target_port > 65535 )); then
        die "REALITY_TARGET_ENV 端口无效"
    fi
    REALITY_TARGET="${target_host}:${target_port}"
    REALITY_SNI=${REALITY_TARGET%:*}
    HY2_MASQUERADE_URL="https://${REALITY_SNI}/"
    info "地区：${COUNTRY}；Reality target：${REALITY_TARGET}"
}

detect_ssh_port() {
    SSH_PORT=""
    # 当前 SSH 会话的服务端端口最可靠，也能覆盖 systemd socket activation。
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        SSH_PORT=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    fi
    if [[ -z "$SSH_PORT" ]] && command -v sshd >/dev/null 2>&1; then
        SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)
    fi
    if [[ ! "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535 )); then
        SSH_PORT=22
    fi
    info "SSH 实际端口：${SSH_PORT}（脚本不会修改 SSH 配置）"
}

verify_direct_dns() {
    [[ "$SKIP_DNS_CHECK" == "1" ]] && {
        XRAY_LISTEN=${STATE_XRAY_LISTEN:-0.0.0.0}
        [[ "$XRAY_LISTEN" == "::" ]] && XRAY_TEST_ADDRESS="::1" || XRAY_TEST_ADDRESS="127.0.0.1"
        warn "已按 SKIP_DNS_CHECK_ENV=1 跳过 DNS 验证"
        return
    }
    local public_v4 public_v6 a_records aaaa_records a_status aaaa_status bindv6only
    public_v4=$(curl -4 -fsS --noproxy '*' --max-time 8 https://api.ipify.org 2>/dev/null || true)
    public_v6=$(curl -6 -fsS --noproxy '*' --max-time 8 https://api64.ipify.org 2>/dev/null || true)
    a_records=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | sed '/^$/d' || true)
    aaaa_records=$(dig +short AAAA "$DOMAIN" @1.1.1.1 2>/dev/null | sed '/^$/d' || true)
    a_status=$(dns_record_status 4 "$public_v4" "$a_records")
    aaaa_status=$(dns_record_status 6 "$public_v6" "$aaaa_records")
    if [[ "$a_status" == "absent" && "$aaaa_status" == "absent" ]]; then
        die "$DOMAIN 没有可用的 A/AAAA 记录"
    fi
    if [[ "$a_status" == "mismatch" || "$aaaa_status" == "mismatch" ]]; then
        err "公共 DNS 未指向本机，或记录开启了 Cloudflare 橙云"
        err "本机 IPv4=${public_v4:-无}；A=${a_records//$'\n'/,}"
        err "本机 IPv6=${public_v6:-无}；AAAA=${aaaa_records//$'\n'/,}"
        die "请把 $DOMAIN 设置为 DNS only 并指向本机后重跑"
    fi

    bindv6only=$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || printf '1')
    if [[ "$a_status" == "match" && "$aaaa_status" == "match" && "$bindv6only" == "0" ]]; then
        XRAY_LISTEN="::"
        XRAY_TEST_ADDRESS="127.0.0.1"
    elif [[ "$a_status" == "match" ]]; then
        XRAY_LISTEN="0.0.0.0"
        XRAY_TEST_ADDRESS="127.0.0.1"
        if [[ "$aaaa_status" == "match" ]]; then
            warn "net.ipv6.bindv6only=1；Reality 本次仅监听 IPv4，避免双栈端口冲突"
        fi
    else
        XRAY_LISTEN="::"
        XRAY_TEST_ADDRESS="::1"
    fi
    info "公共 DNS 与本机地址一致（DNS only）"
}

dns_record_status() {
    local family=$1 public_ip=$2 records=$3
    python3 - "$family" "$public_ip" "$records" <<'PY'
import ipaddress
import sys

family = int(sys.argv[1])
public = sys.argv[2]
records = []
for value in sys.argv[3].splitlines():
    try:
        address = ipaddress.ip_address(value.rstrip('.'))
    except ValueError:
        continue
    if address.version == family:
        records.append(address)

if not records:
    print('absent')
    raise SystemExit
try:
    expected = ipaddress.ip_address(public)
except ValueError:
    print('mismatch')
    raise SystemExit
print('match' if all(address == expected for address in records) else 'mismatch')
PY
}

listener_conflict() {
    local protocol=$1 port=$2 expected=$3 label=$4 output flag
    if [[ "$protocol" == "tcp" ]]; then
        flag="-ltnp"
    else
        flag="-lunp"
    fi
    output=$(ss -H "$flag" "sport = :$port" 2>/dev/null || true)
    [[ -n "$output" ]] || return 0
    if grep -qi "$expected" <<<"$output" && managed_listener "$expected"; then
        info "$label $protocol/$port 已由本脚本服务占用（重跑）"
        return 0
    fi
    err "$label $protocol/$port 已被其他进程占用：$output"
    return 1
}

managed_listener() {
    local service_name=$1 unit=""
    if state_file_is_safe "$STATE_FILE" || state_file_is_safe "$LEGACY_STATE_FILE"; then
        return 0
    fi
    case "$service_name" in
        xray) unit=/etc/systemd/system/xray.service ;;
        hysteria) unit=/etc/systemd/system/hysteria-server.service ;;
        caddy) unit=/etc/systemd/system/caddy.service ;;
        *) return 1 ;;
    esac
    [[ -f "$unit" ]] && grep -Fq '# Managed by vps-deploy.sh v4' "$unit"
}

preflight_ports() {
    local failed=false
    listener_conflict tcp 443 xray "VLESS Reality" || failed=true
    listener_conflict udp 443 hysteria "Hysteria2" || failed=true
    if [[ "$ACME_MODE" == "http" ]]; then
        listener_conflict tcp 80 hysteria "ACME HTTP-01/续期" || failed=true
    fi
    if $ENABLE_CDN; then
        listener_conflict tcp "$CADDY_ORIGIN_PORT" caddy "Caddy 本地入口" || failed=true
        listener_conflict tcp "$XHTTP_PORT" xray "XHTTP 本地入口" || failed=true
        listener_conflict tcp "$WS_PORT" xray "WebSocket 本地入口" || failed=true
    fi
    if $failed; then
        die "端口冲突不会被自动停止或杀进程；请先手动处理"
    fi
}

optimize_system() {
    info "写入保守的网络参数"
    local bbr_lines=""
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        bbr_lines=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
    fi
    cat > /etc/sysctl.d/99-vps-proxy.conf <<EOF
# Managed by vps-deploy.sh ${SCRIPT_VERSION}
${bbr_lines}
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3
vm.swappiness = 10
EOF
    if ! sysctl -p /etc/sysctl.d/99-vps-proxy.conf >/dev/null; then
        warn "部分 sysctl 参数不受当前内核支持；代理仍可运行"
    fi
}

setup_firewall() {
    if [[ "$MANAGE_UFW" == "0" ]]; then
        warn "MANAGE_UFW_ENV=0：未修改主机防火墙；请自行开放 ${SSH_PORT}/tcp、443/tcp、443/udp"
        [[ "$ACME_MODE" == "http" ]] && warn "HTTP-01 续期还需要永久允许 80/tcp"
        return
    fi
    info "增量配置 UFW（不 reset、不删除既有规则）"
    ufw allow "${SSH_PORT}/tcp" comment 'vps-proxy SSH' >/dev/null
    ufw allow 443/tcp comment 'vps-proxy Reality' >/dev/null
    ufw allow 443/udp comment 'vps-proxy Hysteria2' >/dev/null
    if [[ "$ACME_MODE" == "http" ]]; then
        # Hysteria 自行续证，挑战发生时间不可预知，因此 80/tcp 必须保留。
        ufw allow 80/tcp comment 'vps-proxy ACME renewal' >/dev/null
    fi
    ufw --force enable >/dev/null
}

sha256_verify() {
    local file=$1 expected=$2 actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || die "SHA-256 校验失败：$file"
}

download_file() {
    local url=$1 output=$2
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 240 -o "$output" "$url"
    [[ -s "$output" ]] || die "下载为空：$url"
}

architecture() {
    case "$(uname -m)" in
        x86_64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) die "仅支持 x86_64/amd64 和 aarch64/arm64" ;;
    esac
}

install_xray_binary() {
    local arch current="" asset checksum temp_dir
    arch=$(architecture)
    if [[ -x /usr/local/bin/xray ]]; then
        current=$(/usr/local/bin/xray version 2>/dev/null | sed -n '1p' || true)
    fi
    if grep -q "${XRAY_VERSION#v}" <<<"$current"; then
        info "Xray ${XRAY_VERSION} 已安装"
        return
    fi
    if [[ "$arch" == "amd64" ]]; then
        asset="Xray-linux-64.zip"
        checksum="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
    else
        asset="Xray-linux-arm64-v8a.zip"
        checksum="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"
    fi
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    info "下载并校验 Xray ${XRAY_VERSION}"
    download_file "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${asset}" "$temp_dir/xray.zip"
    sha256_verify "$temp_dir/xray.zip" "$checksum"
    unzip -q "$temp_dir/xray.zip" xray geoip.dat geosite.dat -d "$temp_dir"
    install -m 0755 "$temp_dir/xray" /usr/local/bin/xray
    install -d -m 0755 /usr/local/share/xray
    install -m 0644 "$temp_dir/geoip.dat" "$temp_dir/geosite.dat" /usr/local/share/xray/
}

install_hysteria_binary() {
    local arch current="" asset checksum temp_dir
    arch=$(architecture)
    if [[ -x /usr/local/bin/hysteria ]]; then
        current=$(/usr/local/bin/hysteria version 2>&1 | tr -d '\r' || true)
    fi
    if grep -q "${HYSTERIA_VERSION#app/}" <<<"$current"; then
        info "Hysteria ${HYSTERIA_VERSION#app/} 已安装"
        return
    fi
    if [[ "$arch" == "amd64" ]]; then
        asset="hysteria-linux-amd64"
        checksum="ffc032c7ca6b78676d337097ca7f61bebc3a90a4f3a656693adf368f304cdbc7"
    else
        asset="hysteria-linux-arm64"
        checksum="c9cd1af6395eee13a937f429ea71b290e3cc571eea2b4d7f8bc7c49c1d23a792"
    fi
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    info "下载并校验 Hysteria ${HYSTERIA_VERSION#app/}"
    download_file "https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/${asset}" "$temp_dir/hysteria"
    sha256_verify "$temp_dir/hysteria" "$checksum"
    install -m 0755 "$temp_dir/hysteria" /usr/local/bin/hysteria
}

managed_tree_is_safe() {
    local root=$1
    python3 - "$root" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
try:
    root_stat = os.lstat(root)
except OSError:
    raise SystemExit(1)
if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
    raise SystemExit(1)

root_device = root_stat.st_dev
for directory, directories, files in os.walk(root, followlinks=False):
    for name in directories + files:
        path = os.path.join(directory, name)
        try:
            item = os.lstat(path)
        except OSError:
            raise SystemExit(1)
        if item.st_dev != root_device:
            raise SystemExit(1)
        if stat.S_ISLNK(item.st_mode):
            raise SystemExit(1)
        if stat.S_ISREG(item.st_mode):
            if item.st_nlink != 1:
                raise SystemExit(1)
        elif not stat.S_ISDIR(item.st_mode):
            raise SystemExit(1)
PY
}

normalize_hysteria_acme_ownership() {
    local acme_root=/var/lib/hysteria/acme mismatched=""
    [[ ! -L /var/lib/hysteria && ! -L "$acme_root" ]] || \
        die "Hysteria 数据目录不能是符号链接：$acme_root"
    install -d -m 0750 -o hysteria -g hysteria /var/lib/hysteria "$acme_root"
    managed_tree_is_safe "$acme_root" || \
        die "Hysteria ACME 目录包含链接、特殊文件或跨文件系对象；拒绝自动修改所有权：$acme_root"
    mismatched=$(find "$acme_root" -xdev \( ! -user hysteria -o ! -group hysteria \) \
        -print -quit 2>/dev/null || true)
    if [[ -n "$mismatched" ]]; then
        warn "检测到 Hysteria ACME 遗留所有权，将在不跟随链接的前提下修复：$mismatched"
        find "$acme_root" -xdev \( ! -user hysteria -o ! -group hysteria \) \
            -exec chown --no-dereference hysteria:hysteria {} +
        info "Hysteria ACME 遗留所有权已修复"
    fi
}

ensure_service_users() {
    getent group xray >/dev/null || groupadd --system xray
    id xray >/dev/null 2>&1 || useradd --system --gid xray --home-dir /nonexistent --shell /usr/sbin/nologin xray
    getent group hysteria >/dev/null || groupadd --system hysteria
    id hysteria >/dev/null 2>&1 || useradd --system --gid hysteria --home-dir /var/lib/hysteria --shell /usr/sbin/nologin hysteria
    normalize_hysteria_acme_ownership
    if $ENABLE_CDN; then
        getent group caddy >/dev/null || groupadd --system caddy
        id caddy >/dev/null 2>&1 || useradd --system --gid caddy --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
        install -d -m 0750 -o caddy -g caddy /var/lib/caddy
    fi
}

new_uuid() {
    cat /proc/sys/kernel/random/uuid
}

ensure_secrets() {
    VR_CLASH_UUID="${STATE_VR_CLASH_UUID:-}"
    VR_LOON_UUID="${STATE_VR_LOON_UUID:-}"
    HY2_PASS="${STATE_HY2_PASS:-}"
    XHTTP_UUID="${STATE_XHTTP_UUID:-}"
    XHTTP_PATH="${STATE_XHTTP_PATH:-}"
    WS_UUID="${STATE_WS_UUID:-}"
    WS_PATH="${STATE_WS_PATH:-}"
    SUB_TOKEN="${STATE_SUB_TOKEN:-}"
    REALITY_PRIVKEY="${STATE_REALITY_PRIVKEY:-}"
    REALITY_PUBKEY="${STATE_REALITY_PUBKEY:-}"
    REALITY_SHORTID="${STATE_REALITY_SHORTID:-}"

    valid_uuid "$VR_CLASH_UUID" || VR_CLASH_UUID=$(new_uuid)
    valid_uuid "$VR_LOON_UUID" || VR_LOON_UUID=$(new_uuid)
    [[ "$HY2_PASS" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || HY2_PASS=$(openssl rand -hex 24)
    valid_uuid "$XHTTP_UUID" || XHTTP_UUID=$(new_uuid)
    valid_xhttp_path "$XHTTP_PATH" || XHTTP_PATH="/${XHTTP_UUID%%-*}-xhttp"
    valid_uuid "$WS_UUID" || WS_UUID=$(new_uuid)
    valid_ws_path "$WS_PATH" || WS_PATH="/${WS_UUID%%-*}-ws"
    [[ "$WS_PATH" != "$XHTTP_PATH" ]] || WS_PATH="/${WS_UUID%%-*}-ws"
    [[ "$SUB_TOKEN" =~ ^[a-f0-9]{24,64}$ ]] || SUB_TOKEN=$(openssl rand -hex 18)

    if [[ -z "$REALITY_PRIVKEY" ]]; then
        local keypair
        keypair=$(/usr/local/bin/xray x25519)
        REALITY_PRIVKEY=$(awk -F': ' '/^PrivateKey:/ {print $2}' <<<"$keypair")
        REALITY_PUBKEY=$(awk -F': ' '/PublicKey/ {print $2}' <<<"$keypair")
    elif [[ -z "$REALITY_PUBKEY" ]]; then
        REALITY_PUBKEY=$(/usr/local/bin/xray x25519 -i "$REALITY_PRIVKEY" |
            awk -F': ' '/PublicKey/ {print $2}')
    fi
    [[ "$REALITY_PRIVKEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || die "Reality 私钥生成/迁移失败"
    [[ "$REALITY_PUBKEY" =~ ^[A-Za-z0-9_-]{40,64}$ ]] || die "Reality 公钥生成/推导失败"
    valid_short_id "$REALITY_SHORTID" || REALITY_SHORTID=$(openssl rand -hex 8)
}

probe_reality_target() {
    local output successes
    output=$(timeout 20 /usr/local/bin/xray tls ping "$REALITY_TARGET" 2>&1 || true)
    successes=$(grep -c 'Handshake succeeded' <<<"$output" || true)
    if (( successes < 2 )); then
        err "$output"
        die "Reality target 未同时通过无 SNI/有 SNI TLS 探测；请设置 REALITY_TARGET_ENV"
    fi
    grep -q 'TLS Version:.*TLS 1.3' <<<"$output" || die "Reality target 不支持 TLS 1.3"
    info "Reality target TLS 1.3 探测通过"
}

backup_file() {
    local path=$1 backup_dir
    BACKUP_FILE_PATH=""
    [[ -e "$path" ]] || return 0
    backup_dir="${BACKUP_ROOT}/$(date +%Y%m%dT%H%M%S)"
    install -d -m 0700 "$backup_dir"
    cp -a -- "$path" "$backup_dir/"
    BACKUP_FILE_PATH="${backup_dir}/$(basename "$path")"
    info "已备份 $path → $backup_dir"
}

rollback_config() {
    local config=$1 backup=$2 service=$3
    [[ -n "$backup" && -e "$backup" ]] || return 0
    cp -a -- "$backup" "$config"
    warn "${service} 新配置失败，已恢复备份：${backup}"
    systemctl restart "$service" >/dev/null 2>&1 || \
        warn "${service} 恢复旧配置后仍无法启动，需要人工检查"
}

render_xray_config() {
    local config=$1 cdn_blocks=""
    if $ENABLE_CDN; then
        cdn_blocks=$(cat <<EOF
,
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${XHTTP_UUID}", "email": "cdn"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {"path": "${XHTTP_PATH}"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    },
    {
      "tag": "vless-websocket",
      "listen": "127.0.0.1",
      "port": ${WS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${WS_UUID}", "email": "cdn-websocket"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "websocket",
        "security": "none",
        "wsSettings": {"path": "${WS_PATH}"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    }
EOF
)
    fi
    cat > "$config" <<EOF
{
  "log": {"loglevel": "warning"},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}
    ]
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "${XRAY_LISTEN:-0.0.0.0}",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "${VR_CLASH_UUID}", "flow": "xtls-rprx-vision", "email": "clash"},
          {"id": "${VR_LOON_UUID}", "flow": "xtls-rprx-vision", "email": "loon"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVKEY}",
          "shortIds": ["${REALITY_SHORTID}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
    }${cdn_blocks}
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
EOF
}

write_xray_config() {
    local temp_dir config old_config
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    config="$temp_dir/xray.json"
    render_xray_config "$config"
    XRAY_LOCATION_ASSET=/usr/local/share/xray \
        /usr/local/bin/xray run -test -config "$config" >/dev/null
    install -d -m 0750 -o root -g xray /usr/local/etc/xray
    backup_file /usr/local/etc/xray/config.json
    old_config=$BACKUP_FILE_PATH
    install -m 0640 -o root -g xray "$config" /usr/local/etc/xray/config.json

    cat > /etc/systemd/system/xray.service <<'EOF'
# Managed by vps-deploy.sh v4
[Unit]
Description=Xray proxy service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=xray
Group=xray
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/xray.service
    systemctl daemon-reload
    systemctl enable xray.service >/dev/null
    if ! systemctl restart xray.service || ! systemctl is-active --quiet xray.service; then
        journalctl -u xray.service --no-pager -n 30 >&2 || true
        rollback_config /usr/local/etc/xray/config.json "$old_config" xray.service
        die "Xray 启动失败"
    fi
}

render_hysteria_config() {
    local config=$1 email_line dns_block=""
    email_line="  email: ${EMAIL}"
    if [[ "$ACME_MODE" == "dns" ]]; then
        dns_block=$(cat <<EOF
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: ${CF_DNS_TOKEN}
EOF
)
    fi
    cat > "$config" <<EOF
listen: :${HY2_PORT}

acme:
  domains:
    - ${DOMAIN}
${email_line}
  ca: letsencrypt
  dir: /var/lib/hysteria/acme
  type: ${ACME_MODE}
${dns_block}

auth:
  type: password
  password: ${HY2_PASS}

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
  type: proxy
  proxy:
    url: ${HY2_MASQUERADE_URL}
    rewriteHost: true
    insecure: false
EOF
}

write_hysteria_config() {
    local temp_dir config old_config
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    config="$temp_dir/hysteria.yaml"
    render_hysteria_config "$config"
    install -d -m 0750 -o root -g hysteria /etc/hysteria
    backup_file /etc/hysteria/config.yaml
    old_config=$BACKUP_FILE_PATH
    install -m 0640 -o root -g hysteria "$config" /etc/hysteria/config.yaml

    cat > /etc/systemd/system/hysteria-server.service <<'EOF'
# Managed by vps-deploy.sh v4
[Unit]
Description=Hysteria 2 server
Documentation=https://hysteria.network/
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
User=hysteria
Group=hysteria
WorkingDirectory=/var/lib/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=30s
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/hysteria

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload
    systemctl enable hysteria-server.service >/dev/null
    if ! systemctl restart hysteria-server.service; then
        journalctl -u hysteria-server.service --no-pager -n 30 >&2 || true
        rollback_config /etc/hysteria/config.yaml "$old_config" hysteria-server.service
        die "Hysteria2 无法启动"
    fi

    for _ in $(seq 1 60); do
        if systemctl is-active --quiet hysteria-server.service && \
            ss -H -lun "sport = :${HY2_PORT}" 2>/dev/null | grep -q .; then
            break
        fi
        sleep 3
    done
    if ! systemctl is-active --quiet hysteria-server.service || \
        ! ss -H -lun "sport = :${HY2_PORT}" 2>/dev/null | grep -q .; then
        journalctl -u hysteria-server.service --no-pager -n 30 >&2 || true
        rollback_config /etc/hysteria/config.yaml "$old_config" hysteria-server.service
        die "Hysteria2 启动或 ACME 申请失败"
    fi
    if find /var/lib/hysteria/acme -type f -name '*.crt' -print -quit | grep -q .; then
        info "Hysteria2 证书已就绪"
    else
        warn "Hysteria2 已运行，但未在 ACME 目录中定位到 .crt；请检查日志"
    fi
}

render_caddy_config() {
    local caddyfile=$1
    cat > "$caddyfile" <<EOF
{
	admin off
	auto_https off
}

:${CADDY_ORIGIN_PORT} {
	# 仅绑定回环地址，但接受 Cloudflare 保留的原始 Host。
	bind 127.0.0.1

	@xhttp path ${XHTTP_PATH} ${XHTTP_PATH}/*
	handle @xhttp {
		reverse_proxy 127.0.0.1:${XHTTP_PORT}
	}

	@websocket path ${WS_PATH} ${WS_PATH}/*
	handle @websocket {
		reverse_proxy 127.0.0.1:${WS_PORT}
	}

	handle {
		root * ${SUB_ROOT}
		header {
			Cache-Control "no-store"
			X-Content-Type-Options "nosniff"
		}
		file_server
	}
}
EOF
}

install_caddy_binary() {
    local arch current="" asset checksum temp_dir
    arch=$(architecture)
    if [[ -x /usr/local/bin/caddy ]]; then
        current=$(/usr/local/bin/caddy version 2>/dev/null | awk '{print $1}' || true)
    fi
    if [[ "$current" == "$CADDY_VERSION" ]]; then
        info "Caddy ${CADDY_VERSION} 已安装"
        return
    fi
    if [[ "$arch" == "amd64" ]]; then
        asset="caddy_${CADDY_VERSION#v}_linux_amd64.tar.gz"
        checksum="527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9"
    else
        asset="caddy_${CADDY_VERSION#v}_linux_arm64.tar.gz"
        checksum="52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904"
    fi
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    info "下载并校验 Caddy ${CADDY_VERSION}"
    download_file "https://github.com/caddyserver/caddy/releases/download/${CADDY_VERSION}/${asset}" "$temp_dir/caddy.tar.gz"
    sha256_verify "$temp_dir/caddy.tar.gz" "$checksum"
    tar -xzf "$temp_dir/caddy.tar.gz" -C "$temp_dir" caddy
    install -m 0755 "$temp_dir/caddy" /usr/local/bin/caddy
}

install_caddy() {
    $ENABLE_CDN || return 0
    install_caddy_binary

    local temp_dir caddyfile old_config
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    caddyfile="$temp_dir/Caddyfile"
    render_caddy_config "$caddyfile"
    /usr/local/bin/caddy validate --config "$caddyfile" --adapter caddyfile >/dev/null
    install -d -m 0755 /etc/caddy
    backup_file /etc/caddy/Caddyfile
    old_config=$BACKUP_FILE_PATH
    install -m 0644 -o root -g root "$caddyfile" /etc/caddy/Caddyfile

    cat > /etc/systemd/system/caddy.service <<'EOF'
# Managed by vps-deploy.sh v4
[Unit]
Description=Caddy local origin for vps-proxy
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_DATA_HOME=/var/lib/caddy/.local/share
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/caddy
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 /etc/systemd/system/caddy.service
    systemctl daemon-reload
    systemctl enable caddy.service >/dev/null
    if ! systemctl restart caddy.service || ! systemctl is-active --quiet caddy.service; then
        journalctl -u caddy.service --no-pager -n 30 >&2 || true
        rollback_config /etc/caddy/Caddyfile "$old_config" caddy.service
        die "Caddy 启动失败"
    fi
}

install_cloudflared() {
    $ENABLE_CDN || return 0
    local arch asset checksum temp_dir current="" cloudflared_bin
    arch=$(architecture)
    if command -v cloudflared >/dev/null 2>&1; then
        current=$(cloudflared --version 2>/dev/null || true)
    fi
    if ! grep -q "$CLOUDFLARED_VERSION" <<<"$current"; then
        if [[ "$arch" == "amd64" ]]; then
            asset="cloudflared-linux-amd64.deb"
            checksum="049777d30f9bf93da6df8bbe31383460eb2aa51a832c6551824d56f9fcc55974"
        else
            asset="cloudflared-linux-arm64.deb"
            checksum="d3ea7d22dd337b465da33d6bc1c4b3cfd381407447a2a7d29542c19783430db3"
        fi
        new_temp_dir
        temp_dir=$NEW_TEMP_DIR
        info "下载并校验 cloudflared ${CLOUDFLARED_VERSION}"
        download_file "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/${asset}" "$temp_dir/cloudflared.deb"
        sha256_verify "$temp_dir/cloudflared.deb" "$checksum"
        dpkg -i "$temp_dir/cloudflared.deb" >/dev/null || apt-get install -f -y -qq >/dev/null
    else
        info "cloudflared ${CLOUDFLARED_VERSION} 已安装"
    fi

    if systemctl cat cloudflared.service >/dev/null 2>&1; then
        if [[ -n "$CF_TOKEN" ]]; then
            warn "检测到已有 cloudflared 服务；为避免覆盖其他 Tunnel，忽略新 Token"
        fi
        if systemctl cat cloudflared.service 2>/dev/null | grep -Eq -- '--token(=|[[:space:]]+)eyJ'; then
            warn "现有 cloudflared 单元可能内嵌 Tunnel Token；建议按 MANUAL.md 迁移为 600 权限的 token 文件"
        fi
        systemctl enable --now cloudflared.service >/dev/null || die "现有 cloudflared 服务无法启动"
    else
        [[ -n "$CF_TOKEN" ]] || die "缺少 Tunnel Token，无法注册 cloudflared 服务"
        cloudflared_bin=$(readlink -f "$(command -v cloudflared)")
        [[ "$cloudflared_bin" =~ ^/[A-Za-z0-9_./-]+$ && -x "$cloudflared_bin" ]] || \
            die "cloudflared 可执行文件路径异常"
        install -d -m 0700 -o root -g root /etc/cloudflared
        new_temp_dir
        temp_dir=$NEW_TEMP_DIR
        printf '%s\n' "$CF_TOKEN" > "$temp_dir/tunnel-token"
        install -m 0600 -o root -g root "$temp_dir/tunnel-token" /etc/cloudflared/token
        CF_TOKEN=""
        cat > /etc/systemd/system/cloudflared.service <<EOF
# Managed by vps-deploy.sh v4
[Unit]
Description=Cloudflare Tunnel client
Documentation=https://developers.cloudflare.com/tunnel/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${cloudflared_bin} --no-autoupdate tunnel run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/etc/cloudflared/token

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 /etc/systemd/system/cloudflared.service
        systemctl daemon-reload
        systemctl enable --now cloudflared.service >/dev/null || die "cloudflared 服务安装失败"
    fi
    systemctl is-active --quiet cloudflared.service || die "cloudflared 未运行"
}

write_state_file() {
    local destination=$1
    install -d -m 0700 -o root -g root "$STATE_DIR"
    local temp_dir state
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    state="$temp_dir/state.env"
    {
        printf 'STATE_VERSION=%q\n' "$SCRIPT_VERSION"
        printf 'STATE_DOMAIN=%q\n' "$DOMAIN"
        printf 'STATE_EMAIL=%q\n' "$EMAIL"
        printf 'STATE_ACME_MODE=%q\n' "$ACME_MODE"
        printf 'STATE_CDN_DOMAIN=%q\n' "$CDN_DOMAIN"
        printf 'STATE_COUNTRY=%q\n' "$COUNTRY"
        printf 'STATE_REALITY_TARGET=%q\n' "$REALITY_TARGET"
        printf 'STATE_XRAY_LISTEN=%q\n' "$XRAY_LISTEN"
        printf 'STATE_VR_CLASH_UUID=%q\n' "$VR_CLASH_UUID"
        printf 'STATE_VR_LOON_UUID=%q\n' "$VR_LOON_UUID"
        printf 'STATE_HY2_PASS=%q\n' "$HY2_PASS"
        printf 'STATE_XHTTP_UUID=%q\n' "$XHTTP_UUID"
        printf 'STATE_XHTTP_PATH=%q\n' "$XHTTP_PATH"
        printf 'STATE_WS_UUID=%q\n' "$WS_UUID"
        printf 'STATE_WS_PATH=%q\n' "$WS_PATH"
        printf 'STATE_SUB_TOKEN=%q\n' "$SUB_TOKEN"
        printf 'STATE_REALITY_PRIVKEY=%q\n' "$REALITY_PRIVKEY"
        printf 'STATE_REALITY_PUBKEY=%q\n' "$REALITY_PUBKEY"
        printf 'STATE_REALITY_SHORTID=%q\n' "$REALITY_SHORTID"
    } > "$state"
    install -m 0600 -o root -g root "$state" "$destination"
}

write_pending_state() {
    write_state_file "$PENDING_STATE_FILE"
}

promote_pending_state() {
    state_file_is_safe "$PENDING_STATE_FILE" || die "待提交状态缺失或权限不安全：$PENDING_STATE_FILE"
    mv -f -- "$PENDING_STATE_FILE" "$STATE_FILE"
    chown root:root "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
}

write_subscriptions() {
    local sub_dir="${SUB_ROOT}/${SUB_TOKEN}"
    install -d -m 0750 "$SUB_ROOT" "$sub_dir"
    if [[ $(id -u) -eq 0 ]]; then
        if $ENABLE_CDN; then
            chown root:caddy "$SUB_ROOT" "$sub_dir"
        else
            chown root:root "$SUB_ROOT" "$sub_dir"
        fi
    fi
    local cdn_yaml="" cdn_group="" loon_ws=""
    if $ENABLE_CDN; then
        cdn_yaml=$(cat <<EOF

  - name: "${NODE_PREFIX} VX"
    type: vless
    server: ${CDN_DOMAIN}
    port: 443
    uuid: ${XHTTP_UUID}
    udp: true
    tls: true
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome
    alpn: [h2]
    network: xhttp
    xhttp-opts:
      host: ${CDN_DOMAIN}
      path: ${XHTTP_PATH}
      mode: packet-up
    skip-cert-verify: false

  - name: "${NODE_PREFIX} VW"
    type: vless
    server: ${CDN_DOMAIN}
    port: 443
    uuid: ${WS_UUID}
    udp: true
    tls: true
    servername: ${CDN_DOMAIN}
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${CDN_DOMAIN}
    skip-cert-verify: false
EOF
)
        cdn_group=$(cat <<EOF
      - "${NODE_PREFIX} VX"
      - "${NODE_PREFIX} VW"
EOF
)
        loon_ws="${NODE_PREFIX} VW = VLESS,${CDN_DOMAIN},443,\"${WS_UUID}\",transport=ws,path=${WS_PATH},host=${CDN_DOMAIN},over-tls=true,sni=${CDN_DOMAIN},skip-cert-verify=false,udp=true"
    fi
    cat > "$sub_dir/clash.yaml" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: true

proxies:
  - name: "${NODE_PREFIX} VR"
    type: vless
    server: ${DOMAIN}
    port: ${REALITY_PORT}
    uuid: ${VR_CLASH_UUID}
    udp: true
    tls: true
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    flow: xtls-rprx-vision
    network: tcp
    reality-opts:
      public-key: ${REALITY_PUBKEY}
      short-id: ${REALITY_SHORTID}
    skip-cert-verify: true

  - name: "${NODE_PREFIX} H2"
    type: hysteria2
    server: ${DOMAIN}
    port: ${HY2_PORT}
    password: ${HY2_PASS}
    sni: ${DOMAIN}
    skip-cert-verify: false
    udp: true
${cdn_yaml}

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - "${NODE_PREFIX} VR"
      - "${NODE_PREFIX} H2"
${cdn_group}

rules:
  - MATCH,PROXY
EOF

    cat > "$sub_dir/loon.conf" <<EOF
${NODE_PREFIX} VR = VLESS,${DOMAIN},${REALITY_PORT},"${VR_LOON_UUID}",transport=tcp,flow=xtls-rprx-vision,public-key="${REALITY_PUBKEY}",short-id=${REALITY_SHORTID},over-tls=true,sni=${REALITY_SNI},skip-cert-verify=true,udp=true
${NODE_PREFIX} H2 = Hysteria2,${DOMAIN},${HY2_PORT},"${HY2_PASS}",sni=${DOMAIN},skip-cert-verify=false,udp=true
${loon_ws}
EOF

    cat > "$sub_dir/index.html" <<EOF
<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>${NODE_PREFIX}</title><style>body{max-width:38rem;margin:4rem auto;padding:1rem;background:#0d1117;color:#c9d1d9;font-family:system-ui}a{display:block;margin:.8rem 0;padding:1rem;color:#58a6ff;background:#161b22;border:1px solid #30363d;border-radius:.5rem;text-decoration:none}</style></head><body><h1>${NODE_PREFIX}</h1><a href="clash.yaml">Clash Verge 配置</a><a href="loon.conf">Loon 配置</a><a href="traffic/">流量看板</a></body></html>
EOF

    if $ENABLE_CDN && command -v getent >/dev/null 2>&1 && getent group caddy >/dev/null; then
        chown -R root:caddy "$sub_dir"
        find "$sub_dir" -type d -exec chmod 0750 {} +
        find "$sub_dir" -type f -exec chmod 0640 {} +
    else
        chmod 0700 "$sub_dir"
        chmod 0600 "$sub_dir/clash.yaml" "$sub_dir/loon.conf" "$sub_dir/index.html"
    fi
}

install_traffic_dashboard() {
    local iface sub_traffic iface_quoted traffic_root_quoted sub_traffic_quoted
    iface=$(ip -o route show to default | awk '{print $5; exit}')
    [[ -n "$iface" ]] || iface="eth0"
    sub_traffic="${SUB_ROOT}/${SUB_TOKEN}/traffic"
    install -d -m 0750 "$TRAFFIC_ROOT" "$sub_traffic"
    vnstat --add -i "$iface" >/dev/null 2>&1 || true
    systemctl enable --now vnstat.service >/dev/null 2>&1 || warn "vnstat 服务未启动"

    printf -v iface_quoted '%q' "$iface"
    printf -v traffic_root_quoted '%q' "$TRAFFIC_ROOT"
    printf -v sub_traffic_quoted '%q' "$sub_traffic"

    cat > /usr/local/bin/vps-proxy-traffic.sh <<EOF
#!/usr/bin/env bash
set -u
iface=${iface_quoted}
out=${traffic_root_quoted}
published=${sub_traffic_quoted}
mkdir -p "\$out" "\$published"
vnstati -i "\$iface" -h -o "\$out/hourly.png" >/dev/null 2>&1 || true
vnstati -i "\$iface" -d -o "\$out/daily.png" >/dev/null 2>&1 || true
vnstati -i "\$iface" -m -o "\$out/monthly.png" >/dev/null 2>&1 || true
vnstati -i "\$iface" -s -o "\$out/summary.png" >/dev/null 2>&1 || true
cp -f "\$out"/*.png "\$published"/ 2>/dev/null || true
cat > "\$published/index.html" <<HTML
<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>流量看板</title><style>body{max-width:70rem;margin:auto;padding:1rem;background:#0d1117;color:#c9d1d9;font-family:system-ui}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:1rem}img{max-width:100%;background:#161b22;border:1px solid #30363d}</style></head><body><h1>流量看板</h1><p>网卡：\$iface · 更新时间：\$(date '+%F %T')</p><div class="grid"><img src="summary.png"><img src="hourly.png"><img src="daily.png"><img src="monthly.png"></div></body></html>
HTML
EOF
    chmod 0755 /usr/local/bin/vps-proxy-traffic.sh
    /usr/local/bin/vps-proxy-traffic.sh
    printf '%s\n' '*/5 * * * * root /usr/local/bin/vps-proxy-traffic.sh' > /etc/cron.d/vps-proxy-traffic
    chmod 0644 /etc/cron.d/vps-proxy-traffic
    if $ENABLE_CDN; then
        chown -R root:caddy "$sub_traffic"
        find "$sub_traffic" -type d -exec chmod 0750 {} +
        find "$sub_traffic" -type f -exec chmod 0640 {} +
    else
        chmod -R go-rwx "$sub_traffic"
    fi
}

setup_fail2ban() {
    local attempt
    install -d -m 0755 /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/vps-proxy.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 3
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1d
EOF
    systemctl enable fail2ban.service >/dev/null 2>&1 || \
        warn "fail2ban 无法设为开机启动"
    for attempt in 1 2 3; do
        systemctl restart fail2ban.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet fail2ban.service; then
            info "fail2ban：active"
            return
        fi
        warn "fail2ban 第 ${attempt}/3 次启动尚未就绪"
        systemctl reset-failed fail2ban.service >/dev/null 2>&1 || true
        sleep 1
    done
    warn "fail2ban 启动失败；不影响代理，但应检查 journalctl -u fail2ban"
}

free_local_tcp_port() {
    python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
}

wait_for_socks() {
    local port=$1
    for _ in $(seq 1 20); do
        ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . && return 0
        sleep 0.25
    done
    return 1
}

test_via_socks() {
    local port=$1 result
    result=$(curl -fsS --noproxy '' --connect-timeout 8 --max-time 20 \
        --socks5-hostname "127.0.0.1:${port}" https://api.ipify.org 2>/dev/null || true)
    if ! valid_ip_literal "$result"; then
        result=$(curl -fsS --noproxy '' --connect-timeout 8 --max-time 20 \
            --socks5-hostname "127.0.0.1:${port}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
            awk -F= '$1 == "ip" {print $2; exit}' || true)
    fi
    valid_ip_literal "$result" && printf '%s' "$result"
}

valid_ip_literal() {
    python3 - "$1" <<'PY'
import ipaddress
import sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

render_reality_client_config() {
    local config=$1 port=$2
    cat > "$config" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": ${port}, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "${XRAY_TEST_ADDRESS:-127.0.0.1}", "port": 443, "users": [{"id": "${VR_CLASH_UUID}", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
    "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"serverName": "${REALITY_SNI}", "fingerprint": "chrome", "password": "${REALITY_PUBKEY}", "shortId": "${REALITY_SHORTID}"}}
  }]
}
EOF
}

render_xhttp_client_config() {
    local config=$1 port=$2
    cat > "$config" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": ${port}, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "${CDN_DOMAIN}", "port": 443, "users": [{"id": "${XHTTP_UUID}", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "xhttp",
      "security": "tls",
      "tlsSettings": {"serverName": "${CDN_DOMAIN}", "fingerprint": "chrome", "alpn": ["h2"]},
      "xhttpSettings": {"host": "${CDN_DOMAIN}", "path": "${XHTTP_PATH}", "mode": "packet-up"}
    }
  }]
}
EOF
}

render_ws_client_config() {
    local config=$1 port=$2
    cat > "$config" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": ${port}, "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "${CDN_DOMAIN}", "port": 443, "users": [{"id": "${WS_UUID}", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "websocket",
      "security": "tls",
      "tlsSettings": {"serverName": "${CDN_DOMAIN}", "fingerprint": "chrome", "alpn": ["http/1.1"]},
      "wsSettings": {"host": "${CDN_DOMAIN}", "path": "${WS_PATH}"}
    }
  }]
}
EOF
}

run_xray_socks_test() {
    local config=$1 port=$2 log=$3 pid result
    /usr/local/bin/xray run -test -config "$config" >/dev/null
    /usr/local/bin/xray run -config "$config" >"$log" 2>&1 &
    pid=$!
    CHILD_PIDS+=("$pid")
    wait_for_socks "$port" || {
        sed -n '1,80p' "$log" >&2
        return 1
    }
    result=$(test_via_socks "$port" || true)
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    unregister_child_pid "$pid"
    valid_ip_literal "$result"
}

selftest_reality() {
    local temp_dir config port
    port=$(free_local_tcp_port)
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    config="$temp_dir/reality-client.json"
    render_reality_client_config "$config" "$port"
    run_xray_socks_test "$config" "$port" "$temp_dir/client.log"
}

selftest_xhttp() {
    local temp_dir config port
    port=$(free_local_tcp_port)
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    config="$temp_dir/xhttp-client.json"
    render_xhttp_client_config "$config" "$port"
    run_xray_socks_test "$config" "$port" "$temp_dir/client.log"
}

selftest_ws() {
    local temp_dir config port
    port=$(free_local_tcp_port)
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    config="$temp_dir/ws-client.json"
    render_ws_client_config "$config" "$port"
    run_xray_socks_test "$config" "$port" "$temp_dir/client.log"
}

selftest_hysteria() {
    local temp_dir config port pid result hy2_address
    port=$(free_local_tcp_port)
    new_temp_dir
    temp_dir=$NEW_TEMP_DIR
    config="$temp_dir/hysteria-client.yaml"
    hy2_address=${XRAY_TEST_ADDRESS:-127.0.0.1}
    [[ "$hy2_address" == *:* ]] && hy2_address="[${hy2_address}]"
    cat > "$config" <<EOF
server: ${hy2_address}:${HY2_PORT}
auth: ${HY2_PASS}
tls:
  sni: ${DOMAIN}
  insecure: false
socks5:
  listen: 127.0.0.1:${port}
EOF
    /usr/local/bin/hysteria client -c "$config" >"$temp_dir/client.log" 2>&1 &
    pid=$!
    CHILD_PIDS+=("$pid")
    wait_for_socks "$port" || {
        sed -n '1,80p' "$temp_dir/client.log" >&2
        return 1
    }
    result=$(test_via_socks "$port" || true)
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    unregister_child_pid "$pid"
    valid_ip_literal "$result"
}

health_check() {
    local failed=false service
    CDN_READY=false
    info "执行服务与真实协议验收"
    for service in xray hysteria-server; do
        if systemctl is-active --quiet "$service"; then
            info "${service}：active"
        else
            err "${service}：inactive"
            failed=true
        fi
    done
    if $ENABLE_CDN; then
        for service in caddy cloudflared; do
            if systemctl is-active --quiet "$service"; then
                info "${service}：active"
            else
                err "${service}：inactive"
                failed=true
            fi
        done
        if ! ss -H -ltn "sport = :${CADDY_ORIGIN_PORT}" | grep -Fq "127.0.0.1:${CADDY_ORIGIN_PORT}"; then
            err "Caddy 未按预期仅监听 127.0.0.1:${CADDY_ORIGIN_PORT}"
            failed=true
        fi
        if ! ss -H -ltn "sport = :${XHTTP_PORT}" | grep -Fq "127.0.0.1:${XHTTP_PORT}"; then
            err "XHTTP 未按预期仅监听 127.0.0.1:${XHTTP_PORT}"
            failed=true
        fi
        if ! ss -H -ltn "sport = :${WS_PORT}" | grep -Fq "127.0.0.1:${WS_PORT}"; then
            err "WebSocket 未按预期仅监听 127.0.0.1:${WS_PORT}"
            failed=true
        fi
    fi
    if systemctl is-active --quiet fail2ban.service; then
        info "fail2ban：active"
    else
        warn "fail2ban：inactive；代理可用，但 SSH 暴力尝试防护未就绪"
    fi
    XRAY_LOCATION_ASSET=/usr/local/share/xray \
        /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/dev/null || failed=true
    ss -H -ltn "sport = :443" | grep -q . || failed=true
    ss -H -lun "sport = :443" | grep -q . || failed=true
    if selftest_reality; then
        info "VLESS Reality 真实出站自测：通过"
    else
        err "VLESS Reality 真实出站自测：失败"
        failed=true
    fi
    if selftest_hysteria; then
        info "Hysteria2 真实出站自测：通过"
    else
        err "Hysteria2 真实出站自测：失败"
        failed=true
    fi
    if $ENABLE_CDN; then
        if curl -fsS --noproxy '*' --max-time 8 "http://127.0.0.1:${CADDY_ORIGIN_PORT}/${SUB_TOKEN}/clash.yaml" >/dev/null; then
            info "Caddy 本地订阅：通过"
        else
            err "Caddy 本地订阅：失败"
            failed=true
        fi
        if curl -fsS --noproxy '*' --max-time 12 "https://${CDN_DOMAIN}/${SUB_TOKEN}/clash.yaml" >/dev/null; then
            info "Cloudflare HTTPS 订阅：通过"
            local cdn_protocols_ok=true
            if selftest_xhttp; then
                info "VLESS XHTTP/Cloudflare 真实出站自测：通过"
            else
                err "VLESS XHTTP/Cloudflare 真实出站自测：失败"
                failed=true
                cdn_protocols_ok=false
            fi
            if selftest_ws; then
                info "VLESS WebSocket/Cloudflare 真实出站自测：通过"
            else
                err "VLESS WebSocket/Cloudflare 真实出站自测：失败"
                failed=true
                cdn_protocols_ok=false
            fi
            if $cdn_protocols_ok; then
                CDN_READY=true
            fi
        else
            warn "Cloudflare HTTPS 订阅尚不可达；请完成 Published application 路由后运行 --check"
        fi
    fi
    if $failed; then
        die "关键验收失败；不要把摘要当作部署成功"
    fi
}

print_summary() {
    if $ENABLE_CDN && ! ${CDN_READY:-false}; then
        printf '\n%b直连协议部署与自测通过；CDN 等待外部配置%b\n' "$YELLOW" "$NC"
    else
        printf '\n%b部署与已启用协议的真实出站自测均通过%b\n' "$GREEN" "$NC"
    fi
    printf '  Reality：%s:443/tcp\n' "$DOMAIN"
    printf '  Hysteria2：%s:443/udp\n' "$DOMAIN"
    if $ENABLE_CDN; then
        printf '  XHTTP：%s:443（Cloudflare → http://127.0.0.1:%s）\n' "$CDN_DOMAIN" "$CADDY_ORIGIN_PORT"
        printf '  WebSocket：%s:443（Cloudflare → http://127.0.0.1:%s）\n' "$CDN_DOMAIN" "$CADDY_ORIGIN_PORT"
        printf '  Clash：https://%s/%s/clash.yaml\n' "$CDN_DOMAIN" "$SUB_TOKEN"
        printf '  Loon：https://%s/%s/loon.conf\n' "$CDN_DOMAIN" "$SUB_TOKEN"
        printf '\nCloudflare Published application 必须设置为：\n'
        printf '  %s → http://127.0.0.1:%s\n' "$CDN_DOMAIN" "$CADDY_ORIGIN_PORT"
    else
        printf '  Clash 文件：%s/%s/clash.yaml\n' "$SUB_ROOT" "$SUB_TOKEN"
        printf '  Loon 文件：%s/%s/loon.conf\n' "$SUB_ROOT" "$SUB_TOKEN"
        printf '  未启用 CDN；Loon 配置只含官方支持的 Reality 与 Hysteria2。\n'
    fi
    printf '\n只读复检：sudo bash %s --check\n' "$0"
    printf '说明：脚本验证协议可用性；客户端到 VPS 的 <100ms 延迟取决于物理距离和线路，无法由脚本保证。\n'
}

load_check_state() {
    [[ -f "$STATE_FILE" ]] || die "未找到 v4 状态文件：$STATE_FILE"
    load_state
    DOMAIN=${STATE_DOMAIN:?}
    EMAIL=${STATE_EMAIL:?}
    ACME_MODE=${STATE_ACME_MODE:?}
    CDN_DOMAIN=${STATE_CDN_DOMAIN:-}
    COUNTRY=${STATE_COUNTRY:-XX}
    REALITY_TARGET=${STATE_REALITY_TARGET:?}
    REALITY_SNI=${REALITY_TARGET%:*}
    XRAY_LISTEN=${STATE_XRAY_LISTEN:-0.0.0.0}
    [[ "$XRAY_LISTEN" == "::" ]] && XRAY_TEST_ADDRESS="::1" || XRAY_TEST_ADDRESS="127.0.0.1"
    FLAG=$(python3 - "$COUNTRY" <<'PY'
import sys
c=sys.argv[1]
print(''.join(chr(0x1F1E6 + ord(x)-65) for x in c) if len(c)==2 and c!='XX' else '🏳️')
PY
)
    NODE_PREFIX="${FLAG} ${COUNTRY}"
    VR_CLASH_UUID=${STATE_VR_CLASH_UUID:?}
    VR_LOON_UUID=${STATE_VR_LOON_UUID:?}
    HY2_PASS=${STATE_HY2_PASS:?}
    XHTTP_UUID=${STATE_XHTTP_UUID:-}
    XHTTP_PATH=${STATE_XHTTP_PATH:-}
    WS_UUID=${STATE_WS_UUID:-}
    WS_PATH=${STATE_WS_PATH:-}
    SUB_TOKEN=${STATE_SUB_TOKEN:?}
    REALITY_PRIVKEY=${STATE_REALITY_PRIVKEY:?}
    REALITY_PUBKEY=${STATE_REALITY_PUBKEY:?}
    REALITY_SHORTID=${STATE_REALITY_SHORTID:?}
    [[ -n "$CDN_DOMAIN" ]] && ENABLE_CDN=true || ENABLE_CDN=false
    if $ENABLE_CDN; then
        if ! valid_uuid "$XHTTP_UUID" || ! valid_xhttp_path "$XHTTP_PATH" || \
            ! valid_uuid "$WS_UUID" || ! valid_ws_path "$WS_PATH"; then
            die "CDN 状态缺失或损坏；从 v4.0 升级后请先运行一次安装模式，再使用 --check"
        fi
    fi
}

main() {
    parse_args "$@"
    require_platform
    if [[ "$MODE" == "check" ]]; then
        load_check_state
        health_check
        print_summary
        return
    fi

    load_state
    configure_inputs
    mark_install_phase validated
    install_dependencies
    detect_region
    detect_ssh_port
    verify_direct_dns
    preflight_ports
    mark_install_phase system-changes
    optimize_system
    setup_firewall

    install_xray_binary
    install_hysteria_binary
    ensure_service_users
    ensure_secrets
    write_pending_state
    mark_install_phase service-configuration
    probe_reality_target
    write_xray_config
    write_hysteria_config
    install_caddy
    write_subscriptions
    install_traffic_dashboard
    mark_install_phase tunnel-and-security
    install_cloudflared
    # 流量看板刚写入了新文件，再次统一 Caddy 的只读权限。
    if $ENABLE_CDN; then
        chown -R root:caddy "${SUB_ROOT}/${SUB_TOKEN}"
        find "${SUB_ROOT}/${SUB_TOKEN}" -type d -exec chmod 0750 {} +
        find "${SUB_ROOT}/${SUB_TOKEN}" -type f -exec chmod 0640 {} +
    fi
    setup_fail2ban
    mark_install_phase verification
    health_check
    promote_pending_state
    clear_install_phase
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
