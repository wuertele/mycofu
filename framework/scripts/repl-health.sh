#!/usr/bin/env bash
# repl-health.sh — Topology-aware replication network health check
#
# Outputs JSON describing replication network health. Designed to be called
# by repl-health-server.sh (HTTP wrapper) and scraped by Gatus.
#
# Deployed to /usr/local/bin/repl-health.sh by configure-node-network.sh.
# Configuration: /etc/repl-health.conf and /etc/repl-watchdog.conf

set -uo pipefail

CONF_FILE="/etc/repl-health.conf"
WATCHDOG_CONF="/etc/repl-watchdog.conf"
WATCHDOG_STATE="/run/repl-watchdog"

if [[ ! -f "$CONF_FILE" ]]; then
  echo '{"error": "no config file", "healthy": false}'
  exit 1
fi

# Read config
NODE_NAME=""
NODE_REPL_IP=""
HEALTH_PORT=""
TOPOLOGY=""

while IFS='=' read -r key val; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  case "$key" in
    NODE_NAME)    NODE_NAME="$val" ;;
    NODE_REPL_IP) NODE_REPL_IP="$val" ;;
    HEALTH_PORT)  HEALTH_PORT="$val" ;;
    TOPOLOGY)     TOPOLOGY="$val" ;;
  esac
done < "$CONF_FILE"

TOPOLOGY="${TOPOLOGY:-mesh}"
healthy=true

# --- Helper: JSON-escape a string ---
json_str() { printf '"%s"' "$1"; }

# --- Read peer config from watchdog conf ---
PEER_NAMES=()
PEER_IPS=()
PEER_IFACES=()

if [[ -f "$WATCHDOG_CONF" ]]; then
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    if [[ "$key" =~ ^PEER_(.+)_IP$ ]]; then
      name="${BASH_REMATCH[1]}"
      found=0
      for (( i=0; i<${#PEER_NAMES[@]}; i++ )); do
        if [[ "${PEER_NAMES[$i]}" == "$name" ]]; then
          PEER_IPS[$i]="$val"
          found=1; break
        fi
      done
      if [[ $found -eq 0 ]]; then
        PEER_NAMES+=("$name")
        PEER_IPS+=("$val")
        PEER_IFACES+=("")
      fi
    elif [[ "$key" =~ ^PEER_(.+)_IFACE$ ]]; then
      name="${BASH_REMATCH[1]}"
      found=0
      for (( i=0; i<${#PEER_NAMES[@]}; i++ )); do
        if [[ "${PEER_NAMES[$i]}" == "$name" ]]; then
          PEER_IFACES[$i]="$val"
          found=1; break
        fi
      done
      if [[ $found -eq 0 ]]; then
        PEER_NAMES+=("$name")
        PEER_IPS+=("")
        PEER_IFACES+=("$val")
      fi
    fi
  done < "$WATCHDOG_CONF"
fi

# --- Collect interface status ---
ifaces_json="{"
first_iface=true
for (( i=0; i<${#PEER_NAMES[@]}; i++ )); do
  iface="${PEER_IFACES[$i]}"
  [[ -z "$iface" ]] && continue

  state=$(ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
  carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null) || carrier="0"
  ip_addr=$(ip -4 -br addr show "$iface" 2>/dev/null | awk '{print $3}')

  [[ "$state" != "UP" ]] && healthy=false
  [[ "$carrier" != "1" ]] && healthy=false

  $first_iface || ifaces_json+=", "
  first_iface=false
  ifaces_json+="\"${iface}\": {\"state\": \"${state:-DOWN}\", \"carrier\": $([ "$carrier" = "1" ] && echo true || echo false), \"ip\": \"${ip_addr:-none}\"}"
done

# dummy0 (mesh only)
if [[ "$TOPOLOGY" == "mesh" && -n "$NODE_REPL_IP" ]]; then
  dummy_state=$(ip -br link show dummy0 2>/dev/null | awk '{print $2}')
  dummy_ip=$(ip -4 -br addr show dummy0 2>/dev/null | awk '{print $3}')

  [[ "$dummy_state" != "UNKNOWN" && "$dummy_state" != "UP" ]] && healthy=false
  [[ "$dummy_ip" != "${NODE_REPL_IP}/32" ]] && healthy=false

  $first_iface || ifaces_json+=", "
  first_iface=false
  ifaces_json+="\"dummy0\": {\"state\": \"${dummy_state:-DOWN}\", \"ip\": \"${dummy_ip:-none}\"}"
fi
ifaces_json+="}"

# --- Collect routes (mesh only) ---
routes_json="{}"
if [[ "$TOPOLOGY" == "mesh" ]]; then
  routes_json="{"
  first_route=true

  # Enumerate host routes in the corosync subnet (10.10.0.x).
  # Note: ip route show omits the /32 suffix for host routes.
  while IFS= read -r dest; do
    [[ "$dest" == "$NODE_REPL_IP" ]] && continue  # skip our own

    route_lines=$(ip route show "${dest}/32" 2>/dev/null)
    count=$(echo "$route_lines" | grep -c '.' || true)
    metrics=$(echo "$route_lines" | grep -oP 'metric \K\d+' | sort -n | tr '\n' ',' | sed 's/,$//')

    [[ "$count" -lt 2 ]] && healthy=false

    $first_route || routes_json+=", "
    first_route=false
    routes_json+="\"${dest}\": {\"count\": ${count}, \"metrics\": [${metrics}]}"
  done < <(ip route show | awk '$1 ~ /^10\.10\.0\./' | awk '{print $1}' | sort -u)

  routes_json+="}"
fi

# --- Collect corosync link status ---
corosync_json="{}"
if command -v corosync-cfgtool &>/dev/null; then
  coro_output=$(corosync-cfgtool -s 2>/dev/null) || coro_output=""
  if [[ -n "$coro_output" ]]; then
    corosync_json="{"
    # Parse link status for each link
    current_link=""
    first_link=true
    declare -A link_peers 2>/dev/null || true
    # Use a simpler parsing approach
    link0_peers=""
    link1_peers=""
    current_link_num=""

    while IFS= read -r line; do
      if [[ "$line" =~ ^LINK\ ID\ ([0-9]+) ]]; then
        current_link_num="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ nodeid:.*localhost ]]; then
        continue
      elif [[ "$line" =~ nodeid:[[:space:]]+([0-9]+):[[:space:]]+(.*) ]]; then
        nodeid="${BASH_REMATCH[1]}"
        status="${BASH_REMATCH[2]}"
        status=$(echo "$status" | xargs)  # trim whitespace

        [[ "$status" == "disconnected" ]] && healthy=false

        entry="\"node${nodeid}\": \"${status}\""
        if [[ "$current_link_num" == "0" ]]; then
          [[ -n "$link0_peers" ]] && link0_peers+=", "
          link0_peers+="$entry"
        elif [[ "$current_link_num" == "1" ]]; then
          [[ -n "$link1_peers" ]] && link1_peers+=", "
          link1_peers+="$entry"
        fi
      fi
    done <<< "$coro_output"

    corosync_json="{\"link0\": {${link0_peers}}, \"link1\": {${link1_peers}}}"
  fi
fi

# --- Collect peer reachability ---
peers_json="{"
first_peer=true
for (( i=0; i<${#PEER_NAMES[@]}; i++ )); do
  peer="${PEER_NAMES[$i]}"
  ip="${PEER_IPS[$i]}"
  iface="${PEER_IFACES[$i]}"
  [[ -z "$ip" || -z "$iface" ]] && continue

  p2p_ok=false
  coro_ok=false

  # Point-to-point reachability
  if ping -c 1 -W 1 -I "$iface" "$ip" &>/dev/null 2>&1; then
    p2p_ok=true
  else
    healthy=false
  fi

  # Corosync address reachability (mesh only — find peer's repl_ip from routes)
  if [[ "$TOPOLOGY" == "mesh" ]]; then
    # Find peer's repl_ip from the direct route via this interface
    peer_repl_ip=$(ip route show | awk '$1 ~ /^10\.10\.0\./' | grep "dev ${iface}" | grep 'metric 100' | awk '{print $1}' | head -1)
    if [[ -n "$peer_repl_ip" ]]; then
      if ping -c 1 -W 1 "$peer_repl_ip" &>/dev/null 2>&1; then
        coro_ok=true
      else
        healthy=false
      fi
    else
      # Interface might be down (route removed) — can't check corosync reachability
      coro_ok=false
    fi
  fi

  $first_peer || peers_json+=", "
  first_peer=true  # intentional: handled by the comma logic above
  first_peer=false
  peers_json+="\"${peer}\": {\"p2p_reachable\": ${p2p_ok}, \"corosync_reachable\": ${coro_ok}}"
done
peers_json+="}"

# --- Watchdog status (mesh only) ---
watchdog_json="null"
if [[ "$TOPOLOGY" == "mesh" ]]; then
  timer_active=false
  if systemctl is-active repl-watchdog.timer &>/dev/null; then
    timer_active=true
  else
    healthy=false
  fi

  peers_down="[]"
  if [[ -d "$WATCHDOG_STATE" ]]; then
    down_list=$(find "$WATCHDOG_STATE" -name '*.down' -exec basename {} .down \; 2>/dev/null | sort)
    if [[ -n "$down_list" ]]; then
      peers_down="["
      first_down=true
      while IFS= read -r p; do
        $first_down || peers_down+=", "
        first_down=false
        peers_down+="\"${p}\""
      done <<< "$down_list"
      peers_down+="]"
    fi
  fi

  watchdog_json="{\"active\": ${timer_active}, \"peers_down\": ${peers_down}}"
fi

# --- ip_forward (mesh only) ---
ip_fwd_json="null"
if [[ "$TOPOLOGY" == "mesh" ]]; then
  fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || fwd="0"
  [[ "$fwd" != "1" ]] && healthy=false
  ip_fwd_json="${fwd}"
fi

# --- Collect ZFS replication staleness ---
repl_json="{"
first_repl=true
repl_stale=false
if command -v pvesr &>/dev/null; then
  # pvesr status outputs a table: JobID Enabled Target LastSync NextSync Duration FailCount State
  # Error states produce multi-line output — continuation lines (e.g., "Please remove...")
  # don't start with a job ID pattern. Only parse lines matching <digits>-<digits>.
  while IFS= read -r line; do
    # Skip header and blank lines
    [[ "$line" =~ ^JobID ]] && continue
    [[ -z "$line" ]] && continue
    # Only parse lines starting with a valid job ID (e.g., "104-2")
    [[ "$line" =~ ^[0-9]+-[0-9]+ ]] || continue

    job_id=$(echo "$line" | awk '{print $1}')
    last_sync_str=$(echo "$line" | awk '{print $4}')
    fail_count=$(echo "$line" | awk '{print $7}')
    # State field may contain spaces (e.g., "No common base snapshot on volume(s)...")
    # Extract everything from field 8 onwards as the state
    state=$(echo "$line" | awk '{for(i=8;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

    # Sanitize state for JSON (truncate long error messages, escape quotes)
    if [[ ${#state} -gt 60 ]]; then
      state="${state:0:57}..."
    fi
    state=$(echo "$state" | sed 's/"/\\"/g')

    # Parse last_sync timestamp (format: YYYY-MM-DD_HH:MM:SS)
    stale=false
    if [[ "$last_sync_str" == "-" || -z "$last_sync_str" ]]; then
      stale=true
      age=-1
    else
      last_ts=$(date -d "${last_sync_str//_/ }" +%s 2>/dev/null) || last_ts=0
      now_ts=$(date +%s)
      age=$(( now_ts - last_ts ))
      # Stale if last sync > 5 minutes ago
      if [[ "$age" -gt 300 ]]; then
        stale=true
      fi
    fi

    # fail_count > 0 means the job is in error state
    if [[ "${fail_count:-0}" -gt 0 ]]; then
      stale=true
    fi

    if [[ "$stale" == "true" ]]; then
      repl_stale=true
    fi

    $first_repl || repl_json+=", "
    first_repl=false
    repl_json+="\"${job_id}\": {\"state\": \"${state}\", \"age_seconds\": ${age}, \"fail_count\": ${fail_count:-0}, \"stale\": ${stale}}"
  done < <(pvesr status 2>/dev/null)
fi
repl_json+="}"

# --- Collect ZFS pool health ---
zfs_json="{"
first_pool=true
while IFS= read -r pool; do
  [[ -z "$pool" ]] && continue
  pool_status=$(zpool status -x "$pool" 2>&1)
  if echo "$pool_status" | grep -q "is healthy"; then
    pool_health="healthy"
  else
    pool_health="degraded"
    healthy=false
  fi

  $first_pool || zfs_json+=", "
  first_pool=false
  zfs_json+="\"${pool}\": \"${pool_health}\""
done < <(zpool list -H -o name 2>/dev/null)
zfs_json+="}"

# --- Assemble output ---
# Mesh-only fields are omitted entirely when topology is switched
output="{"
output+="\"node\": \"${NODE_NAME}\", "
output+="\"healthy\": ${healthy}, "
output+="\"topology\": \"${TOPOLOGY}\", "
output+="\"interfaces\": ${ifaces_json}, "
if [[ "$TOPOLOGY" == "mesh" ]]; then
  output+="\"routes\": ${routes_json}, "
fi
output+="\"corosync\": ${corosync_json}, "
output+="\"peers\": ${peers_json}"
if [[ "$TOPOLOGY" == "mesh" ]]; then
  output+=", \"watchdog\": ${watchdog_json}"
  output+=", \"ip_forward\": ${ip_fwd_json}"
fi
output+=", \"replication\": ${repl_json}"
output+=", \"replication_stale\": ${repl_stale}"
output+=", \"zfs_pools\": ${zfs_json}"
output+="}"

echo "$output" | python3 -m json.tool 2>/dev/null || echo "$output"
