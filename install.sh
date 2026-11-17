#!/usr/bin/env bash
# install.sh — 部署并安装 Lima Proxy Manager 到本地系统

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.lima-proxy"
APP_DIR="$HOME/Applications/Lima Proxy.app/Contents/MacOS"

echo "🚀 开始安装 Lima Proxy Manager..."

# 1. 确保目标目录存在
mkdir -p "$TARGET_DIR/web"
mkdir -p "$APP_DIR"

# 2. 安装脚本与前端资源
cp "$SCRIPT_DIR/scripts/lima-proxy-switch.sh" "$TARGET_DIR/lima-proxy-switch.sh"
chmod +x "$TARGET_DIR/lima-proxy-switch.sh"
cp "$SCRIPT_DIR/web/index.html" "$TARGET_DIR/web/index.html"
cp "$SCRIPT_DIR/app/LimaProxyApp.swift" "$TARGET_DIR/LimaProxyApp.swift"

# 3. 如果本地没有 config.json，则基于模板创建
if [[ ! -f "$TARGET_DIR/config.json" ]]; then
  echo "📄 正在初始化 $TARGET_DIR/config.json ..."
  cp "$SCRIPT_DIR/config.example.json" "$TARGET_DIR/config.json"
fi

# 4. 编译 Swift GUI 应用
echo "🔨 正在编译 macOS 原生应用..."
swiftc -O -o "$TARGET_DIR/LimaProxy" "$TARGET_DIR/LimaProxyApp.swift"
cp "$TARGET_DIR/LimaProxy" "$APP_DIR/LimaProxy"
chmod +x "$APP_DIR/LimaProxy"

echo "✅ 安装完成！您可以在 Dock 栏或通过 CLI 使用该工具："
echo "   CLI: ~/.lima-proxy/lima-proxy-switch.sh status"
echo "   GUI: open -a \"$HOME/Applications/Lima Proxy.app\""
