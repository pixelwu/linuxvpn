# macOS 端置分流 + Lima 内部纯全局代理架构说明书 (Technical Blueprint & SOP)

> 💡 **项目说明**：本文档旨在长效固化 **“macOS 宿主机国内外分流 + Lima Linux 虚拟机 100% 全局代理”** 的架构设计、数据拓扑、排障手册与双 VPN 兼容机制。防止后续会话重置后上下文丢失。

---

## 1. 核心架构目标与三大绝对红线 (Hard Constraints)

1. **严格 1 个远端设备在线额度**：
   - 机场服务商严格限制单连接/单设备同时在线。
   - 架构基石：**对外永远只有 Linux 虚拟机内部唯一一个客户端与远端机场建立加密连接**。macOS 宿主机侧绝对不配置任何机场节点密钥、不直连机场，彻底杜绝设备额度超标与风控封禁。
2. **Linux 内部 100% 保持纯全局代理（零泄漏、零改动）**：
   - Linux 内部运行着高敏感度的 AI 工具链与开发环境，所有出站流量必须强制走代理通道。
   - 严禁在 Linux 虚拟机内部修改 `sing-box.json`、严禁添加 `geosite:cn` 等分流规则、严禁改动 `nftables` 防火墙白名单，杜绝真实 IP 泄漏。
3. **国内外分流 100% 前置在 macOS 端完成**：
   - macOS 宿主机的日常软件（微信、钉钉、飞书、B站、国内开发源）流量巨大。
   - 所有“国内直连（DIRECT）/ 海外走代理（PROXY）”的判定，必须在流量离开 Mac 物理网卡或进入 Lima 映射端口之前，在宿主机侧拦截并决策完毕。

---

## 2. 系统拓扑与数据流向图

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ 🖥️ macOS 宿主机 (分流决策中心 · 零远端凭据)                                  │
│                                                                             │
│   各类桌面软件 / Chrome / 终端 / Antigravity IDE                            │
│                         │                                                   │
│                         ▼                                                   │
│   系统代理层 (指向 127.0.0.1:7890 + PAC Fail-Open 127.0.0.1:18080)          │
│                         │                                                   │
│                         ▼                                                   │
│   macOS 本地轻量 sing-box (路由核心 · 规则集嗅探)                            │
│           ├──▶ [命中 CN 域名 / 国内 IP / 局域网] ──▶ DIRECT (走 Mac 物理网卡出站)
│           │                                                                 │
│           └──▶ [命中海外 / 未命中直连流量] ───────▶ 推向 127.0.0.1:17890    │
└───────────────────────────────────────────────────────┬─────────────────────┘
                                                        │ (SSH vsock 环回隧道)
┌───────────────────────────────────────────────────────▼─────────────────────┐
│ 🐧 Lima 虚拟机 (Linux mini-work · 100% 全局透明代理 · 零修改)               │
│                                                                             │
│   内部代理核心监听 (10.203.0.1:17890) ◀─────────────────────────────────────┘
│           ▲
│           │ (内部透明代理通道)
│   Linux 内部 AI 任务 / 开发工具
│           │
│           ▼
│   远端机场节点 (全局唯一出海连接 · 严格仅占 1 设备额度)                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 关键端口与组件清单

| 端口 / 路径 | 组件名称 | 核心作用 |
| :--- | :--- | :--- |
| **`127.0.0.1:7890`** | Mac 本地 sing-box | 接收全系统 HTTP/HTTPS/SOCKS5 流量，执行 GeoSite/GeoIP 分流 |
| **`127.0.0.1:17890`** | Lima 宿主映射隧道 | 将 Mac 需翻墙的流量安全送入 Linux VM `10.203.0.1:17890` |
| **`127.0.0.1:18080`** | 本地 PAC 软挂载服务 | 托管 `proxy.pac`，提供 0ms Fail-Open 直连回退防断网保护 |
| **`127.0.0.1:19090`** | 本地 Clash API 控制台 | 提供免输管理员密码的毫秒级热切换接口（Rule / Direct / Global） |
| **`127.0.0.1:1082`** | 外部商用 VPN（如 MacPacket） | 用户原有的独立外部 VPN，物理端口完全隔离 |
| `~/.lima-proxy/mac-proxy-bridge.sh` | 宿主控制中心 | 管理隧道、sing-box 核心、系统代理挂载与容灾重置 |
| `~/Applications/Lima Proxy.app` | 常驻 Dock 的 GUI 控制台 | 提供图形化开关、状态灯与一键彻底恢复按钮 |
| `~/Desktop/🚨紧急恢复Mac网络.command` | 桌面双击自救脚本 | 遇到极端网络卡死或需维修时，双击 0.5 秒恢复纯净直连 |

---

## 4. 为什么 Antigravity IDE 之前不走内部 VPN？（原理与修复方案）

### 4.1 故障根因剖析
- **现象**：开启 Lima 共享代理后，Chrome 浏览器可以正常分流翻墙，但 **Antigravity IDE 仍然需要依赖外部 VPN，关了外部 VPN 就连不上 Google**。
- **根因**：
  1. Chrome / Safari 是标准的 WebKit / Chromium 桌面应用，原生支持 **`PAC (Proxy Auto-Config)`** 脚本解析；
  2. Antigravity 的后端核心进程是 Go 编译的二进制文件（`/Applications/Gemini.app/Contents/Helpers/agy`）。**Go 标准库（`net/http` 及 `grpc-go`）根本不支持解析 `.pac` 的 JavaScript 文件**！
  3. 当初期方案仅开启了系统的 PAC（`setautoproxyurl`）而把系统的静态代理（`setwebproxystate off`）关闭时，Go 进程与 Antigravity 看不到任何可用的 HTTP/HTTPS 代理，直接采用原生套接字尝试直连 Google，因而被 GFW 拦截。

### 4.2 修复方案
在 `mac-proxy-bridge.sh` 的 `enable` 逻辑中升级为 **`双轨并行挂载 (Dual Mode)`**：
1. **静态代理全开**：通过 `networksetup -setwebproxy`、`-setsecurewebproxy`、`-setsocksfirewallproxy` 将系统的 HTTP/HTTPS/SOCKS5 代理全部显式指向 `127.0.0.1:7890`。
   - Antigravity IDE、Electron、Go 程序、Python、curl 立刻识别到静态代理并全部打给本地 sing-box；
2. **本地核心处理所有决策**：所有打给 `127.0.0.1:7890` 的流量，由本地 `sing-box` 内置的高性能二进制规则集（`geosite-cn.srs` / `geoip-cn.srs`）进行智能分流，国内秒级直连，海外经由 Lima 出海；
3. **PAC 同步在线**：依然挂载 `http://127.0.0.1:18080/proxy.pac` 作为 WebKit 浏览器的 Fail-Open 兜底保障。

---

## 5. 外部 VPN 与 Lima 共享 VPN 交互矩阵与避坑指南

用户在日常使用中，可能会遇到同时存在“外部商用 VPN（如 Shadowrocket / Clash / 公司 VPN）”与“Lima 共享分流”的情况。以下是各种操作顺序下的系统行为与应对方案：

| 触发场景 | 系统底层实际发生的情况 | 潜在影响与 Bug 表现 | 规范处理对策 |
| :--- | :--- | :--- | :--- |
| **场景 A：先开外部 VPN，再开 Lima 共享** | 外部 VPN 占据了系统底层网卡（如 `utun`）；点击 Lima 共享后，系统代理被设为 `7890`。 | **双层代理 / 代理链**：应用先把包给 `7890`（本地 sing-box），sing-box 判断直连的包送出物理网卡时，又被外部 VPN 再次接管分流。海外流量则走 Lima，不受影响。 | **推荐二选一**：若想使用 Lima 共享，建议关闭外部 VPN；若需同时开，确保外部 VPN 为规则分流模式。 |
| **场景 B：先开 Lima 共享，再开外部 VPN** | Lima 共享已将系统代理指向 `7890`；随后启动外部 VPN。 | **覆盖冲突**：大部分外部 VPN 启动时会强行把 macOS 系统代理改成它自己的端口（如 `1082`）或挂起 `utun` TUN 虚拟网卡。此时 Lima 分流被强行抢夺，流量全面被外部 VPN 接管。 | 如果需要用外部 VPN 维修或工作，先在 Lima GUI 点「🛑 关闭共享」，再开启外部 VPN。 |
| **场景 C：开着 Lima 共享，外部 VPN 突然崩溃/退出** | 外部 VPN 异常退出时，可能会将系统的代理设置全部抹掉重置为 OFF，或留下死网卡。 | Mac 浏览器或 Antigravity 可能会突然变成无代理直连状态，导致海外请求瞬间中断。 | 在 Lima GUI 点击一次「🔗 开启 Mac 共享」（重新声明接管），或在终端执行 `~/.lima-proxy/mac-proxy-bridge.sh enable`。 |
| **场景 D：Lima 虚拟机卡死/关闭，而 Mac 共享开着** | 本地 7890 sing-box 进程仍存活，但推往 17890 的隧道无法连接。 | 国内流量（百度、微信）不受任何影响依然秒开；海外流量因 Lima 端口断开而报连接超时。 | 1. 在 GUI 点击「🛑 关闭共享」；<br>2. 或直接双击桌面「🚨 紧急恢复Mac网络.command」，0.5 秒切回纯物理直连。 |

### 💡 核心使用口诀：
> **“用 Lima 关外部，用外部关 Lima；网络紊乱不用慌，桌面核弹双击光。”**

---

## 6. GUI (Lima Proxy.app) 一键操作与交互说明

Dock 栏中的 `Lima Proxy.app` 提供直观图形化控制：

1. **🔗 一键开启 Mac 代理 (全局共享)**：
   - 自动检测并打通 Lima VM 映射隧道 (`127.0.0.1:17890`)；
   - 启动 Mac 本地智能分流核心 (`127.0.0.1:7890`)；
   - 自动检测并断开死黑洞状态的 Shadowrocket 系统扩展，将代理权交还给真实的 Mac 物理网卡 (`Wi-Fi 2`)；
   - 将系统 HTTP/HTTPS/SOCKS5 代理同时挂载，Antigravity IDE 与 Chrome 无缝出海，国内流量零损耗直连。
2. **🛑 关闭 Mac 代理**：
   - 关闭系统代理，恢复普通物理直连；
   - 释放本地分流核心进程。
3. **🚨 彻底恢复直连 (Panic Reset)**：
   - 遇到任何异常时一键兜底：彻底清空 Mac 所有硬件网卡上的代理配置；
   - 断开一切死黑洞隧道；
   - 恢复 100% 干净物理网络，方便立即开启外部商业 VPN 进行维修。
4. **📁 订阅分组与测速**：
   - 节点列表按订阅来源清晰分组（如 `📡 订阅1`、`📡 cc213`）；
   - 点击分组标题栏可自由折叠与展开分组，操作丝滑不卡顿；
   - 点击「⚡ 全部测速」可实时探测各节点延迟，点击「切换」即可热切换出海节点。


### 5.1 极其隐蔽的系统级踩坑点：外部 VPN (如 Shadowrocket) 假关闭
在 macOS 上，以 **Shadowrocket (小火箭)** 为代表的商用 VPN 采用了 macOS **`NetworkExtension (系统 VPN 扩展)`** 机制：
- **假关闭现象**：当你在 Shadowrocket 软件窗口里点击断开时，很多时候只是把其内部节点停用了，但 macOS 系统的 **`VPN 网络扩展 (MacPacketTunnel)` 并没有断开**（`scutil --nc list` 依然显示 `(Connected)`）；
- **致命后果**：此时虚拟网卡 `utun` 依然占据着 macOS 的 `IsPrimaryInterface: 1`（第一主路由），并且将全局默认代理强行指向了 `1082`。这导致任何新发起的请求（包括 Antigravity IDE）全部被强行塞进已停用的 `1082` 端口，变成死黑洞！
- **彻底解决办法**：
  1. 在 macOS 顶部菜单栏或「系统设置 -> VPN」中，找到 Shadowrocket，显式将其开关彻底拨到 **关闭 (OFF)**；
  2. 或在终端运行：`scutil --nc stop "Shadowrocket"`；
  3. 退出并重新打开 Antigravity (Cmd + Q 重启 Gemini.app)，释放旧的挂起 Socket。

---

## 6. 常用管理指令速查表 (CLI Cheat Sheet)

所有管理均可通过终端脚本直接完成（或在 Dock 的 `Lima Proxy.app` 界面点选）：

```bash
# 1. 查看当前 macOS 宿主与 Lima 代理桥接状态
~/.lima-proxy/mac-proxy-bridge.sh status

# 2. 输出 JSON 格式状态 (供自动化或前端读取)
~/.lima-proxy/mac-proxy-bridge.sh status --json

# 3. 启动本地分流核心并接管 Mac 系统代理 (国内外自动智能分流)
~/.lima-proxy/mac-proxy-bridge.sh enable

# 4. 关闭 Mac 系统代理，切回纯直连模式 (停止本地核心与隧道)
~/.lima-proxy/mac-proxy-bridge.sh disable

# 5. 测试当前 Mac 分流连通性 (同时测试国内 Baidu 与海外 Google 延迟)
~/.lima-proxy/mac-proxy-bridge.sh test

# 6. 利用 Clash API 进行 0 权限热切换 (不弹密码框)
~/.lima-proxy/mac-proxy-bridge.sh set-mode rule     # 智能分流
~/.lima-proxy/mac-proxy-bridge.sh set-mode direct   # 强制全直连
~/.lima-proxy/mac-proxy-bridge.sh set-mode global   # 强制全走 Lima 代理

# 7. 🚨 核弹级彻底清退重置 (强退进程、全网卡关代理、刷空 DNS 缓存、回退 100% 物理直连)
~/.lima-proxy/mac-proxy-bridge.sh panic-reset
```

---

## 7. 故障排查与应急维护流程 (Troubleshooting SOP)

如果未来任何时候感觉网络异常、网页打不开，请执行以下标准三步排查法：

1. **第一步（极速自救）**：
   - 直接前往 Mac 桌面，双击 **[🚨 紧急恢复Mac网络.command](file:///Users/herryzheng/Desktop/🚨紧急恢复Mac网络.command)**；
   - 看到窗口输出 `✅ 恢复完成！macOS 已 100% 恢复纯净物理直连` 后，网络已恢复至初始状态。此时您可以自由开启您的外部 VPN 进行排障。
2. **第二步（检查 Lima 虚拟机代理健康度）**：
   - 确保虚拟机正在运行：`limactl list`；
   - 检查 Linux 内部代理是否正常：`~/.lima-proxy/lima-proxy-switch.sh test`；
   - 若节点失效，切换至可用节点：`~/.lima-proxy/lima-proxy-switch.sh switch <node-id>`。
3. **第三步（重新激活 Mac 分流共享）**：
   - 确认 Linux 内部正常后，在 Dock 打开 `Lima Proxy.app`，点击「🔗 开启 Mac 共享」即可重新满血运作。
