# VPS 一键部署脚本

三协议代理节点一键部署：**VLESS Reality + Hysteria2 + VMess (CDN)**

## 一键安装

```bash
curl -sLo vps-deploy.sh https://raw.githubusercontent.com/Erwin-lark/jp-bvl/main/vps-deploy.sh
sudo bash vps-deploy.sh
```

非交互式（跳过所有提问，直接传参）：
```bash
sudo bash vps-deploy.sh us-gcp.alecyinshis.com GCP
```

> 脚本完全独立，不依赖任何 VPS，所有组件从 GitHub 官方源下载。

---

## 架构

```
                   ┌──────────────────────────┐
                   │      客户端 (Clash / Loon) │
                   └──────┬──────────┬────────┘
                          │          │
            ┌─────────────┼──────────┼─────────────┐
            │ 直连 (灰云)   │          │  CDN (橙云)   │
            │ port 443     │          │  Cloudflare   │
            └──────┬───────┘          └──────┬───────┘
                   │                         │
    ┌──────────────┼──────────────┐          │
    │ VLESS Reality│  Hysteria2   │   VMess WS CDN  │
    │ XTLS Vision  │  UDP QUIC    │   (兜底节点)     │
    │ 低延迟 · 主力 │  高吞吐 · 弱网 │   Cloudflare Tunnel │
    └──────────────┴──────────────┴─────────────────┘
                   │
            ┌──────┴──────┐
            │ Xray + Caddy │
            │  + vnstat    │
            │ + fail2ban   │
            └─────────────┘
```

---

## 安装流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                       开始安装                                   │
│              curl + sudo bash vps-deploy.sh                     │
└─────────────┬───────────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────┐
│  输入域名                     │  ← us-gcp.alecyinshis.com
│  输入服务商代码               │  ← GCP
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  自动检测国家/地区             │
│  → 国旗 + 伪装目标             │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  询问 SSH 端口                │
│  当前 22 → 建议改 23277?     │
│  [y/N]                       │
└─────────────┬───────────────┘
              │
              ▼
    ╔═════════════════════════╗
    ║  脚本自动执行 (约 3 分钟) ║
    ║                         ║
    ║  [1/14]  系统检测        ║
    ║  [2/14]  地区检测        ║
    ║  [3/14]  BBR 系统优化    ║
    ║  [4/14]  安装依赖包      ║
    ║  [5/14]  生成密钥 UUID   ║
    ║  [6/14]  防火墙配置      ║
    ║  [7/14]  安装 Xray       ║
    ║  [8/14]  安装 Hysteria2  ║
    ║  [9/14]  安装 Caddy      ║
    ╚═════════════════════════╝
              │
              ▼
┌─────────────────────────────┐
│  ⚠️  Cloudflare Tunnel (手动) │
│                             │
│  1. 打开 CF Dashboard        │
│  2. 创建 Tunnel               │
│  3. 粘贴 Token (eyJ...)      │
│                             │
│  ⚠️ 必须手动配置:            │
│  Public Hostname:           │
│    → localhost:10001        │
└─────────────┬───────────────┘
              │
              ▼
    ╔═════════════════════════╗
    ║  脚本继续自动执行        ║
    ║                         ║
    ║  [11/14] 流量监控 vnstat ║
    ║  [12/14] 订阅生成器      ║
    ║  [13/14] fail2ban 安装   ║
    ║  [14/14] 服务状态检查    ║
    ╚═════════════════════════╝
              │
              ▼
┌─────────────────────────────┐
│  ✅ 部署完成                  │
│  输出订阅链接 + 流量看板      │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  SSH 端口修改 (如选择 y)      │
│  ⚠️ 红色警告框               │
│  手动测试新端口 → 重启 sshd   │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  🌐 Cloudflare DNS 手动添加  │
│                             │
│  直连: us-gcp.alecyinshis.com│
│        → A 记录 → VPS IP     │
│        → 🟡 灰云 (DNS only)  │
│                             │
│  CDN:  cdn-us-gcp-dc3      │
│        .alecyinshis.com     │
│        → CNAME → Tunnel     │
│        → 🟠 橙云 (Proxied)   │
└─────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────────┐
│                           🎉 全部完成                            │
│                                                                 │
│  将订阅链接导入 Clash Verge / Loon，开启系统代理即可              │
│                                                                 │
│  • Clash Verge: https://<域名>:8443/<token>/clash.yaml          │
│  • Loon:        https://<域名>:8443/<token>/loon.conf           │
│  • 流量看板:    https://<域名>:8443/traffic/                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## 部署后 Cloudflare 手动配置

| 步骤 | 操作 | 说明 |
|---|---|---|
| 1 | 创建 Tunnel | Cloudflare Zero Trust → Networks → Tunnels |
| 2 | 配置 Public Hostname | `cdn-xxx.alecyinshis.com` → `http://localhost:10001` |
| 3 | 粘贴 Token | 脚本会提示粘贴，自动提取有效部分 |
| 4 | 添加 DNS A 记录 | 直连域名 → VPS IP，**灰云** (不代理) |
| 5 | 添加 DNS CNAME | CDN 域名 → Tunnel，**橙云** (代理) |

> ⚠️ **第 2 步（Public Hostname → localhost:10001）必须手动完成**，脚本会弹出红色警告框提醒。

---

## 节点命名

```
🇺🇸 US GCP VR     ← VLESS Reality (主力)
🇺🇸 US GCP H2     ← Hysteria2 (高速)
🇺🇸 US GCP VM     ← VMess CDN (兜底)
```

格式：`{国旗} {国家码} {服务商码} {协议缩写}`（空格分隔）

---

## 支持的系统

- Ubuntu 20.04 / 22.04 / 24.04
- Debian 11 / 12
- 最低 1GB 内存
- root 权限

## 断点续传

脚本中断后重新运行，已安装的服务自动跳过，已生成的密钥自动复用。

## 维护命令

```bash
# 重新生成订阅
/usr/local/bin/gen-subs.sh

# 查看服务状态
systemctl status xray hysteria-server caddy cloudflared

# 修改配置
vim /etc/vps-proxy/subs.conf
/usr/local/bin/gen-subs.sh
```
