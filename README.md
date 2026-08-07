# VPS 三协议代理一键部署

**VLESS Reality + Hysteria2 + VLESS XHTTP (CDN)** 全自动部署脚本，零依赖任何 VPS。

---

## 快速开始

```bash
curl -sLo vps-deploy.sh https://raw.githubusercontent.com/Erwin-lark/vps-proxy-deploy/main/vps-deploy.sh
sudo bash vps-deploy.sh
```

非交互模式（跳过所有询问）：
```bash
# 基础非交互
sudo bash vps-deploy.sh my.example.com PROVIDER email@example.com

# 带 Cloudflare Tunnel
CF_TOKEN_ENV="eyJ..." sudo -E bash vps-deploy.sh my.example.com BVL

# DNS-01 证书模式（推荐，无需开 80 端口）
ACME_MODE_ENV=dns CF_DNS_TOKEN_ENV="cfut_..." sudo -E bash vps-deploy.sh my.example.com BVL
```

断点续传：脚本中断后重新运行，已安装的服务自动跳过，密钥和证书自动复用。

---

## 架构

```
                   ┌──────────────────────────────┐
                   │     客户端 (Clash / Loon)      │
                   └──────┬──────────┬─────────────┘
                          │          │
            ┌─────────────┼──────────┼──────────────┐
            │ 直连 (灰云)   │          │   CDN (橙云)   │
            │ port 443     │          │   Cloudflare   │
            └──────┬───────┘          └──────┬────────┘
                   │                         │
    ┌──────────────┼──────────────┐          │
    │ VLESS Reality│  Hysteria2   │  VLESS XHTTP CDN │
    │ XTLS Vision  │  UDP QUIC    │  (兜底节点)       │
    │ 低延迟 · 主力 │  高吞吐 · 弱网 │  Cloudflare Tunnel│
    └──────────────┴──────────────┴──────────────────┘
                   │
            ┌──────┴──────┐
            │ Xray + Caddy │
            │  + vnstat    │
            │ + fail2ban   │
            │  (SSH+Xray)  │
            └─────────────┘
```

---

## 完整流程图

```
┌─────────────────────────────────────────────────────────────────┐
│  前置准备（在 Cloudflare 手动操作，运行脚本前完成）                │
│                                                                 │
│  ① 添加 DNS A 记录 (灰云)  →  域名 → VPS IP                     │
│  ② 创建 Tunnel → 复制 Token (eyJ...)                            │
│  ③ 配置 Public Hostname  →  cdn-xxx.域名 → localhost:10001      │
│  ④ 添加 DNS CNAME (橙云)   →  cdn-xxx.域名 → cfargotunnel.com   │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  运行脚本: curl + sudo bash vps-deploy.sh                        │
└─────────────────────────────┬───────────────────────────────────┘
                              │
                              ▼
╔═════════════════════════════════════════════════════════════════╗
║  🔴 强提醒 ①：CF 前置确认                                       ║
║  ① DNS A 记录?  ② Tunnel + Token?  ③ Public Hostname?          ║
║  以上 3 项已完成? [y/N]                                         ║
║  → n: 显示操作指南，循环确认                                     ║
║  → y: 继续                                                      ║
╠═════════════════════════════════════════════════════════════════╣
║  🔴 强提醒 ②：端口预检                                          ║
║  检查: 443 / 80 / 8443 / 10001                                  ║
║  · 如被占用 → 显示进程名 → 告知将暂停并自动恢复                  ║
║  · 如空闲 → ✓ 空闲                                               ║
║  继续部署? [回车继续 / q 退出]                                   ║
╠═════════════════════════════════════════════════════════════════╣
║  输入域名 (空值循环重输 · 含格式校验)                              ║
║  ├→ 自动识别服务商代码: GCP [回车确认 / n 重输]                 ║
║  输入邮箱 (含@和. 否则循环重输)                                  ║
║  当前 SSH: 22 → 建议改随机高端口? [y/N]                          ║
╚═════════════════════════════════════════════════════════════════╝
                              │
                              ▼
    ╔══════════════════════════════════════════════════╗
    ║          🤖 自动安装 (约 3 分钟)                  ║
    ╠══════════════════════════════════════════════════╣
    ║  [1/14]  系统检测       OS · 内存 · root · py3   ║
    ║  [2/14]  地区检测       国家 · 国旗 · 伪装目标    ║
    ║  [3/14]  系统优化       BBR · TCP · keepalive    ║
    ║  [4/14]  安装依赖       curl wget python3 ufw    ║
    ║  [5/14]  密钥生成       UUID 复用或重新生成       ║
    ║  [6/14]  防火墙         ufw 新旧端口双放行        ║
    ║  [7/14]  安装 Xray      VLESS Reality + XHTTP    ║
    ║           ├ geo 分流下载 (带重试+fallback)        ║
    ║           ├ DNS 分流: 1.1.1.1 + 8.8.8.8         ║
    ║           ├ 广告黑洞 + 私网阻断                   ║
    ║  [8/14]  安装 Hysteria2  ACME 证书获取            ║
    ║           ├ HTTP-01 模式: 临时开80→获证→关80     ║
    ║           ├ DNS-01 模式: CF API 验证 (无需80)    ║
    ║           ├ 轮询等证书: 最多60秒                  ║
    ║  [9/14]  安装 Caddy     订阅门户 :8443            ║
    ║           ├ 重跑自动更新 Caddyfile                ║
    ╠══════════════════════════════════════════════════╣
    ║  [10/14] 🔴 Cloudflare Tunnel                     ║
    ║           是否安装? [Y/n] (非交互: CF_TOKEN_ENV)   ║
    ║           粘贴 Token → 自动提取 eyJ 有效部分       ║
    ║           🔴 红色强提醒: 确认已手动配 PH           ║
    ╠══════════════════════════════════════════════════╣
    ║  [11/14] 流量监控       vnstat + cron 每5分钟     ║
    ║  [12/14] 订阅生成器     clash.yaml + loon.conf    ║
    ║  [13/14] fail2ban       SSH防爆破 + Xray防扫描    ║
    ║  [14/14] 服务状态检查   全部服务 ✅/❌             ║
    ╚══════════════════════════════════════════════════╝
                              │
                              ▼
    ╔══════════════════════════════════════════════════╗
    ║          🔐 安全加固 (自动执行)                   ║
    ╠══════════════════════════════════════════════════╣
    ║  SSH 硬ening: 仅密钥 · 禁密码 · 禁X11 · 3次锁定 ║
    ║  删除 ubuntu 用户 (NOPASSWD sudo)               ║
    ║  凭证文件 chmod 600                              ║
    ╠══════════════════════════════════════════════════╣
    ║  SSH 端口修改 (如选择了 y)                       ║
    ║  ⚠️ 请手动确认新端口可用后再重启 sshd            ║
    ╚══════════════════════════════════════════════════╝
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  ✅ 部署完成                                                     │
│                                                                 │
│  服务器 IP · 域名 · 协议端口                                      │
│  Clash Verge 订阅: http://域名:8443/<token>/clash.yaml           │
│  Loon 订阅:       http://域名:8443/<token>/loon.conf             │
│  流量看板:        http://域名:8443/traffic/                       │
│                                                                 │
│  📋 端口变更报告                                                  │
│  HTTP-01 模式: 端口 80 临时开→获证→已关闭 ✅                      │
│  DNS-01 模式: 端口 80 全程关闭 ✅                                 │
│                                                                 │
│  🔴 SSH 加固已写入配置 (sshd 未重启，当前会话安全)                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 端口智能管理

```
端口 443 (VLESS Reality):
  被占用? → 暂停原 systemd 服务 → Xray 启动 → 不恢复 (Xray 需要)

端口 80 (仅 HTTP-01 ACME 模式):
  DNS-01 模式: 无需 80 端口，全程关闭
  HTTP-01 模式: 临时开 → 获证 → 关闭 (需 UFW 临时放行)

端口 8443 (Caddy):
  被占用? → 暂停 → 不恢复 (Caddy 需要)

端口 10001 (VLESS XHTTP):
  仅 127.0.0.1 监听，不对外 → Caddy 反代 → CF Tunnel
```

---

## ACME 证书模式

| 模式 | 环境变量 | 需要开端口 | 适用场景 |
|------|---------|-----------|---------|
| **HTTP-01** (默认) | 无需 | 80 (临时) | 简单部署，端口 80 可用 |
| **DNS-01** (推荐) | `ACME_MODE_ENV=dns` + `CF_DNS_TOKEN_ENV=...` | 无 | 生产环境，CF 托管域名 |

DNS-01 Token 创建：https://dash.cloudflare.com/profile/api-tokens → 编辑区域 DNS → 选择域名 → 复制 Token

```bash
# DNS-01 一键部署
ACME_MODE_ENV=dns CF_DNS_TOKEN_ENV="cfut_..." sudo -E bash vps-deploy.sh my.example.com BVL
```

---

## 前置准备（运行脚本之前）

| 步骤 | 操作 |
|---|---|
| ① DNS A | `你的域名` → VPS IP → 🟡 **灰云** (DNS only) |
| ② Tunnel | https://one.dash.cloudflare.com/ → Networks → Tunnels → Create → 复制 Token |
| ③ Public Hostname | Tunnel → Configure → Subdomain: `cdn-xxx` / HTTP / **`localhost:10001`** |
| ④ DNS CNAME | `cdn-xxx.域名` → `xxx.cfargotunnel.com` → 🟠 橙云 |
| ⑤ DNS-01 Token (可选) | API Token → 编辑区域 DNS → 选择域名 |

> ⚠️ 第③步不完成 = CDN 节点永远不通。脚本有红色强提醒。
> 💡 DNS-01 模式下第⑤步可跳过 80 端口操作，推荐生产环境使用。

---

## 节点命名

```
🇯🇵 JP BVL VR     ← VLESS Reality (主力 · 低延迟)
🇯🇵 JP BVL H2     ← Hysteria2   (弱网加速 · 高吞吐)
🇯🇵 JP BVL VX     ← VLESS XHTTP (兜底 · Cloudflare CDN 中转)
```

格式：`{国旗} {国家码} {服务商码} {协议缩写}` — 空格分隔

---

## 环境变量参考

| 变量 | 用途 | 示例 |
|------|------|------|
| `DOMAIN_ENV` | 域名 | `my.example.com` |
| `PROVIDER_ENV` | 服务商标识 | `BVL` |
| `EMAIL_ENV` | Let's Encrypt 通知邮箱 | `admin@example.com` |
| `ACME_MODE_ENV` | 证书验证模式 | `http` (默认) / `dns` |
| `CF_DNS_TOKEN_ENV` | Cloudflare DNS API Token | `cfut_...` |
| `CF_TOKEN_ENV` | Cloudflare Tunnel Token | `eyJ...` |

---

## 订阅链接

| 客户端 | 格式 |
|---|---|
| Clash Verge | `http://<域名>:8443/<token>/clash.yaml` |
| Loon (iPhone) | `http://<域名>:8443/<token>/loon.conf` |
| 流量看板 | `http://<域名>:8443/traffic/` |

---

## 系统要求

| 项目 | 要求 |
|---|---|
| OS | Ubuntu 20.04+ / Debian 11+ |
| 架构 | x86_64 / ARM64 (aarch64) |
| 内存 | ≥ 1GB (<1GB 会警告) |
| 权限 | root (sudo) |
| 域名 | 托管在 Cloudflare |

---

## 断点续传

重跑脚本：已安装服务跳过 · 配置自动更新 · 密钥自动复用 · UUID 旧格式自动迁移 · 订阅 token 不变

---

## 安全特性

| 功能 | 说明 |
|------|------|
| SSH 加固 | 仅密钥登录 · 禁密码 · 禁 X11 · MaxAuthTries=3 |
| fail2ban | SSH 防爆破 + Xray 拒绝日志监控（双 jail） |
| 凭证保护 | 所有密钥文件 chmod 600 ·
| 域名校验 | 输入格式正则验证（防注入） |
| 信号捕获 | trap INT/TERM 自动恢复被暂停的服务 |
| ACME 限速保护 | systemd StartLimitBurst 防 LE 限额耗尽 |

---

## 维护

```bash
/usr/local/bin/gen-subs.sh                    # 重新生成订阅
systemctl status xray hysteria-server caddy   # 服务状态
vim /etc/vps-proxy/subs.conf                  # 修改配置
fail2ban-client status                        # 查看封禁状态
```
