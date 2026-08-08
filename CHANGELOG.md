# CHANGELOG

> 每次改动的操作日志、优化理由、技术决策记录
> 仓库：https://github.com/Erwin-lark/vps-proxy-deploy

---

## v3.1.1 — Bug 紧急修复 (2026-08-08)

### 修复 Bug 汇总

| # | 严重度 | 问题 | 根因 | 修复 |
|---|--------|------|------|------|
| 1 | 🔴 关键 | 订阅门户 clash/loon 下载链接 404 | `gen_index()` 中 `href="${SUBDIR}/..."` 展开为文件系统路径 `/var/lib/subscription/<token>/clash.yaml`，浏览器将其当 URL 拼接导致路径重复 | 改为相对路径 `href="clash.yaml"`（与 index.html 同目录） |
| 2 | 🔴 关键 | 订阅门户页面标题空白 | `subs.conf` 只存了 `NODE_VR/H2/VX`（已拼接最终值），未存 `NODE_PREFIX` 本身；`gen_index()` 引用 `${NODE_PREFIX}` 时为空 | `subs.conf` 新增 `NODE_PREFIX="${NODE_PREFIX}"` |
| 3 | 🟡 中等 | ACME 证书多文件时等待循环永不 break | `[ -f /var/lib/hysteria/acme/*.crt ]` — glob 匹配多个文件时 `[ -f a.crt b.crt ]` 为语法错误，返回 2，`&& break` 短路 | 改为 `ls .../*.crt >/dev/null 2>&1 && break` |
| 4 | 🟡 中等 | 旧 443 端口服务被意外恢复，与 Xray 冲突 | `_kill_port 443` 将旧服务加入 `STOPPED_SERVICES`，后续 `_restore_ports` 无差别恢复所有暂停服务 | `_kill_port` 新增 `permanent` 参数（第 3 参数），Xray 占 443 时传 `true` 跳过恢复队列 |
| 5 | 🟢 轻微 | VMess→XHTTP 迁移后 CDN 断连 | 新 `XHTTP_PATH` 是 `-xhttp` 结尾，旧 `VMESS_WS_PATH` 是 `-vm` 结尾，CF Tunnel 仍指向旧路径 | 迁移时增加 warn 提示手动更新 Tunnel Public Hostname |

### 额外修正
- 去掉 `gen_index()` 中所有 `\"` 无效转义（外层 `'GEOF'` 已阻止展开，`\"` 被原样输出为字面反斜杠+引号，破坏 HTML 属性解析）
- `href="/traffic/"` 和 `href="/vps-deploy.sh"` 同理修复

---

## v3.0 — VMess→VLESS XHTTP + DNS-01 + 安全加固 (2026-08-07)

### 协议升级：VMess WebSocket → VLESS XHTTP

**理由**：
- VLESS 无加密开销，比 VMess 轻量约 15%
- XHTTP 是 Xray-core 1.8+ 新传输协议，支持 `mode: auto`（自动选择 stream/packet-up），兼容 CDN 更优
- 统一协议族：全部 VLESS Reality + VLESS XHTTP + Hysteria2，不再混用 VMess

**迁移兼容**：
- 首次部署直接生成 VLESS XHTTP 配置
- 已有 VMess 配置的 VPS 重跑脚本时，自动从 `VMESS_UUID` 迁移到 `XHTTP_UUID`
- `VMESS_WS_PATH` 自动转为 `XHTTP_PATH`（详见 v3.1.1 Bug #5 修复）

### ACME DNS-01 支持

**理由**：
- HTTP-01 需要临时开放 80 端口做 HTTP 验证，部分 VPS 提供商封锁 80 端口
- DNS-01 通过 Cloudflare API 添加 TXT 记录验证，全程无需开放任何 HTTP 端口
- 更安全：证书获取无需暴露任何对公网的服务

**实现**：
- 新增 `ACME_MODE_ENV` 环境变量（`http`/`dns`），默认 `http`
- DNS-01 模式需 `CF_DNS_TOKEN_ENV`（Cloudflare API Token，权限：Zone:DNS:Edit）
- Hysteria 配置文件按模式追加对应 ACME 段
- DNS-01 模式下跳过端口 80 的 kill/restore/ufw 操作

### 路由与 DNS 增强

**新增 Xray 功能**：
- `dns` 模块：显式指定 `1.1.1.1, 8.8.8.8, localhost`，避免 DNS 泄漏
- `routing` 模块：`geosite:category-ads-all` → blackhole（广告黑洞路由），`geoip:private` → blackhole（内网 IP 阻断）
- `domainStrategy: IPIfNonMatch`：优先域名匹配，未命中回退 IP

**geo 数据文件**：
- 下载 `geosite.dat` + `geoip.dat` 到 `/usr/local/share/xray/`
- 软链接到 `/usr/local/bin/`（Xray 默认搜索路径）
- 下载失败自动降级为无 geo 路由的精简配置

**理由**：
- 广告黑洞减少代理流量浪费
- 内网 IP 阻断防止 SSRF/内网探测
- 降级策略保证即使 GitHub 不可达也能正常部署

### 安全加固

**SSH 硬ening**（`harden_ssh` 函数）：
- `PermitRootLogin prohibit-password`：root 仅密钥登录
- `PasswordAuthentication no`：完全禁用密码
- `ChallengeResponseAuthentication no`：禁用键盘交互
- `X11Forwarding no`：关闭 X11 转发
- `MaxAuthTries 3`：3 次失败断开
- `ClientAliveInterval 60`：60 秒心跳防超时断连

**条件安全**：
- 仅在检测到 `/root/.ssh/authorized_keys` 有内容时才加固，避免没有密钥时锁死
- sshd 不自动重启，由用户确认新端口可用后手动 `systemctl restart sshd`

**用户清理**：
- 自动删除 cloud-init 遗留的 `ubuntu` 用户（如果无 SSH 密钥）
- 删除 `/etc/sudoers.d/90-cloud-init-users`

**凭证保护**：
- `chmod 600` 应用于所有密钥配置：Xray config、Hysteria config、subs.conf

### fail2ban 增强

**理由**：
- 旧版仅防护 SSH，Xray Reality 端口也会被扫描
- Xray 拒绝日志被 syslog 捕获（`rejected` 关键字），可做 fail2ban 触发源

**新增 jail**：
```
[xray-reject]
port     = 443,8443
filter   = xray-reject
logpath  = /var/log/syslog
maxretry = 5
bantime  = 3600
```

**DEFAULT 段配置**：
- `bantime.increment = true`：累进封禁
- `bantime.factor = 2`：每次翻倍
- `bantime.maxtime = 86400`：最长封 24 小时

### 端口智能管理 v2

**内核函数 `_kill_port`**：
- 自动识别端口占用进程所属 systemd 服务
- 有服务 → `systemctl stop` + 记录到 `STOPPED_SERVICES`（稍后恢复）
- 无服务 → `fuser -k` 直接杀进程（无法恢复）
- 区分永久/临时占用（v3.1.1 新增 `permanent` 参数）

**端口生命周期**：

| 端口 | 操作 | 可恢复 |
|------|------|--------|
| 443 (Xray) | 永久占用 | ❌ 不恢复 |
| 80 (ACME HTTP-01) | 临时占用 → 获证后恢复 | ✅ 自动恢复 |
| 8443 (Caddy) | 永久占用 | ❌ 手动处理 |
| 10001 (XHTTP) | 127.0.0.1 本地，无冲突 | — |

**信号捕获**：
- `trap '_restore_ports' INT TERM`
- 部署中断（Ctrl+C / SSH 断连）时，自动恢复被暂停的服务

### 断点续传增强

**UUID 持久化格式变更**：
- 旧版：`VL_UUIDS=(${VL_UUIDS[@]})`（bash 数组语法，source 后可能失效）
- 新版：独立存储 `VL_UUIDS_0/1/2` 三个变量，再从它们重建数组

**配置迁移**：
- 自动检测旧版 `subs.conf` 中的 `VMESS_UUID`，迁移为 `XHTTP_UUID`
- `SUB_TOKEN` 持久化到 `/etc/vps-proxy/sub-token`，重跑不轮换（保持订阅 URL 不变）

### 系统优化增强

**新增内核参数**：
```
net.ipv4.tcp_keepalive_time  = 600   # 10 分钟死连接探测（默认 7200）
net.ipv4.tcp_keepalive_intvl = 60    # 探测间隔
net.ipv4.tcp_keepalive_probes = 3    # 3 次失败判定死亡
```

**理由**：代理长连接场景下，默认 keepalive 2 小时太久，死连接堆积浪费资源

**journald 日志限额**：
```
SystemMaxUse=100M
```
**理由**：VPS 磁盘通常较小，journald 默认 4GB 上限可能撑满磁盘

### 安装健壮性

**Xray 安装双路径**：
1. 官方安装脚本（优先）
2. 直链下载 GitHub Release zip 解压（兜底）
3. 两次都失败 → err 但继续执行后续步骤

**Hysteria 安装错误处理**：
- 下载失败 → return 1 但不中断脚本
- LE 限速检测：检查 journal 中的 `rateLimited/rate limit/too many certificates` 关键字
- 提供明确的用户操作指引

### 摘要输出增强

- 显示被暂停/占用的端口清单（红/黄色提示）
- 区分「无法自动恢复」（红）和「稍后自动恢复」（绿）

---

## v2.5 — UX 改进 (2026-08-06)

### 前置 Cloudflare 确认

**理由**：最常见部署失败原因是用户跳过了 CF 手动配置。与其部署到一半报错，不如在开始前强制确认。

**实现**：
- 脚本启动后第一件事：红色警告框列出 3 项必须手动完成的 CF 操作
- `[y/N]` 确认，N → 显示详细操作指南，循环直到确认
- 非交互模式跳过此检查

### SSH 端口改为 opt-in

**理由**：
- 旧版自动将 SSH 改为 23277，对已有自定义端口的环境造成困扰
- 端口修改有锁死风险（防火墙未放行 → SSH 断连 → 再也连不上）

**改进**：
- 检测当前 SSH 端口，如果是 22 则**建议**修改（设随机高端口），默认 N
- 用户选 y 后才生成随机端口，但**不自动重启 sshd**
- 所有后续操作完成后，最后一个步骤才弹出 SSH 修改提醒
- 红色大框提示：「先开新终端测试新端口，确认可连后再重启 sshd」
- 防火墙同时放行新旧端口（ufw allow 两次）

### README 安装流程图

- 从「前置准备」到「部署完成」的完整 ASCII 流程图
- 每步标注自动/手动/强提醒
- 表格化端口管理、ACME 模式对比、环境变量参考

### Cloudflare Tunnel 强提醒

**理由**：即使 Tunnel 已安装并运行，如果没配 Public Hostname，CDN 节点永远不会通

**实现**：
- Tunnel 安装后输出红色大框提醒
- 填入具体 subdomain/domain/URL（从用户输入的域名自动推导）
- 非交互模式跳过回车确认，交互模式等待用户确认完成

---

## v2.4 — 部署脚本健壮性 (2026-08-05)

### 去掉 `set -e`

**理由**：
- `set -e` 导致任何非零退出码立即终止，不适合「尽力而为」的部署场景
- 例如 GitHub 偶发不可达导致 Xray 下载失败 → 整个脚本退出 → 后续服务全部没装

**替代方案**：
- 每个可能失败的操作用 `|| true` 或 `|| warn` 处理
- 关键步骤（Xray 安装失败）→ err 输出但继续执行

### Xray 安装 fallback

- 官方脚本失败 → 直接下载 GitHub Release zip
- zip 校验（`file` 命令检查是否为 Zip archive）
- geo 数据下载失败 → 自动移除 routing 块 → Xray 仍可启动

### 端口预检

**理由**：脚本需要占用 443/80/8443/10001 端口。如果已有服务在跑（如 nginx），直接 kill 会让用户措手不及。

**实现**：
- 部署前 `ss -tlnp` 扫描所有端口
- 显示占用进程名，标注 [永久占用] 或 [临时→恢复]
- 等待用户回车确认

---

## v2.3 — Cloudflare Tunnel 自动化 (2026-08-04)

### cloudflared 自动安装

**理由**：
- 旧版需要用户手动去 CF 下载 cloudflared、配置 systemd
- Token 提取容易出错（用户常复制整行命令而非仅 Token）

**改进**：
- 脚本自动检测架构、下载 deb 包、安装
- Token 输入自动用 `grep -oP 'eyJ[A-Za-z0-9_\-+/=\.]+'` 提取有效部分
- Token 无效时允许重新输入或跳过

### 服务编号修正

- 步骤计数器 bug：TOTAL 和实际步骤数不一致 → 修正为 TOTAL=14
- Xray 配置目录创建遗漏修复

---

## v2.2 — 部署零中断 (2026-08-03)

### 端口 80 临时接管与恢复

**理由**：Hysteria HTTP-01 验证需要 80 端口。如果有 nginx/apache 占用，旧的脚本直接报错退出。

**实现**：
- 暂停占用 80 端口的 systemd 服务
- ACME 验证完成后恢复
- 即使验证失败也恢复（避免原服务一直停着）

### Caddy 自动重启

- systemd override: `Restart=on-failure, RestartSec=5s`
- Hysteria: `RestartSec=30s` + `StartLimitBurst=5`（防 ACME 失败死循环）

---

## v2.1 — URL 修正 (2026-08-02)

### 安装命令 URL 修复
- 从自定义域名 `jp.dc3.alecyinshi.dpdns.org:8443` 改为 GitHub Raw URL
- 理由：不依赖已部署的 VPS 来下载脚本（先有鸡还是先有蛋问题）

---

## v2.0 — 统一订阅 (2026-08-01)

### 订阅格式统一

**旧版**：
- 3 个客户端 × 独立 clash.yaml（`clash-1.yaml`, `clash-2.yaml`, `clash-3.yaml`）
- VMess WS 作为 CDN 兜底

**新版**：
- 单文件 `clash.yaml` 包含全部 3 个协议节点（Clash Verge 统一）
- `loon.conf` 单独供 iPhone Loon 用户
- 自动生成 `index.html` 订阅门户页面

### 节点命名规范

格式：`{国旗} {国家码} {服务商码} {协议缩写}`

```
🇯🇵 JP BVL VR     ← VLESS Reality (低延迟 · 主力)
🇯🇵 JP BVL H2     ← Hysteria2   (高吞吐 · 弱网)
🇯🇵 JP BVL VX     ← VLESS XHTTP (兜底 · CDN 中转)
```

**理由**：
- 国旗 emoji 一目了然
- 空格分隔（非横线），与主流客户端显示一致
- 国家码 ISO 标准大写，服务商码自定义大写

### 地区自动检测

- 调用 `ip-api.com` 获取 VPS 所在国家
- 国家码 → 国旗 emoji（Unicode Regional Indicator 算法）
- 自动选择对应的 Reality 伪装目标（JP→nic.ad.jp, HK→hk01.com, US→bing.com 等）
- fail2ban 兜底：ip-api 不可用 → ifconfig.me + 重试

---

## v1.0 — 初始版本

### 核心功能

| 组件 | 版本 | 用途 |
|------|------|------|
| Xray-core | latest | VLESS Reality (主力) + VMess WebSocket (兜底) |
| Hysteria2 | latest | UDP QUIC 高性能代理 |
| Caddy | stable | 订阅门户 (8443) + VMess WS 反代 |
| vnstat + vnstati | apt | 流量监控 + PNG 图表 |
| fail2ban | apt | SSH 防爆破 |
| ufw | apt | 防火墙 |

### 系统优化
- BBR 拥塞控制 + fq qdisc
- TCP Fast Open (TFO=3)
- TCP 缓冲区调优（rmem=16M 适配跨境）
- `tcp_slow_start_after_idle=0`
- `tcp_notsent_lowat=16384`
- `vm.swappiness=10`

---
