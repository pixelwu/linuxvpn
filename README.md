# Lima Proxy Manager (Linux VPN 子系统代理管理器)

基于 macOS + Lima Linux 虚拟机（`mini-work`）的 sing-box 代理管理系统。

结合 **nftables 强隔离防火墙** 与 **sing-box 透明/出站代理**，确保 Linux 子系统所有网络流量严格仅能通过指定的受信任 VPN 节点出站，同时提供轻量优雅的 macOS 原生 Dock 栏 GUI 与 CLI 切换管理工具。

---

## ✨ 核心特性

- **订阅安全导入**：一键拉取并解析 Shadowrocket / Clash 订阅，自动过滤保留指定国家（默认：🇯🇵 日本）节点，避免节点频繁变动或跨国跳跃。
- **协议自适应协同**：支持 Trojan、Hysteria2 (QUIC)、AnyTLS 等协议，切换节点时自动协调虚拟机内 sing-box 配置与 Linux `nftables` 防火墙规则（TCP/UDP 智能匹配与放行）。
- **macOS 原生轻量 GUI**：基于 WebKit 构建的 macOS 原生窗口应用，常驻 Dock 栏，支持节点一键切换、连通性探测、日志实时回显。
- **命令行工具 (CLI)**：提供独立、高可移植的 shell 控制脚本，不依赖外部重量级运行时环境。

---

## 📁 目录结构

```
.
├── app/
│   └── LimaProxyApp.swift     # macOS 原生 WKWebView 桥接容器源码
├── scripts/
│   └── lima-proxy-switch.sh   # 核心 CLI 管理脚本 (状态/切换/订阅拉取/防火墙协调)
├── web/
│   └── index.html             # GUI 交互界面 (暗黑主题、防 XSS、响应式卡片)
├── system/
│   ├── sing-box.example.json  # VM 内部 /etc/mini-work/sing-box.json 配置模板
│   └── root.example.nft       # VM 内部 /etc/mini-work/root.nft 防火墙隔离规则模板
├── config.example.json        # 节点与订阅配置文件模板（已脱敏）
├── install.sh                 # 一键安装与编译脚本
├── .gitignore                 # 严禁提交真实订阅与密码配置
└── README.md
```

---

## 🚀 快速使用

### 1. 安装与部署

```bash
chmod +x install.sh
./install.sh
```

### 2. 命令行使用

```bash
# 查看当前代理与防火墙状态
~/.lima-proxy/lima-proxy-switch.sh status

# 列出当前所有可用节点
~/.lima-proxy/lima-proxy-switch.sh list

# 更新订阅（默认仅拉取日本节点）
~/.lima-proxy/lima-proxy-switch.sh import-subscription

# 手动切换节点
~/.lima-proxy/lima-proxy-switch.sh switch <node-id>

# 测试当前代理连通性
~/.lima-proxy/lima-proxy-switch.sh test
```

### 3. 图形界面使用

从 macOS Dock 栏启动 **`Lima Proxy.app`** 或在终端执行：
```bash
open -a "$HOME/Applications/Lima Proxy.app"
```

---

## 🔒 隐私与安全准则

真实配置文件 `config.json` 包含私有订阅 URL 与节点连接密码，已在 `.gitignore` 中默认完全忽略，**绝对禁止**将包含真实凭据的配置文件提交至公共代码仓库。
