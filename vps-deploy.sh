#!/bin/bash
#==============================================================================
#  VPS 一键部署脚本 — 三协议代理 + 流量监控 + 订阅生成
#
#  ██ 交互式安装:                                 ██
#  curl -sLo vps-deploy.sh https://tinyurl.com/jp-bvl-deploy && sudo bash vps-deploy.sh
#
#  ██ 一键安装（跳过交互，直接传参）:                ██
#  curl -sLo vps-deploy.sh https://tinyurl.com/jp-bvl-deploy && sudo bash vps-deploy.sh us-gcp.alecyinshis.com GCP
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
    echo "  ║   VPS 三协议代理一键部署脚本        ║"
    echo "  ║   VLESS Reality + Hysteria2 + VMess ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"

    # 域名（三种方式：环境变量 > 命令行 > 交互输入）
    if [ -n "${DOMAIN_ENV:-}" ]; then
        DOMAIN="$DOMAIN_ENV"
    elif [ -n "$1" ]; then
        DOMAIN="$1"
    else
        echo ""
        echo -e "${GREEN}请输入域名:${NC}"
        read -p "  > " DOMAIN
    fi
    # 去掉末尾斜杠和 http 前缀
    DOMAIN=$(echo "$DOMAIN" | sed 's|^https\?://||; s|/\+$||')
    [ -z "$DOMAIN" ] && err "域名不能为空" && exit 1

    # 服务商代码
    if [ -n "${PROVIDER_ENV:-}" ]; then
        PROVIDER="$PROVIDER_ENV"
    elif [ -n "$2" ]; then
        PROVIDER="$2"
    else
        echo ""
        echo -e "${GREEN}请输入服务商代码 (如 BVL / HZ / AWS):${NC}"
        read -p "  > " PROVIDER
    fi
    [ -z "$PROVIDER" ] && PROVIDER="VPS"

    echo ""
    info "域名:     ${DOMAIN}"
    info "服务商:   ${PROVIDER}"

    # 其余固定配置
    EMAIL="alecyinshi@gmail.com"
    # SSH 端口：保持当前端口不变，不强制修改
    SSH_PORT=$(grep -oP '^Port\s+\K\d+' /etc/ssh/sshd_config 2>/dev/null || echo "22")
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    REALITY_PORT=443
    HY2_PORT=443
    CADDY_PORT=8443
    VMESS_WS_PORT=10001
    CLIENT_COUNT=3
    CLIENT_NAMES=("mac" "windows" "iphone")
    PROTO_VR="VR"
    PROTO_H2="H2"
    PROTO_VM="VM"
    REALITY_TARGET="www.nic.ad.jp:443"
    HY2_MASQUERADE_URL="https://www.nic.ad.jp/"
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

#==============================================================================
#  ██████ 系统检测 ██████
#==============================================================================
check_system() {
    step "系统检测"
    [ "$(id -u)" -ne 0 ] && err "请用 root 运行: sudo bash $0" && exit 1

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
# 减少 swap（代理服务器不应 swap）
vm.swappiness = 10
EOF

    sysctl --system > /dev/null 2>&1
    info "内核参数已优化: BBR TFO=3 小包推送 rmem=16M swappiness=10"
}

#==============================================================================
#  ██████ 安装依赖 ██████
#==============================================================================
install_deps() {
    step "安装依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget unzip openssl cron ufw \
        python3 locales iputils-ping > /dev/null 2>&1

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
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null

    ufw allow "$SSH_PORT/tcp" comment "SSH" > /dev/null
    ufw allow 80/tcp comment "ACME HTTP-01" > /dev/null
    ufw allow "$REALITY_PORT/tcp" comment "VLESS Reality" > /dev/null
    ufw allow "$HY2_PORT/udp" comment "Hysteria2" > /dev/null
    ufw allow "$CADDY_PORT/tcp" comment "HTTPS Subscription" > /dev/null

    ufw --force enable > /dev/null 2>&1
    info "防火墙已配置 (SSH:$SSH_PORT Reality:$REALITY_PORT/tcp Hy2:$HY2_PORT/udp Caddy:$CADDY_PORT)"
}

#==============================================================================
#  ██████ 生成密钥和 UUID ██████
#==============================================================================
generate_keys() {
    step "生成密钥"

    # VMess 备用 UUID
    VMESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    VMESS_WS_PATH="/$(echo "$VMESS_UUID" | cut -d- -f1)-vm"

    # 客户端 VLESS UUID
    VL_UUIDS=()
    for i in $(seq 1 $CLIENT_COUNT); do
        VL_UUIDS+=($(cat /proc/sys/kernel/random/uuid))
    done

    # Hysteria2 密码
    HY2_PASS=$(openssl rand -hex 24)

    info "密钥生成完成 ($((CLIENT_COUNT + 1)) 个 UUID)"
}

#==============================================================================
#  ██████ 安装 Xray (VLESS Reality + VMess WS) ██████
#==============================================================================
install_xray() {
    step "安装 Xray"

    # 安装（官方脚本 + 直链兜底）
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
        --version latest > /dev/null 2>&1 || {
        warn "官方脚本安装失败，尝试直接下载..."
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && ARCH="64"
        [ "$ARCH" = "aarch64" ] && ARCH="arm64-v8a"
        curl -sLo /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        unzip -o /tmp/xray.zip -d /usr/local/bin/ xray 2>/dev/null || true
        chmod +x /usr/local/bin/xray 2>/dev/null
        mkdir -p /usr/local/etc/xray
        rm -f /tmp/xray.zip
    }

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

    # 写入配置
    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json << XEOF
{
  "log": {"loglevel": "warning"},
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
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": ${VMESS_WS_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${VMESS_UUID}", "alterId": 0, "email": "vmess-backup"}]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "${VMESS_WS_PATH}"}
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

    systemctl daemon-reload
    systemctl restart xray
    systemctl is-active --quiet xray && info "Xray 已启动 (VLESS Reality + VMess WS)" || err "Xray 启动失败"
}

#==============================================================================
#  ██████ 安装 Hysteria2 ██████
#==============================================================================
install_hysteria() {
    step "安装 Hysteria2"

    # 下载最新版
    LATEST=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep tag_name | cut -d'"' -f4)
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && ARCH="amd64"
    curl -sLo /usr/local/bin/hysteria \
        "https://github.com/apernet/hysteria/releases/download/${LATEST}/hysteria-linux-${ARCH}"
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
  type: http

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

    # systemd
    cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=Hysteria Server Service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server > /dev/null 2>&1
    systemctl is-active --quiet hysteria-server && info "Hysteria2 已启动" || err "Hysteria2 启动失败"
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
https://${DOMAIN}:${CADDY_PORT} {
    root * /var/lib/subscription
    file_server

    handle_path /traffic/* {
        root * /var/lib/traffic-monitor
        file_server
    }

    handle ${VMESS_WS_PATH} {
        reverse_proxy 127.0.0.1:${VMESS_WS_PORT}
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
    systemctl restart caddy
    systemctl is-active --quiet caddy && info "Caddy 已启动" || err "Caddy 启动失败"
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

    info "流量监控已安装 (https://${DOMAIN}:${CADDY_PORT}/traffic/)"
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
VL_UUID="${VL_UUIDS[0]}"
LOON_VL_UUID="${VL_UUIDS[2]}"
HY2_PORT=${HY2_PORT}
HY2_PASS="${HY2_PASS}"
HY2_SNI="${DOMAIN}"
VMESS_UUID="${VMESS_UUID}"
VMESS_WS_PATH="${VMESS_WS_PATH}"
NODE_VR="${NODE_PREFIX} ${PROTO_VR}"
NODE_H2="${NODE_PREFIX} ${PROTO_H2}"
NODE_VM="${NODE_PREFIX} ${PROTO_VM}"
CONFIG

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

  - name: ${NODE_VM}
    type: vmess
    server: ${SERVER}
    port: ${CADDY_PORT}
    uuid: ${VMESS_UUID}
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: ${SERVER}
    network: ws
    ws-opts:
      path: ${VMESS_WS_PATH}
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
${NODE_VM} = VMess,${SERVER},${CADDY_PORT},"${VMESS_UUID}",ws=true,tls=true,sni=${SERVER},path=${VMESS_WS_PATH},udp=true
LEOF
  echo "  -> loon.conf (iPhone)"
}

gen_index() {
  cat > "$SUBDIR/index.html" << IEOF
<!DOCTYPE html><html lang="zh"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>${NODE_PREFIX}</title><style>*{margin:0;padding:0;box-sizing:border-box}body{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,monospace;display:flex;align-items:center;justify-content:center;min-height:100vh}.box{text-align:center}h1{color:#58a6ff;font-size:1.3em;margin-bottom:24px}a{display:block;color:#c9d1d9;text-decoration:none;padding:10px 20px;margin:8px 0;background:#161b22;border:1px solid #30363d;border-radius:6px;transition:border-color .2s}a:hover{border-color:#58a6ff}.tag{color:#8b949e;font-size:.7em;margin-left:8px}</style></head><body><div class="box"><h1>${NODE_PREFIX}</h1><a href=\"${SUBDIR}/clash.yaml\">📥 Clash Verge<span class=\"tag\">clash.yaml</span></a><a href=\"${SUBDIR}/loon.conf\">📱 Loon (iPhone)<span class=\"tag\">loon.conf</span></a><a href=\"/traffic/\">📊 流量看板</a><a href=\"/vps-deploy.sh\">🔧 部署脚本</a></div></body></html>
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
        info "cloudflared 已安装，跳过"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Cloudflare Tunnel 用于 VMess CDN 兜底节点${NC}"
    echo -e "${YELLOW}  如果不需要 CDN 节点，输入 n 跳过${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "  是否安装 Cloudflare Tunnel? [Y/n]: " INSTALL_CF

    if [ "$INSTALL_CF" = "n" ] || [ "$INSTALL_CF" = "N" ]; then
        info "已跳过 Cloudflare Tunnel（VMess CDN 节点将不可用）"
        return 0
    fi

    # 先安装 cloudflared
    info "正在安装 cloudflared..."
    curl -sLo /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i /tmp/cloudflared.deb > /dev/null 2>&1 || true
    rm -f /tmp/cloudflared.deb

    if [ ! -x /usr/bin/cloudflared ] && [ ! -x /usr/local/bin/cloudflared ]; then
        warn "cloudflared 安装失败，跳过"
        return 0
    fi
    info "cloudflared 已安装"

    echo ""
    echo -e "${GREEN}请按以下步骤获取 Token：${NC}"
    echo ""
    echo "  1️⃣  打开 https://one.dash.cloudflare.com/"
    echo "  2️⃣  Networks → Tunnels → Create a tunnel"
    echo "  3️⃣  Tunnel 名称建议: cdn-us-gcp-dc3"
    echo "  4️⃣  选择 Debian 环境，页面会显示类似命令："
    echo "     sudo cloudflared service install eyJh...长字符串..."
    echo "  5️⃣  只复制那个 eyJ 开头的长 Token，粘贴到下面"
    echo ""
    echo "  创建后进入 Tunnel → Configure → Public Hostname："
    echo "    Subdomain: cdn-us-gcp-dc3"
    echo "    Domain:    alecyinshis.com"
    echo "    Type:      HTTP"
    echo "    URL:       localhost:10001"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  请粘贴 Token（eyJ 开头的那一串）：${NC}"
    echo -e "${CYAN}  输入 n 跳过${NC}"
    read -p "  > " CF_TOKEN

    if [ "$CF_TOKEN" = "n" ] || [ "$CF_TOKEN" = "N" ] || [ -z "$CF_TOKEN" ]; then
        warn "已跳过 Cloudflare Tunnel（VMess CDN 节点将不可用）"
        return 0
    fi

    # 自动提取 eyJ 开头的 Token（忽略前面的无效内容）
    CF_TOKEN=$(echo "$CF_TOKEN" | grep -oP 'eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+' | head -1)
    if [ -z "$CF_TOKEN" ]; then
        warn "未识别到有效 Token（应以 eyJ 开头），已跳过"
        return 0
    fi
    info "已识别 Token: ${CF_TOKEN:0:20}..."

    # 注册服务
    cloudflared service install "$CF_TOKEN" > /dev/null 2>&1

    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        info "Cloudflare Tunnel 已启动 ✅"
    else
        warn "Tunnel 未启动，检查 Token 是否正确: systemctl status cloudflared"
    fi
}

#==============================================================================
#  ██████ fail2ban ██████
#==============================================================================
install_fail2ban() {
    step "安装 fail2ban"

    apt-get install -y -qq fail2ban > /dev/null 2>&1

    cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 3
bantime = 3600
findtime = 600
EOF

    systemctl restart fail2ban > /dev/null 2>&1
    systemctl is-active --quiet fail2ban && info "fail2ban 已启动 (SSH 3次失败封1小时)" || warn "fail2ban 启动失败，检查日志"
}

#==============================================================================
#  ██████ SSH 配置 ██████
#==============================================================================
setup_ssh() {
    # 不使用 step()，避免计数器溢出
    echo -e "\n${CYAN}==== SSH 配置 ====${NC}"

    local CUR_PORT
    CUR_PORT=$(grep -oP '^Port\s+\K\d+' /etc/ssh/sshd_config 2>/dev/null || echo "22")

    if [ "$CUR_PORT" = "$SSH_PORT" ]; then
        info "SSH 端口已是 ${SSH_PORT}，未修改"
        return 0
    fi

    # 备份
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d) 2>/dev/null || true

    # 修改端口
    if grep -q "^Port" /etc/ssh/sshd_config; then
        sed -i "s/^Port.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
    else
        echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
    fi

    SSH_CHANGED=1
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  SSH 端口已修改: ${CUR_PORT} → ${SSH_PORT}                          ║${NC}"
    echo -e "${RED}║                                                        ║${NC}"
    echo -e "${RED}║  当前连接仍在使用旧端口 ${CUR_PORT}，不要关闭本窗口！       ║${NC}"
    echo -e "${RED}║  请立即打开新终端，测试新端口是否能连接：               ║${NC}"
    echo -e "${RED}║  ssh $(whoami)@$(curl -s4 ifconfig.me 2>/dev/null || echo 'IP') -p ${SSH_PORT}                     ║${NC}"
    echo -e "${RED}║  确认成功后执行: sudo systemctl restart sshd           ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
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
    echo -e "${BLUE}║${NC}   VMess WS       TCP:${CADDY_PORT} (via Caddy)             ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 订阅链接:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${CYAN}https://${DOMAIN}:${CADDY_PORT}/${SUB_TOKEN}/clash.yaml${NC}"
    echo -e "${BLUE}║${NC}   ${CYAN}https://${DOMAIN}:${CADDY_PORT}/${SUB_TOKEN}/loon.conf${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 流量看板:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${CYAN}https://${DOMAIN}:${CADDY_PORT}/traffic/${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 节点命名:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${NODE_PREFIX} ${PROTO_VR}                                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${NODE_PREFIX} ${PROTO_H2}                                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   ${NODE_PREFIX} ${PROTO_VM}                                     ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} 维护命令:                                             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   改配置: vim /usr/local/bin/gen-subs.sh               ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   重建订阅: /usr/local/bin/gen-subs.sh                 ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}   服务状态: systemctl status xray hysteria-server caddy${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

#==============================================================================
#  ██████ 主流程 ██████
#==============================================================================
main() {
    TOTAL=14; STEP=0; SSH_CHANGED=0

    # ── 1. 配置 ──
    setup_config "$@"

    # SUB_TOKEN 持久化（不依赖 Caddy）
    mkdir -p /etc/vps-proxy
    echo "${SUB_TOKEN}" > /etc/vps-proxy/sub-token

    # ── 2. 检测 ──
    check_system
    auto_detect_region

    # ── 3. 系统优化 ──
    optimize_system

    # ── 4. 依赖 ──
    install_deps

    # ── 5. 密钥（已存在则复用）──
    if [ -f /etc/vps-proxy/subs.conf ]; then
        step "密钥生成"
        source /etc/vps-proxy/subs.conf
        info "检测到已有配置，复用密钥 (VL: ${VL_UUID:0:8}...)"
        # 确保新域名写入 config
        SERVER="${DOMAIN}"
    else
        generate_keys
    fi

    # ── 6. 防火墙 ──
    setup_firewall

    # ── 7. Xray ──
    if [ -x /usr/local/bin/xray ]; then
        step "安装 Xray"
        info "Xray 已安装，跳过"
    else
        install_xray
    fi

    # ── 8. Hysteria2 ──
    if [ -x /usr/local/bin/hysteria ]; then
        step "安装 Hysteria2"
        info "Hysteria2 已安装，跳过"
    else
        install_hysteria
    fi

    # ── 9. Caddy ──
    if [ -x /usr/bin/caddy ]; then
        step "安装 Caddy"
        info "Caddy 已安装，跳过"
        # 确保订阅目录存在
        mkdir -p /var/lib/subscription/${SUB_TOKEN} /var/lib/traffic-monitor
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

    # ── 14. SSH 端口（放到最后，不重启，用户手动操作）──
    setup_ssh

    if [ "$SSH_CHANGED" = 1 ]; then
        echo -e "${YELLOW}═══ 部署完成！SSH 端口修改待确认 ═══════════════════${NC}"
        echo -e "${YELLOW}请打开新终端，用以下命令测试连接：${NC}"
        echo -e "  ${CYAN}ssh $(whoami)@$(curl -s4 ifconfig.me 2>/dev/null || echo 'IP') -p ${SSH_PORT}${NC}"
        echo -e "${YELLOW}确认新端口可用后，执行：${NC}"
        echo -e "  ${CYAN}sudo systemctl restart sshd${NC}"
        echo ""
    fi
}

# 运行
main "$@"
