# 📑 macOS × Lima 虚拟机代理桥接与生态全链路技术交接文档 (v4.0 完整版)

**文档版本**：v4.0 Full Architecture & Handover  
**生成时间**：2026-11-18 20:28:00 (JST/UTC+9)  
**工作区路径**：`/Users/herryzheng/Documents/antigravity/vpnfix`  
**核心组件路径**：`~/.lima-proxy/`  
**恢复兜底脚本**：`~/Desktop/🚨紧急恢复Mac网络.command`

---

## ⚠️ 【最高级别红色警告】致接手的 AI 助手

> [!CAUTION]
> **切勿自断生路（DO NOT CUT OFF YOUR OWN LIFELINE）！**  
> 你当前运行在用户 macOS 本地的 **Antigravity IDE** 中，你的每一次思考交互、API 请求和终端响应，**全部依赖当前 macOS 宿主机的网络出海通道（外部 VPN Shadowrocket 或生效的代理桥接）**！  
> **严禁执行以下自杀式操作：**
> 1. **严禁杀灭 Shadowrocket**：绝对不可执行 `killall Shadowrocket`、`pkill -f Shadowrocket`、`scutil --nc stop` 等任何尝试程序化断开外部商用 VPN 的命令！
> 2. **严禁停用物理网卡**：绝对不可执行 `networksetup -setnetworkserviceenabled` 关闭物理网卡！
> 3. **严禁修改 Linux 虚拟机内部原生配置**：严禁直接编辑或覆盖虚拟机内部 `/etc/mini-work/sing-box.json` 与 `/etc/mini-work/root.nft`，虚拟机内的配置与防火墙只能由 `~/.lima-proxy/lima-proxy-switch.sh` 脚本驱动！
> 4. **任何修改必须可逆**：若遇网络中断风险，用户桌面已备有 `~/Desktop/🚨紧急恢复Mac网络.command`，执行 `~/.lima-proxy/lima-bridge.sh off` 即可 100% 恢复纯物理直连。

---

## 1. 目标与现存状态一览

### 1.1 项目核心目标
在用户**关闭外部商用 VPN (Shadowrocket)** 的情况下，利用本地运行的 Linux 虚拟机（Lima VM: `mini-work`，内部拥有 sing-box 多节点代理与 nftables 防火墙），将代理能力共享给 macOS 宿主机生态：
* **Chrome / Safari 浏览器**：国内域名直连，海外流量分流出海。
* **Antigravity IDE**：底层 Go RPC 与远程服务正常通信。
* **Gemini.app 客户端**：原生 macOS 应用，能正常与 Google 服务器通信。
* **Lima Proxy Manager**：支持在 macOS Dock 栏 App（`Lima Proxy.app`）中一键切换日本 Trojan / Hysteria2 等节点，自动联动虚拟机内 sing-box 与防火墙重载。

### 1.2 四端生态实测现状对比

| 客户端 / 组件 | 现状 | 依赖链路与通信协议 | 剩余阻碍 / 现状说明 |
| :--- | :---: | :--- | :--- |
| **Chrome / Safari** | ✅ **100% 正常** | 物理网卡 HTTP/HTTPS 代理 `127.0.0.1:7890` | 国内域名纯内存匹配直连，海外直推 VM 远端解析出海 |
| **Antigravity IDE** | ✅ **100% 正常** | `launchctl` / `shell_env.sh` 的 `HTTP_PROXY` | Go `net/http` 尊重 HTTP 代理，已可稳定出海 |
| **节点切换控制** | ✅ **100% 正常** | `~/.lima-proxy/lima-proxy-switch.sh` | 虚拟机处于 Running 状态时，CLI 与 GUI 切换均顺畅 |
| **Gemini.app** | ❌ **仍未通 (阻断)** | `libcurl` 绕过代理，发原生 IP 直连 TCP SYN | 底层代码设置 `CURLOPT_PROXY=""`，直连 Google 撞墙 |

---

## 2. 之前踩过的所有坑与排查血泪史 (Pitfalls & Lessons)

接手者请务必仔细阅读以下踩坑记录，**严禁重走弯路**：

| 序号 | 踩坑场景 | 故障现象 | 深度技术根因 | 彻底解决方案与经验 |
| :---: | :--- | :--- | :--- | :--- |
| **坑 1** | **PAC 软挂载方案** (`18080/proxy.pac`) | Chrome 能翻墙，但 Antigravity 和 Gemini.app 彻底断网 | Chrome 拥有 V8 引擎可解析 PAC JavaScript；而 **Antigravity (Go net/http)** 和 **Gemini.app (libcurl)** 原生不支持 PAC 解析，直接 Fallback 到 DIRECT 物理直连撞墙 | **彻底弃用 PAC**，改用物理网卡硬绑定标准 HTTP/HTTPS 代理 (`127.0.0.1:7890`) |
| **坑 2** | **DNS DoH 环形死锁** (`dns-remote` 走 1.1.1.1) | 连原本正常的 Chrome 网页也彻底瘫痪白屏，耗时 10 秒超时 | Mac 端 `sing-box` 配置了 `geoip-cn` 规则与 DoH `1.1.1.1`（走 SSH 隧道到 VM）。并发请求涌入时，DNS 解析与 SOCKS 代理相互等待，产生**双向依赖死锁** | **彻底拔除 Mac 端 remote-dns 与 geoip-cn**，仅保留 `geosite-cn` 纯内存域名匹配。境外域名不做本地解析，直接将域名字符串以 SOCKS5 协议直推 VM 远端解析 |
| **坑 3** | **sing-box 1.14 语法废弃** | sing-box 启动报 FATAL 直接秒退退出 | 1.14 版本废弃了 `override_destination: true`；旧版 `dns.servers.address` 格式被判定过时 | 移除 `override_destination`，改用 `action: sniff` 原生嗅探；DNS 服务器采用 `{"type": "udp", "server": "223.5.5.5"}` |
| **坑 4** | **直接修改虚拟机内文件** | 节点切换脚本报 `sed` 替换失败，代理彻底损坏 | 试图在宿主机直接修改 VM 内 `/etc/mini-work/sing-box.json`，破坏了 `lima-proxy-switch.sh` 的 JSON 格式与 `root.nft` 正则锚点 | **虚拟机内配置划为绝对禁区**，所有 VM 内改动仅能通过调用 `~/.lima-proxy/lima-proxy-switch.sh switch <id>` 完成 |
| **坑 5** | **Go 进程自回环死循环** | 启动 sing-box 后本地 CPU 飙高，端口打不开 | `sing-box` 和 `ssh` 是 Go/C 编译的，若宿主继承了全局 `HTTP_PROXY=7890`，它们在建立连接时会自己代理自己，陷入死循环 | 启动隧道和代理进程时，必须使用 `env -i` 净空环境隔离启动，并严格设置 `NO_PROXY` 环回绕过白名单 |
| **坑 6** | **非交互终端 sudo 密码阻塞** | 运行脚本无报错但后台卡死，超时退出 | 尝试以 `sudo sing-box` 挂载 `utun99`，但当前用户未配置 sudo 免密，后台默默等待 `Password:` 输入导致死锁 | 增加 `can_sudo` 探测 (`sudo -n true`)。无免密时自动降级到用户态单入站模式，保住 Chrome 与 Antigravity，避免全盘挂起 |
| **坑 7** | **宿主会话重启导致 VM 关机** | 报错“网络打不开、内部测速正常、无法切换” | 容器/会话重启导致 `mini-work` VM 变为 `Stopped`，SSH 隧道死亡，7890 成为黑洞死端口；而 GUI App 显示的是历史缓存延迟 | 脚本中增加 `ensure_vm_running`，启动前调用 `limactl list` 检查，若停机自动调用 `limactl start mini-work` 自愈 |

---

## 3. 当前尚未解决的问题 (Unsolved Problems)

### 🔴 问题一：Gemini.app 底层 libcurl 原生硬编码直连 (Raw IP SYN_SENT)
* **逆向取证事实**：
  在反编译及日志排查中定位到，Gemini.app 客户端底层包含源码逻辑：
  `unauthenticated_transport.cc:145` -> 明确设置了 `CURLOPT_PROXY = ""`（将代理显式设置为空字符串），并在 libcurl 中强行开启 `CURLOPT_NOPROXY = "*"`。
* **抓包抓取现象**：
  打开 Gemini.app 时，macOS 内核产生大量通往 Google 官方 AS15169 IP 网段（如 `172.217.x.x`、`142.250.x.x`、`2001:4860:...`）的 TCP/IP 握手报文，状态恒为 `SYN_SENT`，最终触发 `status=DEADLINE_EXCEEDED (curl code 28 to 86)`。
* **已设计的方案**：
  在 `~/.lima-proxy/mac-singbox.json` 中配置了微创透明网卡 `utun99`（IP: `198.18.0.1/30`），并通过 `route_address` 精准锁定 Google CIDR IP 段，利用 TUN 网卡底层抓包并转发进 `to-lima`。
* **目前的阻碍**：
  macOS 创建虚拟网卡（`utun`）**必须具有 root 权限**。当前用户执行 `sudo` 需要输入密码。如果用户没有在 macOS 执行单行配置赋予 `sing-box` 免密 sudo 权限，`lima-bridge.sh` 只能降级为用户态（仅开 7890 端口，无 utun99）。
* **待接手 AI 完成的方向**：
  1. 方向 A：指导用户在终端执行一次合规且安全的单行免密授权命令：
     ```bash
     sudo sh -c "echo '$USER ALL=(ALL) NOPASSWD: $HOME/.lima-proxy/bin/sing-box, /usr/bin/pkill, /usr/bin/killall, /usr/sbin/dscacheutil' > /etc/sudoers.d/lima-proxy && chmod 0440 /etc/sudoers.d/lima-proxy"
     ```
  2. 方向 B：研究是否存在免 root 的替代方案（如 `pfctl` 重定向、macOS Network Extension、或针对 libcurl 的 `DYLD_INSERT_LIBRARIES` 注入）。

### 🟡 问题二：缺乏系统级守护进程 (Supervisor Daemon)
* **现状**：当前 SSH 隧道（`127.0.0.1:17890`）和 Mac 本地 sing-box（`127.0.0.1:7890`）是由脚本通过 `nohup` 和 `ssh -f` 启动的后台孤儿进程。
* **风险**：一旦 Mac 休眠唤醒、网络切换或会话意外重启，这些进程若被杀，缺乏自动拉起看门狗。
* **待接手 AI 完成的方向**：
  可考虑为 Mac 代理桥接编写标准的 `~/Library/LaunchAgents/com.user.lima-proxy-bridge.plist`，由 macOS `launchd` 进行保活监控，或在 `Lima Proxy.app` 的 Swift 代码中常驻心跳检测。

### 🟡 问题三：Shadowrocket 顶层生效字典与回落检测
* **现状**：当外部 VPN Shadowrocket 开启时，macOS 内核 `scutil --proxy` 顶层字典为 `1082`。
* **期望**：当用户在 Shadowrocket GUI 中点击断开时，系统顶层能平滑透明地切回 `7890`。目前物理网卡已绑定 `7890`，回落基本顺畅，但偶发因 Shadowrocket 未完全清理 `scutil` 导致短暂停留。

---

## 4. 关键文件与架构清单

```
~/.lima-proxy/
├── bin/sing-box               # macOS 本地 sing-box 1.14.4 二进制
├── ruleset/                   # 规则集目录 (geosite-cn.srs, geosite-private.srs)
├── config.json                # 节点列表与活跃节点状态配置
├── mac-singbox.json           # macOS 本地分流规则 (mixed 7890 + 可选 utun99)
├── lima-bridge.sh             # 核心桥接脚本 (on/off/status)，管理隧道、代理与网卡
├── mac-proxy-bridge.sh        # 对接 Web/GUI 的适配器脚本
├── lima-proxy-switch.sh       # 虚拟机内部 sing-box 与 nftables 切换控制工具
├── shell_env.sh               # 终端环境变量 hook (~/.zshrc 自动引用)
└── web/index.html             # Lima Proxy Manager 的 UI 界面

~/Applications/Lima Proxy.app  # macOS 菜单/Dock 栏客户端 (Swift WKWebView 封装)
~/Desktop/🚨紧急恢复Mac网络.command # 桌面一键熔断恢复纯物理直连快捷方式
```
EOF