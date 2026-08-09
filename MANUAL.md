# 从零部署手册：VPS、Cloudflare、Clash Verge 与 Loon

本文是 `vps-deploy.sh` 的逐步操作手册，面向一台全新的 Ubuntu/Debian VPS。它把必须手动完成的 DNS、Cloudflare Token、Tunnel、Public Hostname、客户端导入、验收和故障排查全部展开。

脚本当前部署四种出口：

| 简称 | 协议 | 客户端 | 公网入口 |
|---|---|---|---|
| VR | VLESS Reality | Clash/Mihomo、Loon | 直连域名 `443/tcp` |
| H2 | Hysteria2 | Clash/Mihomo、Loon | 直连域名 `443/udp` |
| VX | VLESS XHTTP + Cloudflare | Clash/Mihomo | CDN 域名 `443/tcp` |
| VW | VLESS WebSocket + Cloudflare | Clash/Mihomo、Loon | CDN 域名 `443/tcp` |

Loon 不支持 XHTTP，因此 Loon 正常情况下只有 `VR / H2 / VW` 三个节点；Clash/Mihomo 有 `VR / H2 / VX / VW` 四个节点。

## 0. 先理解三个名称

不要混淆以下对象：

1. **直连域名**：例如 `jp-bvl.example.com`。它是 Reality 和 Hysteria2 的入口，必须是 DNS only，也就是灰云。
2. **Tunnel 名称**：例如 `cdn-jp-bvl`。它只是 Cloudflare 控制台中的 Tunnel 标识，不是域名。
3. **CDN/Public Hostname**：例如 `cdn-jp-bvl.example.com`。它通过 Cloudflare Tunnel 回源 Caddy，必须经过 Cloudflare 代理。

正确链路如下：

```text
Reality 客户端  ── TCP 443 ──> 直连域名 ──> VPS Xray
Hysteria2 客户端 ─ UDP 443 ──> 直连域名 ──> VPS Hysteria2

XHTTP 客户端 ─┐
WebSocket 客户端 ─ HTTPS 443 ─> CDN 域名 ─> Cloudflare Tunnel
订阅下载 ─────┘                            │
                                           └─> http://127.0.0.1:10000
                                                ├─ XHTTP path -> 127.0.0.1:10001
                                                ├─ WS path    -> 127.0.0.1:10002
                                                └─ 订阅文件
```

Public Hostname 的 Service URL 永远填写 `http://127.0.0.1:10000`，不要填写 `10001`、`10002`，也不要填写 HTTPS。

## 1. 准备清单

部署前把下面每一项写下来。不要把真实 Token 写进本文、GitHub Issue、截图或聊天记录。

```text
SSH 别名：             <SSH_ALIAS>
VPS IPv4：             <VPS_IPV4>
SSH 端口：             <SSH_PORT>
直连域名：             <DIRECT_DOMAIN>
CDN 域名：             <CDN_DOMAIN>
Tunnel 名称：          <TUNNEL_NAME>
服务商代码：           <PROVIDER>
ACME 邮箱：            <EMAIL>
国家代码：             <COUNTRY>
Reality target：       <REALITY_TARGET>:443
Cloudflare 根 Zone：   <ZONE>
```

当前 `jp-bvl` 的非敏感示例是：

```text
SSH_ALIAS=jp-bvl
VPS_IPV4=216.238.54.105
SSH_PORT=23277
DIRECT_DOMAIN=jp-bvl.alecyinshis.com
CDN_DOMAIN=cdn-jp-bvl.alecyinshis.com
TUNNEL_NAME=cdn-jp-bvl
PROVIDER=BVL
EMAIL=alecyinshi@gmail.com
COUNTRY=JP
REALITY_TARGET=www.nic.ad.jp:443
ZONE=alecyinshis.com
```

系统要求：

- Ubuntu 20.04+ 或 Debian 11+；PID 1 必须是 systemd。
- `x86_64/amd64` 或 `aarch64/arm64`。
- VPS 有可用公网 IPv4，或者你明确理解 IPv6-only 部署。
- VPS 提供商允许 `443/tcp` 和 `443/udp`。
- 直连域名与 CDN 域名不能相同。
- 如果要求客户端延迟低于 100ms，必须在购买前从实际客户端网络测试候选机房 IP；脚本无法修复物理距离和运营商绕路。

## 2. 在 Mac 上建立 SSH 别名

如果已经可以执行 `ssh <SSH_ALIAS>`，跳过本节。

编辑 `~/.ssh/config`，为每台 VPS 使用独立 Host 块：

```sshconfig
Host <SSH_ALIAS>
    HostName <VPS_IPV4>
    User root
    Port <SSH_PORT>
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

修正本机权限：

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub
```

首次只测试登录，不修改 VPS：

```bash
ssh <SSH_ALIAS> 'printf "ssh-ok\n"; id; uname -a'
```

如果还没有安装公钥：

```bash
ssh-copy-id -i ~/.ssh/id_rsa.pub <SSH_ALIAS>
ssh -i ~/.ssh/id_rsa <SSH_ALIAS>
```

`setlocale: LC_ALL: cannot change locale` 是远端缺少对应 locale 的警告，不代表 SSH 密钥失败。不要为了消除警告而在部署前修改 SSH 登录方式。

## 3. Cloudflare 第一步：直连 DNS 记录

进入 Cloudflare Dashboard，选择根 Zone `<ZONE>`，打开 DNS Records。

新增或修改直连记录：

```text
Type:       A
Name:       <DIRECT_DOMAIN> 的主机部分
IPv4:       <VPS_IPV4>
Proxy:      DNS only（灰云）
TTL:        Auto
```

例如根 Zone 是 `alecyinshis.com`，完整域名是 `jp-bvl.alecyinshis.com`，Name 通常只填写 `jp-bvl`。

重要检查：

- 直连记录必须是灰云，不能是 Proxied/橙云。
- 如果 VPS 没有公网 IPv6，删除这个直连域名下残留的 AAAA。
- 不要先给 CDN 域名创建指向 VPS IP 的 A 记录；Tunnel 的 Public Hostname 会创建或接管 CDN CNAME。

Mac 上验证：

```bash
dig +short A <DIRECT_DOMAIN> @1.1.1.1
dig +short AAAA <DIRECT_DOMAIN> @1.1.1.1
```

A 记录必须只返回当前 VPS IPv4。没有 IPv6 时，AAAA 应为空。

## 4. Cloudflare 第二步：创建最小权限 DNS API Token

这个 Token 只供 Hysteria2 使用 DNS-01 申请和续期证书。它不是 Tunnel Token。

Cloudflare 操作路径：

1. 点击右上角用户图标。
2. 进入 **My Profile**。
3. 进入 **API Tokens**。
4. 点击 **Create Token**。
5. 选择 **Edit zone DNS** 模板；也可以创建 Custom Token。
6. Token name 填写容易识别的名称，例如 `<SSH_ALIAS>-hysteria-dns01`。
7. Permissions 保留 `Zone / DNS / Edit`。
8. Zone Resources 选择 `Include / Specific zone / <ZONE>`。
9. 不要授权 All zones，不要使用 Global API Key。
10. 点击 **Continue to summary**，复核后点击 **Create Token**。
11. Token 只显示一次，复制它，但不要粘贴到终端命令历史或文本文件。

Cloudflare 官方说明 Token 只显示一次；Hysteria 的配置字段必须是 `cloudflare_api_token`。

### 4.1 保存 DNS Token 到 macOS 钥匙串

先复制刚创建的 DNS Token，然后执行：

```bash
CF_DNS_TOKEN_FULL="$(pbpaste | tr -d '\r\n')"

if [[ ! "$CF_DNS_TOKEN_FULL" =~ ^[A-Za-z0-9_-]{20,128}$ ]]; then
  echo "错误：剪贴板内容不像 Cloudflare DNS API Token"
else
  security add-generic-password \
    -U \
    -a "$USER" \
    -s <SSH_ALIAS>-cf-dns-token \
    -w "$CF_DNS_TOKEN_FULL"
  echo "DNS Token 已保存到钥匙串"
fi

unset CF_DNS_TOKEN_FULL
```

当前 `jp-bvl` 使用的 service name 是：

```text
jp-bvl-cf-dns-token
```

只检查是否存在，不显示 Token：

```bash
security find-generic-password \
  -a "$USER" \
  -s <SSH_ALIAS>-cf-dns-token \
  -w >/dev/null && echo "DNS Token：存在"
```

## 5. Cloudflare 第三步：创建 Tunnel 并保存 Token

Cloudflare 控制台的名称可能随版本调整，通常路径是：

```text
Zero Trust -> Networks -> Connectors / Tunnels -> Create a tunnel
```

操作步骤：

1. Connector type 选择 **Cloudflared**。
2. Tunnel name 填写 `<TUNNEL_NAME>`，例如 `cdn-jp-bvl`。
3. 点击 Save tunnel。
4. 在安装页选择与 VPS 接近的系统选项。Ubuntu/Debian x86_64 选择 Debian 64-bit；ARM VPS 选择 ARM64。
5. 页面会显示一条 `cloudflared service install eyJ...` 命令。
6. **不要直接在 VPS 执行整条命令**。只复制它，让脚本安装固定版本并安全保存 Token。

此时页面显示“尚未检测到连接”是正常的，因为 VPS connector 还没有启动。不要反复删除 Tunnel。

### 5.1 从安装命令中提取 Token 并保存钥匙串

复制 Cloudflare 显示的完整安装命令，然后在 Mac 执行：

```bash
TUNNEL_INSTALL_CMD="$(pbpaste)"
TUNNEL_TOKEN_FULL="$(printf '%s' "$TUNNEL_INSTALL_CMD" |
  grep -oE 'eyJ[A-Za-z0-9_+/=-]+' |
  head -n 1)"

if [[ "$TUNNEL_TOKEN_FULL" != eyJ* ]]; then
  echo "错误：剪贴板中没有完整 Tunnel Token"
else
  security add-generic-password \
    -U \
    -a "$USER" \
    -s <SSH_ALIAS>-tunnel-token \
    -w "$TUNNEL_TOKEN_FULL"
  echo "Tunnel Token 已保存到钥匙串"
fi

unset TUNNEL_INSTALL_CMD TUNNEL_TOKEN_FULL
```

当前 `jp-bvl` 使用：

```text
jp-bvl-tunnel-token
```

只检查存在性：

```bash
security find-generic-password \
  -a "$USER" \
  -s <SSH_ALIAS>-tunnel-token \
  -w >/dev/null && echo "Tunnel Token：存在"
```

Tunnel Token 允许 connector 加入 Tunnel。若泄露，应在 Cloudflare Tunnel 页面 Rotate token，而不只是删除本机钥匙串条目。

## 6. 部署前只读检查 VPS

以下命令不会安装或修改配置：

```bash
ssh -T <SSH_ALIAS> '
  set -eu
  . /etc/os-release
  printf "OS=%s %s\n" "$ID" "$VERSION_ID"
  printf "ARCH=%s\n" "$(uname -m)"
  printf "PID1=%s\n" "$(ps -p 1 -o comm=)"
  printf "SSH_CONNECTION=%s\n" "${SSH_CONNECTION:-unknown}"
  ss -H -ltnp "sport = :443" || true
  ss -H -lunp "sport = :443" || true
  df -h /
'
```

预期：

- OS 是 Ubuntu/Debian。
- PID 1 是 systemd。
- 架构是 x86_64 或 aarch64。
- 新 VPS 的 443/tcp 和 443/udp 没有被其他服务占用。
- 至少保留约 1GB 可用磁盘空间。

若 443 已被 Nginx、Apache、旧代理或面板占用，脚本会停止，不会替你杀进程。

## 7. 把脚本放到 VPS

### 方法 A：从 GitHub main 下载

```bash
ssh -T <SSH_ALIAS> '
  set -Eeuo pipefail
  curl -fL --retry 3 \
    https://raw.githubusercontent.com/Erwin-lark/vps-proxy-deploy/main/vps-deploy.sh \
    -o /root/vps-deploy.sh
  chmod 0700 /root/vps-deploy.sh
  bash -n /root/vps-deploy.sh
  head -n 12 /root/vps-deploy.sh
'
```

确认头部 `SCRIPT_VERSION` 是 README 所述版本。不要使用不经检查的 `curl | bash`。

### 方法 B：从本地已审计仓库上传

在仓库目录执行：

```bash
scp vps-deploy.sh <SSH_ALIAS>:/root/vps-deploy.sh
ssh -T <SSH_ALIAS> 'chmod 0700 /root/vps-deploy.sh; bash -n /root/vps-deploy.sh'
```

## 8. 首次部署：安全传入两枚 Token

下面命令从 macOS 钥匙串读取两枚 Token，通过 SSH 标准输入传给脚本。Token 不会出现在 `ps` 命令行中；DNS Token 不写入 v4 状态文件，Tunnel Token 写入 VPS 上 `root:root 600` 的 `/etc/cloudflared/token`。

先把占位符替换成当前 VPS 的值：

```bash
{
  security find-generic-password \
    -a "$USER" \
    -s <SSH_ALIAS>-cf-dns-token \
    -w
  security find-generic-password \
    -a "$USER" \
    -s <SSH_ALIAS>-tunnel-token \
    -w
} | ssh -T <SSH_ALIAS> '
  set -Eeuo pipefail

  IFS= read -r CF_DNS_TOKEN_ENV
  IFS= read -r CF_TOKEN_ENV
  export CF_DNS_TOKEN_ENV CF_TOKEN_ENV
  export LC_ALL=C.UTF-8 LANG=C.UTF-8

  ACME_MODE_ENV=dns \
  CDN_DOMAIN_ENV=<CDN_DOMAIN> \
  COUNTRY_ENV=<COUNTRY> \
  REALITY_TARGET_ENV=<REALITY_TARGET>:443 \
  MANAGE_UFW_ENV=1 \
  bash /root/vps-deploy.sh \
    <DIRECT_DOMAIN> \
    <PROVIDER> \
    <EMAIL>

  unset CF_DNS_TOKEN_ENV CF_TOKEN_ENV
'
```

`jp-bvl` 的实际结构示例，不包含任何 Token：

```bash
{
  security find-generic-password -a "$USER" -s jp-bvl-cf-dns-token -w
  security find-generic-password -a "$USER" -s jp-bvl-tunnel-token -w
} | ssh -T jp-bvl '
  set -Eeuo pipefail
  IFS= read -r CF_DNS_TOKEN_ENV
  IFS= read -r CF_TOKEN_ENV
  export CF_DNS_TOKEN_ENV CF_TOKEN_ENV
  export LC_ALL=C.UTF-8 LANG=C.UTF-8

  ACME_MODE_ENV=dns \
  CDN_DOMAIN_ENV=cdn-jp-bvl.alecyinshis.com \
  COUNTRY_ENV=JP \
  REALITY_TARGET_ENV=www.nic.ad.jp:443 \
  MANAGE_UFW_ENV=1 \
  bash /root/vps-deploy.sh \
    jp-bvl.alecyinshis.com \
    BVL \
    alecyinshi@gmail.com

  unset CF_DNS_TOKEN_ENV CF_TOKEN_ENV
'
```

首次执行会：

- 安装缺失依赖，不会在依赖齐全的重跑中反复 `apt-get update`。
- 固定并校验 Xray、Hysteria2、Caddy、cloudflared 版本与 SHA-256。
- 写入 Reality/Hysteria2/Caddy/XHTTP/WebSocket 配置。
- 增量允许实际 SSH 端口、443/tcp、443/udp；不会 `ufw reset`。
- 启动服务并执行 Reality、Hysteria2 的真实代理出站测试。
- 启动 cloudflared connector。
- 如果 Public Hostname 尚未建立，显示“CDN 等待外部配置”，这不是直连协议失败。

如果命令在安装依赖、修改配置或重启服务前需要人工审批，应先审阅完整命令和影响，再执行。

## 9. 回到 Cloudflare：等待 Connector 连接

部署脚本运行到 cloudflared 后，回到 `<TUNNEL_NAME>` 的 Overview/Connectors 页面。

预期状态：

```text
Healthy / Connected
```

如果 1 分钟后仍未连接，在 VPS 只读检查：

```bash
ssh -T <SSH_ALIAS> '
  systemctl --no-pager --full status cloudflared
  journalctl -u cloudflared --since "10 minutes ago" --no-pager
  stat -c "%U:%G %a %n" /etc/cloudflared/token
'
```

Token 文件应为：

```text
root:root 600 /etc/cloudflared/token
```

不要把 `systemctl cat cloudflared` 的未脱敏输出发布到网络；历史安装方式可能把 Token 放在单元参数中。

## 10. 创建 Public Hostname

在 Cloudflare Zero Trust 中打开 `<TUNNEL_NAME>`，进入 Public Hostnames、Published Applications 或 Routes 页面，名称可能随控制台更新略有变化。

新增一条公网主机名：

```text
Subdomain:     <CDN_DOMAIN> 的主机部分
Domain:        <ZONE>
Path:          留空
Service Type:  HTTP
Service URL:   127.0.0.1:10000
```

例如：

```text
Hostname:      cdn-jp-bvl.alecyinshis.com
Service:       HTTP
URL:           127.0.0.1:10000
```

保存后检查 Cloudflare DNS：

- 应出现 CDN 主机名的 proxied CNAME/Tunnel route。
- CDN 记录应是橙云代理状态。
- CDN 主机名不要再保留指向 VPS IP 的旧 A/AAAA。
- 直连域名仍必须保持灰云。

Mac 上验证：

```bash
dig +short <CDN_DOMAIN> @1.1.1.1
curl -I --connect-timeout 10 https://<CDN_DOMAIN>/
```

根路径返回 404 并不一定是错误；真正验收使用脚本生成的秘密订阅路径。

## 11. Public Hostname 保存后的最终验收

```bash
ssh -T <SSH_ALIAS> '
  set -eu
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
  bash /root/vps-deploy.sh --check
'
```

必须看到以下项目全部通过：

```text
xray：active
hysteria-server：active
caddy：active
cloudflared：active
VLESS Reality 真实出站自测：通过
Hysteria2 真实出站自测：通过
Caddy 本地订阅：通过
Cloudflare HTTPS 订阅：通过
VLESS XHTTP/Cloudflare 真实出站自测：通过
VLESS WebSocket/Cloudflare 真实出站自测：通过
```

再检查监听范围：

```bash
ssh -T <SSH_ALIAS> '
  ss -H -ltnp "sport = :443 or sport = :10000 or sport = :10001 or sport = :10002"
  ss -H -lunp "sport = :443"
  ufw status numbered
'
```

正确结果：

```text
443/tcp          Xray，对公网
443/udp          Hysteria2，对公网
127.0.0.1:10000 Caddy，仅回环
127.0.0.1:10001 XHTTP，仅回环
127.0.0.1:10002 WebSocket，仅回环
```

10000、10001、10002 不应出现在 UFW 的公网允许规则中。

## 12. 获取订阅 URL

安装摘要会显示：

```text
Clash：https://<CDN_DOMAIN>/<SUB_TOKEN>/clash.yaml
Loon： https://<CDN_DOMAIN>/<SUB_TOKEN>/loon.conf
```

`SUB_TOKEN` 是订阅秘密。不要把完整 URL 发布到 GitHub、截图、公开测速网站或公共订阅转换服务。

如果忘记 URL，可在 VPS 本人可见的 root 会话中重新运行：

```bash
bash /root/vps-deploy.sh --check
```

## 13. Clash Verge 导入与刷新

### 13.1 直接作为独立配置导入

1. 打开 Clash Verge。
2. 进入 Profiles/订阅。
3. 新建 URL 类型订阅。
4. 粘贴脚本输出的 Clash URL。
5. 下载并启用该配置。
6. 进入 Proxies，确认出现：

```text
<国家> <服务商> VR
<国家> <服务商> H2
<国家> <服务商> VX
<国家> <服务商> VW
```

### 13.2 作为主配置的 proxy-provider

如果已有复杂分流主配置，把订阅 URL 填到 provider：

```yaml
proxy-providers:
  MY-VPS:
    type: http
    url: "https://<CDN_DOMAIN>/<SUB_TOKEN>/clash.yaml"
    path: ./proxy_providers/MY-VPS.yaml
    interval: 86400
    health-check:
      enable: true
      url: https://cp.cloudflare.com/generate_204
      interval: 300
      timeout: 3000
      lazy: true
      expected-status: 204
```

服务器更新节点后，要执行“更新 provider”，不只是点击节点测速。否则 Clash 可能继续缓存旧的三节点订阅，看不到 `VW`。

统一测速建议：

```text
URL:             https://cp.cloudflare.com/generate_204
Timeout:         3000 ms
Expected status: 204
```

`unified-delay: true` 可以让 Mihomo 使用统一延迟测量方式，但不能把真实路由延迟变低。

## 14. Loon 导入、刷新与统一测速

1. 在 Loon 中进入代理节点资源/订阅管理。
2. 新增 URL 资源。
3. 粘贴脚本输出的 `loon.conf` URL。
4. 保存并手动更新资源。
5. 预期只看到三项：

```text
VR
H2
VW
```

看不到 VX 是正常的，因为 Loon 官方支持 VLESS WebSocket/HTTP/Reality，但没有 XHTTP。

在 Loon 主配置的 `[General]` 设置：

```ini
proxy-test-url = https://cp.cloudflare.com/generate_204
test-timeout = 3
```

注意：`loon.conf` 是节点资源，不是 iPhone 的完整主配置，因此服务器无法替你修改这两个全局设置。

刷新后如果仍只有 `VR / H2`：

1. 确认服务器脚本版本至少是 v4.1。
2. 在 Loon 删除旧资源缓存后重新添加同一个 URL，或者强制刷新资源。
3. 在浏览器以本人身份打开订阅 URL，确认文本内有一行名称以 `VW = VLESS` 开头；不要把内容截图外发。
4. 运行服务器 `--check`，确认 WebSocket/Cloudflare 自测通过。

## 15. 如何正确比较延迟

不同客户端显示的数字只有在以下条件全部一致时才可比较：

- 同一设备或至少同一物理网络。
- 同一个测试 URL。
- 同一个超时时间。
- 同一轮测试，避免晚高峰变化。
- 区分 TCP、QUIC、Cloudflare Tunnel 的握手差异。

建议记录：

```text
日期和时间：
网络：Wi-Fi / 蜂窝；运营商：
测试 URL：https://cp.cloudflare.com/generate_204
VR：
H2：
VX：
VW：
连续测试次数：5
是否丢包：
```

判断方法：

- Wi-Fi 很慢、蜂窝很快：通常是家庭宽带到机房或 Cloudflare 的路由问题。
- 所有协议都接近同一个高延迟：通常是底层路由问题，不是协议配置。
- 只有 H2 失败：优先检查 UDP 443、运营商 UDP 限制和证书。
- 只有 VX/VW 失败：优先检查 Public Hostname 和 Tunnel。
- HK 机房低于 100ms、JP 同时高于 250ms：说明应更换路由更合适的 VPS，而不是继续堆 sysctl。

在购买新 VPS 前，向提供商索取测试 IP，并从真实 Wi-Fi 与蜂窝分别执行：

```bash
ping -c 20 <TEST_IP>
```

最低要求可设为：平均 RTT 小于 80ms、0% 丢包，为代理握手和抖动预留空间。只达到 95ms 的 ICMP 并不保证应用测速低于 100ms。

## 16. 常见故障

### 16.1 Tunnel 页面一直“尚未检测到连接”

原因：Tunnel 已创建，但 VPS 上 cloudflared 还没安装或 Token 错误。

检查：

```bash
systemctl status cloudflared
journalctl -u cloudflared --since "10 minutes ago" --no-pager
stat -c '%U:%G %a %n' /etc/cloudflared/token
```

不要因为首次尚未连接就删除 Tunnel。先完成第 8 节部署。

### 16.2 Cloudflare 返回 502/Bad Gateway

核对 Public Hostname：

```text
Service type = HTTP
URL = 127.0.0.1:10000
```

VPS 本地检查：

```bash
curl -I http://127.0.0.1:10000/
systemctl status caddy cloudflared
```

不要把 Service URL 设置成 CDN 域名、VPS 公网 IP、HTTPS、10001 或 10002。

### 16.3 DNS 校验说记录不指向本机

检查：

```bash
dig +short A <DIRECT_DOMAIN> @1.1.1.1
dig +short AAAA <DIRECT_DOMAIN> @1.1.1.1
curl -4 --noproxy '*' https://api.ipify.org
curl -6 --noproxy '*' https://api64.ipify.org
```

删除旧 IP、残留 AAAA，并确认直连记录是灰云。不要常态使用 `SKIP_DNS_CHECK_ENV=1` 掩盖错误。

### 16.4 Hysteria2 申请证书失败

检查：

- DNS Token 是否仍有效。
- Token 是否限制到正确 Zone。
- 权限是否为 `Zone / DNS / Edit`。
- 重跑 DNS-01 时是否再次传入 `CF_DNS_TOKEN_ENV`。
- Hysteria 日志是否有 Cloudflare API 错误。

```bash
journalctl -u hysteria-server --since "30 minutes ago" --no-pager
```

DNS Token 不会写入状态文件，所以每次重写 Hysteria DNS-01 配置都必须重新从钥匙串传入。

### 16.5 Hysteria2 节点超时，其他节点正常

```bash
ss -H -lunp 'sport = :443'
ufw status numbered
```

确认 443/udp 对公网允许。某些 Wi-Fi 会限制 UDP/QUIC；切换蜂窝网络是有价值的对照测试。

### 16.6 Clash/Loon 数字差异很大

先统一测试 URL 和超时，再比较。不同 URL 可能命中完全不同的 CDN、DNS 和网络栈；“客户端显示多少毫秒”不是单纯的 VPS ICMP RTT。

### 16.7 Xray 日志提示 WebSocket deprecated

这是上游对 WebSocket 传输的弃用提示。当前保留 VW 是为了 Loon CDN 兼容；Mihomo 优先保留 XHTTP。未来 Loon 若支持 XHTTP，或 Xray 真正移除 WebSocket，需要迁移，而不是忽略版本升级测试。

## 17. 日常只读检查

```bash
ssh -T <SSH_ALIAS> '
  bash /root/vps-deploy.sh --check
  systemctl is-active xray hysteria-server caddy cloudflared
  systemctl is-enabled xray hysteria-server caddy cloudflared
  ss -H -ltnp "sport = :443 or sport = :10000 or sport = :10001 or sport = :10002"
  ss -H -lunp "sport = :443"
  journalctl -u xray -u hysteria-server -u caddy -u cloudflared \
    --since "1 hour ago" --no-pager
'
```

`XHTTP context canceled` 若恰好出现在自测完成时，可能只是测试客户端获得结果后主动结束流，不等于协议失败；以 `--check` 的真实代理出站结果为准。

## 18. 更新脚本的安全流程

更新前：

1. 阅读 CHANGELOG 与 AUDIT。
2. 确认固定组件版本和 SHA-256 已更新。
3. 在本地通过 Bash、ShellCheck、Xray、Hysteria、Mihomo、Caddy 测试。
4. 上传为新文件名，不覆盖最后可用脚本。

示例：

```bash
scp vps-deploy.sh <SSH_ALIAS>:/root/vps-deploy-new.sh
ssh -T <SSH_ALIAS> '
  chmod 0700 /root/vps-deploy-new.sh
  bash -n /root/vps-deploy-new.sh
'
```

然后像首次部署一样，从钥匙串传 DNS Token；已有 cloudflared 服务时不需要再次传 Tunnel Token。更新会重启 Xray、Hysteria2、Caddy，可能有数秒中断，因此必须先说明影响并获得确认。

更新完成后立即执行：

```bash
bash /root/vps-deploy-new.sh --check
systemctl status xray hysteria-server caddy cloudflared --no-pager
```

## 19. 备份与回滚原则

脚本在覆盖 Xray、Hysteria、Caddy 配置前备份到：

```text
/var/backups/vps-proxy/<timestamp>/
```

只读列出备份：

```bash
find /var/backups/vps-proxy -maxdepth 2 -type f -printf '%TY-%Tm-%Td %TH:%TM %m %u:%g %p\n' | sort
```

不要看到错误就删除状态、证书或日志。回滚会覆盖当前配置并重启服务，必须先明确选择哪个时间戳、检查文件内容和权限，再执行恢复。

至少保存：

- 最后可用的部署脚本。
- `/etc/vps-proxy/state.env` 的 root-only 离线备份。
- Hysteria ACME 证书目录。
- Xray/Hysteria/Caddy 最近一次可用配置。

状态文件和订阅包含节点凭证，备份权限必须是 600，不能上传 GitHub。

## 20. Token 轮换

### DNS API Token

1. Cloudflare 创建新的同权限 Token。
2. 更新 macOS 钥匙串同名条目。
3. 用新 Token 重跑脚本并完成 Hysteria 自测。
4. 确认证书管理正常后撤销旧 Token。

### Tunnel Token

1. 在 Tunnel 页面选择 Rotate token。
2. 更新 macOS 钥匙串。
3. 把新 Token 安全写入 `/etc/cloudflared/token`。
4. 重启 cloudflared 并确认多个 edge connection 恢复。
5. Token 若已泄露，按 Cloudflare 官方说明强制断开旧连接。

轮换 Tunnel Token 会影响 connector 重新连接，应安排维护窗口；不要在没有回滚路径时直接删除 Tunnel。

## 21. 全新 VPS 最终验收清单

Cloudflare：

- [ ] 直连 A/AAAA 指向新 VPS。
- [ ] 直连记录灰云。
- [ ] DNS API Token 只授权目标 Zone 的 DNS Edit。
- [ ] Tunnel connector Healthy。
- [ ] CDN Public Hostname 指向 HTTP `127.0.0.1:10000`。
- [ ] CDN DNS 是 proxied Tunnel route，没有旧 A/AAAA。

VPS：

- [ ] `--check` 四协议真实出站全部通过。
- [ ] 四个 systemd 服务 active 且 enabled。
- [ ] 443/tcp 和 443/udp 对公网监听。
- [ ] 10000/10001/10002 只监听 127.0.0.1。
- [ ] UFW 保留实际 SSH 端口。
- [ ] `/etc/cloudflared/token` 是 root:root 600。
- [ ] Hysteria ACME 证书已生成。
- [ ] 重启 VPS 后再次通过 `--check`。
- [ ] 再次运行安装脚本后凭证不变化，节点仍可用。

客户端：

- [ ] Clash 显示 VR/H2/VX/VW。
- [ ] Loon 显示 VR/H2/VW。
- [ ] 两端使用相同测试 URL 和超时。
- [ ] Wi-Fi 与蜂窝分别测试。
- [ ] 记录丢包、平均值与波动，不只看一次数字。
- [ ] 实际网页、视频、UDP 应用均正常，而不只是测速按钮成功。

## 22. 上游资料

- Cloudflare API Token：<https://developers.cloudflare.com/fundamentals/api/get-started/create-token/>
- Cloudflare Tunnel setup：<https://developers.cloudflare.com/tunnel/setup/>
- Cloudflare Tunnel token 轮换：<https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/>
- Hysteria ACME DNS：<https://hysteria.network/docs/advanced/ACME-DNS-Config/>
- Xray Reality：<https://xtls.github.io/en/config/transports/reality.html>
- Xray WebSocket：<https://xtls.github.io/en/config/transports/websocket.html>
- Mihomo proxy-provider 健康检查：<https://wiki.metacubex.one/en/config/proxy-providers/>
- Loon 节点支持：<https://nsloon.app/docs/Node/>
- Loon 全局测速：<https://nsloon.app/docs/General/>
