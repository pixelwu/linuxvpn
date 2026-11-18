#!/bin/bash
# ==============================================================================
# ~/.lima-proxy/lima-bridge.sh (v4.0 - 攻克 Gemini.app 与 agy CLI 终极版)
# 严守三大红线：
# 1. 绝不触碰 Linux 虚拟机 (mini-work) 内部任何文件或 nftables 规则
# 2. 绝不程序化关闭外部商用 VPN (Shadowrocket)
# 3. off 模式一键销毁 utun99、清空系统代理与环境变量，100% 恢复纯净物理直连
# ==============================================================================

set -euo pipefail

BASE_DIR="$HOME/.lima-proxy"
BIN_PATH="$BASE_DIR/bin/sing-box"
RULESET_DIR="$BASE_DIR/ruleset"
CONF_PATH="$BASE_DIR/mac-singbox.json"
LOG_PATH="$BASE_DIR/mac-singbox.log"
SHELL_ENV_FILE="$BASE_DIR/shell_env.sh"
VM_NAME="mini-work"
SSH_CONFIG="${HOME}/.lima/${VM_NAME}/ssh.config"
LIMA_HOST="lima-${VM_NAME}"
LOCAL_PORT="${MAC_PROXY_PORT:-7890}"
TUNNEL_PORT="${LIMA_PORT:-17890}"
VM_PROXY_ADDR="10.203.0.1:${TUNNEL_PORT}"

# 使用标准点号后缀 (.local) 替代 *.local，兼顾 Go net/http 与 libcurl noproxy 解析器
BYPASS_LIST="localhost,127.0.0.1,::1,10.203.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,.local,.internal,.lan"

can_sudo() {
    # 纯权限检测（-l 只检查不执行），避免每次 fork sing-box 进程
    sudo -n -l "$BIN_PATH" >/dev/null 2>&1
}

get_active_hardware_services() {
    networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | grep -E "Wi-Fi|Ethernet|LAN|Thunderbolt|USB" || true
}

ensure_zshrc_hook() {
    local zshrc="$HOME/.zshrc"
    touch "$zshrc"
    if ! grep -q "lima-proxy/shell_env.sh" "$zshrc" 2>/dev/null; then
        cat >> "$zshrc" <<'EOF'

# [Lima-Proxy Dynamic Env Hook for agy CLI]
[[ -f "$HOME/.lima-proxy/shell_env.sh" ]] && source "$HOME/.lima-proxy/shell_env.sh"
EOF
    fi
}

ensure_config_and_rulesets() {
    local enable_tun="${1:-true}"
    mkdir -p "$RULESET_DIR"
    if [[ ! -s "$RULESET_DIR/geosite-private.srs" ]]; then
        curl -fsSL --connect-timeout 8 -o "$RULESET_DIR/geosite-private.srs" \
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-private.srs" 2>/dev/null || true
    fi
    if [[ ! -s "$RULESET_DIR/geosite-cn.srs" ]]; then
        curl -fsSL --connect-timeout 8 -o "$RULESET_DIR/geosite-cn.srs" \
            "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" 2>/dev/null || true
    fi

    if [[ "$enable_tun" == "true" ]]; then
        # v4.0 双入站配置 (mixed 7890 + 微创 utun99)
        cat > "$CONF_PATH" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-direct", "type": "udp", "server": "223.5.5.5" }
    ],
    "final": "dns-direct"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mac-in",
      "listen": "127.0.0.1",
      "listen_port": ${LOCAL_PORT},
      "set_system_proxy": false
    },
    {
      "type": "tun",
      "tag": "tun-google",
      "interface_name": "utun99",
      "address": [
        "198.18.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "mtu": 1400,
      "auto_route": true,
      "strict_route": false,
      "route_address": [
        "8.8.8.0/24",
        "8.8.4.0/24",
        "34.0.0.0/9",
        "35.184.0.0/13",
        "64.233.160.0/19",
        "66.102.0.0/20",
        "66.249.64.0/19",
        "72.14.192.0/18",
        "74.125.0.0/16",
        "108.170.192.0/18",
        "108.177.0.0/17",
        "142.250.0.0/15",
        "172.217.0.0/16",
        "172.253.0.0/16",
        "173.194.0.0/16",
        "209.85.128.0/17",
        "216.58.192.0/19",
        "216.239.32.0/19",
        "2001:4860::/32",
        "2404:6800::/32",
        "2607:f8b0::/32",
        "2800:3f0::/32",
        "2a00:1450::/32",
        "2c0f:fb50::/32"
      ]
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "to-lima",
      "server": "127.0.0.1",
      "server_port": ${TUNNEL_PORT},
      "version": "5"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "geosite-private",
        "type": "local",
        "format": "binary",
        "path": "${RULESET_DIR}/geosite-private.srs"
      },
      {
        "tag": "geosite-cn",
        "type": "local",
        "format": "binary",
        "path": "${RULESET_DIR}/geosite-cn.srs"
      }
    ],
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "protocol": "quic", "action": "reject" },
      { "network": "udp", "port": 443, "action": "reject" },
      { "ip_is_private": true, "outbound": "direct" },
      {
        "domain_suffix": [
          ".cn", ".local", ".internal", ".lan",
          "baidu.com", "qq.com", "weixin.qq.com", "taobao.com",
          "tmall.com", "alicdn.com", "aliyun.com", "bilibili.com",
          "hdslb.com", "feishu.cn", "bytedance.com", "jd.com", "163.com", "126.com"
        ],
        "outbound": "direct"
      },
      {
        "rule_set": ["geosite-private", "geosite-cn"],
        "outbound": "direct"
      }
    ],
    "final": "to-lima",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-direct"
  }
}
EOF
    else
        # 用户态安全单入站配置 (无需 root，保 Chrome 与 Antigravity)
        cat > "$CONF_PATH" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-direct", "type": "udp", "server": "223.5.5.5" }
    ],
    "final": "dns-direct"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mac-in",
      "listen": "127.0.0.1",
      "listen_port": ${LOCAL_PORT}
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "to-lima",
      "server": "127.0.0.1",
      "server_port": ${TUNNEL_PORT},
      "version": "5"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "geosite-private",
        "type": "local",
        "format": "binary",
        "path": "${RULESET_DIR}/geosite-private.srs"
      },
      {
        "tag": "geosite-cn",
        "type": "local",
        "format": "binary",
        "path": "${RULESET_DIR}/geosite-cn.srs"
      }
    ],
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      {
        "domain_suffix": [
          ".cn", ".local", ".internal", ".lan",
          "baidu.com", "qq.com", "weixin.qq.com", "taobao.com",
          "tmall.com", "alicdn.com", "aliyun.com", "bilibili.com",
          "hdslb.com", "feishu.cn", "bytedance.com", "jd.com", "163.com", "126.com"
        ],
        "outbound": "direct"
      },
      {
        "rule_set": ["geosite-private", "geosite-cn"],
        "outbound": "direct"
      }
    ],
    "final": "to-lima",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-direct"
  }
}
EOF
    fi
}

ensure_vm_running() {
    local st
    st=$(limactl list --json 2>/dev/null | jq -r 'select(.name=="'"$VM_NAME"'") | .status' 2>/dev/null | head -1 || true)
    if [[ "$st" != "Running" ]]; then
        echo "🔄 正在自动启动 Lima 虚拟机 '$VM_NAME'..."
        limactl start "$VM_NAME" >/dev/null 2>&1 || true
        sleep 2
    fi
}

start_bridge() {
    local use_tun=false
    if can_sudo; then
        use_tun=true
    fi

    echo "🚀 [1/6] 检查并生成 sing-box 配置文件 (微创 utun99: ${use_tun})..."
    ensure_config_and_rulesets "$use_tun"
    ensure_zshrc_hook
    ensure_vm_running

    echo "🔗 [2/6] 建立 Lima (mini-work) 纯净 SSH 映射隧道 (127.0.0.1:${TUNNEL_PORT})..."
    pkill -f "127.0.0.1:${TUNNEL_PORT}:${VM_PROXY_ADDR}" 2>/dev/null || true
    env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
        ssh -f -N \
        -F "$SSH_CONFIG" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=3 \
        -L "127.0.0.1:${TUNNEL_PORT}:${VM_PROXY_ADDR}" \
        "$LIMA_HOST" || true

    if [[ "$use_tun" == "true" ]]; then
        echo "⚙️ [3/6] 以 root 权限启动本地 sing-box 1.14.4 (挂载 7890 与 Google 专用微创网卡 utun99)..."
        # 先用白名单中的绝对路径 pkill 清理旧进程
        sudo -n /usr/bin/pkill -f "$BIN_PATH run" 2>/dev/null || true
        pkill -f "$BIN_PATH run -c $CONF_PATH" 2>/dev/null || true
        sleep 0.3
        # 关键：env -i 在外层清空环境（用户态），sudo -n 在内层提权（白名单免密）
        # nohup + disown 确保脚本退出后 sing-box 不被 SIGHUP 杀死
        env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
            nohup sudo -n "$BIN_PATH" run -c "$CONF_PATH" >"$LOG_PATH" 2>&1 &
        disown
        sleep 1.2
    else
        echo "⚙️ [3/6] 启动本地 sing-box 1.14.4 (挂载 7890 端口，保 Chrome 与 Antigravity)..."
        pkill -f "$BIN_PATH run -c $CONF_PATH" 2>/dev/null || true
        env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
            nohup "$BIN_PATH" run -c "$CONF_PATH" >"$LOG_PATH" 2>&1 &
        sleep 0.6
        echo "   ⚠️ 提示：未检测到 sudo 免密权限，utun99 暂未挂载。"
        echo "   👉 请在终端执行以下单行命令以开启 Gemini.app 直连流量捕获："
        echo "      sudo sh -c \"echo '\$USER ALL=(ALL) NOPASSWD: \$HOME/.lima-proxy/bin/sing-box, /usr/bin/pkill, /usr/bin/killall, /usr/sbin/dscacheutil' > /etc/sudoers.d/lima-proxy && chmod 0440 /etc/sudoers.d/lima-proxy\""
    fi

    echo "🌐 [4/6] 配置 macOS 物理网卡 HTTP/HTTPS 静态代理 (127.0.0.1:${LOCAL_PORT})..."
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        networksetup -setautoproxystate "$svc" off 2>/dev/null || true
        networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
        networksetup -setwebproxy "$svc" 127.0.0.1 "$LOCAL_PORT" 2>/dev/null || true
        networksetup -setsecurewebproxy "$svc" 127.0.0.1 "$LOCAL_PORT" 2>/dev/null || true
        networksetup -setwebproxystate "$svc" on 2>/dev/null || true
        networksetup -setsecurewebproxystate "$svc" on 2>/dev/null || true
        networksetup -setproxybypassdomains "$svc" "localhost" "127.0.0.1" "::1" "10.203.0.1" "*.local" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" 2>/dev/null || true
        echo "   ✓ 已挂载物理网卡: $svc -> 127.0.0.1:${LOCAL_PORT}"
    done <<< "$(get_active_hardware_services)"

    echo "🧬 [5/6] 同步注入 launchctl 与终端 shell_env.sh (赋能 Antigravity 与终端 agy CLI)..."
    launchctl setenv http_proxy "http://127.0.0.1:${LOCAL_PORT}"
    launchctl setenv https_proxy "http://127.0.0.1:${LOCAL_PORT}"
    launchctl setenv HTTP_PROXY "http://127.0.0.1:${LOCAL_PORT}"
    launchctl setenv HTTPS_PROXY "http://127.0.0.1:${LOCAL_PORT}"
    launchctl setenv no_proxy "$BYPASS_LIST"
    launchctl setenv NO_PROXY "$BYPASS_LIST"
    launchctl unsetenv all_proxy 2>/dev/null || true
    launchctl unsetenv ALL_PROXY 2>/dev/null || true

    cat > "$SHELL_ENV_FILE" <<EOF
export HTTP_PROXY="http://127.0.0.1:${LOCAL_PORT}"
export HTTPS_PROXY="http://127.0.0.1:${LOCAL_PORT}"
export http_proxy="http://127.0.0.1:${LOCAL_PORT}"
export https_proxy="http://127.0.0.1:${LOCAL_PORT}"
export NO_PROXY="${BYPASS_LIST}"
export no_proxy="${BYPASS_LIST}"
unset ALL_PROXY all_proxy
EOF

    echo "🔄 [6/6] 刷新系统 DNS 缓存，清除陈旧状态..."
    if can_sudo; then
        sudo -n /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
    else
        killall -HUP mDNSResponder 2>/dev/null || true
    fi
    dscacheutil -flushcache 2>/dev/null || true

    echo ""
    check_status
}

stop_bridge() {
    echo "🧹 [1/4] 正在关闭所有物理网卡的 HTTP / HTTPS / SOCKS / PAC 代理..."
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        networksetup -setautoproxystate "$svc" off 2>/dev/null || true
        networksetup -setwebproxystate "$svc" off 2>/dev/null || true
        networksetup -setsecurewebproxystate "$svc" off 2>/dev/null || true
        networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
        echo "   ✓ 已恢复物理网卡纯净直连: $svc"
    done <<< "$(get_active_hardware_services)"

    echo "🧹 [2/4] 正在清除 launchctl 与终端 shell_env.sh 环境变量..."
    for var in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
        launchctl unsetenv "$var" 2>/dev/null || true
    done
    cat > "$SHELL_ENV_FILE" <<'EOF'
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
EOF

    echo "🛑 [3/4] 正在停止 sing-box (内核自动销毁 utun99 及路由) 与 SSH 隧道..."
    # 无条件先尝试一次 sudo -n 免密清理 root 进程（防止 can_sudo 判断波动残留），再用普通 pkill 兜底
    sudo -n /usr/bin/pkill -f "$BIN_PATH run" 2>/dev/null || true
    pkill -f "$BIN_PATH run" 2>/dev/null || true
    pkill -f "$BIN_PATH run -c $CONF_PATH" 2>/dev/null || true
    pkill -f "127.0.0.1:${TUNNEL_PORT}:${VM_PROXY_ADDR}" 2>/dev/null || true

    echo "🔄 [4/4] 正在刷新 macOS DNS 缓存..."
    if can_sudo; then
        sudo -n /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
    else
        killall -HUP mDNSResponder 2>/dev/null || true
    fi
    dscacheutil -flushcache 2>/dev/null || true

    echo "✅ 已 100% 恢复 macOS 纯净物理直连（utun99 已卸载、零残留路由）！"
}

check_status() {
    echo "================ 当前代理桥接诊断面板 (v4.0) ================"
    local top_port
    top_port=$(scutil --proxy 2>/dev/null | awk '/HTTPPort :/{print $3; exit}' || echo "未开启")
    echo "• 内核顶层生效 HTTPPort : ${top_port:-未开启}"
    if ifconfig utun99 >/dev/null 2>&1; then
        echo "• 微创透明网卡 utun99   : ✅ 已激活 (精准捕获 Gemini.app & agy 直连 Google IPv4/IPv6)"
    else
        echo "• 微创透明网卡 utun99   : ⚠️ 未激活 (若需激活 Gemini.app 捕获，请配置 sudo 免密)"
    fi
    if [[ "${top_port:-}" == "1082" ]]; then
        echo "⚠️  [只读提示] 当前顶层代理仍为 1082 (外部 VPN Shadowrocket 处于连接状态)。"
        echo "   👉 关闭 Shadowrocket 后，顶层代理将自动秒级回落到 ${LOCAL_PORT}！"
    elif [[ "${top_port:-}" == "${LOCAL_PORT}" ]]; then
        echo "✅ Chrome / Antigravity / Gemini.app / agy CLI 四端桥接已全部就绪！"
    fi
    echo "============================================================="
}

case "${1:-status}" in
    on|enable|start)   start_bridge ;;
    off|disable|reset) stop_bridge ;;
    status)            check_status ;;
    generate-config)
        ensure_config_and_rulesets "$(can_sudo && echo true || echo false)"
        ;;
    *) echo "用法: $0 {on|off|status|generate-config}" ;;
esac
