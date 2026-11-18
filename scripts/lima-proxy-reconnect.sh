#!/usr/bin/env bash
# ==============================================================================
# ~/.lima-proxy/lima-proxy-reconnect.sh
# ⚡ 一键重选当前生效节点并重建开启 Mac 宿主代理共享 (长连接断连自愈)
# ==============================================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

BASE_DIR="$HOME/.lima-proxy"
CONFIG="$BASE_DIR/config.json"
SWITCH_SCRIPT="$BASE_DIR/lima-proxy-switch.sh"
BRIDGE_SCRIPT="$BASE_DIR/lima-bridge.sh"

# 1. 解析目标节点 ID (支持命令行传参指定，若未指定则自动提取当前 active_node)
target_id="${1:-}"
if [[ -z "$target_id" ]]; then
    target_id=$(jq -r '.active_node // empty' "$CONFIG" 2>/dev/null || true)
fi

# 若 active_node 缺失或为 null，安全回退到首个可用节点
if [[ -z "$target_id" || "$target_id" == "null" ]]; then
    target_id=$(jq -r '.nodes[0].id // empty' "$CONFIG" 2>/dev/null || true)
fi

if [[ -z "$target_id" || "$target_id" == "null" ]]; then
    echo "❌ 错误: 未在 $CONFIG 中找到任何可用节点！"
    exit 1
fi

node_name=$(jq -r ".nodes[] | select(.id==\"$target_id\") | .name // \"$target_id\"" "$CONFIG" 2>/dev/null || echo "$target_id")

echo "=================================================================="
echo "⚡ Lima Proxy 节点重置与共享自愈程序"
echo "🎯 目标节点: $node_name"
echo "🆔 节点标识: $target_id"
echo "=================================================================="
echo ""

# 2. 虚拟机内部强制重选节点 (重解落地 IP、重载防火墙、重启 sing-box)
echo "🔄 [1/2] 正在强制重选并重载 Linux 虚拟机节点..."
"$SWITCH_SCRIPT" switch "$target_id"

# 3. 重建 Mac 宿主机桥接共享 (重建 SSH 隧道、重启 7890 + utun99、重置系统代理)
echo ""
echo "🚀 [2/2] 正在重建并开启 Mac 宿主端代理共享..."
"$BRIDGE_SCRIPT" on

echo ""
echo "=================================================================="
echo "✅ 重连与代理共享自愈完成！当前节点: $node_name"
echo "=================================================================="

# 4. macOS 桌面弹窗通知
osascript -e "display notification \"节点 [$node_name] 已重选生效，Mac 代理共享已恢复！\" with title \"⚡ Lima Proxy 自愈成功\" sound name \"Glass\"" 2>/dev/null || true
