# Lima Proxy v5.0 架构重构交接文档（供 Git 提交流程与后续维护）

**版本**：v5.0（健壮单状态机 + 全应用按需分流 + `launchd` 统一托管）  
**重构产物目录**：`/Users/herryzheng/Documents/antigravity/vpnfix/v5/`  
**前置快照目录**：`/Users/herryzheng/Documents/antigravity/vpnfix/snapshot/`（仅供审计对照，推送远程前建议忽略或按需清理）

---

## 1. 重构背景与修复的 4 大核心根因

1. **`launchd` 与脚本互相杀进程打架（导致反复重启、端口抢占、关不掉）**
   - **旧问题**：系统存在两个 `KeepAlive` 的 LaunchAgent（`com.user.lima-proxy-tunnel` 与 `com.user.lima-proxy-singbox`），但旧版 `lima-bridge.sh` 启动时直接 `pkill` + `nohup`/`ssh -f` 拉起孤儿进程，触发 `launchd` 不断重启抢端口；关闭时未 `launchctl bootout`，导致点“关闭代理”后 2 秒又自动复活。
   - **新方案**：`lima-bridge.sh` 成为唯一状态机，彻底废除 `nohup`/`ssh -f`，`on` 时统一通过 `launchctl bootstrap` + `kickstart` 托管，`off`/`panic-reset` 第一步即 `launchctl bootout` 彻底停干净。
2. **`utun99` 仅拦截 Google 网段（导致其他不读系统代理的原生应用/CLI 撞墙）**
   - **旧问题**：`mac-singbox.json` 的 `utun99` 仅通过 `route_address` 拦截 24 个 Google CIDR，其他原生 App / CLI 直连失败。
   - **新方案**：升级为全应用按需分流（`full-tun`）：`utun99` 开启 `auto_route: true` 并通过 `route_exclude_address` 排除所有私网/局域网/回环网段（保障 Mac mini 远程桌面与局域网设备不断连）；国内域名走 `geosite-cn.srs` + 常见国内域名直连，TUN 纯 IP 流量走离线 `geoip-cn.srs` 直连（不配远程 DoH，零 DNS 死锁），其余全部海外流量经 `127.0.0.1:17890` 透传至 Lima 虚拟机。
3. **节点切换无并发锁、无失败回滚、`dig @8.8.8.8` 易阻塞**
   - **旧问题**：`lima-proxy-switch.sh` 定义了 `LOCK_FILE` 却未启用；覆写 VM 内 `/etc/mini-work/sing-box.json` 与 `/etc/mini-work/root.nft` 前未备份，校验失败直接损坏虚拟机代理。
   - **新方案**：新增基于 `mkdir` 的原子目录锁；域名解析改为优先 `223.5.5.5` / 系统 DNS 并加 `+time=2 +tries=1` 限时；切换节点前自动在 VM 内备份 `.bak`，校验或重载失败立即自动回滚。
4. **Web UI 切窗口狂刷命令 + 按钮缺互斥锁 + 缺少 Mac 宿主机链路状态**
   - **旧问题**：`web/index.html` 的 `focus` 与 `visibilitychange` 同时无防抖触发 `limactl shell ... curl`；开启/关闭 Mac 代理按钮未加 `isOperating` 锁。
   - **新方案**：增加 5 秒防抖与全局操作互斥锁；顶部状态卡片新增实时链路健康条（VM / 隧道 17890 / 核心 7890 / 全应用 `utun99` / 外部 VPN 占坑提示）。

---

## 2. 变更文件清单与目标映射

| 重构源文件路径（`v5/` 下） | 部署目标路径 | 改动类型 | 核心改动摘要 |
| :--- | :--- | :--- | :--- |
| `v5/lima-proxy/lima-bridge.sh` | `~/.lima-proxy/lima-bridge.sh` | 重写 | 唯一状态机；原子目录锁；统一托管 `launchd`；Shadowrocket 只读互斥守卫；基于 `jq` 增量生成 `full-tun` / `proxy-only` 配置并自动 `sing-box check`；提供 `status --json` 与 `doctor`。 |
| `v5/lima-proxy/lima-proxy-daemon.sh` | `~/.lima-proxy/lima-proxy-daemon.sh` | 重构 | `tunnel` 禁用 `ControlMaster`、开启 `TCPKeepAlive` 与 10s 心跳；`singbox` 启动前强制校验配置并在无免密权限时平滑降级，防止崩溃重启风暴。 |
| `v5/lima-proxy/lima-proxy-switch.sh` | `~/.lima-proxy/lima-proxy-switch.sh` | 加固 | 启用原子目录锁；优化 DNS 解析超时与顺序；VM 配置/防火墙切换事务化（先备份 `.bak`，失败自动回滚）。 |
| `v5/lima-proxy/lima-proxy-reconnect.sh` | `~/.lima-proxy/lima-proxy-reconnect.sh` | 优化 | 修复 `jq` 参数注入写法，联动新版 `switch` 与 `lima-bridge.sh on`。 |
| `v5/lima-proxy/mac-proxy-bridge.sh` | `~/.lima-proxy/mac-proxy-bridge.sh` | 精简 | 瘦身为薄封装兼容层，统一 `exec` 转发至 `lima-bridge.sh`。 |
| `v5/lima-proxy/web/index.html` | `~/.lima-proxy/web/index.html` | 重构 | 新增 Mac 共享实时健康指示条；为所有桥接按钮加互斥锁；`focus`/`visibilitychange` 加 5 秒防抖。 |
| `v5/launchagents/com.user.lima-proxy-tunnel.plist.tmpl` | `~/Library/LaunchAgents/com.user.lima-proxy-tunnel.plist` | 新增模板 | `RunAtLoad=false`、`KeepAlive`（`SuccessfulExit=false`）、`ThrottleInterval=3`。 |
| `v5/launchagents/com.user.lima-proxy-singbox.plist.tmpl` | `~/Library/LaunchAgents/com.user.lima-proxy-singbox.plist` | 新增模板 | 同上，并在 `EnvironmentVariables` 中显式隔离代理环境变量防自回环。 |
| `v5/🚨紧急恢复Mac网络.command` | `~/Desktop/🚨紧急恢复Mac网络.command` | 加固 | 增加独立 `launchctl bootout` 二次兜底与 `utun99` 卸载校验。 |
| `v5/deploy_v5.sh` | （部署工具） | 新增 | 自动备份原配置至 `~/.lima-proxy/backups/<ts>/`，部署全套 v5 文件、安装 plist、清理旧 PAC 残留文件并运行 `doctor`。 |
| `v5/rollback_v5.sh` | （回滚工具） | 新增 | 一键回滚至最近一次部署前备份。 |
| `v5/ARCHITECTURE_V5.md` | （文档） | 新增 | v5.0 架构图与防呆三态操作手册。 |

---

## 3. 严格遵守的三大红线与安全注意事项

1. **绝不破坏 VM 原生隔离**：仅通过 `lima-proxy-switch.sh` 按既有格式更新 `/etc/mini-work/sing-box.json` 与 `/etc/mini-work/root.nft`，不添加 VM 侧分流规则，对外严格保持唯一机场设备连接。
2. **绝不程序化关闭 Shadowrocket**：仅只读检测 `scutil --nc list` 与 `scutil --proxy`；若检测到外部 VPN 正在运行，`lima-bridge.sh on` 自动退回 `proxy-only` 安全模式，不强抢默认路由。
3. **Git 推送脱敏检查（重要）**：
   - 推送至远程仓库前，请确认 **严禁提交** `~/.lima-proxy/config.json`（含订阅 URL 与节点密码）、`backups/` 或包含个人敏感凭据的文件。
   - `snapshot/` 为本次重构前的只读采样快照，建议加入 `.gitignore` 或在确认不需要历史对照后不纳入主分支提交。

---

## 4. 已完成的本地校验

- 所有 `.sh` 与 `.command` 脚本已通过 `bash -n` 语法检查。
- 两份 LaunchAgent `.plist.tmpl` 已通过 `plutil -lint` 格式校验。
- `lima-bridge.sh` 的 `jq` 全应用配置增量转换逻辑已通过基于原 `mac-singbox.json` 的冒烟测试，输出合法的 `mac-in` + `tun-all` 双入站与 `geosite-private` / `geosite-cn` / `geoip-cn` 三规则集结构。
