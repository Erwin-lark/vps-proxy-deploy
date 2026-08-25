# VPS 代理节点部署脚本

在一台干净的 Ubuntu/Debian VPS 上部署：

- VLESS + XTLS Vision + REALITY（TCP 443，主力）
- Hysteria 2（UDP 443，弱网/高吞吐）
- 可选 VLESS XHTTP（Cloudflare Tunnel，Mihomo 备用线路）
- 可选 VLESS WebSocket（同一 Tunnel，Loon/Quantumult X/Mihomo CDN 备用线路）

v4 的目标是可审计、可重跑、失败不伪装成成功。脚本不依赖任何既有 VPS，也不会修改 SSH 登录方式、删除用户、清空既有防火墙规则或自动杀死端口占用进程。

节点名称只包含国旗、国家码和协议缩写，例如 `🇯🇵 JP VR`；v4.1.2 起不再要求、保存或显示服务商代码。

v4.1.3 为首装失败增加阶段标记和待提交状态，安全重跑会复用已生成凭证；同时会审查并修复无链接的 Hysteria ACME 遗留属主，避免服务用户无法读写证书目录。

v4.2.0 新增 Quantumult X 原生节点资源 `qx.conf`：直连 Reality 使用独立 UUID，启用 CDN 时再加入 VLESS WebSocket。不生成 Quantumult X 当前不支持的 Hysteria2 或 XHTTP 伪节点。

首次部署、Cloudflare 两枚 Token、Tunnel “尚未检测到连接”、Public Hostname、Clash/Loon/Quantumult X 导入、统一测速、更新、回滚和逐项排错，请直接阅读 **[从零部署超详细手册](MANUAL.md)**。

## 支持范围

| 项目 | 支持 |
|---|---|
| 系统 | 使用 systemd 的 Ubuntu 20.04+、Debian 11+ |
| 架构 | x86_64/amd64、aarch64/arm64 |
| 权限 | root；云厂商普通用户可通过免密 sudo 执行 |
| 网络 | 至少一个公网 IPv4 或可直达的公网 IPv6 |
| 域名 | 直连域名必须解析到 VPS，Cloudflare **DNS only/灰云** |

容器内、非 systemd 系统、共享端口 NAT VPS、OpenVZ 内核限制环境不承诺支持。脚本会在修改系统前尽早拒绝明显不兼容的环境。

## 部署前准备

必需：

1. 为直连节点准备域名，例如 `node.example.com`。
2. Cloudflare DNS 中添加 A/AAAA 记录并保持灰云（DNS only）。
3. 准备有效邮箱供 ACME 注册使用。

可选 CDN（XHTTP + WebSocket）：

1. 准备另一个域名，例如 `cdn.node.example.com`。
2. 在 Cloudflare Zero Trust 创建 Tunnel，复制 `eyJ...` Token。
3. 脚本完成后，在 Tunnel 的 Routes 中添加 Published application，Service URL 设为 `http://127.0.0.1:10000`。

不要把直连域名开成橙云；Reality TCP 和 Hysteria UDP 必须直达 VPS。

## 快速开始

先下载，再运行；不要使用未经检查的 `curl | bash`：

```bash
curl -fLo vps-deploy.sh \
  https://raw.githubusercontent.com/Erwin-lark/vps-proxy-deploy/main/vps-deploy.sh
chmod +x vps-deploy.sh
sudo bash vps-deploy.sh
```

若同时下载了 `SHA256SUMS`，先在 Linux 执行 `sha256sum -c SHA256SUMS`，或在 macOS 执行 `shasum -a 256 -c SHA256SUMS`，确认脚本与发布版本一致。

基础非交互部署（Reality + Hysteria2）：

```bash
sudo bash vps-deploy.sh node.example.com admin@example.com
```

加入 Cloudflare Tunnel/XHTTP/WebSocket：

```bash
CDN_DOMAIN_ENV=cdn.node.example.com \
CF_TOKEN_ENV='eyJ...' \
sudo --preserve-env=CDN_DOMAIN_ENV,CF_TOKEN_ENV \
  bash vps-deploy.sh node.example.com admin@example.com
```

DNS-01（无需 HTTP-01，但每次重写 Hysteria 配置时都要重新传 Token）：

```bash
ACME_MODE_ENV=dns \
CF_DNS_TOKEN_ENV='Cloudflare-DNS-API-Token' \
sudo --preserve-env=ACME_MODE_ENV,CF_DNS_TOKEN_ENV \
  bash vps-deploy.sh node.example.com admin@example.com
```

DNS-01 + CDN：

```bash
ACME_MODE_ENV=dns \
CF_DNS_TOKEN_ENV='Cloudflare-DNS-API-Token' \
CDN_DOMAIN_ENV=cdn.node.example.com \
CF_TOKEN_ENV='eyJ...' \
sudo --preserve-env=ACME_MODE_ENV,CF_DNS_TOKEN_ENV,CDN_DOMAIN_ENV,CF_TOKEN_ENV \
  bash vps-deploy.sh node.example.com admin@example.com
```

## Cloudflare Public Hostname

启用 CDN 后，脚本会在本机建立以下链路：

```text
客户端 → https://cdn.node.example.com:443
       → Cloudflare Tunnel
       → http://127.0.0.1:10000 (Caddy，仅监听回环地址)
       ├→ /<xhttp-path> → Xray 127.0.0.1:10001
       ├→ /<websocket-path> → Xray 127.0.0.1:10002
       └→ /<subscription-token>/... → HTTPS 订阅与流量看板
```

在 Cloudflare Dashboard 中打开 `Networking → Tunnels → <Tunnel> → Routes → Add route → Published application`。多 Zone 账号要明确选对 Domain，然后填写：

```text
Public hostname: cdn.node.example.com
Service URL:     http://127.0.0.1:10000
```

不是 `127.0.0.1:10001` 或 `127.0.0.1:10002`。这两个端口分别是 Xray 的 XHTTP 与 WebSocket 内部入口，由 Caddy 根据独立秘密路径分流。客户端统一使用 CDN 域名的标准 TLS 443。

完成 Cloudflare 设置后运行：

```bash
sudo bash vps-deploy.sh --check
```

检查会真实启动本机临时客户端，通过 Reality、Hysteria2，以及已就绪的 XHTTP、WebSocket 节点访问外网；只有真实代理出站成功才算协议自测通过。

如果安装中断，不要删除 `/etc/vps-proxy/install-phase` 或 `/etc/vps-proxy/state.pending`。排除日志中的原因后用相同参数和 Token 重跑；全部健康检查通过后待提交状态才会转为正式 `state.env`。详见 [MANUAL.md](MANUAL.md)。

## ACME 模式

| 模式 | 环境变量 | 防火墙要求 | 说明 |
|---|---|---|---|
| HTTP-01（默认） | `ACME_MODE_ENV=http` | 80/tcp 必须长期允许 | Hysteria 自行续证，续证时间不可预知，不能在首次申请后关闭 80 |
| DNS-01 | `ACME_MODE_ENV=dns` + `CF_DNS_TOKEN_ENV` | 不需要 80/tcp | Cloudflare 配置键使用官方的 `cloudflare_api_token` |

DNS Token 只写入权限为 `root:hysteria 640` 的 Hysteria 配置，不写入 v4 状态文件。重跑 DNS-01 安装时必须再次提供。

## 端口

| 端口 | 协议 | 对公网 |
|---|---|---|
| 当前 SSH 端口/tcp | SSH | 是；脚本从当前连接或 `sshd -T` 检测，不修改端口 |
| 443/tcp | VLESS Reality | 是 |
| 443/udp | Hysteria2 | 是 |
| 80/tcp | HTTP-01 申请和续期 | 仅 HTTP-01 模式 |
| 10000/tcp | Caddy Tunnel origin | 否，只监听 127.0.0.1 |
| 10001/tcp | Xray XHTTP origin | 否，只监听 127.0.0.1 |
| 10002/tcp | Xray WebSocket origin | 否，只监听 127.0.0.1 |

UFW 采用增量规则，不执行 `ufw reset`。如果要自行管理防火墙：

```bash
MANAGE_UFW_ENV=0 sudo --preserve-env=MANAGE_UFW_ENV \
  bash vps-deploy.sh node.example.com admin@example.com
```

脚本遇到端口冲突会停止并报告，不会停止服务或 `fuser -k` 杀进程。

## 客户端配置

启用 CDN 后：

```text
Clash: https://<CDN_DOMAIN>/<token>/clash.yaml
Loon:  https://<CDN_DOMAIN>/<token>/loon.conf
Quantumult X: https://<CDN_DOMAIN>/<token>/qx.conf
```

未启用 CDN 时，文件只保存在 VPS：

```text
/var/lib/subscription/<token>/clash.yaml
/var/lib/subscription/<token>/loon.conf
/var/lib/subscription/<token>/qx.conf
```

可用 `scp` 取回。不要通过明文 HTTP 传输这些文件，它们包含节点凭证。

Loon 官方当前列出的传输没有 XHTTP，因此不会生成伪 XHTTP 节点。启用 CDN 后，Loon 配置包含 Reality、Hysteria2 和官方支持的 VLESS WebSocket；Clash/Mihomo 配置包含 Reality、Hysteria2、XHTTP 和 WebSocket。

Quantumult X 资源使用官方 VLESS Reality/Vision 与 VLESS WSS 字段。`VR` 始终生成，`VW` 只在启用 CDN 时生成；`H2` 与 `VX` 不会写入 `qx.conf`。请使用支持 VLESS Reality 的新版 Quantumult X；v4.2.0 以 1.7.0 官方示例字段为校验基线。

WebSocket 的优势是客户端兼容性，不是隐蔽性或最低延迟。Xray 上游提示 WebSocket 具有明显的 HTTP/1.1 Upgrade 特征，因此 Mihomo 优先保留 XHTTP，Loon 才使用 WebSocket 作为 CDN 兜底。

若要比较 Clash、Loon 与 Quantumult X 的测速数字，应统一测试地址与超时。例如各端都使用：

```text
https://cp.cloudflare.com/generate_204
3000 ms
```

Loon 可在主配置 `[General]` 中设置 `proxy-test-url = https://cp.cloudflare.com/generate_204` 与 `test-timeout = 3`。`loon.conf` 是节点订阅，不能替代 iPhone 上的 Loon 主配置；不同测试地址、超时或客户端测速实现得到的数字不能直接比较。

Quantumult X 可在主配置 `[general]` 中设置 `server_check_url = https://cp.cloudflare.com/generate_204` 与 `server_check_timeout = 3000`。

## 环境变量

| 变量 | 用途 |
|---|---|
| `DOMAIN_ENV` | 直连域名 |
| `EMAIL_ENV` | ACME 邮箱 |
| `COUNTRY_ENV` | 两位国家码；自动检测失败或需覆盖时使用 |
| `REALITY_TARGET_ENV` | `host:443`；未知地区必须显式设置 |
| `ACME_MODE_ENV` | `http` 或 `dns` |
| `CF_DNS_TOKEN_ENV` | Cloudflare DNS API Token |
| `CDN_DOMAIN_ENV` | Cloudflare Tunnel 公网域名；首次不设置则不启用 XHTTP、WebSocket 和在线订阅 |
| `CF_TOKEN_ENV` | Cloudflare Tunnel Token；只用于首次注册服务 |
| `MANAGE_UFW_ENV` | `1`（默认）或 `0` |
| `SKIP_DNS_CHECK_ENV` | 仅紧急情况下设 `1`；正常不要跳过 |

## 幂等、迁移与备份

- v4 状态：`/etc/vps-proxy/state.env`，`root:root 600`。
- 中断恢复：`/etc/vps-proxy/install-phase` 记录阶段，`state.pending` 在健康检查前保留已生成凭证；成功后前者删除、后者提升为 `state.env`。
- 旧版 `subs.conf` 只按字段读取并验证，不再 `source`，避免历史输入造成命令注入。
- Reality 私钥、公钥、Short ID、Clash/Loon/Quantumult X 独立 UUID、Hysteria 密码和订阅 Token 会在重跑时复用。
- 覆盖 Xray、Hysteria、Caddy 配置前会复制到 `/var/backups/vps-proxy/<timestamp>/`。
- 若新配置导致上述服务启动失败，脚本会自动恢复该次备份并尝试重启。
- 现有 cloudflared 服务不会被新 Token 静默覆盖。
- Xray 配置在安装前用官方二进制校验；客户端 Clash 配置由仓库 CI 使用 Mihomo 校验。

固定并校验的组件：

| 组件 | 版本 |
|---|---|
| Xray-core | v26.3.27 |
| Hysteria | v2.12.1 |
| Caddy | v2.11.4 |
| cloudflared | 2026.7.3 |

下载使用仓库中固定的 SHA-256；版本升级必须同步更新版本、校验值和 CI 验证器。

## 验收与维护

```bash
sudo bash vps-deploy.sh --check
systemctl status xray hysteria-server caddy cloudflared
journalctl -u xray -u hysteria-server --since '1 hour ago' --no-pager
```

仓库本地测试：

```bash
bash -n vps-deploy.sh tests/audit-tests.sh
shellcheck -S style vps-deploy.sh tests/audit-tests.sh
bash tests/audit-tests.sh
```

## 关于 100 ms 延迟

安装脚本不能让“任意 VPS”都低于 100 ms。延迟下限主要由客户端到机房的物理距离、运营商路由、晚高峰拥塞和丢包决定；BBR、QUIC、XHTTP 或 WebSocket 都不能突破传播时延。

要争取低于 100 ms：

1. 购买前从实际客户端网络测试机房测试 IP，连续测多个时段。
2. 优先选择物理距离近、回程线路合适的机房；不要只看 VPS 所在国家。
3. 部署后在客户端分别测试 Reality 和 Hysteria2；CDN/XHTTP/WebSocket 是可用性与兼容性兜底，不一定更低延迟。

更完整的缺陷证据、历史结论复核和剩余边界见 [AUDIT.md](AUDIT.md)。
