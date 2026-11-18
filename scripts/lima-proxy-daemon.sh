#!/bin/bash
# ==============================================================================
# ~/.lima-proxy/lima-proxy-daemon.sh — launchd 守护入口
# 用法: lima-proxy-daemon.sh {tunnel|singbox}
# 由 LaunchAgent plist 调用，负责单一职责的进程启动与前置检查。
# 关键：env -i 隔离已在 plist EnvironmentVariables 中完成，此处无需再套。
# ==============================================================================
set -uo pipefail

BASE_DIR="$HOME/.lima-proxy"
BIN_PATH="$BASE_DIR/bin/sing-box"
CONF_PATH="$BASE_DIR/mac-singbox.json"
LOG_PATH="$BASE_DIR/mac-singbox.log"
VM_NAME="mini-work"
SSH_CONFIG="${HOME}/.lima/${VM_NAME}/ssh.config"
LIMA_HOST="lima-${VM_NAME}"
TUNNEL_PORT="${LIMA_PORT:-17890}"
VM_PROXY_ADDR="10.203.0.1:${TUNNEL_PORT}"

ensure_vm_running() {
    local st
    st=$(limactl list --json 2>/dev/null | jq -r 'select(.name=="'"$VM_NAME"'") | .status' 2>/dev/null | head -1 || true)
    if [[ "$st" != "Running" ]]; then
        echo "[daemon] 正在自动启动 Lima VM '$VM_NAME'..."
        limactl start "$VM_NAME" >/dev/null 2>&1 || true
        sleep 3
    fi
}

case "${1:-}" in
    tunnel)
        # SSH 本地端口转发隧道（前台运行，由 launchd KeepAlive 保活）
        ensure_vm_running
        exec ssh -N \
            -F "$SSH_CONFIG" \
            -o ExitOnForwardFailure=yes \
            -o ServerAliveInterval=5 \
            -o ServerAliveCountMax=3 \
            -o ConnectTimeout=10 \
            -L "127.0.0.1:${TUNNEL_PORT}:${VM_PROXY_ADDR}" \
            "$LIMA_HOST"
        ;;
    singbox)
        # 本地 sing-box（前台运行，由 launchd KeepAlive 保活）
        # 等待隧道就绪（最多 15 秒）
        for i in $(seq 1 15); do
            if nc -z 127.0.0.1 "$TUNNEL_PORT" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # 生成 TUN 模式配置
        "$BASE_DIR/lima-bridge.sh" generate-config 2>/dev/null || true
        # env -i 在外层清空环境（防自回环），sudo -n 在内层提权（sudoers 白名单免密）
        exec sudo -n "$BIN_PATH" run -c "$CONF_PATH"
        ;;
    *)
        echo "用法: $0 {tunnel|singbox}"
        exit 1
        ;;
esac
