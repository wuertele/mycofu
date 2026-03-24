#!/usr/bin/env bash
# repl-watchdog.sh — Ping-based replication link watchdog (mesh topology only)
#
# Converts asymmetric link failures into symmetric ones by bringing down the
# local interface when a peer is unreachable on its point-to-point IP. This
# forces the kernel to flush the direct route, allowing traffic to fall back
# to the higher-metric route via the third node.
#
# Deployed to /usr/local/bin/repl-watchdog.sh by configure-node-network.sh.
# Run every 10 seconds by repl-watchdog.timer.
#
# Configuration: /etc/repl-watchdog.conf
# State directory: /run/repl-watchdog/

set -uo pipefail

CONF_FILE="/etc/repl-watchdog.conf"
STATE_DIR="/run/repl-watchdog"
FAIL_THRESHOLD=3          # consecutive failures before bringing interface down
RECOVERY_INTERVAL=60      # seconds between recovery attempts for downed peers
PING_TIMEOUT=2            # seconds

if [[ ! -f "$CONF_FILE" ]]; then
  exit 0
fi

mkdir -p "$STATE_DIR"

# Parse config: lines like PEER_pve02_IP=10.10.1.2 and PEER_pve02_IFACE=nic3
PEERS=()
declare -A PEER_IP PEER_IFACE 2>/dev/null || true

# Bash 3 compat: use parallel arrays
PEER_NAMES=()
PEER_IPS=()
PEER_IFACES=()

while IFS='=' read -r key val; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  if [[ "$key" =~ ^PEER_(.+)_IP$ ]]; then
    name="${BASH_REMATCH[1]}"
    # Check if peer already in list
    found=0
    for (( i=0; i<${#PEER_NAMES[@]}; i++ )); do
      if [[ "${PEER_NAMES[$i]}" == "$name" ]]; then
        PEER_IPS[$i]="$val"
        found=1
        break
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
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      PEER_NAMES+=("$name")
      PEER_IPS+=("")
      PEER_IFACES+=("$val")
    fi
  fi
done < "$CONF_FILE"

for (( i=0; i<${#PEER_NAMES[@]}; i++ )); do
  peer="${PEER_NAMES[$i]}"
  ip="${PEER_IPS[$i]}"
  iface="${PEER_IFACES[$i]}"

  if [[ -z "$ip" || -z "$iface" ]]; then
    continue
  fi

  fail_file="${STATE_DIR}/${peer}.failures"
  down_file="${STATE_DIR}/${peer}.down"

  # --- Recovery path: for peers we previously brought down ---
  if [[ -f "$down_file" ]]; then
    # Check if enough time has passed for a recovery attempt
    last_attempt="${STATE_DIR}/${peer}.last_recovery"
    now=$(date +%s)
    if [[ -f "$last_attempt" ]]; then
      last=$(cat "$last_attempt")
      elapsed=$(( now - last ))
      if (( elapsed < RECOVERY_INTERVAL )); then
        continue
      fi
    fi

    echo "$now" > "$last_attempt"

    # Speculatively bring interface up
    ip link set "$iface" up 2>/dev/null || true
    sleep 2

    # Test if peer is reachable
    if ping -c 1 -W "$PING_TIMEOUT" -I "$iface" "$ip" &>/dev/null; then
      # Peer is back — remove down marker and reset failures
      rm -f "$down_file" "$fail_file" "$last_attempt"
      logger -t repl-watchdog "${iface} recovered — ${peer} reachable again"
    else
      # Still dead — bring it back down
      ip link set "$iface" down 2>/dev/null || true
    fi
    continue
  fi

  # --- Normal monitoring path ---
  # Check if interface is UP first
  iface_state=$(ip -br link show "$iface" 2>/dev/null | awk '{print $2}')
  if [[ "$iface_state" != "UP" ]]; then
    # Interface is down but not by us — could be admin-down or no carrier.
    # If carrier is missing, treat as a failure to increment the counter.
    carrier=$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null) || carrier="0"
    if [[ "$carrier" != "1" ]]; then
      # No carrier — count as failure
      failures=0
      [[ -f "$fail_file" ]] && failures=$(cat "$fail_file")
      failures=$(( failures + 1 ))
      echo "$failures" > "$fail_file"

      if (( failures >= FAIL_THRESHOLD )); then
        ip link set "$iface" down 2>/dev/null || true
        touch "$down_file"
        echo "0" > "$fail_file"
        logger -t repl-watchdog "bringing down ${iface} — ${peer} unreachable for $(( failures * 10 ))s (no carrier)"
      fi
    fi
    continue
  fi

  # Interface is UP — ping the peer
  if ping -c 1 -W "$PING_TIMEOUT" -I "$iface" "$ip" &>/dev/null; then
    # Peer reachable — reset failures
    echo "0" > "$fail_file"
  else
    # Peer unreachable — increment
    failures=0
    [[ -f "$fail_file" ]] && failures=$(cat "$fail_file")
    failures=$(( failures + 1 ))
    echo "$failures" > "$fail_file"

    if (( failures >= FAIL_THRESHOLD )); then
      ip link set "$iface" down 2>/dev/null || true
      touch "$down_file"
      echo "0" > "$fail_file"
      logger -t repl-watchdog "bringing down ${iface} — ${peer} unreachable for $(( failures * 10 ))s"
    fi
  fi
done
