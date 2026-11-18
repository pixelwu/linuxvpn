#!/usr/bin/env bash
# lima-proxy-switch.sh — CLI tool to manage Lima mini-work sing-box proxy
# v3.0 — Multi-subscription grouping & Latency testing

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Usage:
#   lima-proxy-switch.sh status                              — show current proxy status
#   lima-proxy-switch.sh list                                — list nodes grouped by subscription
#   lima-proxy-switch.sh switch <id>                         — switch to node by id
#   lima-proxy-switch.sh test                                — test current proxy connectivity
#   lima-proxy-switch.sh add <json>                          — add a node (JSON string)
#   lima-proxy-switch.sh delete <id>                         — delete a node by id
#   lima-proxy-switch.sh ping <id>                           — test latency of a node (ms)
#   lima-proxy-switch.sh ping-all                            — test latency of all nodes (parallel)
#
# Subscription commands:
#   lima-proxy-switch.sh add-subscription <name> <url> [filter] — add a subscription
#   lima-proxy-switch.sh remove-subscription <sub-id>           — remove subscription & its nodes
#   lima-proxy-switch.sh list-subscriptions                     — list all subscriptions
#   lima-proxy-switch.sh import-subscription [sub-id]           — refresh one or all subscriptions

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

_ensure_vm_running() {
  local st
  st=$(limactl list --json | jq -r 'select(.name=="'"$VM_NAME"'") | .status' 2>/dev/null | head -1)
  if [[ -z "$st" || "$st" != "Running" ]]; then
    echo "❌ VM $VM_NAME 未运行 (status=${st:-not found})"
    echo "   请先运行: limactl start $VM_NAME"
    exit 1
  fi
}

# Atomic config write (macOS compatible)
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

# Auto-migrate v1 config to v2 multi-subscription schema
_migrate_config() {
  [[ ! -f "$CONFIG" ]] && return 0
  if jq -e '.subscription_url' "$CONFIG" >/dev/null 2>&1 || jq -e '.subscriptions == null' "$CONFIG" >/dev/null 2>&1; then
    local old_url old_updated
    old_url=$(jq -r '.subscription_url // ""' "$CONFIG" 2>/dev/null || true)
    old_updated=$(jq -r '.subscription_updated // ""' "$CONFIG" 2>/dev/null || true)
    
    local tmp
    tmp=$(mktemp "$HOME/.lima-proxy/.config.tmp.XXXXXX")
    jq --arg url "$old_url" --arg updated "$old_updated" '
      .version = 2 |
      .subscriptions = (
        if (.subscriptions | type == "array") then
          .subscriptions
        elif ($url != "") then
          [{id: "sub-1", name: "默认订阅", url: $url, filter: "日本", updated_at: $updated}]
        else
          []
        end
      ) |
      .nodes = [
        .nodes[]? |
        if .source == "subscription" then
          .source = "sub-1"
        elif (.source == null or .source == "") then
          .source = "manual"
        else
          .
        end
      ] |
      del(.subscription_url) | del(.subscription_updated)
    ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi
}

# ─── Status & List ───

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

  # Current config
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
  local raw_code code
  raw_code=$(_vm bash -c 'curl -x http://10.203.0.1:17890 -s -o /dev/null -w "%{http_code}" --connect-timeout 8 https://www.google.com 2>/dev/null' 2>/dev/null || true)
  code=$(echo "$raw_code" | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  if [[ "$code" =~ ^[23] ]]; then
    echo "  结果:   ✅ HTTP $code"
  else
    echo "  结果:   ❌ 连接失败 (HTTP ${code})"
  fi

  # Active node from config
  local active_id
  active_id=$(jq -r '.active_node // "none"' "$CONFIG" 2>/dev/null || echo "none")
  echo ""
  echo "  配置活跃节点: $active_id"

  # Subscription summary
  local sub_count
  sub_count=$(jq '.subscriptions | length' "$CONFIG" 2>/dev/null || echo "0")
  echo "  订阅数量: $sub_count 组"
}

cmd_list() {
  echo "📋 节点列表 (按订阅分组)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local active_id
  active_id=$(jq -r '.active_node // ""' "$CONFIG" 2>/dev/null || echo "")

  python3 -c '
import json, sys

with open("'"$CONFIG"'") as f:
    cfg = json.load(f)

active = "'"$active_id"'"
subs = {s["id"]: s["name"] for s in cfg.get("subscriptions", [])}
nodes = cfg.get("nodes", [])

# Group nodes
groups = {}
for n in nodes:
    src = n.get("source", "manual")
    if src not in groups:
        groups[src] = []
    groups[src].append(n)

# Print subscriptions first
for sub_id, sub_name in subs.items():
    sub_nodes = groups.get(sub_id, [])
    print(f"📁 订阅: {sub_name} ({len(sub_nodes)} 节点)")
    if not sub_nodes:
        print("    (无节点)")
    for n in sub_nodes:
        m = "▶ " if n["id"] == active else "  "
        flag = n.get("flag", "🌐")
        name = n.get("name", "")
        ntype = n.get("type", "")
        server = n.get("server", "")
        port = n.get("server_port", "")
        print(f"  {m}{flag} {name}  [{ntype}]  {server}:{port}")
    print()

# Print manual nodes
manual_nodes = groups.get("manual", [])
if manual_nodes or not subs:
    print(f"📌 手动添加 ({len(manual_nodes)} 节点)")
    for n in manual_nodes:
        m = "▶ " if n["id"] == active else "  "
        flag = n.get("flag", "🌐")
        name = n.get("name", "")
        ntype = n.get("type", "")
        server = n.get("server", "")
        port = n.get("server_port", "")
        print(f"  {m}{flag} {name}  [{ntype}]  {server}:{port}")
'
}

# ─── Switch & Reload ───

cmd_switch() {
  local node_id="$1"
  _ensure_vm_running

  local node
  node=$(jq -e ".nodes[] | select(.id==\"$node_id\")" "$CONFIG" 2>/dev/null || true)
  if [[ -z "$node" ]]; then
    echo "❌ 未找到节点: $node_id"
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

  local transport="tcp"
  if [[ "$n_type" == "hysteria2" || "$n_type" == "hysteria" || "$n_type" == "tuic" ]]; then
    transport="udp"
  fi

  # Resolve server hostname to IP for nftables
  local n_ip="$n_server"
  if ! echo "$n_server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "  ℹ️  解析域名 $n_server ..."
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

  # Step 1: Generate sing-box.json
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

  echo "$sing_box_json" | _vm sudo tee "$SING_BOX_CONF" > /dev/null
  _vm sudo chown root:mwproxy "$SING_BOX_CONF"
  _vm sudo chmod 640 "$SING_BOX_CONF"
  echo "  ✅ sing-box.json 已更新"

  # Step 2: Update nftables
  echo "  [2/4] 更新防火墙规则..."
  _generate_and_apply_nftables "$n_ip" "$n_port" "$transport"
  echo "  ✅ root.nft 已更新 (IP=$n_ip, port=$n_port, proto=$transport)"

  # Step 3: Reload
  echo "  [3/4] 校验并重载..."
  if ! _vm sudo /usr/local/bin/sing-box check -c "$SING_BOX_CONF" 2>&1; then
    echo "  ❌ sing-box 配置校验失败!"
    exit 1
  fi
  _vm sudo systemctl reload mw-guard.service
  echo "  ✅ 防火墙已重载"
  _vm sudo systemctl restart mw-proxy.service
  echo "  ✅ sing-box 已重启"

  # Step 4: Update active node
  echo "  [4/4] 更新本地配置..."
  _write_config ".active_node = \"$node_id\""
  echo "  ✅ 活跃节点已设为: $node_id"

  echo ""
  echo "🔗 等待 3 秒后测试连通性..."
  sleep 3
  cmd_test_quiet
}

_generate_and_apply_nftables() {
  local ip="$1"
  local port="$2"
  local proto="${3:-tcp}"

  local nft_content
  nft_content=$(_vm sudo cat "$NFT_CONF" 2>/dev/null)

  local new_nft
  new_nft=$(echo "$nft_content" | sed "s/elements = { [0-9a-f.:, ]* }/elements = { $ip }/")
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

# ─── Node CRUD ───

cmd_add() {
  local node_json="$1"
  if ! echo "$node_json" | jq -e '.id and .type and .server and .server_port and .password' > /dev/null 2>&1; then
    echo "❌ 无效节点 JSON，必须包含: id, type, server, server_port, password"
    exit 1
  fi

  local node_id
  node_id=$(echo "$node_json" | jq -r '.id')

  local existing
  existing=$(jq -r ".nodes[] | select(.id==\"$node_id\") | .id" "$CONFIG" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    _write_config "del(.nodes[] | select(.id==\"$node_id\"))"
  fi

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
  local source="${2:-manual}"

  local proto=""
  if [[ "$url" =~ ^trojan:// ]]; then
    proto="trojan"
  elif [[ "$url" =~ ^hysteria2:// ]]; then
    proto="hysteria2"
  else
    echo "❌ 不支持的协议"
    exit 1
  fi

  local body="${url#*://}"
  local name=""
  if [[ "$body" == *"#"* ]]; then
    local fragment="${body##*#}"
    name=$(_urldecode "$fragment")
    body="${body%%#*}"
  fi

  local password="" host_part=""
  if [[ "$body" == *"@"* ]]; then
    password="${body%%@*}"
    host_part="${body#*@}"
  else
    echo "❌ URL 缺少 @"
    exit 1
  fi
  password=$(_urldecode "$password")

  local host_port_part="${host_part%%\?*}"
  local query_part=""
  if [[ "$host_part" == *"?"* ]]; then
    query_part="${host_part#*\?}"
  fi

  local host port
  if [[ "$host_port_part" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$host_port_part" =~ ^(.+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  else
    echo "❌ 无法解析 host:port: $host_port_part"
    exit 1
  fi

  local sni="$host"
  if [[ -n "$query_part" ]]; then
    local sni_match
    sni_match=$(echo "$query_part" | grep -oE 'sni=[^&]+' | head -1 | cut -d= -f2 || true)
    [[ -n "$sni_match" ]] && sni=$(_urldecode "$sni_match")
    local peer_match
    peer_match=$(echo "$query_part" | grep -oE 'peer=[^&]+' | head -1 | cut -d= -f2 || true)
    [[ -n "$peer_match" ]] && sni=$(_urldecode "$peer_match")
  fi

  local node_id
  node_id="${proto}-$(echo "$host" | tr '.' '-')-${port}"
  [[ -z "$name" ]] && name="$host:$port"

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
    --arg source "$source" \
    '{id:$id, name:$name, type:$type, server:$server, server_port:$port, password:$pw, tls_sni:$sni, flag:$flag, source:$source}')

  cmd_add "$json"
}

# ─── Multi-Subscription Commands ───

cmd_add_subscription() {
  local name="$1"
  local url="$2"
  local filter="${3:-日本}"
  filter="${filter#--filter=}"

  # Generate next ID: sub-1, sub-2, ...
  local next_id
  next_id=$(python3 -c '
import json
with open("'"$CONFIG"'") as f:
    cfg = json.load(f)
existing = [s.get("id","") for s in cfg.get("subscriptions",[])]
i = 1
while f"sub-{i}" in existing:
    i += 1
print(f"sub-{i}")
')

  local new_sub
  new_sub=$(jq -n \
    --arg id "$next_id" \
    --arg name "$name" \
    --arg url "$url" \
    --arg filter "$filter" \
    '{id:$id, name:$name, url:$url, filter:$filter, updated_at:""}')

  _write_config ".subscriptions += [$new_sub]"
  echo "✅ 已添加订阅: $name (ID: $next_id)"
}

cmd_remove_subscription() {
  local sub_id="$1"
  local exists
  exists=$(jq -r ".subscriptions[] | select(.id==\"$sub_id\") | .id" "$CONFIG" 2>/dev/null || true)
  if [[ -z "$exists" ]]; then
    echo "❌ 未找到订阅: $sub_id"
    exit 1
  fi

  # Delete subscription & its nodes
  _write_config "
    del(.subscriptions[] | select(.id==\"$sub_id\")) |
    del(.nodes[] | select(.source==\"$sub_id\"))
  "
  echo "✅ 已删除订阅 $sub_id 及所属节点"
}

cmd_list_subscriptions() {
  echo "📡 已配置的订阅组"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  jq -r '.subscriptions[] | "\(.id)|\(.name)|\(.filter)|\(.updated_at // "从未")|\(.url)"' "$CONFIG" 2>/dev/null | while IFS='|' read -r id name filter updated url; do
    local count
    count=$(jq "[.nodes[] | select(.source==\"$id\")] | length" "$CONFIG" 2>/dev/null || echo "0")
    echo "  🏷️  [$id] $name"
    echo "      节点: ${count} 个 | 过滤: ${filter:-无} | 上次更新: ${updated:-从未}"
    echo "      地址: ${url:0:55}..."
    echo ""
  done
}

cmd_import_subscription() {
  local target_id="${1:-}"

  local subs
  if [[ -n "$target_id" && "$target_id" != "--all" ]]; then
    subs=$(jq -c ".subscriptions[] | select(.id==\"$target_id\")" "$CONFIG" 2>/dev/null || true)
    if [[ -z "$subs" ]]; then
      echo "❌ 未找到订阅: $target_id"
      exit 1
    fi
  else
    subs=$(jq -c '.subscriptions[]' "$CONFIG" 2>/dev/null || true)
    if [[ -z "$subs" ]]; then
      echo "❌ 尚未配置任何订阅，请使用 add-subscription 添加"
      exit 1
    fi
  fi

  local active_id
  active_id=$(jq -r '.active_node // ""' "$CONFIG" 2>/dev/null || echo "")

  while IFS= read -r sub_json; do
    [[ -z "$sub_json" ]] && continue
    local s_id s_name s_url s_filter
    s_id=$(echo "$sub_json" | jq -r '.id')
    s_name=$(echo "$sub_json" | jq -r '.name')
    s_url=$(echo "$sub_json" | jq -r '.url')
    s_filter=$(echo "$sub_json" | jq -r '.filter // ""')

    echo "📡 正在拉取订阅: $s_name ($s_id)..."
    echo "   URL: ${s_url:0:60}..."

    local raw_content
    raw_content=$(curl -sL \
      -A "Shadowrocket/2050 CFNetwork/1568.100.1 Darwin/24.0.0" \
      --connect-timeout 15 \
      --max-time 30 \
      "$s_url" 2>/dev/null || true)

    if [[ -z "$raw_content" ]]; then
      echo "   ❌ 拉取失败: 返回内容为空"
      continue
    fi

    local decoded
    decoded=$(echo "$raw_content" | base64 -D 2>/dev/null || echo "$raw_content" | base64 -d 2>/dev/null || true)
    if [[ -z "$decoded" ]]; then
      echo "   ❌ base64 解码失败"
      continue
    fi

    if echo "$decoded" | head -1 | grep -q "blocked@127.0.0.1"; then
      echo "   ❌ 订阅访问受限 (可能需要更新 Token/URL)"
      continue
    fi

    # Remove existing nodes of THIS subscription only
    _write_config "del(.nodes[] | select(.source==\"$s_id\"))"

    local total=0 imported=0 skipped=0
    while IFS= read -r line; do
      line=$(echo "$line" | tr -d '\r')
      [[ -z "$line" ]] && continue
      total=$((total + 1))

      local node_name=""
      if [[ "$line" == *"#"* ]]; then
        node_name=$(_urldecode "${line##*#}")
      fi

      if [[ -n "$s_filter" && "$node_name" != *"$s_filter"* ]]; then
        skipped=$((skipped + 1))
        continue
      fi

      if [[ "$line" =~ ^trojan:// ]] || [[ "$line" =~ ^hysteria2:// ]]; then
        cmd_import_trojan_url "$line" "$s_id" >/dev/null 2>&1 && imported=$((imported + 1)) || true
      fi
    done <<< "$decoded"

    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    _write_config "
      (.subscriptions[] | select(.id==\"$s_id\")).updated_at = \"$now\"
    "

    echo "   ✅ $s_name 更新完成: 共 $total 节点，导入 $imported 个，跳过 $skipped 个"
    echo ""
  done <<< "$subs"
}

# ─── Latency Testing (Ping) ───

cmd_ping() {
  local node_id="$1"
  local node
  node=$(jq -e ".nodes[] | select(.id==\"$node_id\")" "$CONFIG" 2>/dev/null || true)
  if [[ -z "$node" ]]; then
    echo "{\"id\":\"$node_id\",\"latency_ms\":-1,\"error\":\"not found\"}"
    exit 1
  fi

  python3 -c '
import json, socket, time, sys

node = json.loads("""'"$node"'""")
host = node.get("server")
port = int(node.get("server_port", 443))

t0 = time.monotonic()
try:
    s = socket.create_connection((host, port), timeout=4)
    ms = round((time.monotonic() - t0) * 1000)
    s.close()
except Exception:
    ms = -1

res = {"id": node["id"], "name": node.get("name",""), "latency_ms": ms}
print(json.dumps(res, ensure_ascii=False))
'
}

cmd_ping_all() {
  python3 -c '
import json, socket, time
from concurrent.futures import ThreadPoolExecutor

with open("'"$CONFIG"'") as f:
    cfg = json.load(f)

nodes = cfg.get("nodes", [])

def test_node(node):
    host = node.get("server")
    port = int(node.get("server_port", 443))
    t0 = time.monotonic()
    try:
        s = socket.create_connection((host, port), timeout=3)
        ms = round((time.monotonic() - t0) * 1000)
        s.close()
    except Exception:
        ms = -1
    return {"id": node["id"], "latency_ms": ms}

with ThreadPoolExecutor(max_workers=10) as executor:
    results = list(executor.map(test_node, nodes))

print(json.dumps(results, ensure_ascii=False))
'
}

# ─── Main Dispatch ───

_migrate_config

case "${1:-help}" in
  status)  cmd_status ;;
  list|ls) cmd_list ;;
  switch)  cmd_switch "${2:?需要节点 ID，使用 list 查看}" ;;
  test)    cmd_test ;;
  add)     cmd_add "${2:?需要节点 JSON}" ;;
  delete)  cmd_delete "${2:?需要节点 ID}" ;;
  ping)    cmd_ping "${2:?需要节点 ID}" ;;
  ping-all) cmd_ping_all ;;
  import-trojan-url) cmd_import_trojan_url "${2:?需要 trojan:// 或 hysteria2:// URL}" "${3:-manual}" ;;
  add-subscription)    cmd_add_subscription "${2:?名称}" "${3:?URL}" "${4:-日本}" ;;
  remove-subscription) cmd_remove_subscription "${2:?需要订阅 ID}" ;;
  list-subscriptions)  cmd_list_subscriptions ;;
  import-subscription) shift; cmd_import_subscription "$@" ;;
  help|*)
    echo "Lima Proxy Switch v3.0 — 管理 Lima mini-work VM 代理"
    echo ""
    echo "用法: $(basename "$0") <command> [args]"
    echo ""
    echo "节点操作:"
    echo "  status                         查看当前代理状态和连通性"
    echo "  list                           列出所有已保存节点 (按订阅分组)"
    echo "  switch <id>                    切换到指定节点"
    echo "  ping <id>                      测试单节点延迟 (毫秒)"
    echo "  ping-all                       并行测试全部节点延迟"
    echo "  test                           测试当前代理外网连通性"
    echo "  add '<json>'                   手动添加节点 (JSON)"
    echo "  delete <id>                    删除节点"
    echo ""
    echo "订阅管理:"
    echo "  add-subscription <名称> <URL> [过滤关键词]   添加订阅"
    echo "  remove-subscription <sub-id>               删除订阅及对应节点"
    echo "  list-subscriptions                         列出所有订阅"
    echo "  import-subscription [sub-id]               更新指定订阅或所有订阅"
    echo ""
    echo "配置文件: $CONFIG"
    ;;
esac
