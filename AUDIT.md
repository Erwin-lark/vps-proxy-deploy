# 严格审计报告

审计日期：2026-08-09
审计对象：`aa757e6`（原 main）及完整 Git 历史
修复分支：`audit/portable-v4`

## 结论

原 v3.1.1 不能作为“任意新 VPS 上可靠一键部署”的版本。它包含多项必现或高概率关键故障，其中一些是历史日志中已经修过、随后又被新提交重新引入的回归；另一些来自 CHANGELOG 中未经上游文档验证的技术假设。

v4 已重构关键路径；v4.1 为 Loon 增加了官方支持的 VLESS WebSocket CDN 节点；v4.1.1 又修复了输入校验晚于 `apt-get`、全新 Tunnel Token 出现在进程参数、origin 验收未强制回环监听等问题。本地验证覆盖 Bash 语法、ShellCheck、官方 Xray 配置解析、官方 Hysteria 实际启动解析、Mihomo 客户端配置解析，以及 XHTTP/WebSocket 分别经真实 Caddy 的端到端模拟，共 40 项回归断言。v4.1.0 已在现有 Ubuntu 22.04 `jp-bvl` 上完成从 v4.0 重跑，Reality、Hysteria2、XHTTP、WebSocket 四协议真实出站和服务状态均通过；v4.1.1 尚未声称完成一台可销毁的全新 Ubuntu/Debian VPS 系统级首装验证。

## 已确认的关键缺陷

| 严重度 | 原问题 | 可复现证据 | v4 处理 |
|---|---|---|---|
| Critical | Xray 重启后可能无法读配置 | 官方 Xray 安装器首次默认 `User=nobody`；v3 随后把配置设为 `root:root 600` | 专用 `xray` 用户，配置 `root:xray 640`，systemd 明确 `User=xray` |
| Critical | 重跑后 Reality 公钥为空 | v3 使用 `echo private | xray x25519 -i`；26.3.27 的 `-i` 必须带参数，实测返回 `flag needs an argument` | 使用 `xray x25519 -i "$REALITY_PRIVKEY"`，同时持久化公私钥并校验格式 |
| Critical | DNS-01 Cloudflare 必然配置错误 | Hysteria 官方字段为 `cloudflare_api_token`；v3 写成 `auth_token` | 改用官方字段并加入回归断言 |
| Critical | XHTTP 客户端指向错误入口 | v3 客户端用直连域名 `:8443` + TLS；Caddy 明确配置为 `http://domain:8443`，TLS 不可能匹配；Tunnel 又绕过 Caddy 指向 10001 | CDN 客户端改为独立 CDN 域名 `:443`；Tunnel 回源本地 Caddy 10000，再按秘密路径转发 10001 |
| Critical | 非交互模式会意外进入交互 | `install_cloudflared` 读取 `$1/$2`，但 main 调用时没有传参；ShellCheck SC2120/SC2119 已指出 | 使用全局、显式的非交互状态；配置缺失直接失败并说明 |
| Critical | 关键服务失败仍显示“部署完成” | v3 移除 `set -e` 后大量吞错，最终无条件打印绿色成功 | 严格模式；关键下载、配置解析、服务状态和真实代理出站任一失败即不打印成功 |
| High | HTTP-01 首次申请后关闭 80，续期会失败 | Hysteria 自己管理 ACME，续期时间不可预知；防火墙关闭 80 后 CA 无法访问挑战 | HTTP-01 明确长期允许 80/tcp；不接受“只首次临时开放”的错误说明 |
| High | 防火墙可能清空用户规则 | v3 以规则中是否出现字符串 `SSH` 判断首次运行，条件命中就 `ufw --force reset` | 只增量添加规则，从不 reset 或删除既有规则 |
| High | 会停止服务或杀死未知进程 | `_kill_port` 会停止 systemd 服务，无法识别时直接 `fuser -k`；非交互模式也可能发生 | 端口冲突只报告并停止部署，不自动停止/杀进程 |
| High | 自动 SSH 加固/删用户超出代理部署范围 | v3 自动禁密码、写 SSH 配置、删除 `ubuntu` 用户和 sudoers 文件；仅检查 root key，无法证明当前登录路径安全 | v4 不修改 SSH 认证、不换端口、不删用户；只检测当前实际端口供 UFW/fail2ban 使用 |
| High | 命令行/环境变量可污染被 source 的状态 | 非交互 domain/provider 未统一校验，随后写入并 `source /etc/vps-proxy/subs.conf` | 所有输入白名单校验；v4 状态用 `%q` 安全写入；旧文件只逐字段读取和格式验证 |
| High | 更新配置未必重启 Xray | v3 的 config-only 路径写完配置后执行 `systemctl enable --now`；服务已 active 时不会重启 | 配置先解析，再原子安装，然后明确 `systemctl restart` 和状态检查 |
| High | 明文 HTTP 分发全部节点凭证 | v3 在公网 `http://domain:8443/<token>` 提供 UUID、密码和公钥配置 | 在线订阅仅经 Cloudflare HTTPS；未启用 CDN 时只保留 root 可读本地文件 |
| High | 下载“latest”且不校验内容 | Xray 脚本远程执行、Hysteria/cloudflared 仅检查非空；404/HTML 也可能被移动为二进制 | 固定版本和每架构 SHA-256；CI 使用同一固定验证器 |
| High | 全新 Tunnel Token 作为进程参数传给 cloudflared | `cloudflared service install "$CF_TOKEN"` 会把 Token 放入子进程参数；同机特权观察者可读取 | v4.1.1 写入 `root:root 600` token 文件，受管 systemd 单元只使用 `--token-file` |
| Medium | ACME 证书等待仍检查错目录 | v3.1.1 从 `[ -f glob ]` 改成顶层 `ls *.crt`，但 CertMagic 证书通常在多层目录 | 使用递归 `find`，服务就绪还以真实 UDP 监听和协议自测为准 |
| Medium | 端口预检漏掉 UDP 443 | `_check_port` 始终调用 `ss -tlnp`，所以 Hysteria 的 UDP 冲突不可见 | TCP/UDP 分开检查 |
| Medium | 文档称会接管 8443，实际从未调用接管函数 | Caddy 遇到冲突只会启动失败 | v4 不公开 8443，Caddy 只监听本地 10000；冲突时安全停止 |
| Medium | 根域名按最后两段推断错误 | `co.uk`、委派子域、`dpdns.org` 等不能用最后两段推断 Cloudflare zone | 不推断 zone，要求明确提供完整 `CDN_DOMAIN_ENV` |
| Medium | Loon 生成未受官方支持的 XHTTP | Loon 官方协议列表包含 VLESS WS/HTTP/Reality，没有 XHTTP | v4.1 为 Loon 生成 Reality + Hysteria2 + VLESS WebSocket；XHTTP 仅写入 Mihomo 配置 |
| Medium | 无效输入仍先修改软件包状态 | main 在 `configure_inputs` 前执行 `apt-get update/install` | v4.1.1 先读取状态并验证所有输入；依赖齐全的重跑完全跳过 apt |
| Medium | CDN 内部端口验收只验证“有人监听” | `ss ... | grep -q .` 无法证明 10000/10001/10002 未意外暴露到公网地址 | v4.1.1 强制匹配 `127.0.0.1:<port>`，偏离即判关键验收失败 |
| Medium | 首次步骤计数与重跑不一致 | 首次 `generate_keys` 不调用 `step`，重跑分支才调用 | v4 移除误导性步骤计数，改为结果导向日志 |
| Low | 订阅门户的“部署脚本”链接仍 404 | HTML 链接修成 `/vps-deploy.sh`，但从未把文件放进 document root | 移除无效链接 |

## 对历史 CHANGELOG 结论的复核

以下说法不应继续作为设计依据：

- “VLESS 比 VMess 轻量约 15%”：仓库没有基准、测试条件或上游来源，不能用具体百分比陈述。
- “指定 1.1.1.1/8.8.8.8 可避免 DNS 泄漏”：这是服务器端解析选择，不等同于客户端 DNS 泄漏防护。
- “端口 80 临时开、获证后关”：只覆盖首次 HTTP-01，忽略自动续期。
- “零中断”：脚本曾主动停止服务、杀未知进程并覆盖配置，无法称为零中断。
- “凭证全部 chmod 600”：权限数值本身不是安全性的充分条件；当服务用户不是 root 时会直接造成不可读。旧订阅 token 文件还曾保持默认权限。
- “geo 下载失败自动降级即可保证部署”：旧下载未使用 `curl -f`，HTTP 错误页可能被当作成功文件；且只检查 geosite、不检查 geoip。
- “XHTTP 迁移要更新 Tunnel 路径”：Public Hostname 的 origin URL 与 XHTTP HTTP path 是两层概念。正确架构应由本地 HTTP 路由器按 path 分发。
- “协议优化可以把任意节点做到 100 ms 以下”：不成立。传播距离和运营商路由决定基础 RTT。

## v4.1 验证矩阵

| 验证 | 结果 |
|---|---|
| `bash -n` | 通过 |
| ShellCheck 0.11.0，severity=style | 通过，零诊断 |
| `git diff --check` | 通过 |
| Xray 26.3.27 服务端 Reality + XHTTP + WebSocket 配置解析 | 通过 |
| Xray 26.3.27 Reality 自测客户端配置解析 | 通过 |
| Xray 26.3.27 XHTTP 自测客户端配置解析 | 通过 |
| Xray 26.3.27 WebSocket 自测客户端配置解析 | 通过 |
| Hysteria 2.12.1 使用生成的 QUIC/BBR 字段实际启动 | 通过 |
| Mihomo 1.19.29 解析生成的 Clash 配置 | 通过 |
| Caddy 2.11.4 配置解析 + Cloudflare Host 真实请求 | 通过 |
| Xray XHTTP `packet-up` → Caddy → Xray → HTTP 目标端到端模拟 | 通过 |
| Xray WebSocket → Caddy → Xray → HTTP 目标端到端模拟 | 通过 |
| 非交互 `main` 全路径无副作用模拟 | 通过 |
| 旧配置备份与失败恢复模拟 | 通过 |
| 安全/回归断言 | 40 项通过 |
| 现有 Ubuntu 22.04 `jp-bvl` 从 v4.0 重跑、四协议真实出站、服务重启后复检 | 通过 |

CI 文件：`.github/workflows/validate.yml`
本地测试：`tests/audit-tests.sh`

## 上游依据

- Xray REALITY 官方文档：<https://xtls.github.io/en/config/transports/reality.html>
- Xray 传输配置：<https://xtls.github.io/en/config/transport.html>
- Xray XHTTP 设计与 CDN 兼容模式：<https://github.com/XTLS/Xray-core/discussions/4113>
- Xray WebSocket 传输：<https://xtls.github.io/en/config/transports/websocket.html>
- Hysteria 服务端完整配置：<https://hysteria.network/docs/advanced/Full-Server-Config/>
- Hysteria ACME DNS 配置：<https://hysteria.network/docs/advanced/ACME-DNS-Config/>
- Cloudflare Tunnel 路由：<https://developers.cloudflare.com/tunnel/routing/>
- Caddy Automatic HTTPS：<https://caddyserver.com/docs/automatic-https>
- Mihomo VLESS/XHTTP：<https://wiki.metacubex.one/en/config/proxies/transport/>
- Loon 节点支持列表：<https://nsloon.app/docs/Node/>
- Caddy WebSocket reverse proxy：<https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>

REALITY 官方明确提示：认证失败流量会被转发到 target；若 target 是特殊 CDN IP，服务器可能被扫描后滥用。v4 会在 VPS 上验证 target 的 TLS 1.3 与 SNI 行为，但“同 ASN target”无法仅靠通用脚本可靠自动化，未知国家因此要求显式提供 `REALITY_TARGET_ENV`。

## 尚未消除的边界

1. **缺少一次可销毁新 VPS 的端到端系统级验收。** 配置解析不等价于验证 apt、systemd、UFW、ACME、Cloudflare 控制面在所有发行版组合上的真实行为。
2. **Cloudflare Public Hostname 仍需控制面操作。** Token 只能注册 connector，不能证明 hostname 已映射到 `127.0.0.1:10000`；v4 会把未完成状态标成 pending，而不是成功。
3. **Reality target 会随网络和站点运维变化。** 今天支持 TLS 1.3 不代表永久适合；每次安装会重新探测。
4. **版本固定意味着需要维护。** 固定版本提高可复现性，但不会自动获得上游安全更新；升级必须复核配置兼容并更新 SHA-256/CI。
5. **延迟无脚本保证。** v4 的真实出站自测证明协议能转发，不代表客户端侧 RTT 小于 100 ms。

在交付“任意新 VPS 可用”结论前，最低还应在一台临时 Ubuntu 22.04/24.04 或 Debian 12/13 VPS 上完成：首次安装、重跑、重启、证书续期路径、Reality/Hysteria/XHTTP/WebSocket 客户端真实连接和回滚演练。
