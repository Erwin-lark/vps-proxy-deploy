#!/bin/bash
#==============================================================================
#  VPS 一键部署脚本 — 三协议代理 + 流量监控 + 订阅生成
#
#  ██ 交互式安装:                                 ██
#  curl -sLo vps-deploy.sh https://tinyurl.com/vps-proxy-deploy && sudo bash vps-deploy.sh
#
#  ██ 一键安装（跳过交互，直接传参）:                ██
#  curl -sLo vps-deploy.sh https://tinyurl.com/vps-proxy-deploy && sudo bash vps-deploy.sh my.example.com PROVIDER
#
#  ██ 断点续传：中断后重新运行，已安装的服务自动跳过 ██
#
#  支持: Ubuntu 20.04/22.04/24.04, Debian 11/12
#  需要: root 权限, 至少 1GB 内存
#==============================================================================
# set -e 已移除：非致命错误不中断部署，用 || true 和 || warn 处理

#==============================================================================
#  ██████  交互式配置 ██████
#==============================================================================
setup_config() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   VPS 三协议代理一键部署脚本            ║"
    echo "  ║   VLESS Reality + Hysteria2 + VLESS XHTTP ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"

    # ═══════════════════════════════════════════════════
    # 前置检查：在所有操作之前确认 Cloudflare 已就绪
    # ═══════════════════════════════════════════════════
    if [ -n "$1" ] && [ -n "$2" ]; then
        info "非交互模式，跳过前置确认"
    else
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ⚠️  运行脚本前，必须完成以下 Cloudflare 操作：  ║${NC}"
        echo -e "${RED}╠════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║                                                    ║${NC}"
        echo -e "${RED}║  ① 添加 DNS A 记录 (灰云 DNS only)                ║${NC}"
        echo -e "${RED}║     你的域名 → VPS IP                              ║${NC}"
        echo -e "${RED}║                                                    ║${NC}"
        echo -e "${RED}║  ② 创建 Cloudflare Tunnel 并复制 Token             ║${NC}"
        echo -e "${RED}║     eyJ 开头的长字符串                             ║${NC}"
        echo -e "${RED}║                                                    ║${NC}"
        echo -e "${RED}║  ③ 配置 Tunnel Public Hostname (必须手动!)         ║${NC}"
        echo -e "${RED}║     cdn-xxx.你的域名 → HTTP → localhost:10001      ║${NC}"
        echo -e "${RED}║                                                    ║${NC}"
        echo -e "${RED}╠════════════════════════════════════════════════════╣${NC}"
        echo -e "${RED}║  ⚠️ 第③步不做 = CDN 节点永远不会通!               ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
        echo ""

        while true; do
            echo -e "${GREEN}以上 3 项是否已完成? [y/N]:${NC}"
            read -p "  > " CF_READY
            case "$CF_READY" in
                y|Y|yes|YES)
                    info "已确认，开始部署"
                    break
                    ;;
                n|N|no|NO|"")
                    echo ""
                    echo -e "${CYAN}请完成以下操作后回来：${NC}"
                    echo ""
                    echo "  🌐 https://dash.cloudflare.com/ → DNS → Add record"
                    echo "     A 记录: 你的域名 → VPS IP，灰云"
                    echo ""
                    echo "  🔗 https://one.dash.cloudflare.com/ → Networks → Tunnels"
                    echo "     Create a tunnel → 复制 Token (eyJ...)"
                    echo ""
                    echo "  ⚙️  Tunnel → Configure → Public Hostname → Add"
                    echo "     Subdomain: cdn-你的域名"
                    echo "     URL 填: localhost:10001"
                    echo ""
                    echo -e "${GREEN}完成后输入 y，或输入 q 退出${NC}"
                    read -p "  > " RETRY
                    if [ "$RETRY" = "q" ] || [ "$RETRY" = "Q" ]; then
                        echo "已退出"
                        exit 0
                    fi
                    ;;
                *) echo "请输入 y 或 n" ;;
            esac
        done
    fi

    # ═══════════════════════════════════════════════════
    # 端口预检：检测即将占用的端口是否已被使用
    # ═══════════════════════════════════════════════════
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  端口预检：脚本将占用以下端口${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    PORT_CONFLICTS=""
    _check_port() {
        local port=$1 svc=$2 lifetime=$3
        local proc
        proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | sed 's/users:(("//;s/",.*//' | head -1)
        if [ -n "$proc" ]; then
            echo -e "  ${RED}⚠ 端口 ${port}${NC} (${svc}) ${YELLOW}[${lifetime}]${NC} ← 已被占用: ${proc}"
            PORT_CONFLICTS="${PORT_CONFLICTS}${port} "
        else
            echo -e "  ${GREEN}✓ 端口 ${port}${NC} (${svc}) ${CYAN}[${lifetime}]${NC} ← 空闲"
        fi
    }

    _check_port 443  "VLESS Reality + Hysteria2"        "永久占用"
    _check_port 80   "Hysteria ACME 证书验证"            "临时 → 获证后恢复"
    _check_port 8443 "Caddy 订阅门户"                    "永久占用"
    _check_port 10001 "VLESS XHTTP (内部)"               "永久占用"

    if [ -n "$PORT_CONFLICTS" ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  ⚠  端口冲突说明：${NC}"
        echo -e "${YELLOW}  [永久占用] 端口将被脚本长期占用，原服务不会恢复${NC}"
        echo -e "${YELLOW}  [临时→恢复] 仅安装期间暂停，证书完成后自动恢复${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo ""
        echo -e "${GREEN}  所有端口空闲，无冲突 ✅${NC}"
    fi
    echo ""

    # 非交互模式跳过确认；交互模式等待回车
    if [ -z "$1" ] || [ -z "$2" ]; then
        read -p "  继续部署? [回车继续 / q 退出]: " PORT_OK
        if [ "$PORT_OK" = "q" ] || [ "$PORT_OK" = "Q" ]; then
            echo "已退出"
            exit 0
        fi
    fi

    # 域名（四种方式：环境变量 > 命令行 > 交互输入 > stdin）
    if [ -n "${DOMAIN_ENV:-}" ]; then
        DOMAIN="$DOMAIN_ENV"
    elif [ -n "$1" ]; then
        DOMAIN="$1"
    else
        while true; do
            echo ""
            echo -e "${GREEN}请输入域名:${NC}"
            read -p "  > " DOMAIN
            DOMAIN=$(echo "$DOMAIN" | sed 's|^https\?://||; s|/\+$||')
            # 验证域名格式（防止注入 + 确保配置合法）
            if [ -n "$DOMAIN" ] && echo "$DOMAIN" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
                break
            fi
            [ -z "$DOMAIN" ] && echo -e "${RED}域名不能为空，请重新输入${NC}"
            [ -n "$DOMAIN" ] && echo -e "${RED}域名格式无效（如 example.com），请重新输入${NC}"
            DOMAIN=""
        done
    fi

    # 服务商代码 — 自动从域名提取
    AUTO_PROVIDER=""
    if [ -n "$DOMAIN" ]; then
        # 取域名第一段，尝试从地区-服务商格式提取（如 jp-bvl → BVL）
        FIRST_LABEL=$(echo "$DOMAIN" | cut -d. -f1)
        if echo "$FIRST_LABEL" | grep -q '-'; then
            # 格式: us-gcp → 取 gcp
            AUTO_PROVIDER=$(echo "$FIRST_LABEL" | cut -d- -f2- | tr '[:lower:]' '[:upper:]')
        fi
    fi

    if [ -n "${PROVIDER_ENV:-}" ]; then
        PROVIDER="$PROVIDER_ENV"
    elif [ -n "$2" ]; then
        PROVIDER="$2"
    elif [ -n "$AUTO_PROVIDER" ]; then
        echo ""
        echo -e "${GREEN}检测到服务商代码: ${CYAN}${AUTO_PROVIDER}${NC}"
        read -p "  确认? [回车确认 / n 重新输入]: " CONFIRM_PROV
        if [ "$CONFIRM_PROV" = "n" ] || [ "$CONFIRM_PROV" = "N" ]; then
            while true; do
                read -p "  请输入服务商代码: " PROVIDER
                [ -n "$PROVIDER" ] && break
            done
            PROVIDER=$(echo "$PROVIDER" | tr '[:lower:]' '[:upper:]')
        else
            PROVIDER="$AUTO_PROVIDER"
        fi
    else
        while true; do
            echo ""
            echo -e "${GREEN}请输入服务商代码 (如 BVL / HZ / AWS):${NC}"
            read -p "  > " PROVIDER
            [ -n "$PROVIDER" ] && break
            echo -e "${RED}服务商代码不能为空，请重新输入${NC}"
        done
    fi
    [ -z "$PROVIDER" ] && PROVIDER="VPS"

    echo ""
    info "域名:     ${DOMAIN}"
    info "服务商:   ${PROVIDER}"

    # SSH 端口
    SSH_OLD_PORT=$(grep -oP '^Port\s+\K\d+' /etc/ssh/sshd_config 2>/dev/null || echo "22")
    [ -z "$SSH_OLD_PORT" ] && SSH_OLD_PORT=22

    # 非交互模式不询问，保持当前端口
    if [ -n "$1" ] && [ -n "$2" ]; then
        SSH_PORT="$SSH_OLD_PORT"
        info "SSH 端口: ${SSH_PORT} (保持当前)"
    else
        echo ""
        if [ "$SSH_OLD_PORT" = "22" ]; then
            echo -e "${YELLOW}当前 SSH 端口: 22（默认端口，容易被暴力扫描）${NC}"
            echo -e "${GREEN}建议修改为随机高端口以提高安全性，是否修改? [y/N]:${NC}"
            read -p "  > " CHANGE_SSH
            if [ "$CHANGE_SSH" = "y" ] || [ "$CHANGE_SSH" = "Y" ]; then
                SSH_PORT=$((22000 + RANDOM % 2000))
                info "SSH 将在部署最后阶段修改为 ${SSH_PORT}"
            else
                SSH_PORT=22
                info "SSH 端口保持 22"
            fi
        else
            SSH_PORT="$SSH_OLD_PORT"
            info "SSH 端口: ${SSH_PORT} (保持当前)"
        fi
    fi

    # Email（环境变量 > 命令行参数 > 交互输入）
    EMAIL="${EMAIL_ENV:-${3:-}}"
    if [ -z "$1" ] || [ -z "$2" ]; then
        while true; do
            echo ""
            echo -e "${GREEN}Let's Encrypt 通知邮箱 (必须有效):${NC}"
            [ -n "$EMAIL" ] && echo -e "  回车使用默认: ${CYAN}${EMAIL}${NC}"
            read -p "  > " EMAIL_INPUT
            [ -n "$EMAIL_INPUT" ] && EMAIL="$EMAIL_INPUT"
            # 验证邮箱包含 @ 和 .
            if echo "$EMAIL" | grep -q '@.*\.'; then
                break
            fi
            echo -e "${RED}邮箱格式无效，必须包含 @ 和域名 (如 admin@gmail.com)${NC}"
            EMAIL=""
        done
    fi
    # 非交互模式：用环境变量或安全默认值
    [ -z "$EMAIL" ] && EMAIL="${EMAIL_ENV:-admin@${DOMAIN#*.}}"
    # 如果域名解析失败导致的无效默认，最后兜底
    echo "$EMAIL" | grep -q '@.*\.' || EMAIL="admin@vps.local"

    # 其余固定配置
    REALITY_PORT=443
    HY2_PORT=443
    CADDY_PORT=8443
    XHTTP_PORT=10001
    CLIENT_COUNT=3
    CLIENT_NAMES=("mac" "windows" "iphone")
    PROTO_VR="VR"
    PROTO_H2="H2"
    PROTO_VX="VX"
    REALITY_TARGET="www.nic.ad.jp:443"
    HY2_MASQUERADE_URL="https://www.nic.ad.jp/"
    ACME_MODE="${ACME_MODE_ENV:-http}"          # http 或 dns（dns 需要 CF_DNS_TOKEN）
    CF_DNS_TOKEN="${CF_DNS_TOKEN_ENV:-}"        # DNS-01 模式需要的 Cloudflare API Token
    SUB_TOKEN=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 36)
}

#==============================================================================
#  ██████ 自动检测：国家 + 国旗 + 伪装目标 ██████
#==============================================================================
auto_detect_region() {
    step "自动检测地区"

    # 方法1: ip-api.com（免费，不需要 key）
    local geo
    geo=$(curl -s --max-time 5 http://ip-api.com/json/ 2>/dev/null || true)

    if [ -n "$geo" ] && echo "$geo" | grep -q '"countryCode"'; then
        COUNTRY=$(echo "$geo" | python3 -c "import sys,json; print(json.load(sys.stdin).get('countryCode','XX'))" 2>/dev/null || echo "XX")
    fi

    # 方法2: 如果 ip-api 失败，用 ifconfig 推断
    if [ -z "$COUNTRY" ] || [ "$COUNTRY" = "XX" ]; then
        local ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || true)
        if [ -n "$ip" ]; then
            geo=$(curl -s --max-time 5 "http://ip-api.com/json/$ip" 2>/dev/null || true)
            COUNTRY=$(echo "$geo" | python3 -c "import sys,json; print(json.load(sys.stdin).get('countryCode','XX'))" 2>/dev/null || echo "XX")
        fi
    fi

    # 国家码 → 国旗 emoji (ISO 3166-1 alpha-2 → Unicode Regional Indicator)
    FLAG=$(python3 -c "
import sys
code = '${COUNTRY}'.upper()
if len(code) == 2 and code.isalpha():
    flag = chr(0x1F1E6 + ord(code[0]) - ord('A')) + chr(0x1F1E6 + ord(code[1]) - ord('A'))
    print(flag)
else:
    print('🏳️')
" 2>/dev/null || echo "🏳️")

    NODE_PREFIX="${FLAG} ${COUNTRY} ${PROVIDER}"

    # 根据地区自动选 Reality 伪装目标
    case "$COUNTRY" in
        JP) REALITY_TARGET="www.nic.ad.jp:443"
            HY2_MASQUERADE_URL="https://www.nic.ad.jp/" ;;
        HK) REALITY_TARGET="www.hk01.com:443"
            HY2_MASQUERADE_URL="https://www.hk01.com/" ;;
        SG) REALITY_TARGET="www.channelnewsasia.com:443"
            HY2_MASQUERADE_URL="https://www.channelnewsasia.com/" ;;
        US) REALITY_TARGET="www.bing.com:443"
            HY2_MASQUERADE_URL="https://www.bing.com/" ;;
        KR) REALITY_TARGET="www.naver.com:443"
            HY2_MASQUERADE_URL="https://www.naver.com/" ;;
        DE) REALITY_TARGET="www.spiegel.de:443"
            HY2_MASQUERADE_URL="https://www.spiegel.de/" ;;
        GB) REALITY_TARGET="www.bbc.com:443"
            HY2_MASQUERADE_URL="https://www.bbc.com/" ;;
        *)  REALITY_TARGET="www.bing.com:443"
            HY2_MASQUERADE_URL="https://www.bing.com/" ;;
    esac

    info "国家: $COUNTRY | 国旗: $FLAG | 伪装: ${REALITY_TARGET%:*}"
    info "节点前缀: $NODE_PREFIX"
}

#==============================================================================
#  ██████ 颜色输出 ██████
#==============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR]${NC}   $*"; }
step()  { STEP=$((STEP + 1)); echo -e "\n${CYAN}==== [$STEP/$TOTAL] $* ====${NC}"; }

# 临时释放端口（保存占用者信息，稍后自动恢复）
KILLED_PORTS=""
STOPPED_SERVICES=""

_kill_port() {
    local port=$1 label=$2 permanent=${3:-false}
    local pids
    pids=$(fuser ${port}/tcp 2>/dev/null | tr -d ' ')
    if [ -z "$pids" ]; then
        return 0
    fi

    # 逐个 PID 找出所属 systemd 服务，记录并临时停止
    for pid in $pids; do
        local svc
        svc=$(ps -p $pid -o pid=,comm= 2>/dev/null | awk '{print $2}')
        # 尝试找到 systemd 服务名
        local unit
        unit=$(systemctl status $pid 2>/dev/null | head -1 | grep -oP '● \K[^ ]+' | sed 's/\.service$//')
        if [ -n "$unit" ] && systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl stop "$unit" 2>/dev/null || true
            if ! $permanent; then
                STOPPED_SERVICES="${STOPPED_SERVICES}${unit} "
                KILLED_PORTS="${KILLED_PORTS}  ${YELLOW}端口 ${port}${NC} → 暂停 ${unit} (${label}临时需要) → ${GREEN}稍后自动恢复${NC}\n"
            else
                KILLED_PORTS="${KILLED_PORTS}  ${RED}端口 ${port}${NC} → 已停止 ${unit} (${label}永久占用)${NC}\n"
            fi
        else
            fuser -k ${port}/tcp 2>/dev/null || true
            KILLED_PORTS="${KILLED_PORTS}  ${RED}端口 ${port}${NC} → 进程 ${svc:-未知} (${label}需要) → ${YELLOW}无法自动恢复${NC}\n"
        fi
    done
    sleep 1
}

# 恢复被临时暂停的服务
_restore_ports() {
    for unit in $STOPPED_SERVICES; do
        systemctl start "$unit" 2>/dev/null && info "已恢复 ${unit}" || warn "恢复 ${unit} 失败"
    done
    STOPPED_SERVICES=""
}

# 注册退出信号处理器（防止中途断线导致端口永久丢失）
trap '_restore_ports' INT TERM

#==============================================================================
#  ██████ 系统检测 ██████
#==============================================================================
check_system() {
    step "系统检测"
    [ "$(id -u)" -ne 0 ] && err "请用 root 运行: sudo bash $0" && exit 1

    # 确保 python3 可用（后续 auto_detect_region 等需要）
    if ! command -v python3 >/dev/null 2>&1; then
        apt-get update -qq > /dev/null 2>&1
        apt-get install -y -qq python3 > /dev/null 2>&1 || warn "python3 安装失败，部分功能退化"
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        info "系统: $NAME $VERSION_ID"
        case "$ID" in
            ubuntu|debian) ;;
            *) err "不支持的系统: $ID（仅支持 Ubuntu/Debian）" ; exit 1 ;;
        esac
    else
        err "无法检测系统版本" && exit 1
    fi

    TOTAL_MEM=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    info "内存: ${TOTAL_MEM}MB"
    [ "$TOTAL_MEM" -lt 900 ] && warn "内存不足 1GB，部分服务可能不稳定"

    info "系统检测通过"
}

#==============================================================================
#  ██████ 系统优化 ██████
#==============================================================================
optimize_system() {
    step "系统优化"

    local SYSCTL_FILE=/etc/sysctl.d/99-vps-proxy.conf

    # 幂等写入：先移除旧文件，避免重复追加
    rm -f "$SYSCTL_FILE"

    # 启用 BBR
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
        cat >> "$SYSCTL_FILE" << EOF
# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        info "BBR 已启用"
    else
        warn "BBR 不可用，跳过"
    fi

    # TCP 优化
    cat >> "$SYSCTL_FILE" << EOF
# TCP Fast Open（双向）
net.ipv4.tcp_fastopen = 3
# 小包即时推送（降低交互延迟）
net.ipv4.tcp_notsent_lowat = 16384
# 空闲连接不降速
net.ipv4.tcp_slow_start_after_idle = 0
# TCP 缓冲区（适配高延迟跨境链路）
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 16384 4194304
# TCP keepalive（死连接快速回收）
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 3
# 减少 swap（代理服务器不应 swap）
vm.swappiness = 10
EOF

    sysctl --system > /dev/null 2>&1
    info "内核参数已优化: BBR TFO=3 keepalive=600s rmem=16M swappiness=10"

    # journald 日志大小限制
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-limit.conf << EOF
[Journal]
SystemMaxUse=100M
EOF
    systemctl restart systemd-journald > /dev/null 2>&1 || true
    info "日志限额: journald 100M"
}

#==============================================================================
#  ██████ 安装依赖 ██████
#==============================================================================
install_deps() {
    step "安装依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget unzip openssl cron ufw \
        python3 locales iputils-ping gnupg psmisc > /dev/null 2>&1

    # locale
    locale-gen en_US.UTF-8 > /dev/null 2>&1 || true
    update-locale LANG=en_US.UTF-8 > /dev/null 2>&1 || true

    info "依赖安装完成"
}

#==============================================================================
#  ██████ 防火墙 ██████
#==============================================================================
setup_firewall() {
    step "防火墙"

    # 首次安装做 reset；重跑时幂等添加缺失规则
    if ! ufw status | grep -q "SSH" 2>/dev/null; then
        ufw --force reset > /dev/null 2>&1
        ufw default deny incoming > /dev/null
        ufw default allow outgoing > /dev/null
    fi

    # 同时放行新旧 SSH 端口，防止 SSH 切换中途锁死
    ufw allow "$SSH_OLD_PORT/tcp" comment "SSH (current)" > /dev/null 2>&1
    if [ "$SSH_PORT" != "$SSH_OLD_PORT" ]; then
        ufw allow "$SSH_PORT/tcp" comment "SSH (new)" > /dev/null 2>&1
    fi
    ufw allow "$REALITY_PORT/tcp" comment "VLESS Reality" > /dev/null
    ufw allow "$HY2_PORT/udp" comment "Hysteria2" > /dev/null
    ufw allow "$CADDY_PORT/tcp" comment "HTTPS Subscription" > /dev/null

    ufw --force enable > /dev/null 2>&1
    info "防火墙已配置 (SSH:${SSH_OLD_PORT}→${SSH_PORT} Reality:${REALITY_PORT}/tcp Hy2:${HY2_PORT}/udp Caddy:${CADDY_PORT})"
}

#==============================================================================
#  ██████ 生成密钥和 UUID ██████
#==============================================================================
generate_keys() {
    # 不调用 step()，由 main() 统一管理步骤计数

    # VLESS XHTTP CDN 备用 UUID
    XHTTP_UUID=$(cat /proc/sys/kernel/random/uuid)
    XHTTP_PATH="/$(echo "$XHTTP_UUID" | cut -d- -f1)-xhttp"

    # 客户端 VLESS UUID
    VL_UUIDS=()
    for i in $(seq 1 $CLIENT_COUNT); do
        VL_UUIDS+=($(cat /proc/sys/kernel/random/uuid))
    done

    # Hysteria2 密码
    HY2_PASS=$(openssl rand -hex 24)

    info "密钥生成完成 (${CLIENT_COUNT} VLESS Reality + 1 VLESS XHTTP)"
}

#==============================================================================
#  ██████ 安装 Xray (VLESS Reality + VLESS XHTTP) ██████
#==============================================================================
install_xray() {
    step "安装 Xray"

    # 安装（官方脚本 + 直链兜底）
    local xray_ok=false
    bash -c "$(curl -sL --retry 3 --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
        --version latest > /dev/null 2>&1 && xray_ok=true
    if ! $xray_ok; then
        warn "官方脚本安装失败，尝试直接下载..."
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && ARCH="64"
        [ "$ARCH" = "aarch64" ] && ARCH="arm64-v8a"
        curl -sL --retry 3 --max-time 120 -o /tmp/xray.zip \
            "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        if [ -s /tmp/xray.zip ] && file /tmp/xray.zip 2>/dev/null | grep -q "Zip archive"; then
            unzip -o /tmp/xray.zip -d /usr/local/bin/ xray 2>/dev/null || true
            chmod +x /usr/local/bin/xray 2>/dev/null
            mkdir -p /usr/local/etc/xray
            rm -f /tmp/xray.zip
            [ -x /usr/local/bin/xray ] && xray_ok=true
        fi
        rm -f /tmp/xray.zip
    fi

    if ! $xray_ok; then
        err "Xray 安装失败！请检查网络连接（GitHub 可达性）"
        err "如果在中国大陆，请先配置代理后重试"
        return 1
    fi

    # Reality 密钥
    REALITY_KEYPAIR=$(/usr/local/bin/xray x25519 2>/dev/null)
    REALITY_PRIVKEY=$(echo "$REALITY_KEYPAIR" | grep "Private" | awk '{print $NF}')
    REALITY_PUBKEY=$(echo "$REALITY_KEYPAIR" | grep "Public" | awk '{print $NF}')
    REALITY_SHORTID=$(openssl rand -hex 8)

    # 构建客户端列表 JSON
    CLIENT_JSON=""
    for i in $(seq 0 $((CLIENT_COUNT - 1))); do
        [ -n "$CLIENT_JSON" ] && CLIENT_JSON+=","
        CLIENT_JSON+="{\"id\":\"${VL_UUIDS[$i]}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"${CLIENT_NAMES[$i]}\"}"
    done

    # 若官方脚本未创建 systemd，手动创建
    if [ ! -f /etc/systemd/system/xray.service ]; then
        cat > /etc/systemd/system/xray.service << SVCEOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
SVCEOF
        systemctl daemon-reload
    fi

    # 下载 geo 数据文件（DNS 分流 + 路由规则需要）
    info "下载 geo 数据文件..."
    mkdir -p /usr/local/share/xray
    GEO_OK=true
    curl -sLo /usr/local/share/xray/geosite.dat --retry 3 --retry-delay 10 \
        https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat || GEO_OK=false
    curl -sLo /usr/local/share/xray/geoip.dat --retry 3 --retry-delay 10 \
        https://github.com/v2fly/geoip/releases/latest/download/geoip.dat || GEO_OK=false
    if $GEO_OK; then
        ln -sf /usr/local/share/xray/geosite.dat /usr/local/bin/geosite.dat
        ln -sf /usr/local/share/xray/geoip.dat /usr/local/bin/geoip.dat
        info "geo 数据下载完成"
    else
        warn "geo 数据下载失败，将使用无 geo 路由的精简配置"
    fi

    # 写入配置（VLESS Reality + VLESS XHTTP + DNS + Routing）
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json << XEOF
{
  "log": {"loglevel": "info"},
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "::",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [${CLIENT_JSON}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "xver": 0,
          "serverNames": ["$(echo ${REALITY_TARGET} | cut -d: -f1)"],
          "privateKey": "${REALITY_PRIVKEY}",
          "shortIds": ["${REALITY_SHORTID}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true}
    },
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${XHTTP_UUID}", "email": "vless-cdn"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls"]}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
XEOF

    # 自动重启
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/restart.conf << EOF
[Service]
Restart=on-failure
RestartSec=5s
EOF

    # geo 下载失败时移除 geo 路由规则（否则 Xray 无法启动）
    if ! $GEO_OK; then
        python3 -c "
import json
c = json.load(open('/usr/local/etc/xray/config.json'))
del c['routing']
c['dns'] = {'servers': ['1.1.1.1', '8.8.8.8', 'localhost']}
json.dump(c, open('/usr/local/etc/xray/config.json', 'w'), indent=2)
" 2>/dev/null || true
        info "已降级为无 geo 路由配置"
    fi

    systemctl daemon-reload
    # 记录并释放 443 端口
    _kill_port 443 "Xray" true
    sleep 1
    systemctl enable --now xray > /dev/null 2>&1
    systemctl is-active --quiet xray && info "Xray 已启动 (VLESS Reality + VLESS XHTTP)" || err "Xray 启动失败"
}

# 仅更新配置（Xray 二进制已安装时）
install_xray_config_only() {
    # 优先复用已有 Reality 密钥（避免客户端断连）
    if [ -f /usr/local/etc/xray/config.json ] && grep -q '"privateKey"' /usr/local/etc/xray/config.json 2>/dev/null; then
        REALITY_PRIVKEY=$(python3 -c "import json;c=json.load(open('/usr/local/etc/xray/config.json'));print(c['inbounds'][0]['streamSettings']['realitySettings']['privateKey'])" 2>/dev/null)
        REALITY_SHORTID=$(python3 -c "import json;c=json.load(open('/usr/local/etc/xray/config.json'));print(c['inbounds'][0]['streamSettings']['realitySettings']['shortIds'][0])" 2>/dev/null)
        # 从私钥推导公钥
        REALITY_PUBKEY=$(echo "$REALITY_PRIVKEY" | /usr/local/bin/xray x25519 -i 2>/dev/null | grep "Public" | awk '{print $NF}')
        [ -n "$REALITY_PRIVKEY" ] && info "复用已有 Reality 密钥" || {
            warn "读取旧密钥失败，生成新密钥"
            REALITY_KEYPAIR=$(/usr/local/bin/xray x25519 2>/dev/null)
            REALITY_PRIVKEY=$(echo "$REALITY_KEYPAIR" | grep "Private" | awk '{print $NF}')
            REALITY_PUBKEY=$(echo "$REALITY_KEYPAIR" | grep "Public" | awk '{print $NF}')
            REALITY_SHORTID=$(openssl rand -hex 8)
        }
    else
        REALITY_KEYPAIR=$(/usr/local/bin/xray x25519 2>/dev/null)
        REALITY_PRIVKEY=$(echo "$REALITY_KEYPAIR" | grep "Private" | awk '{print $NF}')
        REALITY_PUBKEY=$(echo "$REALITY_KEYPAIR" | grep "Public" | awk '{print $NF}')
        REALITY_SHORTID=$(openssl rand -hex 8)
    fi

    CLIENT_JSON=""
    for i in $(seq 0 $((CLIENT_COUNT - 1))); do
        [ -n "$CLIENT_JSON" ] && CLIENT_JSON+=","
        CLIENT_JSON+="{\"id\":\"${VL_UUIDS[$i]}\",\"flow\":\"xtls-rprx-vision\",\"email\":\"${CLIENT_NAMES[$i]}\"}"
    done

    mkdir -p /usr/local/etc/xray

    # 确保 geo 文件存在
    GEO_OK=true
    if [ ! -f /usr/local/bin/geosite.dat ]; then
        info "下载 geo 数据文件..."
        mkdir -p /usr/local/share/xray
        curl -sLo /usr/local/share/xray/geosite.dat --retry 3 --retry-delay 10 \
            https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat || GEO_OK=false
        curl -sLo /usr/local/share/xray/geoip.dat --retry 3 --retry-delay 10 \
            https://github.com/v2fly/geoip/releases/latest/download/geoip.dat || GEO_OK=false
        if $GEO_OK; then
            ln -sf /usr/local/share/xray/geosite.dat /usr/local/bin/geosite.dat
            ln -sf /usr/local/share/xray/geoip.dat /usr/local/bin/geoip.dat
            info "geo 数据下载完成"
        else
            warn "geo 数据下载失败，将使用无 geo 路由的精简配置"
        fi
    fi

    cat > /usr/local/etc/xray/config.json << XEOF
{
  "log": {"loglevel": "info"},
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "::",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [${CLIENT_JSON}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "xver": 0,
          "serverNames": ["$(echo ${REALITY_TARGET} | cut -d: -f1)"],
          "privateKey": "${REALITY_PRIVKEY}",
          "shortIds": ["${REALITY_SHORTID}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true}
    },
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${XHTTP_UUID}", "email": "vless-cdn"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls"]}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
XEOF

    # 确保 systemd 存在
    if [ ! -f /etc/systemd/system/xray.service ]; then
        cat > /etc/systemd/system/xray.service << SVCEOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
SVCEOF
    fi
    # geo 下载失败时移除 geo 路由规则
    if ! $GEO_OK; then
        python3 -c "
import json
c = json.load(open('/usr/local/etc/xray/config.json'))
del c['routing']
c['dns'] = {'servers': ['1.1.1.1', '8.8.8.8', 'localhost']}
json.dump(c, open('/usr/local/etc/xray/config.json', 'w'), indent=2)
" 2>/dev/null || true
        info "已降级为无 geo 路由配置"
    fi

    systemctl daemon-reload
    # 释放 443 端口
    _kill_port 443 "Xray" true
    sleep 1
    systemctl enable --now xray > /dev/null 2>&1
    systemctl is-active --quiet xray && info "Xray 配置已更新并重启 ✅" || err "Xray 启动失败，检查 journalctl -u xray"
    chmod 600 /usr/local/etc/xray/config.json 2>/dev/null || true
}

#==============================================================================
#  ██████ 安装 Hysteria2 ██████
#==============================================================================
install_hysteria() {
    step "安装 Hysteria2"

    # 下载最新版
    LATEST=$(curl -s --max-time 10 --retry 3 https://api.github.com/repos/apernet/hysteria/releases/latest | grep tag_name | cut -d'"' -f4)
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="arm" ;;
        *)       err "不支持的架构: $ARCH" ; return 1 ;;
    esac
    curl -sL --max-time 120 --retry 3 -o /tmp/hysteria \
        "https://github.com/apernet/hysteria/releases/download/${LATEST}/hysteria-linux-${ARCH}"
    mv /tmp/hysteria /usr/local/bin/hysteria 2>/dev/null
    chmod +x /usr/local/bin/hysteria

    # 配置目录
    mkdir -p /etc/hysteria /var/lib/hysteria/acme

    # 写入配置
    cat > /etc/hysteria/config.yaml << YEOF
listen: :${HY2_PORT}

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}
  ca: letsencrypt
  dir: /var/lib/hysteria/acme
  type: ${ACME_MODE}
YEOF
    # DNS-01 模式：追加 Cloudflare DNS 配置
    if [ "$ACME_MODE" = "dns" ] && [ -n "$CF_DNS_TOKEN" ]; then
        cat >> /etc/hysteria/config.yaml << YEOF
  dns:
    name: cloudflare
    config:
      auth_token: ${CF_DNS_TOKEN}
YEOF
    fi
    cat >> /etc/hysteria/config.yaml << YEOF

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
YEOF

    # systemd（含启动限速，防止 ACME 失败时死循环耗尽 Let's Encrypt 限额）
    cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=Hysteria Server Service
After=network.target
StartLimitBurst=5
StartLimitIntervalSec=600

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    # HTTP-01 模式需要 80 端口；DNS-01 模式无需
    if [ "$ACME_MODE" = "http" ]; then
        _kill_port 80 "Hysteria ACME"
        sleep 1
        ufw allow 80/tcp comment "ACME temp" > /dev/null 2>&1
    fi
    systemctl enable --now hysteria-server > /dev/null 2>&1
    # 轮询等待证书获取（最多 60 秒，DNS-01 可能需要更长时间）
    for i in $(seq 1 12); do
        sleep 5
        ls /var/lib/hysteria/acme/*.crt >/dev/null 2>&1 && break
    done
    # HTTP-01 模式关闭 80 端口
    [ "$ACME_MODE" = "http" ] && ufw delete allow 80/tcp > /dev/null 2>&1
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        info "Hysteria2 已启动"
        chmod 600 /etc/hysteria/config.yaml 2>/dev/null || true
        _restore_ports   # 证书获取完毕，恢复被暂停的服务 (nginx 等)
    else
        err "Hysteria2 启动失败"
        # 检查是否是 Let's Encrypt 限速
        if journalctl -u hysteria-server --no-pager -n 5 2>/dev/null | grep -qi "rateLimited\|rate.limit\|too many certificates"; then
            warn "Let's Encrypt 证书限速！该域名本周已申请 5 次证书"
            warn "Hysteria2 将在限速解除后自动重试（每10分钟最多5次）"
            warn "手动检查: journalctl -u hysteria-server --no-pager -n 10"
        fi
        _restore_ports   # 即使失败也恢复，至少别让原服务一直停着
    fi
}

# 仅更新 Hysteria2 配置（二进制已安装时）

# 仅更新 Hysteria2 配置（二进制已安装时）
install_hysteria_config_only() {
    mkdir -p /etc/hysteria
    cat > /etc/hysteria/config.yaml << YEOF
listen: :${HY2_PORT}

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}
  ca: letsencrypt
  dir: /var/lib/hysteria/acme
  type: ${ACME_MODE}
YEOF
    # DNS-01 模式：追加 Cloudflare DNS 配置
    if [ "$ACME_MODE" = "dns" ] && [ -n "$CF_DNS_TOKEN" ]; then
        cat >> /etc/hysteria/config.yaml << YEOF
  dns:
    name: cloudflare
    config:
      auth_token: ${CF_DNS_TOKEN}
YEOF
    fi
    cat >> /etc/hysteria/config.yaml << YEOF

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
YEOF

    # systemd 兜底（含启动限速）
    if [ ! -f /etc/systemd/system/hysteria-server.service ]; then
        cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=Hysteria Server Service
After=network.target
StartLimitBurst=5
StartLimitIntervalSec=600

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=30s
[Install]
WantedBy=multi-user.target
EOF
    else
        # 确保已有 systemd unit 也有限速参数
        if ! grep -q "StartLimitBurst" /etc/systemd/system/hysteria-server.service 2>/dev/null; then
            sed -i '/^\[Unit\]$/a StartLimitBurst=5\nStartLimitIntervalSec=600' /etc/systemd/system/hysteria-server.service
        fi
        sed -i 's/^RestartSec=.*/RestartSec=30s/' /etc/systemd/system/hysteria-server.service 2>/dev/null || true
    fi
    systemctl daemon-reload
    # HTTP-01 模式需要 80 端口；DNS-01 模式无需
    if [ "$ACME_MODE" = "http" ]; then
        _kill_port 80 "Hysteria ACME"
        sleep 1
        ufw allow 80/tcp comment "ACME temp" > /dev/null 2>&1
    fi
    systemctl restart hysteria-server
    # 轮询等待证书获取（最多 60 秒）
    for i in $(seq 1 12); do
        sleep 5
        ls /var/lib/hysteria/acme/*.crt >/dev/null 2>&1 && break
    done
    [ "$ACME_MODE" = "http" ] && ufw delete allow 80/tcp > /dev/null 2>&1
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        info "Hysteria2 配置已更新并重启 ✅"
        _restore_ports
    else
        warn "Hysteria2 启动失败（可能 DNS 未就绪或证书限流，稍后自动重试）"
        if journalctl -u hysteria-server --no-pager -n 5 2>/dev/null | grep -qi "rateLimited\|rate.limit\|too many certificates"; then
            warn "Let's Encrypt 证书限速！限速解除前重启上限 5次/10分钟"
        fi
        _restore_ports
    fi
}

#==============================================================================
#  ██████ 安装 Caddy ██████
#==============================================================================
install_caddy() {
    step "安装 Caddy"

    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https > /dev/null 2>&1
    curl -sL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq caddy > /dev/null 2>&1

    # 目录
    mkdir -p /var/lib/subscription/${SUB_TOKEN} /var/lib/traffic-monitor /etc/vps-proxy

    # Caddyfile（文件服务器根目录指向 subscription）
    cat > /etc/caddy/Caddyfile << CEOF
http://${DOMAIN}:${CADDY_PORT} {
    root * /var/lib/subscription
    file_server

    handle_path /traffic/* {
        root * /var/lib/traffic-monitor
        file_server
    }

    handle ${XHTTP_PATH} {
        reverse_proxy 127.0.0.1:${XHTTP_PORT}
    }
}
CEOF

    # 自动重启
    mkdir -p /etc/systemd/system/caddy.service.d
    cat > /etc/systemd/system/caddy.service.d/restart.conf << EOF
[Service]
Restart=on-failure
RestartSec=5s
EOF

    systemctl daemon-reload
    systemctl enable --now caddy > /dev/null 2>&1
    systemctl is-active --quiet caddy && info "Caddy 已启动" || err "Caddy 启动失败"

    # 收紧密钥文件权限（防止本机其他用户读取凭证）
    chmod 600 /usr/local/etc/xray/config.json 2>/dev/null || true
}

#==============================================================================
#  ██████ 安装 vnstat + 流量看板 ██████
#==============================================================================
install_vnstat() {
    step "安装流量监控"

    apt-get install -y -qq vnstat vnstati > /dev/null 2>&1

    # 获取主网卡
    IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -z "$IFACE" ] && IFACE=eth0

    # 看板生成脚本
    cat > /usr/local/bin/traffic-dashboard.sh << TEOF
#!/bin/bash
OUTDIR=/var/lib/traffic-monitor
IFACE=${IFACE}
mkdir -p "\$OUTDIR"
vnstati -i \$IFACE -h -o \$OUTDIR/hourly.png
vnstati -i \$IFACE -d -o \$OUTDIR/daily.png
vnstati -i \$IFACE -m -o \$OUTDIR/monthly.png
vnstati -i \$IFACE -t -o \$OUTDIR/top10.png
vnstati -i \$IFACE -s -o \$OUTDIR/summary.png
vnstat -i \$IFACE > \$OUTDIR/summary.txt
vnstat -i \$IFACE -h > \$OUTDIR/hourly.txt
vnstat -i \$IFACE -d > \$OUTDIR/daily.txt
vnstat -i \$IFACE -m > \$OUTDIR/monthly.txt
vnstat -i \$IFACE -t > \$OUTDIR/top10.txt

REFRESH=\$(date '+%Y-%m-%d %H:%M:%S')
cat > \$OUTDIR/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>流量监控</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',monospace;padding:20px}
h1{color:#58a6ff;margin-bottom:20px;font-size:1.5em}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(400px,1fr));gap:20px}
.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px}
.card h2{color:#f0883e;font-size:1em;margin-bottom:10px}
.card img{width:100%;height:auto;display:block}
.card pre{font-size:11px;line-height:1.4;overflow-x:auto;color:#8b949e;max-height:360px;overflow-y:auto}
.refresh{color:#8b949e;font-size:.75em;margin-bottom:16px}
</style>
</head>
<body>
<h1>📊 流量监控</h1>
<p class="refresh">更新时间: <span>REFRESH_TIME</span> · 每5分钟刷新 · <a href="javascript:location.reload()" style="color:#58a6ff">手动刷新</a></p>
<div class="grid">
<div class="card"><h2>📋 概览</h2><img src="summary.png"></div>
<div class="card"><h2>🕐 小时</h2><img src="hourly.png"></div>
<div class="card"><h2>📅 每日</h2><img src="daily.png"></div>
<div class="card"><h2>📆 每月</h2><img src="monthly.png"></div>
<div class="card"><h2>🔝 Top10</h2><img src="top10.png"></div>
</div>
<h2 style="color:#f0883e;margin-top:20px">📝 文本详情</h2>
<div class="grid">
<div class="card"><h2>📋 概览</h2><pre>SUMMARY_TXT</pre></div>
<div class="card"><h2>🕐 小时</h2><pre>HOURLY_TXT</pre></div>
<div class="card"><h2>📅 每日</h2><pre>DAILY_TXT</pre></div>
<div class="card"><h2>📆 每月</h2><pre>MONTHLY_TXT</pre></div>
<div class="card"><h2>🔝 Top10</h2><pre>TOP10_TXT</pre></div>
</div>
</body>
</html>
HTMLEOF

sed -i "s|REFRESH_TIME|\$REFRESH|" \$OUTDIR/index.html
for PLACE in SUMMARY_TXT HOURLY_TXT DAILY_TXT MONTHLY_TXT TOP10_TXT; do
  FILE=\$(echo \$PLACE | tr '[:upper:]' '[:lower:]')
  CONTENT=\$(cat "\$OUTDIR/\$FILE" | sed 's/&/\\&/g; s/</\\</g; s/>/\\>/g')
  sed -i "/\${PLACE}/{r /dev/stdin;d}" \$OUTDIR/index.html <<< "\$CONTENT"
done
TEOF
    chmod +x /usr/local/bin/traffic-dashboard.sh

    # 首次生成
    /usr/local/bin/traffic-dashboard.sh

    # cron 每5分钟
    echo "*/5 * * * * root /usr/local/bin/traffic-dashboard.sh" > /etc/cron.d/traffic-dashboard

    info "流量监控已安装 (http://${DOMAIN}:${CADDY_PORT}/traffic/)"
}

#==============================================================================
#  ██████ 订阅生成器 ██████
#==============================================================================
install_sub_generator() {
    step "订阅生成器"

    # 使用 install_caddy 创建的目录
    SUB_TOKEN=$(cat /etc/vps-proxy/sub-token 2>/dev/null || echo "default")
    SUB_DIR=/var/lib/subscription/${SUB_TOKEN}
    mkdir -p "$SUB_DIR" /etc/vps-proxy
    cat > /etc/vps-proxy/subs.conf << CONFIG
# 订阅生成器配置 — 由部署脚本自动生成
SUBDIR="${SUB_DIR}"
SERVER="${DOMAIN}"
CADDY_PORT=${CADDY_PORT}
REALITY_PORT=${REALITY_PORT}
VL_PUBKEY="${REALITY_PUBKEY}"
VL_SHORTID="${REALITY_SHORTID}"
VL_SNI="$(echo ${REALITY_TARGET} | cut -d: -f1)"
# VLESS UUID 数组（断点续传时复用，避免客户端断连）
CLIENT_COUNT="${CLIENT_COUNT}"
VL_UUIDS_0="${VL_UUIDS[0]}"
VL_UUIDS_1="${VL_UUIDS[1]}"
VL_UUIDS_2="${VL_UUIDS[2]}"
VL_UUID="${VL_UUIDS[0]}"
LOON_VL_UUID="${VL_UUIDS[2]}"
HY2_PORT=${HY2_PORT}
HY2_PASS="${HY2_PASS}"
HY2_SNI="${DOMAIN}"
XHTTP_UUID="${XHTTP_UUID}"
XHTTP_PATH="${XHTTP_PATH}"
NODE_PREFIX="${NODE_PREFIX}"
NODE_VR="${NODE_PREFIX} ${PROTO_VR}"
NODE_H2="${NODE_PREFIX} ${PROTO_H2}"
NODE_VX="${NODE_PREFIX} ${PROTO_VX}"
# SUB_TOKEN（持久化避免每次重跑轮换）
SUB_TOKEN="${SUB_TOKEN}"
CONFIG
    chmod 600 /etc/vps-proxy/subs.conf 2>/dev/null || true

    # --- 写 gen-subs.sh（带 'GEOF' 防止变量展开）---
    cat > /usr/local/bin/gen-subs.sh << 'GEOF'
#!/bin/bash
# 订阅自动生成器 — Clash Meta (统一) + Loon
# 用法: /usr/local/bin/gen-subs.sh
# 配置: /etc/vps-proxy/subs.conf

source /etc/vps-proxy/subs.conf

gen_clash() {
  cat > "$SUBDIR/clash.yaml" << YEOF
proxies:
  - name: ${NODE_VR}
    type: vless
    server: ${SERVER}
    port: ${REALITY_PORT}
    uuid: ${VL_UUID}
    udp: true
    tls: true
    servername: ${VL_SNI}
    client-fingerprint: chrome
    flow: xtls-rprx-vision
    network: tcp
    reality-opts:
      public-key: ${VL_PUBKEY}
      short-id: ${VL_SHORTID}
    skip-cert-verify: true
    smux:
      enabled: true
      protocol: h2mux
      max-connections: 4

  - name: ${NODE_H2}
    type: hysteria2
    server: ${SERVER}
    port: ${HY2_PORT}
    password: ${HY2_PASS}
    sni: ${HY2_SNI}
    skip-cert-verify: false
    udp: true

  - name: ${NODE_VX}
    type: vless
    server: ${SERVER}
    port: ${CADDY_PORT}
    uuid: ${XHTTP_UUID}
    udp: true
    tls: true
    servername: ${SERVER}
    network: xhttp
    xhttp-opts:
      path: ${XHTTP_PATH}
      mode: auto
    skip-cert-verify: false
    smux:
      enabled: true
      protocol: h2mux
      max-connections: 4
YEOF
  echo "  -> clash.yaml (Clash Verge 统一)"
}

gen_loon() {
  cat > "$SUBDIR/loon.conf" << LEOF
${NODE_VR} = VLESS,${SERVER},${REALITY_PORT},"${LOON_VL_UUID}",transport=tcp,flow=xtls-rprx-vision,public-key="${VL_PUBKEY}",short-id=${VL_SHORTID},over-tls=true,sni=${VL_SNI},udp=true
${NODE_H2} = Hysteria2,${SERVER},${HY2_PORT},"${HY2_PASS}",sni=${HY2_SNI},skip-cert-verify=false,udp=true
${NODE_VX} = VLESS,${SERVER},${CADDY_PORT},"${XHTTP_UUID}",transport=xhttp,tls=true,sni=${SERVER},path=${XHTTP_PATH},udp=true
LEOF
  echo "  -> loon.conf (iPhone)"
}

gen_index() {
  cat > "$SUBDIR/index.html" << IEOF
<!DOCTYPE html><html lang="zh"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>${NODE_PREFIX}</title><style>*{margin:0;padding:0;box-sizing:border-box}body{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,monospace;display:flex;align-items:center;justify-content:center;min-height:100vh}.box{text-align:center}h1{color:#58a6ff;font-size:1.3em;margin-bottom:24px}a{display:block;color:#c9d1d9;text-decoration:none;padding:10px 20px;margin:8px 0;background:#161b22;border:1px solid #30363d;border-radius:6px;transition:border-color .2s}a:hover{border-color:#58a6ff}.tag{color:#8b949e;font-size:.7em;margin-left:8px}</style></head><body><div class="box"><h1>${NODE_PREFIX}</h1><a href="clash.yaml">📥 Clash Verge<span class="tag">clash.yaml</span></a><a href="loon.conf">📱 Loon (iPhone)<span class="tag">loon.conf</span></a><a href="/traffic/">📊 流量看板</a><a href="/vps-deploy.sh">🔧 部署脚本</a></div></body></html>
IEOF
  echo "  -> index.html (订阅门户)"
}

mkdir -p "$SUBDIR"
echo "[gen-subs] 生成订阅文件..."
gen_clash
gen_loon
gen_index
chown -R caddy:caddy "$SUBDIR" 2>/dev/null
echo "[gen-subs] 完成."
ls -la "$SUBDIR"/{clash.yaml,loon.conf,index.html}
GEOF
    chmod +x /usr/local/bin/gen-subs.sh
    /usr/local/bin/gen-subs.sh

    info "订阅生成器已安装 (配置: /etc/vps-proxy/subs.conf)"
}

#==============================================================================
#  ██████ Cloudflare Tunnel (cloudflared) ██████
#==============================================================================
install_cloudflared() {
    step "Cloudflare Tunnel"

    if [ -x /usr/bin/cloudflared ] || [ -x /usr/local/bin/cloudflared ]; then
        if systemctl is-active --quiet cloudflared 2>/dev/null; then
            info "cloudflared 已安装且运行中，跳过"
            return 0
        fi
        info "cloudflared 已安装但未运行，重新配置..."
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Cloudflare Tunnel 用于 VLESS XHTTP CDN 兜底节点${NC}"
    echo -e "${YELLOW}  如果不需要 CDN 节点，输入 n 跳过${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    # 非交互模式：有 CF_TOKEN 环境变量则自动安装，否则跳过
    if [ -n "${CF_TOKEN_ENV:-}" ]; then
        INSTALL_CF="y"
    elif [ -z "$1" ] || [ -z "$2" ]; then
        read -p "  是否安装 Cloudflare Tunnel? [Y/n]: " INSTALL_CF
        [ -z "$INSTALL_CF" ] && INSTALL_CF="y"
    else
        warn "非交互模式且无 CF_TOKEN_ENV，跳过 Cloudflare Tunnel"
        return 0
    fi

    if [ "$INSTALL_CF" = "n" ] || [ "$INSTALL_CF" = "N" ]; then
        info "已跳过 Cloudflare Tunnel（VMess CDN 节点将不可用）"
        return 0
    fi

    # 安装 cloudflared（如果尚未安装）
    if [ ! -x /usr/bin/cloudflared ] && [ ! -x /usr/local/bin/cloudflared ]; then
        info "正在安装 cloudflared..."
        local CF_ARCH
        case "$(uname -m)" in
            aarch64) CF_ARCH="arm64" ;;
            armv7l)  CF_ARCH="arm" ;;
            *)       CF_ARCH="amd64" ;;
        esac
        curl -sL --retry 3 --max-time 120 -o /tmp/cloudflared.deb \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb"
        if [ -s /tmp/cloudflared.deb ]; then
            dpkg -i /tmp/cloudflared.deb > /dev/null 2>&1 || true
        fi
        rm -f /tmp/cloudflared.deb

        if [ ! -x /usr/bin/cloudflared ] && [ ! -x /usr/local/bin/cloudflared ]; then
            warn "cloudflared 安装失败，跳过（CDN 节点不可用）"
            return 0
        fi
        info "cloudflared 已安装"
    fi

    # 提取根域名用于提示
    CF_ROOT_DOMAIN=$(echo "$DOMAIN" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF}')
    [ -z "$CF_ROOT_DOMAIN" ] && CF_ROOT_DOMAIN="$DOMAIN"
    CF_CDN_SUB="cdn-$(echo "$DOMAIN" | cut -d. -f1)"

    echo ""
    echo -e "${GREEN}请按以下步骤获取 Token：${NC}"
    echo ""
    echo "  1️⃣  打开 https://one.dash.cloudflare.com/"
    echo "  2️⃣  Networks → Tunnels → Create a tunnel"
    echo "  3️⃣  Tunnel 名称建议: ${CF_CDN_SUB}"
    echo "  4️⃣  选择 Debian 环境，页面会显示类似命令："
    echo "     sudo cloudflared service install eyJh...长字符串..."
    echo "  5️⃣  只复制那个 eyJ 开头的长 Token，粘贴到下面"
    echo ""
    echo "  创建后进入 Tunnel → Configure → Public Hostname："
    echo "    Subdomain: ${CF_CDN_SUB}"
    echo "    Domain:    ${CF_ROOT_DOMAIN}"
    echo "    Type:      HTTP"
    echo "    URL:       localhost:10001"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  请粘贴 Token（eyJ 开头的那一串）：${NC}"
    echo -e "${CYAN}  输入 n 跳过${NC}"

    # 非交互模式优先用环境变量
    if [ -n "${CF_TOKEN_ENV:-}" ]; then
        CF_TOKEN="$CF_TOKEN_ENV"
        info "使用 CF_TOKEN_ENV 环境变量"
    else
        read -p "  > " CF_TOKEN
    fi

    if [ "$CF_TOKEN" = "n" ] || [ "$CF_TOKEN" = "N" ] || [ -z "$CF_TOKEN" ]; then
        warn "已跳过 Cloudflare Tunnel（VMess CDN 节点将不可用）"
        return 0
    fi

    # 自动提取 eyJ 开头的 Token（忽略前面的无效内容）
    CF_TOKEN=$(echo "$CF_TOKEN" | grep -oP 'eyJ[A-Za-z0-9_\-+/=\.]+' | head -1)
    if [ -z "$CF_TOKEN" ]; then
        warn "未识别到有效 Token（应以 eyJ 开头）"
        read -p "  未识别到 Token，跳过 Tunnel 安装? [y/N]: " CF_SKIP
        if [ "$CF_SKIP" = "y" ] || [ "$CF_SKIP" = "Y" ]; then
            warn "已跳过 Cloudflare Tunnel"
            return 0
        fi
        read -p "  请重新粘贴 Token: " CF_TOKEN
        CF_TOKEN=$(echo "$CF_TOKEN" | grep -oP 'eyJ[A-Za-z0-9_\-+/=\.]+' | head -1)
        if [ -z "$CF_TOKEN" ]; then
            warn "仍然未识别，跳过 Cloudflare Tunnel"
            return 0
        fi
    fi
    info "已识别 Token: ${CF_TOKEN:0:20}..."

    # 注册服务
    cloudflared service install "$CF_TOKEN" > /dev/null 2>&1

    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        info "Cloudflare Tunnel 已启动 ✅"
    else
        warn "Tunnel 未启动，检查 Token 是否正确: systemctl status cloudflared"
    fi

    # ⚠️ 强提醒：手动配置 Public Hostname
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  ⚠️  还没完！请立即在 Cloudflare 完成以下手动操作：${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  🔗 ${CYAN}https://one.dash.cloudflare.com/${NC}"
    echo -e "  📍 Networks → Tunnels → 点击刚创建的隧道 → Configure"
    echo -e "  📍 Public Hostname → Add a public hostname"
    echo ""
    echo -e "  ${GREEN}填写以下内容：${NC}"
    echo -e "    Subdomain : ${CYAN}${CF_CDN_SUB}${NC}"
    echo -e "    Domain    : ${CYAN}${CF_ROOT_DOMAIN}${NC}"
    echo -e "    Type      : ${CYAN}HTTP${NC}"
    echo -e "    URL       : ${RED}localhost:10001${NC}"
    echo ""
    echo -e "${RED}  ⚠️  不完成这一步，CDN 节点永远不会通！${NC}"
    echo ""
    # 非交互模式跳过确认
    if [ -z "${CF_TOKEN_ENV:-}" ]; then
        read -p "  已完成上述手动配置? [按回车继续] " _DUMMY
    fi
}

#==============================================================================
#  ██████ fail2ban ██████
#==============================================================================
install_fail2ban() {
    step "安装 fail2ban"

    apt-get install -y -qq fail2ban rsyslog > /dev/null 2>&1
    systemctl enable --now rsyslog > /dev/null 2>&1 || true

    # Xray reject 过滤器
    cat > /etc/fail2ban/filter.d/xray-reject.conf << EOF
[Definition]
failregex = ^.*from <HOST>.*rejected.*$
ignoreregex =
EOF

    cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 3
bantime = 3600
findtime = 600

[xray-reject]
enabled = true
port = ${REALITY_PORT},${CADDY_PORT}
filter = xray-reject
logpath = /var/log/syslog
maxretry = 5
bantime = 3600
findtime = 300

[DEFAULT]
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 86400
EOF

    systemctl enable --now fail2ban > /dev/null 2>&1
    systemctl is-active --quiet fail2ban && info "fail2ban 已启动 (SSH + Xray 防护)" || warn "fail2ban 启动失败，检查日志"
}

#==============================================================================
#  ██████ SSH 配置 ██████
#==============================================================================
setup_ssh() {
    # 只有用户选择了修改端口才执行
    if [ "$SSH_PORT" = "$SSH_OLD_PORT" ]; then
        echo -e "\n${CYAN}==== SSH 端口 ====${NC}"
        info "SSH 端口保持 ${SSH_PORT}，未修改"
        return 0
    fi

    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  ⚠️⚠️⚠️  SSH 端口即将修改: ${SSH_OLD_PORT} → ${SSH_PORT}  ⚠️⚠️⚠️                ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  当前会话使用端口 ${SSH_OLD_PORT}，修改后请勿关闭本窗口！              ║${NC}"
    echo -e "${RED}║  立即打开新终端窗口测试新端口连接：                        ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  ssh $(whoami)@$(curl -s4 ifconfig.me 2>/dev/null || echo 'YOUR_IP') -p ${SSH_PORT}                         ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  确认新端口可连接后，在本窗口执行:                         ║${NC}"
    echo -e "${RED}║  sudo systemctl restart sshd                              ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 备份并修改
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d) 2>/dev/null || true
    if grep -q "^Port" /etc/ssh/sshd_config; then
        sed -i "s/^Port.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
    else
        echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
    fi
    info "SSH 配置文件已修改（sshd 未重启，旧端口仍生效）"
    warn "请确认新端口可用后再重启 sshd！"
}

# 安全加固（SSH 硬ening + 清理无用用户）
harden_ssh() {
    # 仅在 root 有 SSH 密钥时才加固（避免锁死）
    if [ -s /root/.ssh/authorized_keys ]; then
        info "SSH 安全加固..."
        # 禁用密码登录 + root 密码登录
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
        sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
        grep -q "^MaxAuthTries" /etc/ssh/sshd_config || echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
        grep -q "^ClientAliveInterval" /etc/ssh/sshd_config || echo "ClientAliveInterval 60" >> /etc/ssh/sshd_config
        # 不重启 sshd（由用户手动确认新端口后再重启，避免锁死）
        info "SSH 配置已加固（sshd 未重启，当前会话不受影响）"
        info "  请手动执行: systemctl restart sshd (确认新端口可用后)"
    else
        warn "未检测到 SSH 密钥，跳过加固（避免锁死）"
    fi

    # 删除无密钥的 ubuntu 用户（cloud-init 遗留，NOPASSWD sudo）
    if id ubuntu >/dev/null 2>&1 && [ ! -s /home/ubuntu/.ssh/authorized_keys ]; then
        userdel -r ubuntu 2>/dev/null && info "已删除无用 ubuntu 用户"
        rm -f /etc/sudoers.d/90-cloud-init-users 2>/dev/null
    fi
}

#==============================================================================
#  ██████ 摘要输出 ██████
#==============================================================================
print_summary() {
    SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "未知")
    SUB_TOKEN=$(cat /etc/vps-proxy/sub-token 2>/dev/null || echo "default")

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}         ${GREEN}✅ 部署完成！${NC}                              ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 服务器 IP: ${CYAN}${SERVER_IP}${NC}"
    echo -e "${BLUE}║${NC} 域名:      ${CYAN}${DOMAIN}${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 协议端口:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   VLESS Reality  TCP:${REALITY_PORT}                         ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   Hysteria2      UDP:${HY2_PORT}                          ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   VLESS XHTTP    TCP:${CADDY_PORT} (via Caddy)             ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 订阅链接:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${CYAN}http://${DOMAIN}:${CADDY_PORT}/${SUB_TOKEN}/clash.yaml${NC}"
    echo -e "${BLUE}║${NC}   ${CYAN}http://${DOMAIN}:${CADDY_PORT}/${SUB_TOKEN}/loon.conf${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 流量看板:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${CYAN}http://${DOMAIN}:${CADDY_PORT}/traffic/${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 节点命名:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${NODE_PREFIX} ${PROTO_VR}                                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${NODE_PREFIX} ${PROTO_H2}                                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${NODE_PREFIX} ${PROTO_VX}                                     ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 维护命令:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   改配置: vim /usr/local/bin/gen-subs.sh               ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   重建订阅: /usr/local/bin/gen-subs.sh                 ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   服务状态: systemctl status xray hysteria-server caddy${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"

    # 报告被释放的端口
    if [ -n "$KILLED_PORTS" ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  ⚠️  脚本运行期间释放了以下端口：${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "$KILLED_PORTS"
        echo -e "${YELLOW}  如上述端口原运行着重要服务，请手动恢复。${NC}"
    fi
    echo ""
}

#==============================================================================
#  ██████ 主流程 ██████
#==============================================================================
main() {
    TOTAL=14; STEP=0

    # ── 1. 配置 ──
    setup_config "$@"

    # SUB_TOKEN 持久化（仅在首次创建，避免每次重跑轮换）
    mkdir -p /etc/vps-proxy
    [ -f /etc/vps-proxy/sub-token ] || echo "${SUB_TOKEN}" > /etc/vps-proxy/sub-token

    # ── 2. 检测 ──
    check_system
    auto_detect_region

    # ── 3. 系统优化 ──
    optimize_system

    # ── 4. 依赖 ──
    install_deps

    # ── 5. 密钥（已存在则复用，但先验证有效性）──
    if [ -f /etc/vps-proxy/subs.conf ]; then
        step "密钥生成"
        source /etc/vps-proxy/subs.conf
        # 从独立变量重建 VL_UUIDS 数组（subs.conf 持久化为 VL_UUIDS_0/1/2）
        if [ -z "${VL_UUIDS:-}" ]; then
            if [ -n "${VL_UUIDS_0:-}" ]; then
                VL_UUIDS=("${VL_UUIDS_0}" "${VL_UUIDS_1:-}" "${VL_UUIDS_2:-}")
                [ -z "${VL_UUID:-}" ] && VL_UUID="${VL_UUIDS_0}"
                [ -z "${LOON_VL_UUID:-}" ] && LOON_VL_UUID="${VL_UUIDS_2:-${VL_UUIDS_0}}"
            fi
        fi
        # 验证 UUID 是否有效
        if [ -z "${VL_UUIDS:-}" ] || [ -z "${VL_UUIDS[0]:-}" ]; then
            warn "旧配置的 UUID 无效，重新生成密钥"
            rm -f /etc/vps-proxy/subs.conf
            generate_keys
        else
            info "检测到已有配置，复用密钥 (VL: ${VL_UUIDS[0]:0:8}...)"
            # 复用 SUB_TOKEN（避免订阅 URL 变化）
            SUB_TOKEN="${SUB_TOKEN:-$(cat /etc/vps-proxy/sub-token 2>/dev/null || echo "default")}"
            SERVER="${DOMAIN}"
            # 旧配置迁移: VMESS_UUID → XHTTP_UUID
            if [ -z "${XHTTP_UUID:-}" ] && [ -n "${VMESS_UUID:-}" ]; then
                XHTTP_UUID="${VMESS_UUID}"
                XHTTP_PATH="/$(echo "$XHTTP_UUID" | cut -d- -f1)-xhttp"
                info "已从旧 VMess 配置迁移到 VLESS XHTTP"
                warn "⚠️  CDN Tunnel Public Hostname 路径可能仍指向旧的 VMess WS 路径"
                warn "    请在 Cloudflare 手动更新: Tunnel → Public Hostname → URL 改为 localhost:10001"
            elif [ -z "${XHTTP_UUID:-}" ]; then
                XHTTP_UUID=$(cat /proc/sys/kernel/random/uuid)
                XHTTP_PATH="/$(echo "$XHTTP_UUID" | cut -d- -f1)-xhttp"
                info "生成新的 VLESS XHTTP UUID"
            fi
        fi
    else
        generate_keys
    fi

    # ── 6. 防火墙 ──
    setup_firewall

    # ── 7. Xray ──
    XRAY_OK=true
    if [ -x /usr/local/bin/xray ] && [ -f /usr/local/etc/xray/config.json ]; then
        step "安装 Xray"
        info "Xray 已安装，更新配置..."
        install_xray_config_only || XRAY_OK=false
    else
        install_xray || XRAY_OK=false
    fi
    if ! $XRAY_OK; then
        err "Xray 安装/更新失败，代理核心不可用！"
        warn "后续步骤将继续执行，但 VLESS 节点将不可用"
    fi

    # ── 8. Hysteria2 ──
    if [ -x /usr/local/bin/hysteria ]; then
        step "安装 Hysteria2"
        info "Hysteria2 已安装，更新配置..."
        # 重写配置（域名可能已变更）
        install_hysteria_config_only
    else
        install_hysteria
    fi

    # ── 9. Caddy ──
    if [ -x /usr/bin/caddy ]; then
        step "安装 Caddy"
        info "Caddy 已安装，更新 Caddyfile..."
        # 确保订阅目录存在
        mkdir -p /var/lib/subscription/${SUB_TOKEN} /var/lib/traffic-monitor
        # 更新 Caddyfile（协议路径可能已变更）
        cat > /etc/caddy/Caddyfile << CEOF
http://${DOMAIN}:${CADDY_PORT} {
    root * /var/lib/subscription
    file_server

    handle_path /traffic/* {
        root * /var/lib/traffic-monitor
        file_server
    }

    handle ${XHTTP_PATH} {
        reverse_proxy 127.0.0.1:${XHTTP_PORT}
    }
}
CEOF
        systemctl reload caddy 2>/dev/null || systemctl restart caddy
        systemctl is-active --quiet caddy && info "Caddy 配置已更新 ✅" || warn "Caddy 重载失败"
    else
        install_caddy
    fi

    # ── 10. Cloudflare Tunnel ──
    install_cloudflared

    # ── 11. 流量监控 ──
    if [ -x /usr/bin/vnstat ]; then
        step "流量监控"
        info "vnstat 已安装，跳过"
    else
        install_vnstat
    fi

    # ── 12. 订阅生成器 ──
    install_sub_generator

    # ── 13. fail2ban ──
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        step "fail2ban"
        info "fail2ban 已运行，跳过"
    else
        install_fail2ban
    fi

    # ── 检查 ──
    step "服务状态检查"
    for svc in xray hysteria-server caddy cloudflared fail2ban vnstat; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            info "$svc ✅"
        else
            warn "$svc ❌ (检查: journalctl -u $svc --no-pager -n 20)"
        fi
    done

    # ── 摘要 ──
    print_summary

    # ── 14. SSH 端口（所有工作完成后，最后处理）──
    setup_ssh

    # ── 15. SSH 安全加固（密钥确认后再执行）──
    harden_ssh

    # 安全兜底：确保被暂停的服务都已恢复
    _restore_ports
}

# 运行
main "$@"
