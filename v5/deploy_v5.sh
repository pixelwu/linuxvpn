#!/usr/bin/env bash
# ==============================================================================
# deploy_v5.sh — 安全无感部署 Lima Proxy v5.0（自动备份 + 先拷贝后热切换，绝不留死代理断网）
# 说明：
# - 绝不触碰外部 VPN (Shadowrocket)
# - 绝不修改 Linux 虚拟机内部原生配置
# - 如果部署前正在使用 Lima 共享 (7890)，部署完立刻自动热拉起新版守护，避免留死代理断网
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
echo "🚀 开始部署 Lima Proxy v5.0 健壮重构版 (零死代理防断网模式)"
echo "📦 备份目录: $BACKUP_DIR"
echo "=================================================================="

mkdir -p "$TARGET_DIR/web" "$TARGET_DIR/logs" "$TARGET_DIR/ruleset" "$BACKUP_DIR" "$LAUNCH_DIR"

# 0. 部署前探测：当前是否正在使用 Lima 共享 (7890)
WAS_ACTIVE=false
TOP_PORT=$(scutil --proxy 2>/dev/null | awk '/HTTPPort :/{print $3; exit}' || echo "0")
if [[ "$TOP_PORT" == "7890" ]] || nc -z 127.0.0.1 7890 >/dev/null 2>&1; then
    WAS_ACTIVE=true
fi
echo "ℹ️  部署前状态检测: Lima 共享活跃=${WAS_ACTIVE} (顶层端口: ${TOP_PORT:-无})"

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

echo "2️⃣  先原子替换全部 v5.0 脚本、Web UI 与 LaunchAgent 模板（不停现网）..."
cp "$SCRIPT_DIR/lima-proxy/lima-bridge.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/lima-proxy-daemon.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/mac-proxy-bridge.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/lima-proxy-reconnect.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/lima-proxy-switch.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/NETWORK_GUARDRAILS.md" "$TARGET_DIR/"
cp "$SCRIPT_DIR/lima-proxy/web/index.html" "$TARGET_DIR/web/index.html"
chmod +x "$TARGET_DIR"/*.sh

cp "$SCRIPT_DIR/🚨紧急恢复Mac网络.command" "$DESKTOP_CMD"
chmod +x "$DESKTOP_CMD"

sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$USER|g" \
    "$SCRIPT_DIR/launchagents/com.user.lima-proxy-tunnel.plist.tmpl" \
    > "$LAUNCH_DIR/com.user.lima-proxy-tunnel.plist"
sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$USER|g" \
    "$SCRIPT_DIR/launchagents/com.user.lima-proxy-singbox.plist.tmpl" \
    > "$LAUNCH_DIR/com.user.lima-proxy-singbox.plist"

rm -f "$TARGET_DIR/proxy.pac" "$TARGET_DIR/pac-server.pid" "$TARGET_DIR/env.sh" "$TARGET_DIR/network_snapshot.json"
echo "   ✓ 文件替换完成"

echo "3️⃣  平滑切换守护进程（防止出现死代理窗口）..."
if [[ "$WAS_ACTIVE" == "true" ]]; then
    echo "   🔄 检测到您正在使用 Lima 共享，正在自动热重载新版 v5.0 守护与全应用 utun99..."
    "$TARGET_DIR/lima-bridge.sh" on
else
    echo "   ℹ️  当前未处于 Lima 共享模式，安全卸载旧版闲置守护（不触碰当前网络/Shadowrocket）。"
    launchctl bootout "gui/${UID_NUM}/com.user.lima-proxy-singbox" 2>/dev/null || true
    launchctl bootout "gui/${UID_NUM}/com.user.lima-proxy-tunnel" 2>/dev/null || true
    "$TARGET_DIR/lima-bridge.sh" doctor
fi

echo ""
echo "=================================================================="
echo "✅ Lima Proxy v5.0 部署完成！"
echo "=================================================================="
