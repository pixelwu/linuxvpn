#!/usr/bin/env bash
# ==============================================================================
# ~/.lima-proxy/lima-proxy-reconnect.sh (v5.0)
# ⚡ 一键重选当前生效节点并重建 Mac 宿主代理共享 (断连自愈)
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -euo pipefail

BASE_DIR="$HOME/.lima-proxy"
CONFIG="$BASE_DIR/config.json"
SWITCH_SCRIPT="$BASE_DIR/lima-proxy-switch.sh"
BRIDGE_SCRIPT="$BASE_DIR/lima-bridge.sh"

target_id="${1:-}"
if [[ -z "$target_id" ]]; then
    target_id=$(jq -r '.active_node // empty' "$CONFIG" 2>/dev/null || true)
fi
if [[ -z "$target_id" || "$target_id" == "null" ]]; then
    target_id=$(jq -r '.nodes[0].id // empty' "$CONFIG" 2>/dev/null || true)
fi
if [[ -z "$target_id" || "$target_id" == "null" ]]; then
    echo "❌ 错误: 未在 $CONFIG 中找到任何可用节点！"
    exit 1
fi

node_name=$(jq -r --arg id "$target_id" '.nodes[] | select(.id==$id) | .name // $id' "$CONFIG" 2>/dev/null || echo "$target_id")

echo "=================================================================="
echo "⚡ Lima Proxy 节点重置与共享自愈程序 (v5.0)"
echo "🎯 目标节点: $node_name ($target_id)"
echo "=================================================================="

echo ""
echo "🔄 [1/2] 正在重选并重载 Linux 虚拟机节点..."
"$SWITCH_SCRIPT" switch "$target_id"

echo ""
echo "🚀 [2/2] 正在重建并开启 Mac 宿主端代理共享..."
"$BRIDGE_SCRIPT" on

echo ""
echo "✅ 重连与代理共享自愈完成！当前节点: $node_name"
osascript -e "display notification \"节点 [$node_name] 已生效，Mac 代理共享已恢复！\" with title \"⚡ Lima Proxy 自愈成功\" sound name \"Glass\"" 2>/dev/null || true
