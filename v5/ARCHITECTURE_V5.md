# Lima Proxy v5.0 架构重构与操作手册

## 1. 根因复盘：之前为什么老是重启、断连、关不掉？

1. **`launchd` 与 `lima-bridge.sh` 互相杀进程打架（核心元凶）**：系统里原本有两个 `KeepAlive` 的 LaunchAgent，但旧版 `lima-bridge.sh` 启动时直接 `pkill` + `nohup` 拉起孤儿进程，触发 `launchd` 疯狂重启抢端口；关闭时也没卸载 LaunchAgent，导致“明明点了关闭代理，2 秒后又偷偷重启”。
2. **`utun99` 仅拦截 Google 网段**：旧版 `route_address` 只覆写了 Google 24 个 CIDR，其他不走 HTTP 代理的原生应用/CLI 全部直连撞墙。
3. **节点切换无锁、无回滚、`dig @8.8.8.8` 易卡死**：旧版 `lima-proxy-switch.sh` 的 `LOCK_FILE` 从未使用，且覆写虚拟机 `sing-box.json` / `root.nft` 前没有备份，校验失败会把虚拟机代理直接改残。
4. **Web UI 切窗口狂刷命令 + 缺并发锁**：`focus` 与 `visibilitychange` 同时无防抖触发 `limactl shell ... curl`，且开启/关闭 Mac 代理按钮未加全局锁，连点会直接把状态搅乱。

## 2. v5.0 健壮架构分层

```text
[Lima Proxy.app / CLI]  ──►  唯一状态机: lima-bridge.sh (v5.0)
                                 ├── 原子互斥锁 (.bridge.lock)
                                 ├── Shadowrocket 只读防冲突守卫 (绝不杀外部 VPN)
                                 ├── 配置生成器: gen-singbox-config.sh (jq + sing-box check)
                                 └── 统一托管 launchd (bootstrap / bootout)
                                       ├── com.user.lima-proxy-tunnel  ──► SSH vsock 保活 (17890)
                                       └── com.user.lima-proxy-singbox ──► 本地分流核心 (7890 + utun99)
                                             ├── 局域网/私网/远程桌面 ──► 路由表层排除 (100% 物理直连)
                                             ├── 国内域名 & 离线 geoip-cn ──► Direct (物理网卡)
                                             └── 其余全部海外流量 ──► SOCKS5 透传至 Lima 17890
```

## 3. 日常极简操作规范（防呆三态）

| 当前状态 | 怎么切 | 底层保障 |
| :--- | :--- | :--- |
| **用 Lima 全应用共享** | 1. 先在系统设置/菜单栏彻底关掉 Shadowrocket<br>2. 在 `Lima Proxy.app` 点「🔗 开启 Mac 全应用共享」 | 自动拉起 `launchd` 保活 + `7890` + 全应用 `utun99`（排除私网，远程桌面不掉线） |
| **临时改用 Shadowrocket** | 1. 在 `Lima Proxy.app` 点「🛑 关闭共享」<br>2. 再打开 Shadowrocket | 自动 `launchctl bootout` 卸载守护、销毁 `utun99`、清空代理与 DNS 缓存 |
| **节点断连 / 异常卡死** | 点「⚡ 自愈重连」或双击桌面 `🚨紧急恢复Mac网络.command` | 一键重选当前节点并重建桥接，或 0.5 秒物理级净空恢复直连 |

## 4. 部署与回滚命令

```bash
# 一键备份并部署 v5.0（不影响当前 Shadowrocket）
bash /Users/herryzheng/Documents/antigravity/vpnfix/v5/deploy_v5.sh

# 如需一键回滚到部署前版本
bash /Users/herryzheng/Documents/antigravity/vpnfix/v5/rollback_v5.sh
```
