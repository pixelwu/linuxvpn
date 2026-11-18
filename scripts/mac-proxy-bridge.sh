#!/usr/bin/env bash
# mac-proxy-bridge.sh — macOS Host Router & Disaster-Recovery Bridge
# Thin wrapper & unified dispatcher for ~/.lima-proxy/lima-bridge.sh

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

BASE_DIR="$HOME/.lima-proxy"
LIMA_BRIDGE="$BASE_DIR/lima-bridge.sh"

case "${1:-status}" in
    start-core)
        "$LIMA_BRIDGE" on
        ;;
    stop-core)
        "$LIMA_BRIDGE" off
        ;;
    enable)
        "$LIMA_BRIDGE" on
        ;;
    disable)
        "$LIMA_BRIDGE" off
        ;;
    restore|panic-reset)
        "$LIMA_BRIDGE" off
        ;;
    status)
        if [[ "${2:-}" == "--json" ]]; then
            # JSON format for Web GUI
            top_port=$(scutil --proxy 2>/dev/null | awk '/HTTPPort :/{print $3; exit}' || echo "0")
            ext_vpn="none"
            if scutil --nc list 2>/dev/null | grep -q "\(Connected\).*Shadowrocket"; then
                ext_vpn="Shadowrocket"
            fi
            vm_st=$(limactl list --json 2>/dev/null | jq -r 'select(.name=="mini-work") | .status' 2>/dev/null | head -1 || echo "Stopped")
            tunnel_st="down"
            nc -z 127.0.0.1 17890 >/dev/null 2>&1 && tunnel_st="up"
            singbox_st="down"
            nc -z 127.0.0.1 7890 >/dev/null 2>&1 && singbox_st="up"

            jq -n \
                --arg vm_status "$vm_st" \
                --arg tunnel "$tunnel_st" \
                --arg singbox "$singbox_st" \
                --arg mode "direct-domain" \
                --arg ext_vpn "$ext_vpn" \
                --arg top_port "$top_port" \
                '{vm_status: $vm_status, tunnel: $tunnel, singbox: $singbox, mode: $mode, ext_vpn: $ext_vpn, top_port: $top_port}'
        else
            "$LIMA_BRIDGE" status
        fi
        ;;
    set-mode)
        echo "✅ 零死锁架构已采用纯内存域名分流模式 (无需切换模式，国内直连/国外透传)"
        ;;
    *)
        "$LIMA_BRIDGE" "${1:-status}"
        ;;
esac
