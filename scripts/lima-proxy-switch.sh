#!/usr/bin/env bash
# ==============================================================================
# lima-proxy-switch.sh (v5.0) — 管理 Lima mini-work 虚拟机内代理与订阅
# 加固改进：
# 1. 真正的原子目录锁，杜绝并发读写 config.json 损坏
# 2. 切换节点采用事务化备份+失败自动回滚，绝不把 VM 内配置/防火墙改坏
# 3. 域名解析优先本地/阿里 DNS 并严格限时，避免 8.8.8.8 卡死
# ==============================================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

set -euo pipefail

CONFIG="$HOME/.lima-proxy/config.json"
VM_NAME="mini-work"
SING_BOX_CONF="/etc/mini-work/sing-box.json"
NFT_CONF="/etc/mini-work/root.nft"
LOCK_DIR="$HOME/.lima-proxy/.config.lock.d"

# ─── Helpers ───

_vm() {
  limactl shell "$VM_NAME" -- "$@"
}

_acquire_config_lock() {
  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ -d "$LOCK_DIR" ]]; then
      local mtime now
      mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
      now=$(date +%s)
      if (( now - mtime > 60 )); then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        continue
      fi
    fi
    waited=$((waited + 1))
    if (( waited >= 30 )); then
      echo "❌ 配置文件正被其他操作占用，请稍后重试"
      exit 1
    fi
    sleep 0.3
  done
  trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

_ensure_vm_running() {
  local st
  st=$(limactl list --json 2>/dev/null | jq -r 'select(.name=="'"$VM_NAME"'") | .status' 2>/dev/null | head -1 || true)
  if [[ -z "$st" || "$st" != "Running" ]]; then
    echo "❌ VM $VM_NAME 未运行 (status=${st:-not found})"
    echo "   请先运行: limactl start $VM_NAME"
    exit 1
  fi
}

_write_config() {
  local jq_expr="$1"
  local tmp
  tmp=$(mktemp "$HOME/.lima-proxy/.config.tmp.XXXXXX")
  if jq "$jq_expr" "$CONFIG" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$CONFIG"
  else
    rm -f "$tmp"
    echo "❌ jq 表达式执行失败: $jq_expr"
    return 1
  fi
}

_urldecode() {
  python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" <<< "$1" 2>/dev/null || printf '%s' "$1"
}

_resolve_host_ipv4() {
  local host="$1"
  local ip=""
  # 1. 优先阿里公共 DNS (国内直连最快，限时 2 秒)
  ip=$(dig @223.5.5.5 +time=2 +tries=1 +short "$host" A 2>/dev/null | grep -vE '^198\.(18|19)\.' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  # 2. 回退系统默认 DNS
  if [[ -z "$ip" ]]; then
    ip=$(dig +time=2 +tries=1 +short "$host" A 2>/dev/null | grep -vE '^198\.(18|19)\.' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  fi
  # 3. 回退 8.8.8.8
  if [[ -z "$ip" ]]; then
    ip=$(dig @8.8.8.8 +time=2 +tries=1 +short "$host" A 2>/dev/null | grep -vE '^198\.(18|19)\.' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  fi
  # 4. 最后回退 Google DoH
  if [[ -z "$ip" ]]; then
    ip=$(curl -fsSL --connect-timeout 4 --max-time 6 "https://dns.google/resolve?name=${host}&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' 2>/dev/null | grep -vE '^198\.(18|19)\.' | head -1 || true)
  fi
  echo "$ip"
}

_migrate_config() {
  [[ ! -f "$CONFIG" ]] && return 0
  if jq -e '.subscription_url' "$CONFIG" >/dev/null 2>&1 || jq -e '.subscriptions == null' "$CONFIG" >/dev/null 2>&1; then
    _acquire_config_lock
    local old_url old_updated tmp
    old_url=$(jq -r '.subscription_url // ""' "$CONFIG" 2>/dev/null || true)
    old_updated=$(jq -r '.subscription_updated // ""' "$CONFIG" 2>/dev/null || true)
    tmp=$(mktemp "$HOME/.lima-proxy/.config.tmp.XXXXXX")
    jq --arg url "$old_url" --arg updated "$old_updated" '
      .version = 2 |
      .subscriptions = (
        if (.subscriptions | type == "array") then .subscriptions
        elif ($url != "") then [{id: "sub-1", name: "默认订阅", url: $url, filter: "日本", updated_at: $updated}]
        else [] end
      ) |
      .nodes = [
        .nodes[]? |
        if .source == "subscription" then .source = "sub-1"
        elif (.source == null or .source == "") then .source = "manual"
        else . end
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

  local svc_status
  svc_status=$(_vm sudo systemctl is-active mw-proxy.service 2>/dev/null || echo "unknown")
  if [[ "$svc_status" == "active" ]]; then
    echo "  服务:   ✅ active"
  else
    echo "  服务:   ❌ $svc_status"
  fi

  local current
  current=$(_vm sudo cat "$SING_BOX_CONF" 2>/dev/null | jq -r '.outbounds[0] | "\(.type)|\(.server)|\(.server_port)|\(.tls.server_name // "-")"' 2>/dev/null || echo "unknown|unknown|unknown|unknown")
  IFS='|' read -r c_type c_server c_port c_sni <<< "$current"
  echo "  协议:   ${c_type:-unknown}"
  echo "  服务器: ${c_server:-unknown}"
  echo "  端口:   ${c_port:-unknown}"
  echo "  SNI:    ${c_sni:-unknown}"

  local fw_ip
  fw_ip=$(_vm sudo nft list set inet mini_work_guard upstream4 2>/dev/null | grep -oE '([0-9]+\.){3}[0-9]+' | head -1 || echo "unknown")
  echo "  防火墙: ${fw_ip:-unknown}"

  echo ""
  echo "🔗 连通性测试..."
  local raw_code code
  raw_code=$(_vm bash -c 'curl -x http://10.203.0.1:17890 -s -o /dev/null -w "%{http_code}" --connect-timeout 6 --max-time 8 https://www.google.com 2>/dev/null' 2>/dev/null || true)
  code=$(echo "$raw_code" | grep -oE '[0-9]{3}' | tail -1 || echo "000")
  if [[ "$code" =~ ^[23] ]]; then
    echo "  结果:   ✅ HTTP $code"
  else
    echo "  结果:   ❌ 连接失败 (HTTP ${code})"
  fi

  local active_id sub_count
  active_id=$(jq -r '.active_node // "none"' "$CONFIG" 2>/dev/null || echo "none")
  sub_count=$(jq '.subscriptions | length' "$CONFIG" 2>/dev/null || echo "0")
  echo ""
  echo "  配置活跃节点: $active_id"
  echo "  订阅数量: $sub_count 组"
}

cmd_list() {
  echo "📋 节点列表 (按订阅分组)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local active_id
  active_id=$(jq -r '.active_node // ""' "$CONFIG" 2>/dev/null || echo "")

  python3 - "$CONFIG" "$active_id" <<'PYEOF'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    cfg = json.load(f)

active = sys.argv[2]
subs = {s["id"]: s["name"] for s in cfg.get("subscriptions", [])}
nodes = cfg.get("nodes", [])

groups = {}
for n in nodes:
    src = n.get("source", "manual")
    groups.setdefault(src, []).append(n)

for sub_id, sub_name in subs.items():
    sub_nodes = groups.get(sub_id, [])
    print(f"📁 订阅: {sub_name} ({len(sub_nodes)} 节点)")
    if not sub_nodes:
        print("    (无节点)")
    for n in sub_nodes:
        m = "▶ " if n["id"] == active else "  "
        print(f"  {m}{n.get('flag','🌐')} {n.get('name','')}  [{n.get('type','')}]  {n.get('server','')}:{n.get('server_port','')}")
    print()

manual_nodes = groups.get("manual", [])
if manual_nodes or not subs:
    print(f"📌 手动添加 ({len(manual_nodes)} 节点)")
    for n in manual_nodes:
        m = "▶ " if n["id"] == active else "  "
        print(f"  {m}{n.get('flag','🌐')} {n.get('name','')}  [{n.get('type','')}]  {n.get('server','')}:{n.get('server_port','')}")
PYEOF
}

# ─── Switch & Reload (事务化：失败自动回滚 VM 配置) ───

_rollback_vm_configs() {
  echo "  ↩️  正在自动回滚虚拟机内原 sing-box 与防火墙配置..."
  _vm sudo bash -c "
    [[ -f '${SING_BOX_CONF}.bak' ]] && cp '${SING_BOX_CONF}.bak' '${SING_BOX_CONF}'
    [[ -f '${NFT_CONF}.bak' ]] && cp '${NFT_CONF}.bak' '${NFT_CONF}'
    systemctl reload mw-guard.service 2>/dev/null || true
    systemctl restart mw-proxy.service 2>/dev/null || true
  " 2>/dev/null || true
}

cmd_switch() {
  local node_id="$1"
  _acquire_config_lock
  _ensure_vm_running

  local node
  node=$(jq -e --arg id "$node_id" '.nodes[] | select(.id==$id)' "$CONFIG" 2>/dev/null || true)
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

  local n_ip="$n_server"
  if ! echo "$n_server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "  ℹ️  解析域名 $n_server ..."
    n_ip=$(_resolve_host_ipv4 "$n_server")
    if [[ -z "$n_ip" ]]; then
      echo "❌ 无法解析域名: $n_server (原节点配置未改动)"
      exit 1
    fi
    echo "  ℹ️  解析结果: $n_ip"
  fi

  # 事务备份：保留 VM 内原文件，校验或重载失败立即自动回滚
  _vm sudo bash -c "
    cp '${SING_BOX_CONF}' '${SING_BOX_CONF}.bak' 2>/dev/null || true
    cp '${NFT_CONF}' '${NFT_CONF}.bak' 2>/dev/null || true
  "

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

  echo "  [2/4] 更新防火墙规则..."
  if ! _generate_and_apply_nftables "$n_ip" "$n_port" "$transport"; then
    echo "  ❌ 防火墙规则生成失败!"
    _rollback_vm_configs
    exit 1
  fi
  echo "  ✅ root.nft 已更新 (IP=$n_ip, port=$n_port, proto=$transport)"

  echo "  [3/4] 校验并重载..."
  if ! _vm sudo /usr/local/bin/sing-box check -c "$SING_BOX_CONF" 2>&1; then
    echo "  ❌ sing-box 配置校验失败!"
    _rollback_vm_configs
    exit 1
  fi
  if ! _vm sudo systemctl reload mw-guard.service; then
    echo "  ❌ 防火墙重载失败!"
    _rollback_vm_configs
    exit 1
  fi
  echo "  ✅ 防火墙已重载"
  if ! _vm sudo systemctl restart mw-proxy.service; then
    echo "  ❌ sing-box 重启失败!"
    _rollback_vm_configs
    exit 1
  fi
  echo "  ✅ sing-box 已重启"

  echo "  [4/4] 更新本地配置..."
  _write_config ".active_node = \"$node_id\""
  echo "  ✅ 活跃节点已设为: $node_id"

  echo ""
  echo "🔗 等待 2 秒后测试连通性..."
  sleep 2
  cmd_test_quiet
}

_generate_and_apply_nftables() {
  local ip="$1"
  local port="$2"
  local proto="${3:-tcp}"

  local nft_content
  nft_content=$(_vm sudo cat "$NFT_CONF" 2>/dev/null)
  [[ -z "$nft_content" ]] && return 1

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
    local raw_code code
    raw_code=$(_vm bash -c "curl -x http://10.203.0.1:17890 -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 8 '$target' 2>/dev/null" 2>/dev/null || true)
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
  local raw_code code
  raw_code=$(_vm bash -c "curl -x http://10.203.0.1:17890 -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 8 'https://www.google.com' 2>/dev/null" 2>/dev/null || true)
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
  _acquire_config_lock
  if ! echo "$node_json" | jq -e '.id and .type and .server and .server_port and .password' > /dev/null 2>&1; then
    echo "❌ 无效节点 JSON，必须包含: id, type, server, server_port, password"
    exit 1
  fi

  local node_id existing enriched name
  node_id=$(echo "$node_json" | jq -r '.id')
  existing=$(jq -r --arg id "$node_id" '.nodes[] | select(.id==$id) | .id' "$CONFIG" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    _write_config "del(.nodes[] | select(.id==\"$node_id\"))"
  fi

  enriched=$(echo "$node_json" | jq '{
    id, name: (.name // .id), type, server, server_port, password,
    tls_sni: (.tls_sni // .server),
    tls_insecure: (.tls_insecure // false),
    flag: (.flag // "🌐"),
    source: (.source // "manual"),
    added_at: (now | strftime("%Y-%m-%dT%H:%M:%S+09:00"))
  }')

  _write_config ".nodes += [$enriched]"
  name=$(echo "$enriched" | jq -r '.name')
  echo "✅ 已添加节点: $name"
}

cmd_delete() {
  local node_id="$1"
  _acquire_config_lock
  local exists active
  exists=$(jq -r --arg id "$node_id" '.nodes[] | select(.id==$id) | .id' "$CONFIG" 2>/dev/null || true)
  if [[ -z "$exists" ]]; then
    echo "❌ 未找到节点: $node_id"
    exit 1
  fi

  active=$(jq -r '.active_node // ""' "$CONFIG" 2>/dev/null || echo "")
  if [[ "$active" == "$node_id" ]]; then
    echo "⚠️  正在删除当前活跃节点，active_node 将被清空"
  fi

  _write_config "del(.nodes[] | select(.id==\"$node_id\")) | if .active_node == \"$node_id\" then .active_node = null else . end"
  echo "✅ 已删除节点: $node_id"
}

_import_node_url_unlocked() {
  local url="$1"
  local source="${2:-manual}"

  local proto=""
  if [[ "$url" =~ ^trojan:// ]]; then
    proto="trojan"
  elif [[ "$url" =~ ^hysteria2:// ]]; then
    proto="hysteria2"
  else
    return 1
  fi

  local body="${url#*://}"
  local name=""
  if [[ "$body" == *"#"* ]]; then
    name=$(_urldecode "${body##*#}")
    body="${body%%#*}"
  fi

  local password="" host_part=""
  if [[ "$body" == *"@"* ]]; then
    password=$(_urldecode "${body%%@*}")
    host_part="${body#*@}"
  else
    return 1
  fi

  local host_port_part="${host_part%%\?*}"
  local query_part=""
  [[ "$host_part" == *"?"* ]] && query_part="${host_part#*\?}"

  local host port
  if [[ "$host_port_part" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$host_port_part" =~ ^(.+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  local sni="$host"
  if [[ -n "$query_part" ]]; then
    local sni_match peer_match
    sni_match=$(echo "$query_part" | grep -oE 'sni=[^&]+' | head -1 | cut -d= -f2 || true)
    [[ -n "$sni_match" ]] && sni=$(_urldecode "$sni_match")
    peer_match=$(echo "$query_part" | grep -oE 'peer=[^&]+' | head -1 | cut -d= -f2 || true)
    [[ -n "$peer_match" ]] && sni=$(_urldecode "$peer_match")
  fi

  local node_id="${proto}-$(echo "$host" | tr '.' '-')-${port}"
  [[ -z "$name" ]] && name="$host:$port"

  local flag="🌐"
  case "$name" in
    *日本*|*JP*|*Japan*) flag="🇯🇵" ;;
    *美国*|*US*) flag="🇺🇸" ;;
    *香港*|*HK*) flag="🇭🇰" ;;
    *新加坡*|*SG*) flag="🇸🇬" ;;
    *台湾*|*TW*) flag="🇹🇼" ;;
    *荷兰*|*NL*) flag="🇳🇱" ;;
    *德国*|*DE*) flag="🇩🇪" ;;
    *英国*|*UK*) flag="🇬🇧" ;;
    *澳大利亚*|*AU*) flag="🇦🇺" ;;
  esac

  local enriched
  enriched=$(jq -n \
    --arg id "$node_id" --arg name "$name" --arg type "$proto" \
    --arg server "$host" --argjson port "$port" --arg pw "$password" \
    --arg sni "$sni" --arg flag "$flag" --arg source "$source" \
    '{
      id:$id, name:$name, type:$type, server:$server, server_port:$port,
      password:$pw, tls_sni:$sni, tls_insecure:false, flag:$flag, source:$source,
      added_at:(now | strftime("%Y-%m-%dT%H:%M:%S+09:00"))
    }')

  _write_config "del(.nodes[] | select(.id==\"$node_id\")) | .nodes += [$enriched]"
}

cmd_import_trojan_url() {
  _acquire_config_lock
  if _import_node_url_unlocked "$1" "${2:-manual}"; then
    echo "✅ 已导入节点"
  else
    echo "❌ 不支持或无效的节点 URL"
    exit 1
  fi
}

# ─── Multi-Subscription Commands ───

cmd_add_subscription() {
  local name="$1"
  local url="$2"
  local filter="${3:-日本}"
  filter="${filter#--filter=}"
  _acquire_config_lock

  local next_id new_sub
  next_id=$(python3 - "$CONFIG" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    cfg = json.load(f)
existing = {s.get("id", "") for s in cfg.get("subscriptions", [])}
i = 1
while f"sub-{i}" in existing:
    i += 1
print(f"sub-{i}")
PYEOF
)
  new_sub=$(jq -n --arg id "$next_id" --arg name "$name" --arg url "$url" --arg filter "$filter" \
    '{id:$id, name:$name, url:$url, filter:$filter, updated_at:""}')
  _write_config ".subscriptions += [$new_sub]"
  echo "✅ 已添加订阅: $name (ID: $next_id)"
}

cmd_remove_subscription() {
  local sub_id="$1"
  _acquire_config_lock
  local exists
  exists=$(jq -r --arg id "$sub_id" '.subscriptions[] | select(.id==$id) | .id' "$CONFIG" 2>/dev/null || true)
  if [[ -z "$exists" ]]; then
    echo "❌ 未找到订阅: $sub_id"
    exit 1
  fi
  _write_config "del(.subscriptions[] | select(.id==\"$sub_id\")) | del(.nodes[] | select(.source==\"$sub_id\"))"
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
  _acquire_config_lock

  local subs
  if [[ -n "$target_id" && "$target_id" != "--all" ]]; then
    subs=$(jq -c --arg id "$target_id" '.subscriptions[] | select(.id==$id)' "$CONFIG" 2>/dev/null || true)
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

  while IFS= read -r sub_json; do
    [[ -z "$sub_json" ]] && continue
    local s_id s_name s_url s_filter
    s_id=$(echo "$sub_json" | jq -r '.id')
    s_name=$(echo "$sub_json" | jq -r '.name')
    s_url=$(echo "$sub_json" | jq -r '.url')
    s_filter=$(echo "$sub_json" | jq -r '.filter // ""')

    echo "📡 正在拉取订阅: $s_name ($s_id)..."
    local raw_content decoded
    raw_content=$(curl -sL -A "Shadowrocket/2050 CFNetwork/1568.100.1 Darwin/24.0.0" \
      --connect-timeout 12 --max-time 25 "$s_url" 2>/dev/null || true)
    if [[ -z "$raw_content" ]]; then
      echo "   ❌ 拉取失败: 返回内容为空"
      continue
    fi

    decoded=$(echo "$raw_content" | base64 -D 2>/dev/null || echo "$raw_content" | base64 -d 2>/dev/null || true)
    if [[ -z "$decoded" ]]; then
      echo "   ❌ base64 解码失败"
      continue
    fi
    if echo "$decoded" | head -1 | grep -q "blocked@127.0.0.1"; then
      echo "   ❌ 订阅访问受限 (可能需要更新 Token/URL)"
      continue
    fi

    _write_config "del(.nodes[] | select(.source==\"$s_id\"))"

    local total=0 imported=0 skipped=0
    while IFS= read -r line; do
      line=$(echo "$line" | tr -d '\r')
      [[ -z "$line" ]] && continue
      total=$((total + 1))

      local node_name=""
      [[ "$line" == *"#"* ]] && node_name=$(_urldecode "${line##*#}")
      if [[ -n "$s_filter" && "$node_name" != *"$s_filter"* ]]; then
        skipped=$((skipped + 1))
        continue
      fi

      if [[ "$line" =~ ^trojan:// ]] || [[ "$line" =~ ^hysteria2:// ]]; then
        _import_node_url_unlocked "$line" "$s_id" >/dev/null 2>&1 && imported=$((imported + 1)) || true
      fi
    done <<< "$decoded"

    local now
    now=$(date +"%Y-%m-%d %H:%M:%S")
    _write_config "(.subscriptions[] | select(.id==\"$s_id\")).updated_at = \"$now\""
    echo "   ✅ $s_name 更新完成: 共 $total 节点，导入 $imported 个，跳过 $skipped 个"
    echo ""
  done <<< "$subs"
}

# ─── Latency Testing (Ping) ───

cmd_ping() {
  local node_id="$1"
  python3 - "$CONFIG" "$node_id" <<'PYEOF'
import json, socket, time, sys

with open(sys.argv[1], encoding="utf-8") as f:
    cfg = json.load(f)

target = next((n for n in cfg.get("nodes", []) if n.get("id") == sys.argv[2]), None)
if not target:
    print(json.dumps({"id": sys.argv[2], "latency_ms": -1, "error": "not found"}))
    sys.exit(1)

t0 = time.monotonic()
try:
    with socket.create_connection((target["server"], int(target.get("server_port", 443))), timeout=4):
        ms = round((time.monotonic() - t0) * 1000)
except Exception:
    ms = -1

print(json.dumps({"id": target["id"], "name": target.get("name", ""), "latency_ms": ms}, ensure_ascii=False))
PYEOF
}

cmd_ping_all() {
  python3 - "$CONFIG" <<'PYEOF'
import json, socket, time, sys
from concurrent.futures import ThreadPoolExecutor

with open(sys.argv[1], encoding="utf-8") as f:
    cfg = json.load(f)

def test_node(node):
    t0 = time.monotonic()
    try:
        with socket.create_connection((node["server"], int(node.get("server_port", 443))), timeout=3):
            ms = round((time.monotonic() - t0) * 1000)
    except Exception:
        ms = -1
    return {"id": node["id"], "latency_ms": ms}

with ThreadPoolExecutor(max_workers=10) as ex:
    results = list(ex.map(test_node, cfg.get("nodes", [])))

print(json.dumps(results, ensure_ascii=False))
PYEOF
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
    echo "Lima Proxy Switch v5.0 — 管理 Lima mini-work VM 代理"
    echo "用法: $(basename "$0") {status|list|switch <id>|ping <id>|ping-all|test|add <json>|delete <id>|add-subscription|remove-subscription|list-subscriptions|import-subscription}"
    ;;
esac
