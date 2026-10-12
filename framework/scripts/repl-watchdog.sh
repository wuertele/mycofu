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

# Pin PATH so ifup/ifdown are findable under any systemd unit's default
# (Debian bookworm / Proxmox 8: /usr/sbin/ifup, /usr/sbin/ifdown; same as
# usrmerged /sbin/ifup). Append (not prepend) so a caller-provided PATH
# wins for any directory it does specify — important for hermetic tests
# that put shim binaries on PATH.
export PATH="${PATH:-}:/usr/sbin:/usr/bin:/sbin:/bin"

# Config and state paths. Env-overridable for hermetic tests; production
# uses the defaults via the systemd unit.
CONF_FILE="${REPL_WATCHDOG_CONF_FILE:-/etc/repl-watchdog.conf}"
STATE_DIR="${REPL_WATCHDOG_STATE_DIR:-/run/repl-watchdog}"
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

    # Speculatively bring interface up.
    # MUST use ifup, not `ip link set up`: the mesh static routes
    # (10.10.0.x/32 via <peer> dev <iface> metric 100 + metric 200
    # fallback) are installed by post-up hooks in
    # /etc/network/interfaces. `ip link set` does not run those hooks,
    # so routes stay gone after recovery and the cluster runs in a
    # silent broken state. See:
    # docs/reports/2026-05-09-mesh-route-loss-after-peer-reboot-retrospective.md
    # ifup/ifdown stdout+stderr go to syslog so failures (lock
    # contention, /etc/network/interfaces syntax error, missing iface)
    # are visible in `journalctl -t repl-watchdog` instead of being
    # swallowed — the silent-failure shape that defined the incident.
    ifup "$iface" 2>&1 | logger -t repl-watchdog -p daemon.warning || true
    sleep 2

    # Test if peer is reachable
    if ping -c 1 -W "$PING_TIMEOUT" -I "$iface" "$ip" &>/dev/null; then
      # Peer is back — remove down marker and reset failures
      rm -f "$down_file" "$fail_file" "$last_attempt"
      logger -t repl-watchdog "${iface} recovered — ${peer} reachable again"
    else
      # Still dead — bring it back down via ifdown so ifupdown2 state
      # stays sync'd with the kernel for the next recovery cycle.
      ifdown "$iface" 2>&1 | logger -t repl-watchdog -p daemon.warning || true
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
        # ifdown, not `ip link set down`: keeps ifupdown2's
        # /run/network/ifstate sync'd with the kernel so the recovery
        # branch's `ifup` actually re-runs post-up hooks. See header
        # comment at speculative-up.
        ifdown "$iface" 2>&1 | logger -t repl-watchdog -p daemon.warning || true
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
      ifdown "$iface" 2>&1 | logger -t repl-watchdog -p daemon.warning || true
      touch "$down_file"
      echo "0" > "$fail_file"
      logger -t repl-watchdog "bringing down ${iface} — ${peer} unreachable for $(( failures * 10 ))s"
    fi
  fi
done
