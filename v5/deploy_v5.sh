#!/usr/bin/env bash
# ==============================================================================
# deploy_v5.sh — 安全部署 Lima Proxy v5.0 重构架构（自动备份 + 原子替换）
# 说明：
# - 绝不触碰外部 VPN (Shadowrocket)
# - 绝不修改 Linux 虚拟机内部原生配置
# - 自动备份原 ~/.lima-proxy 脚本、LaunchAgent 与桌面恢复脚本，支持 rollback_v5.sh 一键回滚
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.lima-proxy"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
DESKTOP_CMD="$HOME/Desktop/🚨紧急恢复Mac网络.command"
BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$TARGET_DIR/backups/$BACKUP_TS"
UID_NUM="$(id -u)"

echo "=================================================================="
echo "🚀 开始部署 Lima Proxy v5.0 健壮重构版"
echo "📦 备份目录: $BACKUP_DIR"
echo "=================================================================="

mkdir -p "$TARGET_DIR/web" "$TARGET_DIR/logs" "$TARGET_DIR/ruleset" "$BACKUP_DIR" "$LAUNCH_DIR"

echo "1️⃣  备份现有脚本与配置..."
for f in lima-bridge.sh mac-proxy-bridge.sh lima-proxy-daemon.sh lima-proxy-reconnect.sh lima-proxy-switch.sh mac-singbox.json env.sh proxy.pac pac-server.pid network_snapshot.json; do
    [[ -f "$TARGET_DIR/$f" ]] && cp "$TARGET_DIR/$f" "$BACKUP_DIR/"
done
[[ -f "$TARGET_DIR/web/index.html" ]] && cp "$TARGET_DIR/web/index.html" "$BACKUP_DIR/index.html"
[[ -f "$LAUNCH_DIR/com.user.lima-proxy-tunnel.plist" ]] && cp "$LAUNCH_DIR/com.user.lima-proxy-tunnel.plist" "$BACKUP_DIR/"
[[ -f "$LAUNCH_DIR/com.user.lima-proxy-singbox.plist" ]] && cp "$LAUNCH_DIR/com.user.lima-proxy-singbox.plist" "$BACKUP_DIR/"
[[ -f "$DESKTOP_CMD" ]] && cp "$DESKTOP_CMD" "$BACKUP_DIR/"
echo "$BACKUP_DIR" > "$TARGET_DIR/.last_backup"
echo "   ✓ 备份完成"

echo "2️⃣  安全停止旧版 launchd 守护（不影响 Shadowrocket）..."
launchctl bootout "gui/${UID_NUM}/com.user.lima-proxy-singbox" 2>/dev/null || true
launchctl bootout "gui/${UID_NUM}/com.user.lima-proxy-tunnel" 2>/dev/null || true

echo "3️⃣  部署 v5.0 核心脚本与 Web UI..."
cp "$SCRIPT_DIR/lima-proxy/lima-bridge.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/lima-proxy-daemon.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/mac-proxy-bridge.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/lima-proxy-reconnect.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/lima-proxy-switch.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/web/index.html" "$TARGET_DIR/web/index.html"
chmod +x "$TARGET_DIR"/*.sh

cp "$SCRIPT_DIR/🚨紧急恢复Mac网络.command" "$DESKTOP_CMD"
chmod +x "$DESKTOP_CMD"

echo "4️⃣  安装标准化 LaunchAgent (RunAtLoad=false, KeepAlive防抖保活)..."
sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$USER|g" \
    "$SCRIPT_DIR/launchagents/com.user.lima-proxy-tunnel.plist.tmpl" \
    > "$LAUNCH_DIR/com.user.lima-proxy-tunnel.plist"
sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$USER|g" \
    "$SCRIPT_DIR/launchagents/com.user.lima-proxy-singbox.plist.tmpl" \
    > "$LAUNCH_DIR/com.user.lima-proxy-singbox.plist"

echo "5️⃣  清理早期 PAC/旧版遗留碎片文件（已保留在备份目录中）..."
rm -f "$TARGET_DIR/proxy.pac" "$TARGET_DIR/pac-server.pid" "$TARGET_DIR/env.sh" "$TARGET_DIR/network_snapshot.json"

echo ""
echo "6️⃣  运行系统体检 (lima-bridge.sh doctor)..."
"$TARGET_DIR/lima-bridge.sh" doctor

echo ""
echo "=================================================================="
echo "✅ Lima Proxy v5.0 部署完成！"
echo "👉 使用方式："
echo "   • 开启全应用共享: ~/.lima-proxy/lima-bridge.sh on  (或在 Lima Proxy.app 点「开启 Mac 代理」)"
echo "   • 关闭并恢复直连: ~/.lima-proxy/lima-bridge.sh off (或点「关闭 Mac 代理」)"
echo "   • 如需回滚旧版本: bash $SCRIPT_DIR/rollback_v5.sh"
echo "=================================================================="
