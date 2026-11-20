# Mac mini 网络与代理架构安全红线 (Network Guardrails)

> 适用范围：本机所有 AI 辅助开发工具（Antigravity、Codex、Claude Code、Cursor、终端 Agent）与日常项目运维。

---

## 1. 架构速览 (Architecture Overview)

```
[原生 App / CLI 流量]
       │
       ▼
 [utun99 (sing-box 7890)] ──(国内/私网直连)──► 本地网络 / 局域网
       │
       ▼ (海外流量)
 [127.0.0.1:17890 SSH Tunnel]
       │
       ▼
 [Lima mini-work (192.168.105.x:17890 sing-box AnyTLS)]
       │
       ▼ (单连接外联)
    [出海机场]
```

- **保活机制**：macOS `launchd` 托管服务：
  - `com.user.lima-proxy-tunnel` (SSH 隧道转发 17890)
  - `com.user.lima-proxy-singbox` (宿主机 sing-box 7890 + utun99)
- **备用 VPN**：Shadowrocket（Socks5/HTTP 端口 `127.0.0.1:1082`）

---

## 2. 核心红线提示词 (15 行精炼版)

```markdown
【本机 Mac mini 网络与代理架构红线 — 任何项目必须遵守】

1. 网络架构背景：本机通过 Lima 虚拟机（mini-work，端口 127.0.0.1:17890）+ Mac 宿主机 sing-box（127.0.0.1:7890 + 全应用透明网卡 utun99）实现国内外智能分流出海，由 macOS launchd（com.user.lima-proxy-tunnel / com.user.lima-proxy-singbox）保活托管；外部备用 VPN 为 Shadowrocket（端口 1082）。
2. 严禁直接杀进程或改底层网络：在任何项目中严禁执行 pkill sing-box、killall Shadowrocket、scutil --nc stop、停用物理网卡或手动删改 utun99 路由表（强杀会导致 7890 死代理断网或触发 launchd 抢端口）。
3. 严禁直接编辑虚拟机代理文件：严禁直接修改 Lima mini-work 内的 /etc/mini-work/sing-box.json 与 /etc/mini-work/root.nft，所有宿主机桥接操作必须通过 ~/.lima-proxy/lima-bridge.sh {status|on|off} 完成。
4. 保护环境变量与保留端口：不要删除或覆盖 ~/.zshrc 中的 ~/.lima-proxy/shell_env.sh 钩子及 NO_PROXY 私网豁免；本地开发起服务时请避开保留端口 7890、17890、1082、60022、5901、6080。
5. 远程桌面防断连：本机通过远程桌面 + BetterDisplay 管理，任何防火墙或路由改动都必须保持局域网/私网网段（10.0.0.0/8、172.16.0.0/12、192.168.0.0/16）100% 物理直连。
```

---

## 3. 保留端口清单 (Reserved Ports)

| 端口 | 用途 | 约束要求 |
| :--- | :--- | :--- |
| `7890` | Mac 宿主机 sing-box 核心混合端口 | 严禁占用，严禁杀进程 |
| `17890` | SSH 本地转发端口（指向 Lima mini-work） | 严禁占用，由 launchd 守护 |
| `1082` | Shadowrocket 备用代理端口 | 严禁强抢或强制停止 |
| `60022` | Lima mini-work SSH 互联端口 | 严禁篡改或阻断 |
| `5901` | VNC 远程桌面服务端口 | 严禁封锁，保障远程控制 |
| `6080` | noVNC / Web 远控或辅助服务端口 | 保留端口 |

---

## 4. 允许的标准管理命令 (Safe Commands)

如需对代理进行管理，**唯一合规**方式是调用规范工具链：

```bash
# 查看代理与链路运行状态
~/.lima-proxy/lima-bridge.sh status

# 健康体检诊断
~/.lima-proxy/lima-bridge.sh doctor

# 开启 / 重启代理
~/.lima-proxy/lima-bridge.sh on

# 优雅关闭代理（安全注销 launchd 与恢复路由）
~/.lima-proxy/lima-bridge.sh off
```
