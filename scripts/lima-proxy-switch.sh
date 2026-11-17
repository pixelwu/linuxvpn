#!/usr/bin/env bash
# lima-proxy-switch.sh — CLI tool to manage Lima mini-work sing-box proxy
# v2.0 — refactored for robustness + subscription support

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Usage:
#   lima-proxy-switch.sh status                      — show current proxy status
#   lima-proxy-switch.sh list                        — list all nodes from config
#   lima-proxy-switch.sh switch <id>                 — switch to node by id
#   lima-proxy-switch.sh add <json>                  — add a node (JSON string)
#   lima-proxy-switch.sh delete <id>                 — delete a node by id
#   lima-proxy-switch.sh test                        — test current proxy connectivity
#   lima-proxy-switch.sh import-trojan-url <url>     — import trojan:// URL
#   lima-proxy-switch.sh import-subscription [--url] — import from subscription (uses saved URL or --url=xxx)
#   lima-proxy-switch.sh set-subscription <url>      — save subscription URL
#   lima-proxy-switch.sh subscription-info           — show saved subscription info

set -euo pipefail

CONFIG="$HOME/.lima-proxy/config.json"
VM_NAME="mini-work"
SING_BOX_CONF="/etc/mini-work/sing-box.json"
NFT_CONF="/etc/mini-work/root.nft"
LOCK_FILE="$HOME/.lima-proxy/.config.lock"

# ─── Helpers ───

_vm() {
  limactl shell "$VM_NAME" -- "$@"
}

_vm_sudo() {
  limactl shell "$VM_NAME" -- sudo bash -c "$1"
}

_jq_config() {
  jq "$@" "$CONFIG"
}

_ensure_vm_running() {
  local st
  st=$(limactl list --json | jq -r 'select(.name=="'"$VM_NAME"'") | .status' 2>/dev/null | head -1)
  if [[ -z "$st" || "$st" != "Running" ]]; then
    echo "❌ VM $VM_NAME 未运行 (status=${st:-not found})"
    echo "   请先运行: limactl start $VM_NAME"
    exit 1
  fi
}

# Atomic config write (macOS compatible, no flock needed)
_write_config() {
  local jq_expr="$1"
  local tmp
  tmp=$(mktemp "$HOME/.lima-proxy/.config.tmp.XXXXXX")
  if jq "$jq_expr" "$CONFIG" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CONFIG"
  else
    rm -f "$tmp"
    echo "❌ jq 表达式执行失败: $jq_expr"
    return 1
  fi
}

# URL-decode a string
_urldecode() {
  python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" <<< "$1" 2>/dev/null || printf '%s' "$1"
}

# Escape string for safe HTML display
_sanitize_name() {
  local name="$1"
  # Remove any HTML tags but keep emoji and normal chars
  echo "$name" | sed 's/<[^>]*>//g'
}

# ─── Commands ───

cmd_status() {
  _ensure_vm_running
  echo "📡 当前代理状态"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Service status
  local svc_status
  svc_status=$(_vm sudo systemctl is-active mw-proxy.service 2>/dev/null || echo "unknown")
  if [[ "$svc_status" == "active" ]]; then
    echo "  服务:   ✅ active"
  else
    echo "  服务:   ❌ $svc_status"
  fi

  # Current config — read outbound[0] fields safely
  local current
  current=$(_vm sudo cat "$SING_BOX_CONF" 2>/dev/null | jq -r '.outbounds[0] | "\(.type)|\(.server)|\(.server_port)|\(.tls.server_name // "-")"' 2>/dev/null || echo "unknown|unknown|unknown|unknown")
  IFS='|' read -r c_type c_server c_port c_sni <<< "$current"
  echo "  协议:   ${c_type:-unknown}"
  echo "  服务器: ${c_server:-unknown}"
  echo "  端口:   ${c_port:-unknown}"
  echo "  SNI:    ${c_sni:-unknown}"

  # Firewall
  local fw_ip
  fw_ip=$(_vm sudo nft list set inet mini_work_guard upstream4 2>/dev/null | grep -oE '([0-9]+\.){3}[0-9]+' | head -1 || echo "unknown")
  echo "  防火墙: ${fw_ip:-unknown}"

  # Connectivity
  echo ""
  echo "🔗 连通性测试..."
  local http_code
  http_code=$(_vm bash -c 'curl -x http://10.203.0.1:17890 -s -o /dev/null -w "%{http_code}" --connect-timeout 8 https://www.google.com' 2>/dev/null || true)
  if [[ "$http_code" =~ ^[23] ]]; then
    echo "  结果:   ✅ HTTP $http_code"
  else
    echo "  结果:   ❌ 连接失败 (HTTP ${http_code:-000})"
  fi

  # Active node from config
  local active_id
  active_id=$(jq -r '.active_node // "none"' "$CONFIG" 2>/dev/null || echo "none")
  echo ""
  echo "  配置活跃节点: $active_id"

  # Subscription info
  local sub_url
  sub_url=$(jq -r '.subscription_url // empty' "$CONFIG" 2>/dev/null || true)
  if [[ -n "$sub_url" ]]; then
    local sub_updated
    sub_updated=$(jq -r '.subscription_updated // "从未"' "$CONFIG" 2>/dev/null || echo "从未")
    echo "  订阅: 已配置 (上次更新: $sub_updated)"
  fi
}

cmd_list() {
  echo "📋 已保存的节点"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local active_id
  active_id=$(jq -r '.active_node // ""' "$CONFIG" 2>/dev/null || echo "")
  local count
  count=$(jq '.nodes | length' "$CONFIG" 2>/dev/null || echo "0")

  if [[ "$count" == "0" ]]; then
    echo "  (无节点)"
    return
  fi

  jq -r '.nodes[] | "\(.id)|\(.flag // "🌐")|\(.name)|\(.type)|\(.server):\(.server_port)|\(.source // "manual")"' "$CONFIG" 2>/dev/null | while IFS='|' read -r id flag name type endpoint source; do
    local marker="  "
    if [[ "$id" == "$active_id" ]]; then
      marker="▶ "
    fi
    local source_tag=""
    if [[ "$source" == "subscription" ]]; then
      source_tag=" 📡"
    fi
    printf "%s%s %s  [%s]  %s%s\n" "$marker" "$flag" "$name" "$type" "$endpoint" "$source_tag"
  done
}

cmd_switch() {
  local node_id="$1"
  _ensure_vm_running

  # Get node from config
  local node
  node=$(jq -e ".nodes[] | select(.id==\"$node_id\")" "$CONFIG" 2>/dev/null || true)
  if [[ -z "$node" ]]; then
    echo "❌ 未找到节点: $node_id"
    echo "可用节点:"
    cmd_list
    exit 1
  fi

  local n_type n_server n_port n_password n_sni n_insecure n_name
  n_type=$(echo "$node" | jq -r '.type')
  n_server=$(echo "$node" | jq -r '.server')
  n_port=$(echo "$node" | jq -r '.server_port')
  n_password=$(echo "$node" | jq -r '.password')
  n_sni=$(echo "$node" | jq -r '.tls_sni // .server')
  n_insecure=$(echo "$node" | jq -r '.tls_insecure // false')
  n_name=$(echo "$node" | jq -r '.name')

  echo "🔄 切换到: $n_name [$n_type] ($n_server:$n_port)"

  # Determine transport protocol for nftables
  local transport="tcp"
  if [[ "$n_type" == "hysteria2" || "$n_type" == "hysteria" || "$n_type" == "tuic" ]]; then
    transport="udp"
  fi

  # Resolve server hostname to IP for nftables (nftables needs IP)
  local n_ip="$n_server"
  if ! echo "$n_server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "  ℹ️  解析域名 $n_server ..."
    # Avoid Fake-IP (198.18.x.x / 198.19.x.x) caused by macOS VPN/TUN
    n_ip=$(dig @8.8.8.8 +short "$n_server" A 2>/dev/null | grep -vE '^198\.(18|19)\.' | grep -E '^[0-9]+\.' | head -1 || true)
    if [[ -z "$n_ip" ]]; then
      n_ip=$(curl -s "https://dns.google/resolve?name=$n_server&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | grep -vE '^198\.(18|19)\.' | head -1 || true)
    fi
    if [[ -z "$n_ip" ]]; then
      n_ip=$(dig +short "$n_server" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
    fi
    if [[ -z "$n_ip" ]]; then
      echo "❌ 无法解析域名: $n_server"
      exit 1
    fi
    echo "  ℹ️  解析结果: $n_ip"
  fi

  # Step 1: Generate new sing-box.json using jq (safe JSON generation)
  echo "  [1/4] 生成 sing-box 配置..."
  local sing_box_json
  sing_box_json=$(jq -n \
    --arg type "$n_type" \
    --arg tag "${n_type}-out" \
    --arg server "$n_ip" \
    --argjson port "$n_port" \
    --arg password "$n_password" \
    --arg sni "$n_sni" \
    --argjson insecure "$n_insecure" \
    '{
      log: { level: "warn", timestamp: true },
      inbounds: [{
        type: "mixed",
        tag: "work-in",
        listen: "10.203.0.1",
        listen_port: 17890
      }],
      outbounds: [{
        type: $type,
        tag: $tag,
        server: $server,
        server_port: $port,
        password: $password,
        tls: {
          enabled: true,
          server_name: $sni,
          insecure: $insecure
        }
      }],
      dns: {
        servers: [{
          type: "https",
          tag: "remote-dns",
          server: "1.1.1.1",
          server_port: 443,
          path: "/dns-query",
          tls: { enabled: true, server_name: "cloudflare-dns.com" },
          detour: $tag
        }],
        final: "remote-dns"
      },
      route: {
        default_domain_resolver: "remote-dns",
        final: $tag
      }
    }')

  # Write to VM
  echo "$sing_box_json" | _vm sudo tee "$SING_BOX_CONF" > /dev/null
  _vm sudo chown root:mwproxy "$SING_BOX_CONF"
  _vm sudo chmod 640 "$SING_BOX_CONF"
  echo "  ✅ sing-box.json 已更新"

  # Step 2: Update nftables — regenerate the proxy_out rule (not sed)
  echo "  [2/4] 更新防火墙规则..."
  _generate_and_apply_nftables "$n_ip" "$n_port" "$transport"
  echo "  ✅ root.nft 已更新 (IP=$n_ip, port=$n_port, proto=$transport)"

  # Step 3: Validate + reload
  echo "  [3/4] 校验并重载..."
  if ! _vm sudo /usr/local/bin/sing-box check -c "$SING_BOX_CONF" 2>&1; then
    echo "  ❌ sing-box 配置校验失败!"
    exit 1
  fi
  _vm sudo systemctl reload mw-guard.service
  echo "  ✅ 防火墙已重载"
  _vm sudo systemctl restart mw-proxy.service
  echo "  ✅ sing-box 已重启"

  # Step 4: Update config.json active node
  echo "  [4/4] 更新本地配置..."
  _write_config ".active_node = \"$node_id\""
  echo "  ✅ 活跃节点已设为: $node_id"

  # Test connectivity
  echo ""
  echo "🔗 等待 3 秒后测试连通性..."
  sleep 3
  cmd_test_quiet
}

# Generate nftables config with correct protocol (tcp/udp)
_generate_and_apply_nftables() {
  local ip="$1"
  local port="$2"
  local proto="${3:-tcp}"  # tcp or udp

  # Read the current nftables config and replace the proxy_out rules
  local nft_content
  nft_content=$(_vm sudo cat "$NFT_CONF" 2>/dev/null)

  # Build new proxy_out chain content
  # We need to replace: elements = { ... } and the protocol/port rule
  local new_nft
  new_nft=$(echo "$nft_content" | sed "s/elements = { [0-9a-f.:, ]* }/elements = { $ip }/")

  # Replace the outbound rule line (tcp or udp, any port) in proxy_out
  # Match: ip daddr @upstream4 {tcp|udp} dport {port} ct state ...
  new_nft=$(echo "$new_nft" | sed -E "s/(ip daddr @upstream4 )(tcp|udp)( dport )[0-9]+( ct state)/\1${proto}\3${port}\4/")

  echo "$new_nft" | _vm sudo tee "$NFT_CONF" > /dev/null
}

cmd_test() {
  _ensure_vm_running
  echo "🔗 连通性测试"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local targets=("https://www.google.com" "https://api.github.com" "https://cloudflare.com")
  for target in "${targets[@]}"; do
    local raw_code
    raw_code=$(_vm bash -c "curl -x http://10.203.0.1:17890 -s -o /dev/null -w '%{http_code}' --connect-timeout 8 '$target' 2>/dev/null" 2>/dev/null || true)
    local code
    code=$(echo "$raw_code" | grep -oE '[0-9]{3}' | tail -1 || echo "000")
    if [[ "$code" =~ ^[23] ]]; then
      echo "  ✅ $target → HTTP $code"
    elif [[ -n "$code" && "$code" != "000" ]]; then
      echo "  ⚠️  $target → HTTP $code"
    else
      echo "  ❌ $target → 连接超时或失败"
    fi
  done
}

cmd_test_quiet() {
  local raw_code
  raw_code=$(_vm bash -c "curl -x http://10.203.0.1:17890 -s -o /dev/null -w '%{http_code}' --connect-timeout 8 'https://www.google.com' 2>/dev/null" 2>/dev/null || true)
  local code
  code=$(echo "$raw_code" | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  if [[ "$code" =~ ^[23] ]]; then
    echo "  ✅ 代理正常 (HTTP $code)"
  else
    echo "  ❌ 代理不通 (HTTP ${code} — 上游节点可能需要更长时间或不可用)"
  fi
}

cmd_add() {
  local node_json="$1"
  # Validate JSON
  if ! echo "$node_json" | jq -e '.id and .type and .server and .server_port and .password' > /dev/null 2>&1; then
    echo "❌ 无效节点 JSON，必须包含: id, type, server, server_port, password"
    echo '示例: {"id":"my-node","name":"我的节点","type":"trojan","server":"1.2.3.4","server_port":443,"password":"xxx","tls_sni":"example.com","flag":"🇯🇵"}'
    exit 1
  fi

  local node_id
  node_id=$(echo "$node_json" | jq -r '.id')

  # Check for duplicate ID
  local existing
  existing=$(jq -r ".nodes[] | select(.id==\"$node_id\") | .id" "$CONFIG" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    echo "⚠️  节点 $node_id 已存在，将更新"
    _write_config "del(.nodes[] | select(.id==\"$node_id\"))"
  fi

  # Set defaults via jq (safe)
  local enriched
  enriched=$(echo "$node_json" | jq '{
    id, name: (.name // .id), type, server, server_port, password,
    tls_sni: (.tls_sni // .server),
    tls_insecure: (.tls_insecure // false),
    flag: (.flag // "🌐"),
    source: (.source // "manual"),
    added_at: (now | strftime("%Y-%m-%dT%H:%M:%S+09:00"))
  }')

  _write_config ".nodes += [$enriched]"

  local name
  name=$(echo "$enriched" | jq -r '.name')
  echo "✅ 已添加节点: $name"
}

cmd_delete() {
  local node_id="$1"

  # Check if exists
  local exists
  exists=$(jq -r ".nodes[] | select(.id==\"$node_id\") | .id" "$CONFIG" 2>/dev/null || true)
  if [[ -z "$exists" ]]; then
    echo "❌ 未找到节点: $node_id"
    exit 1
  fi

  local active
  active=$(jq -r '.active_node // ""' "$CONFIG" 2>/dev/null || echo "")
  if [[ "$active" == "$node_id" ]]; then
    echo "⚠️  正在删除当前活跃节点，active_node 将被清空"
  fi

  _write_config "del(.nodes[] | select(.id==\"$node_id\")) | if .active_node == \"$node_id\" then .active_node = null else . end"
  echo "✅ 已删除节点: $node_id"
}

cmd_import_trojan_url() {
  local url="$1"

  # Determine protocol
  local proto=""
  if [[ "$url" =~ ^trojan:// ]]; then
    proto="trojan"
  elif [[ "$url" =~ ^hysteria2:// ]]; then
    proto="hysteria2"
  else
    echo "❌ 不支持的协议 (支持: trojan://, hysteria2://)"
    exit 1
  fi

  local body="${url#*://}"

  # Extract fragment (node name) — must be before stripping
  local name=""
  if [[ "$body" == *"#"* ]]; then
    local fragment="${body##*#}"
    name=$(_urldecode "$fragment")
    body="${body%%#*}"
  fi

  # Extract password and host part
  local password=""
  local host_part=""
  if [[ "$body" == *"@"* ]]; then
    password="${body%%@*}"
    host_part="${body#*@}"
  else
    echo "❌ URL 格式错误: 缺少 @ 分隔符"
    exit 1
  fi

  # URL-decode password (may contain special chars)
  password=$(_urldecode "$password")

  # Separate host:port from query string
  local host_port_part="${host_part%%\?*}"
  local query_part=""
  if [[ "$host_part" == *"?"* ]]; then
    query_part="${host_part#*\?}"
  fi

  # Parse host and port
  local host port
  if [[ "$host_port_part" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
    # IPv6: [::1]:443
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$host_port_part" =~ ^(.+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  else
    echo "❌ 无法解析 host:port: $host_port_part"
    exit 1
  fi

  # Extract SNI from query params
  local sni="$host"
  if [[ -n "$query_part" ]]; then
    local sni_match
    sni_match=$(echo "$query_part" | grep -oE 'sni=[^&]+' | head -1 | cut -d= -f2 || true)
    if [[ -n "$sni_match" ]]; then
      sni=$(_urldecode "$sni_match")
    fi
    # Also check peer= for hysteria2
    local peer_match
    peer_match=$(echo "$query_part" | grep -oE 'peer=[^&]+' | head -1 | cut -d= -f2 || true)
    if [[ -n "$peer_match" ]]; then
      sni=$(_urldecode "$peer_match")
    fi
  fi

  # Generate stable ID
  local node_id
  node_id="${proto}-$(echo "$host" | tr '.' '-')-${port}"

  [[ -z "$name" ]] && name="$host:$port"

  # Detect flag from name
  local flag="🌐"
  if [[ "$name" == *"日本"* || "$name" == *"JP"* || "$name" == *"Japan"* ]]; then
    flag="🇯🇵"
  elif [[ "$name" == *"美国"* || "$name" == *"US"* ]]; then
    flag="🇺🇸"
  elif [[ "$name" == *"香港"* || "$name" == *"HK"* ]]; then
    flag="🇭🇰"
  elif [[ "$name" == *"新加坡"* || "$name" == *"SG"* ]]; then
    flag="🇸🇬"
  elif [[ "$name" == *"台湾"* || "$name" == *"TW"* ]]; then
    flag="🇹🇼"
  elif [[ "$name" == *"荷兰"* || "$name" == *"NL"* ]]; then
    flag="🇳🇱"
  elif [[ "$name" == *"德国"* || "$name" == *"DE"* ]]; then
    flag="🇩🇪"
  elif [[ "$name" == *"英国"* || "$name" == *"UK"* ]]; then
    flag="🇬🇧"
  elif [[ "$name" == *"澳大利亚"* || "$name" == *"AU"* ]]; then
    flag="🇦🇺"
  elif [[ "$name" == *"爱沙尼亚"* || "$name" == *"EE"* ]]; then
    flag="🇪🇪"
  fi

  local json
  json=$(jq -n \
    --arg id "$node_id" \
    --arg name "$name" \
    --arg type "$proto" \
    --arg server "$host" \
    --argjson port "$port" \
    --arg pw "$password" \
    --arg sni "$sni" \
    --arg flag "$flag" \
    --arg source "${2:-manual}" \
    '{id:$id, name:$name, type:$type, server:$server, server_port:$port, password:$pw, tls_sni:$sni, flag:$flag, source:$source}')

  cmd_add "$json"
}

# ─── Subscription Commands ───

cmd_set_subscription() {
  local url="$1"
  _write_config ". + {subscription_url: \"$url\"}"
  echo "✅ 订阅地址已保存"
}

cmd_subscription_info() {
  local url
  url=$(jq -r '.subscription_url // empty' "$CONFIG" 2>/dev/null || true)
  if [[ -z "$url" ]]; then
    echo "❌ 未配置订阅地址"
    echo "   使用: $(basename "$0") set-subscription <url>"
    return 1
  fi
  local updated
  updated=$(jq -r '.subscription_updated // "从未"' "$CONFIG" 2>/dev/null || echo "从未")
  local sub_count
  sub_count=$(jq '[.nodes[] | select(.source=="subscription")] | length' "$CONFIG" 2>/dev/null || echo "0")

  echo "📡 订阅信息"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  地址:     ${url:0:50}..."
  echo "  上次更新: $updated"
  echo "  订阅节点: ${sub_count} 个"
}

cmd_import_subscription() {
  local url=""
  local filter_country="日本"

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url=*) url="${1#--url=}" ;;
      --filter=*) filter_country="${1#--filter=}" ;;
      --all) filter_country="" ;;
      *) url="$1" ;;
    esac
    shift
  done

  # Use saved URL if none provided
  if [[ -z "$url" ]]; then
    url=$(jq -r '.subscription_url // empty' "$CONFIG" 2>/dev/null || true)
    if [[ -z "$url" ]]; then
      echo "❌ 未提供订阅地址，也未保存过订阅地址"
      echo "   使用: $(basename "$0") set-subscription <url>"
      echo "   或:   $(basename "$0") import-subscription <url>"
      exit 1
    fi
  fi

  echo "📡 更新订阅..."
  echo "  地址: ${url:0:60}..."

  # Fetch subscription (needs Shadowrocket UA)
  local raw_content
  raw_content=$(curl -sL \
    -A "Shadowrocket/2050 CFNetwork/1568.100.1 Darwin/24.0.0" \
    --connect-timeout 15 \
    --max-time 30 \
    "$url" 2>/dev/null)

  if [[ -z "$raw_content" ]]; then
    echo "❌ 获取订阅失败: 返回为空"
    exit 1
  fi

  # Decode base64
  local decoded
  decoded=$(echo "$raw_content" | base64 -D 2>/dev/null || echo "$raw_content" | base64 -d 2>/dev/null || true)

  if [[ -z "$decoded" ]]; then
    echo "❌ base64 解码失败"
    exit 1
  fi

  # Check for access denied
  if echo "$decoded" | head -1 | grep -q "blocked@127.0.0.1"; then
    echo "❌ 订阅访问受限 (可能需要更新订阅地址)"
    echo "  响应: $(echo "$decoded" | head -1 | sed 's/.*#//' | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || echo "$decoded")"
    exit 1
  fi

  # Parse lines
  local total_lines=0
  local filtered_count=0
  local imported_count=0
  local skipped_count=0

  # Save subscription URL
  _write_config ". + {subscription_url: \"$url\"}"

  # Remove old subscription nodes (but preserve manually added ones + active node)
  local active_id
  active_id=$(jq -r '.active_node // ""' "$CONFIG" 2>/dev/null || echo "")
  _write_config 'del(.nodes[] | select(.source=="subscription"))'

  # Re-add active node if it was a subscription node (preserve current connection)
  # (it was already deleted above, but we'll re-import it if it matches)

  echo "  解析节点..."

  while IFS= read -r line; do
    line=$(echo "$line" | tr -d '\r')
    [[ -z "$line" ]] && continue

    total_lines=$((total_lines + 1))

    # Extract name from fragment for filtering
    local node_name=""
    if [[ "$line" == *"#"* ]]; then
      local frag="${line##*#}"
      node_name=$(_urldecode "$frag")
    fi

    # Apply country filter
    if [[ -n "$filter_country" ]]; then
      if [[ "$node_name" != *"$filter_country"* ]]; then
        skipped_count=$((skipped_count + 1))
        continue
      fi
      filtered_count=$((filtered_count + 1))
    fi

    # Import based on protocol
    if [[ "$line" =~ ^trojan:// ]] || [[ "$line" =~ ^hysteria2:// ]]; then
      cmd_import_trojan_url "$line" "subscription" 2>/dev/null && imported_count=$((imported_count + 1)) || true
    else
      local proto="${line%%://*}"
      echo "  ⚠️  跳过不支持的协议: $proto (${node_name:-unnamed})"
    fi
  done <<< "$decoded"

  # Update timestamp
  local now
  now=$(date +"%Y-%m-%d %H:%M:%S")
  _write_config ". + {subscription_updated: \"$now\"}"

  echo ""
  echo "✅ 订阅更新完成"
  echo "  总节点: $total_lines"
  if [[ -n "$filter_country" ]]; then
    echo "  ${filter_country}节点: $filtered_count"
  fi
  echo "  已导入: $imported_count"
  echo "  已跳过: $skipped_count (非${filter_country:-目标})"

  # If active node was removed, warn
  if [[ -n "$active_id" ]]; then
    local still_exists
    still_exists=$(jq -r ".nodes[] | select(.id==\"$active_id\") | .id" "$CONFIG" 2>/dev/null || true)
    if [[ -z "$still_exists" ]]; then
      echo ""
      echo "⚠️  注意: 之前的活跃节点 ($active_id) 不在新订阅中"
      echo "   请切换到新的节点"
    fi
  fi
}

# ─── Main dispatch ───

case "${1:-help}" in
  status)  cmd_status ;;
  list|ls) cmd_list ;;
  switch)  cmd_switch "${2:?需要节点 ID，使用 list 查看}" ;;
  test)    cmd_test ;;
  add)     cmd_add "${2:?需要节点 JSON}" ;;
  delete)  cmd_delete "${2:?需要节点 ID}" ;;
  import-trojan-url) cmd_import_trojan_url "${2:?需要 trojan:// 或 hysteria2:// URL}" ;;
  set-subscription)  cmd_set_subscription "${2:?需要订阅 URL}" ;;
  subscription-info) cmd_subscription_info ;;
  import-subscription) shift; cmd_import_subscription "$@" ;;
  help|*)
    echo "Lima Proxy Switch v2.0 — 管理 Lima mini-work VM 代理"
    echo ""
    echo "用法: $(basename "$0") <command> [args]"
    echo ""
    echo "命令:"
    echo "  status                        查看当前代理状态和连通性"
    echo "  list                          列出所有已保存节点"
    echo "  switch <id>                   切换到指定节点"
    echo "  test                          测试代理连通性"
    echo "  add '<json>'                  添加节点 (JSON)"
    echo "  delete <id>                   删除节点"
    echo "  import-trojan-url <url>       导入 trojan:// 或 hysteria2:// 链接"
    echo ""
    echo "订阅管理:"
    echo "  set-subscription <url>        保存订阅地址"
    echo "  import-subscription [url]     更新订阅 (只导入日本节点)"
    echo "  import-subscription --all     更新订阅 (导入全部节点)"
    echo "  subscription-info             查看订阅信息"
    echo ""
    echo "配置文件: $CONFIG"
    ;;
esac
