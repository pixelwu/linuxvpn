#!/usr/bin/env bash
# ==============================================================================
# ~/.lima-proxy/lima-proxy-daemon.sh (v5.0) — launchd 专属守护入口
# 用法: lima-proxy-daemon.sh {tunnel|singbox}
# 说明: 仅由 LaunchAgent 调用，前台运行 (exec)，由 launchd KeepAlive 负责保活与防抖重启。
# ==============================================================================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -uo pipefail

BASE_DIR="$HOME/.lima-proxy"
BIN_PATH="$BASE_DIR/bin/sing-box"
CONF_PATH="$BASE_DIR/mac-singbox.json"
VM_NAME="mini-work"
SSH_CONFIG="${HOME}/.lima/${VM_NAME}/ssh.config"
LIMA_HOST="lima-${VM_NAME}"
TUNNEL_PORT="${LIMA_PORT:-17890}"
VM_PROXY_ADDR="10.203.0.1:${TUNNEL_PORT}"

log() {
    printf '[%s] [daemon:%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${1:-main}" "${2:-}"
}

ensure_vm_running() {
    local st
    st=$(limactl list --json 2>/dev/null | jq -r 'select(.name=="'"$VM_NAME"'") | .status' 2>/dev/null | head -1 || true)
    if [[ "$st" != "Running" ]]; then
        log "tunnel" "检测到 Lima VM '$VM_NAME' 未运行 (${st:-Stopped})，尝试自动拉起..."
        limactl start "$VM_NAME" >/dev/null 2>&1 || true
        sleep 3
    fi
}

case "${1:-}" in
    tunnel)
        ensure_vm_running
        if [[ ! -f "$SSH_CONFIG" ]]; then
            log "tunnel" "未找到 SSH 配置 $SSH_CONFIG，等待 5 秒后重试..."
            sleep 5
            exit 1
        fi
        log "tunnel" "建立 SSH vsock 转发 127.0.0.1:${TUNNEL_PORT} -> ${VM_PROXY_ADDR}"
        # 禁用 ControlMaster 防止休眠唤醒后残留坏 Socket；10 秒保活探活失败即退出由 launchd 拉起
        exec ssh -N \
            -F "$SSH_CONFIG" \
            -o ControlMaster=no \
            -o ControlPath=none \
            -o TCPKeepAlive=yes \
            -o ExitOnForwardFailure=yes \
            -o ServerAliveInterval=5 \
            -o ServerAliveCountMax=2 \
            -o ConnectTimeout=10 \
            -L "127.0.0.1:${TUNNEL_PORT}:${VM_PROXY_ADDR}" \
            "$LIMA_HOST"
        ;;
    singbox)
        # 等待隧道端口就绪（最多 20 秒）
        for _ in $(seq 1 20); do
            if nc -z 127.0.0.1 "$TUNNEL_PORT" 2>/dev/null; then
                break
            fi
            sleep 1
        done

        # 确保配置文件存在且合法，不合法则退出等待人工排查，避免死循环刷屏
        if [[ ! -s "$CONF_PATH" ]]; then
            "$BASE_DIR/lima-bridge.sh" generate-config 2>/dev/null || true
        fi
        if ! "$BIN_PATH" check -c "$CONF_PATH" >/dev/null 2>&1; then
            log "singbox" "配置校验失败 ($CONF_PATH)，暂停 10 秒避免重启风暴"
            sleep 10
            exit 1
        fi

        # 根据配置是否包含 tun 入站决定是否需要 sudo -n 提权
        if jq -e '.inbounds[]? | select(.type=="tun")' "$CONF_PATH" >/dev/null 2>&1; then
            if sudo -n -l "$BIN_PATH" >/dev/null 2>&1; then
                log "singbox" "以 root 权限启动 sing-box (含 utun99 全应用分流)"
                exec sudo -n "$BIN_PATH" run -c "$CONF_PATH"
            else
                log "singbox" "无 sudo 免密权限，自动降级生成 proxy-only 配置"
                "$BASE_DIR/lima-bridge.sh" generate-config proxy-only 2>/dev/null || true
            fi
        fi

        log "singbox" "以用户态启动 sing-box (仅 7890 端口)"
        exec "$BIN_PATH" run -c "$CONF_PATH"
        ;;
    *)
        echo "用法: $0 {tunnel|singbox}"
        exit 1
        ;;
esac
