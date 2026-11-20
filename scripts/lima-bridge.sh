#!/usr/bin/env bash
# ==============================================================================
# ~/.lima-proxy/lima-bridge.sh (v5.0 - 健壮单状态机 + 全应用分流 + launchd 统一托管)
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -euo pipefail

BASE_DIR="$HOME/.lima-proxy"
BIN_PATH="$BASE_DIR/bin/sing-box"
BASE_CONF="$BASE_DIR/mac-singbox.base.json"
RULESET_DIR="$BASE_DIR/ruleset"
CONF_PATH="$BASE_DIR/mac-singbox.json"
LOG_DIR="$BASE_DIR/logs"
SHELL_ENV_FILE="$BASE_DIR/shell_env.sh"
LOCK_DIR="$BASE_DIR/.bridge.lock"

VM_NAME="mini-work"
LOCAL_PORT="${MAC_PROXY_PORT:-7890}"
TUNNEL_PORT="${LIMA_PORT:-17890}"
VM_PROXY_ADDR="10.203.0.1:${TUNNEL_PORT}"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
TUNNEL_LABEL="com.user.lima-proxy-tunnel"
SINGBOX_LABEL="com.user.lima-proxy-singbox"
TUNNEL_PLIST="$LAUNCH_AGENTS_DIR/${TUNNEL_LABEL}.plist"
SINGBOX_PLIST="$LAUNCH_AGENTS_DIR/${SINGBOX_LABEL}.plist"
UID_NUM="$(id -u)"

BRIDGE_MODE="${LIMA_BRIDGE_MODE:-full-tun}"
BYPASS_LIST="localhost,127.0.0.1,::1,10.203.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,.local,.internal,.lan"

mkdir -p "$BASE_DIR" "$RULESET_DIR" "$LOG_DIR"

acquire_lock() {
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        if [[ -d "$LOCK_DIR" ]]; then
            local mtime now
            mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
            now=$(date +%s)
            if (( now - mtime > 60 )); then
                rm -rf "$LOCK_DIR" 2>/dev/null || true
                continue
            fi
        fi
        waited=$((waited + 1))
        if (( waited >= 30 )); then
            echo "❌ 另一个桥接操作正在进行中，等待超时，请稍后重试。"
            exit 1
        fi
        sleep 0.5
    done
    trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

can_sudo() {
    sudo -n -l "$BIN_PATH" >/dev/null 2>&1
}

detect_external_vpn() {
    if scutil --nc list 2>/dev/null | grep -qE '\(Connected\).*Shadowrocket'; then
        echo "Shadowrocket"
        return 0
    fi
    local top_port
    top_port=$(scutil --proxy 2>/dev/null | awk '/HTTPPort :/{print $3; exit}' || true)
    if [[ "$top_port" == "1082" ]]; then
        echo "Shadowrocket"
        return 0
    fi
    echo "none"
}

get_active_hardware_services() {
    networksetup -listallnetworkservices 2>/dev/null \
        | tail -n +2 | grep -v '^\*' | grep -E "Wi-Fi|Ethernet|LAN|Thunderbolt|USB" || true
}

get_all_hardware_services() {
    networksetup -listallnetworkservices 2>/dev/null \
        | tail -n +2 | sed 's/^\*//' | grep -E "Wi-Fi|Ethernet|LAN|Thunderbolt|USB" || true
}

get_vm_status() {
    limactl list --json 2>/dev/null \
        | jq -r 'select(.name=="'"$VM_NAME"'") | .status' 2>/dev/null \
        | head -1 || echo "Unknown"
}

is_launchd_loaded() {
    launchctl print "gui/${UID_NUM}/${1}" >/dev/null 2>&1
}

ensure_rulesets() {
    mkdir -p "$RULESET_DIR"
    local base_geosite="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
    local base_geoip="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set"

    if [[ ! -s "$RULESET_DIR/geosite-private.srs" ]]; then
        curl -fsSL --connect-timeout 6 --max-time 15 -o "$RULESET_DIR/geosite-private.srs" \
            "${base_geosite}/geosite-private.srs" 2>/dev/null || rm -f "$RULESET_DIR/geosite-private.srs"
    fi
    if [[ ! -s "$RULESET_DIR/geosite-cn.srs" ]]; then
        curl -fsSL --connect-timeout 6 --max-time 15 -o "$RULESET_DIR/geosite-cn.srs" \
            "${base_geosite}/geosite-cn.srs" 2>/dev/null || rm -f "$RULESET_DIR/geosite-cn.srs"
    fi
    if [[ ! -s "$RULESET_DIR/geoip-cn.srs" ]]; then
        curl -fsSL --connect-timeout 6 --max-time 15 -o "$RULESET_DIR/geoip-cn.srs" \
            "${base_geoip}/geoip-cn.srs" 2>/dev/null || rm -f "$RULESET_DIR/geoip-cn.srs"
    fi
}

generate_config() {
    local requested_mode="${1:-$BRIDGE_MODE}"
    local effective_mode="$requested_mode"

    if [[ "$effective_mode" != "proxy-only" ]] && ! can_sudo; then
        effective_mode="proxy-only"
    fi

    ensure_rulesets

    # 保留用户原有路由基础配置，首次运行时自动快照为 mac-singbox.base.json
    if [[ ! -s "$BASE_CONF" && -s "$CONF_PATH" ]]; then
        cp "$CONF_PATH" "$BASE_CONF"
    fi
    if [[ ! -s "$BASE_CONF" ]]; then
        echo "❌ 未找到基础配置文件 $CONF_PATH，请先恢复备份或初始化配置。" >&2
        return 1
    fi

    local has_ip_cn=false
    [[ -s "$RULESET_DIR/geoip-cn.srs" ]] && has_ip_cn=true

    local tmp_conf
    tmp_conf=$(mktemp "$BASE_DIR/.mac-singbox.tmp.XXXXXX")

    jq \
      --arg mode "$effective_mode" \
      --argjson local_port "$LOCAL_PORT" \
      --argjson tunnel_port "$TUNNEL_PORT" \
      --arg ruleset_dir "$RULESET_DIR" \
      --argjson has_ip_cn "$has_ip_cn" \
      '
        .inbounds = (
          if $mode == "full-tun" then
            [
              (.inbounds[] | select(.type == "mixed") | .listen_port = $local_port),
              {
                type: "tun",
                tag: "tun-all",
                interface_name: "utun99",
                address: ["198.18.0.1/30", "fdfe:dcba:9876::1/126"],
                mtu: 1400,
                auto_route: true,
                strict_route: false,
                route_exclude_address: [
                  "127.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16",
                  "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
                  "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
                ]
              }
            ]
          else
            [.inbounds[] | select(.type == "mixed") | .listen_port = $local_port]
          end
        )
        | (.outbounds[] | select(.tag == "to-lima") | .server_port) = $tunnel_port
        | .route.rule_set = (
            [(.route.rule_set // [])[] | select(.tag != "geoip-cn")] +
            (if ($has_ip_cn and $mode == "full-tun") then
              [{tag: "geoip-cn", type: "local", format: "binary", path: ($ruleset_dir + "/geoip-cn.srs")}]
            else [] end)
          )
        | .route.rules = (
            [(.route.rules // [])[] | select((.rule_set // []) != ["geoip-cn"] and (.process_name // []) != ["ssh", "limactl", "lima-guestagent"])]
            | (.[0:1] + [{process_name: ["ssh", "limactl", "lima-guestagent"], outbound: "direct"}] + .[1:])
            + (if ($has_ip_cn and $mode == "full-tun") then
                [{inbound: ["tun-all"], rule_set: ["geoip-cn"], outbound: "direct"}]
              else [] end)
          )
      ' "$BASE_CONF" > "$tmp_conf"

    if [[ -x "$BIN_PATH" ]] && ! "$BIN_PATH" check -c "$tmp_conf" >/dev/null 2>&1; then
        echo "❌ 生成的 sing-box 配置校验失败，已保留原配置:" >&2
        "$BIN_PATH" check -c "$tmp_conf" >&2 || true
        rm -f "$tmp_conf"
        return 1
    fi

    mv "$tmp_conf" "$CONF_PATH"
    echo "$effective_mode"
}

stop_daemons() {
    launchctl bootout "gui/${UID_NUM}/${SINGBOX_LABEL}" 2>/dev/null || true
    launchctl bootout "gui/${UID_NUM}/${TUNNEL_LABEL}" 2>/dev/null || true
    sleep 0.3

    sudo -n /usr/bin/pkill -f "$BIN_PATH run" 2>/dev/null || true
    pkill -f "$BIN_PATH run" 2>/dev/null || true
    pkill -f "127.0.0.1:${TUNNEL_PORT}:${VM_PROXY_ADDR}" 2>/dev/null || true
}

start_daemons() {
    if [[ ! -f "$TUNNEL_PLIST" || ! -f "$SINGBOX_PLIST" ]]; then
        echo "❌ 缺少 LaunchAgent 配置文件，请先运行 deploy_v5.sh 完成部署。"
        return 1
    fi

    launchctl bootout "gui/${UID_NUM}/${SINGBOX_LABEL}" 2>/dev/null || true
    launchctl bootout "gui/${UID_NUM}/${TUNNEL_LABEL}" 2>/dev/null || true
    sleep 0.2

    launchctl bootstrap "gui/${UID_NUM}" "$TUNNEL_PLIST" 2>/dev/null || true
    launchctl kickstart -k "gui/${UID_NUM}/${TUNNEL_LABEL}" 2>/dev/null || true

    local tunnel_ready=false
    for _ in $(seq 1 20); do
        if nc -z 127.0.0.1 "$TUNNEL_PORT" >/dev/null 2>&1; then
            tunnel_ready=true
            break
        fi
        sleep 0.5
    done
    if [[ "$tunnel_ready" != "true" ]]; then
        echo "⚠️  SSH 隧道 (127.0.0.1:${TUNNEL_PORT}) 启动超时，请检查日志: $LOG_DIR/tunnel.log"
    else
        echo "   ✓ SSH vsock 隧道已就绪并交由 launchd 保活 (127.0.0.1:${TUNNEL_PORT})"
    fi

    launchctl bootstrap "gui/${UID_NUM}" "$SINGBOX_PLIST" 2>/dev/null || true
    launchctl kickstart -k "gui/${UID_NUM}/${SINGBOX_LABEL}" 2>/dev/null || true

    local sb_ready=false
    for _ in $(seq 1 16); do
        if nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
            sb_ready=true
            break
        fi
        sleep 0.5
    done
    if [[ "$sb_ready" != "true" ]]; then
        echo "❌ 本地 sing-box (127.0.0.1:${LOCAL_PORT}) 启动失败，请查看日志: $LOG_DIR/singbox-daemon.log"
        return 1
    fi
    echo "   ✓ 本地 sing-box 已就绪并交由 launchd 保活 (127.0.0.1:${LOCAL_PORT})"
}

ensure_vm_running() {
    local st
    st=$(get_vm_status)
    if [[ "$st" != "Running" ]]; then
        echo "🔄 正在自动启动 Lima 虚拟机 '$VM_NAME' (当前状态: ${st:-Stopped})..."
        limactl start "$VM_NAME" >/dev/null 2>&1 || true
        sleep 2
    fi
}

flush_dns() {
    if can_sudo; then
        sudo -n /usr/bin/killall -HUP mDNSResponder 2>/dev/null || true
        sudo -n /usr/sbin/dscacheutil -flushcache 2>/dev/null || true
    else
        killall -HUP mDNSResponder 2>/dev/null || true
        dscacheutil -flushcache 2>/dev/null || true
    fi
}

start_bridge() {
    acquire_lock

    local ext_vpn target_mode
    ext_vpn=$(detect_external_vpn)
    target_mode="$BRIDGE_MODE"

    if [[ "$ext_vpn" != "none" ]]; then
        echo "⚠️  检测到外部 VPN ($ext_vpn) 处于连接状态！"
        echo "   为防双 TUN 网卡路由冲突，本次以安全兼容模式 (proxy-only) 挂载 7890；"
        echo "   关闭 $ext_vpn 后再次点「开启 Mac 代理」即可激活全应用接管 (utun99)。"
        target_mode="proxy-only"
    fi

    echo "🚀 [1/5] 校验环境并生成 sing-box 配置 (目标模式: ${target_mode})..."
    local effective_mode
    effective_mode=$(generate_config "$target_mode")
    ensure_vm_running
    echo "   ✓ 实际生效模式: ${effective_mode}"

    echo "🔗 [2/5] 通过 macOS launchd 启动并托管隧道与本地分流核心..."
    start_daemons

    echo "🌐 [3/5] 挂载物理网卡 HTTP/HTTPS 系统代理 (127.0.0.1:${LOCAL_PORT})..."
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        networksetup -setautoproxystate "$svc" off 2>/dev/null || true
        networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
        networksetup -setwebproxy "$svc" 127.0.0.1 "$LOCAL_PORT" 2>/dev/null || true
        networksetup -setsecurewebproxy "$svc" 127.0.0.1 "$LOCAL_PORT" 2>/dev/null || true
        networksetup -setwebproxystate "$svc" on 2>/dev/null || true
        networksetup -setsecurewebproxystate "$svc" on 2>/dev/null || true
        networksetup -setproxybypassdomains "$svc" \
            "localhost" "127.0.0.1" "::1" "10.203.0.1" "*.local" \
            "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" 2>/dev/null || true
        echo "   ✓ 已挂载: $svc -> 127.0.0.1:${LOCAL_PORT}"
    done <<< "$(get_active_hardware_services)"

    echo "🧬 [4/5] 同步注入 launchctl 与终端 shell_env.sh 代理环境变量..."
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

    echo "🔄 [5/5] 刷新系统 DNS 缓存..."
    flush_dns
    echo ""
    check_status
}

stop_bridge() {
    acquire_lock

    echo "🛑 [1/4] 正在卸载 launchd 守护进程并停止本地 sing-box / SSH 隧道..."
    stop_daemons
    echo "   ✓ 守护进程已卸载，utun99 与后台转发已彻底终止"

    echo "🧹 [2/4] 正在关闭所有物理网卡的 HTTP / HTTPS / SOCKS / PAC 代理..."
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        networksetup -setautoproxystate "$svc" off 2>/dev/null || true
        networksetup -setwebproxystate "$svc" off 2>/dev/null || true
        networksetup -setsecurewebproxystate "$svc" off 2>/dev/null || true
        networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null || true
        echo "   ✓ 已恢复直连: $svc"
    done <<< "$(get_all_hardware_services)"

    echo "🧹 [3/4] 正在清除 launchctl 与终端 shell_env.sh 环境变量..."
    for var in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
        launchctl unsetenv "$var" 2>/dev/null || true
    done
    cat > "$SHELL_ENV_FILE" <<'EOF'
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
EOF

    echo "🔄 [4/4] 正在刷新 macOS DNS 缓存..."
    flush_dns
    echo "✅ 已 100% 恢复 macOS 纯净物理直连（launchd 已停止、utun99 已卸载、零残留）！"
}

check_status_json() {
    local vm_st tunnel_st singbox_st tun_st ext_vpn top_port sudo_ok launchd_tunnel launchd_sb
    vm_st=$(get_vm_status)
    tunnel_st="down"
    nc -z 127.0.0.1 "$TUNNEL_PORT" >/dev/null 2>&1 && tunnel_st="up"
    singbox_st="down"
    nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1 && singbox_st="up"
    tun_st="off"
    ifconfig utun99 >/dev/null 2>&1 && tun_st="on"
    ext_vpn=$(detect_external_vpn)
    top_port=$(scutil --proxy 2>/dev/null | awk '/HTTPPort :/{print $3; exit}' || echo "0")
    sudo_ok="false"
    can_sudo && sudo_ok="true"
    launchd_tunnel="false"
    is_launchd_loaded "$TUNNEL_LABEL" && launchd_tunnel="true"
    launchd_sb="false"
    is_launchd_loaded "$SINGBOX_LABEL" && launchd_sb="true"

    jq -n \
        --arg vm_status "${vm_st:-Stopped}" \
        --arg tunnel "$tunnel_st" \
        --arg singbox "$singbox_st" \
        --arg tun "$tun_st" \
        --arg mode "$BRIDGE_MODE" \
        --arg ext_vpn "$ext_vpn" \
        --arg top_port "${top_port:-0}" \
        --argjson sudo_ok "$sudo_ok" \
        --argjson launchd_tunnel "$launchd_tunnel" \
        --argjson launchd_singbox "$launchd_sb" \
        '{
            vm_status: $vm_status,
            tunnel: $tunnel,
            singbox: $singbox,
            tun: $tun,
            mode: $mode,
            ext_vpn: $ext_vpn,
            top_port: $top_port,
            sudo_ok: $sudo_ok,
            launchd: { tunnel: $launchd_tunnel, singbox: $launchd_singbox }
        }'
}

check_status() {
    if [[ "${1:-}" == "--json" ]]; then
        check_status_json
        return 0
    fi

    local vm_st top_port ext_vpn
    vm_st=$(get_vm_status)
    top_port=$(scutil --proxy 2>/dev/null | awk '/HTTPPort :/{print $3; exit}' || echo "未开启")
    ext_vpn=$(detect_external_vpn)

    echo "================ Lima Proxy 桥接健康面板 (v5.0) ================"
    echo "• Lima 虚拟机 ($VM_NAME) : ${vm_st:-Unknown}"
    if nc -z 127.0.0.1 "$TUNNEL_PORT" >/dev/null 2>&1; then
        echo "• SSH vsock 隧道 ($TUNNEL_PORT) : ✅ 运行中 (launchd: $(is_launchd_loaded "$TUNNEL_LABEL" && echo '托管中' || echo '未托管'))"
    else
        echo "• SSH vsock 隧道 ($TUNNEL_PORT) : ❌ 未连接"
    fi
    if nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
        echo "• Mac 分流核心 ($LOCAL_PORT)    : ✅ 运行中 (launchd: $(is_launchd_loaded "$SINGBOX_LABEL" && echo '托管中' || echo '未托管'))"
    else
        echo "• Mac 分流核心 ($LOCAL_PORT)    : ❌ 未运行"
    fi
    if ifconfig utun99 >/dev/null 2>&1; then
        echo "• 全应用网卡 (utun99)    : ✅ 已激活 (所有海外流量透明接管，国内直连)"
    else
        echo "• 全应用网卡 (utun99)    : ⚪ 未激活 (免密授权: $(can_sudo && echo '已就绪' || echo '未配置'))"
    fi
    echo "• 系统顶层 HTTPPort      : ${top_port:-未开启}"

    if [[ "$ext_vpn" != "none" ]]; then
        echo "⚠️  [互斥提示] 外部 VPN ($ext_vpn) 处于连接状态，系统顶层路由正由其接管。"
    elif [[ "${top_port:-}" == "${LOCAL_PORT}" ]]; then
        echo "✅ Mac 全生态代理桥接运行正常！"
    else
        echo "ℹ️  当前处于纯净物理直连状态。"
    fi
    echo "================================================================"
}

cmd_test() {
    echo "🧪 测试 Mac 宿主机双轨分流连通性..."
    local cn_code overseas_code
    cn_code=$(curl -x "http://127.0.0.1:${LOCAL_PORT}" -s -o /dev/null -w "%{http_code}" --connect-timeout 5 https://www.baidu.com 2>/dev/null || echo "000")
    overseas_code=$(curl -x "http://127.0.0.1:${LOCAL_PORT}" -s -o /dev/null -w "%{http_code}" --connect-timeout 8 https://www.google.com 2>/dev/null || echo "000")
    echo "  • 国内直连 (baidu.com)  : HTTP ${cn_code}"
    echo "  • 海外代理 (google.com) : HTTP ${overseas_code}"
    if [[ "$overseas_code" =~ ^[23] ]]; then
        echo "✅ Mac 分流代理工作正常！"
    else
        echo "❌ 海外代理不可用，请检查 Lima VM 与节点状态。"
        return 1
    fi
}

case "${1:-status}" in
    on|enable|start|start-core)
        start_bridge
        ;;
    off|disable|stop|stop-core|restore|panic-reset)
        stop_bridge
        ;;
    restart)
        stop_bridge
        start_bridge
        ;;
    status|doctor)
        check_status "${2:-}"
        ;;
    test)
        cmd_test
        ;;
    generate-config)
        generate_config "${2:-$BRIDGE_MODE}" >/dev/null
        ;;
    *)
        echo "用法: $0 {on|off|restart|status [--json]|doctor|test|generate-config}"
        exit 1
        ;;
esac
