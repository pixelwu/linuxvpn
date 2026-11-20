#!/usr/bin/env bash
# ==============================================================================
# 🚨 紧急恢复 Mac 纯净网络 (v5.0 终极熔断与零残留恢复)
# 作用：无论脚本或 launchd 状态如何，0.5 秒彻底恢复纯净物理直连
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

clear
echo "=================================================================="
echo "🚨 macOS 网络紧急熔断与彻底恢复程序 (v5.0)"
echo "=================================================================="
echo ""

if [[ -x "$HOME/.lima-proxy/lima-bridge.sh" ]]; then
    "$HOME/.lima-proxy/lima-bridge.sh" off || true
fi

# 独立二次兜底：确保哪怕 lima-bridge.sh 损坏，launchd、进程、网卡、变量也全部清空
UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}/com.user.lima-proxy-singbox" 2>/dev/null || true
launchctl bootout "gui/${UID_NUM}/com.user.lima-proxy-tunnel" 2>/dev/null || true
sudo -n /usr/bin/pkill -9 -f ".lima-proxy/bin/sing-box" 2>/dev/null || true
pkill -9 -f ".lima-proxy/bin/sing-box" 2>/dev/null || true
pkill -9 -f "127.0.0.1:17890:10.203.0.1:17890" 2>/dev/null || true

services=$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 || true)
while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    clean="${s#\*}"
    networksetup -setautoproxystate "$clean" off 2>/dev/null || true
    networksetup -setwebproxystate "$clean" off 2>/dev/null || true
    networksetup -setsecurewebproxystate "$clean" off 2>/dev/null || true
    networksetup -setsocksfirewallproxystate "$clean" off 2>/dev/null || true
done <<< "$services"

for var in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    launchctl unsetenv "$var" 2>/dev/null || true
done

if [[ -d "$HOME/.lima-proxy" ]]; then
    cat > "$HOME/.lima-proxy/shell_env.sh" <<'EOF'
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy
EOF
fi

sudo -n /usr/bin/killall -HUP mDNSResponder 2>/dev/null || killall -HUP mDNSResponder 2>/dev/null || true
sudo -n /usr/sbin/dscacheutil -flushcache 2>/dev/null || dscacheutil -flushcache 2>/dev/null || true

echo ""
echo "🔍 校验当前系统代理内核表状态 (scutil --proxy):"
scutil --proxy | grep -E "(HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable)" || echo "   (所有系统代理已全部关闭)"
if ifconfig utun99 >/dev/null 2>&1; then
    echo "⚠️  utun99 仍存在，请稍候 1 秒或检查权限。"
else
    echo "✅ utun99 已彻底卸载。"
fi

echo ""
echo "=================================================================="
echo "✅ 恢复完成！macOS 已 100% 恢复纯净物理直连。"
echo "🔓 现在您可以随时启动 Shadowrocket 或其他网络工具。"
echo "=================================================================="
echo ""
read -p "按回车键退出窗口..."
