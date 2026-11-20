#!/usr/bin/env bash
# ==============================================================================
# ~/.lima-proxy/mac-proxy-bridge.sh (v5.0)
# 兼容层：全部统一转发至唯一状态机 ~/.lima-proxy/lima-bridge.sh
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -euo pipefail

LIMA_BRIDGE="$HOME/.lima-proxy/lima-bridge.sh"

case "${1:-status}" in
    set-mode)
        echo "✅ v5.0 架构采用纯内存域名+离线IP智能分流，国内直连/海外走 Lima，无需手动切模式。"
        ;;
    *)
        exec "$LIMA_BRIDGE" "$@"
        ;;
esac
