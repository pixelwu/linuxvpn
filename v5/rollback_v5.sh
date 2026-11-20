#!/usr/bin/env bash
# ==============================================================================
# rollback_v5.sh — 一键回滚至部署 v5.0 前的备份状态
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
set -euo pipefail

TARGET_DIR="$HOME/.lima-proxy"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
DESKTOP_CMD="$HOME/Desktop/🚨紧急恢复Mac网络.command"
UID_NUM="$(id -u)"

if [[ ! -f "$TARGET_DIR/.last_backup" ]]; then
    echo "❌ 未找到部署备份记录 ($TARGET_DIR/.last_backup)"
    exit 1
fi

BACKUP_DIR="$(cat "$TARGET_DIR/.last_backup")"
if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "❌ 备份目录不存在: $BACKUP_DIR"
    exit 1
fi

echo "↩️  正在回滚至备份: $BACKUP_DIR"
launchctl bootout "gui/${UID_NUM}/com.user.lima-proxy-singbox" 2>/dev/null || true
launchctl bootout "gui/${UID_NUM}/com.user.lima-proxy-tunnel" 2>/dev/null || true

for f in lima-bridge.sh mac-proxy-bridge.sh lima-proxy-daemon.sh lima-proxy-reconnect.sh lima-proxy-switch.sh mac-singbox.json env.sh proxy.pac; do
    [[ -f "$BACKUP_DIR/$f" ]] && cp "$BACKUP_DIR/$f" "$TARGET_DIR/"
done
[[ -f "$BACKUP_DIR/index.html" ]] && cp "$BACKUP_DIR/index.html" "$TARGET_DIR/web/index.html"
[[ -f "$BACKUP_DIR/com.user.lima-proxy-tunnel.plist" ]] && cp "$BACKUP_DIR/com.user.lima-proxy-tunnel.plist" "$LAUNCH_DIR/"
[[ -f "$BACKUP_DIR/com.user.lima-proxy-singbox.plist" ]] && cp "$BACKUP_DIR/com.user.lima-proxy-singbox.plist" "$LAUNCH_DIR/"
[[ -f "$BACKUP_DIR/🚨紧急恢复Mac网络.command" ]] && cp "$BACKUP_DIR/🚨紧急恢复Mac网络.command" "$DESKTOP_CMD"
chmod +x "$TARGET_DIR"/*.sh "$DESKTOP_CMD" 2>/dev/null || true

echo "✅ 已成功回滚到部署前版本！"
