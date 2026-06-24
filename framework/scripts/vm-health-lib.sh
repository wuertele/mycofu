#!/usr/bin/env bash
# vm-health-lib.sh — Health gates for backup-backed VMs.
#
# Intended to be sourced by backup-now.sh.
#
# Exports:
#   vm_health_check <vm_key> <vm_label> <vm_ip> <hosting_node_ip> <vmid>
#   vm_health_vault <vm_label> <vm_ip>
#   vm_health_gitlab <vm_label> <vm_ip>
#   vm_health_influxdb <vm_label> <vm_ip>
#   vm_health_roon <vm_label> <vm_ip>
#   vm_health_workstation <vm_label> <vm_ip> <hosting_node_ip> <vmid>
#   vm_health_generic <vm_label> <vm_ip> <hosting_node_ip> <vmid>
#
# On failure, a function prints one line to stderr and sets:
#   VM_HEALTH_LAST_REASON
#   VM_HEALTH_LAST_CLASS   ("unhealthy" or "unreachable")

VM_HEALTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${VM_HEALTH_LIB_DIR}/vdb-state-lib.sh"

VM_HEALTH_LAST_REASON=""
VM_HEALTH_LAST_CLASS=""

vm_health_reset_state() {
  VM_HEALTH_LAST_REASON=""
  VM_HEALTH_LAST_CLASS=""
}

vm_health_fail() {
  local reason="$1"
  local failure_class="${2:-unhealthy}"
  VM_HEALTH_LAST_REASON="$reason"
  VM_HEALTH_LAST_CLASS="$failure_class"
  echo "$reason" >&2
  return 1
}

vm_health_ssh() {
  local ip="$1"
  shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

vm_health_node_ssh() {
  local ip="$1"
  shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

vm_health_vault() {
  local label="$1"
  local ip="$2"
  local health_json=""

  vm_health_reset_state

  if health_json="$(vm_health_ssh "$ip" "curl -sk https://127.0.0.1:8200/v1/sys/health")"; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: vault health probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: vault health probe failed"
    fi
    return 1
  fi

  if ! jq empty >/dev/null 2>&1 <<< "$health_json"; then
    vm_health_fail "${label}: vault health probe returned malformed JSON"
    return 1
  fi

  if ! jq -e '.initialized == true' >/dev/null 2>&1 <<< "$health_json"; then
    vm_health_fail "${label}: vault is not initialized"
    return 1
  fi

  if ! jq -e '.sealed == false' >/dev/null 2>&1 <<< "$health_json"; then
    vm_health_fail "${label}: vault is sealed"
    return 1
  fi

  # vault.db is the barrier (encrypted KV store) — all Vault data lives here.
  # raft.db is only the Raft consensus log; removing it doesn't lose data.
  # Path from vault.nix: storage "raft" { path = "/var/lib/vault/data" }
  if vm_health_ssh "$ip" "test -s /var/lib/vault/data/vault.db"; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: vault barrier probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: vault.db (barrier) missing or empty"
    fi
    return 1
  fi
}

vm_health_gitlab() {
  local label="$1"
  local ip="$2"

  vm_health_reset_state

  # GitLab listens on HTTPS (port 443 via nginx), not HTTP port 80
  if vm_health_ssh "$ip" "curl -fsSk https://127.0.0.1/-/readiness >/dev/null"; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: gitlab readiness probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: gitlab readiness probe failed"
    fi
    return 1
  fi

  # Path from gitlab.nix: gitlabStatePath = "/var/lib/gitlab/state"
  if vm_health_ssh "$ip" "test -d /var/lib/gitlab/state/repositories"; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: gitlab repository probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: gitlab repositories directory missing"
    fi
    return 1
  fi

  # NixOS GitLab uses systemd-managed PostgreSQL, not Omnibus gitlab-ctl
  if vm_health_ssh "$ip" "systemctl is-active postgresql >/dev/null"; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: gitlab postgresql probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: gitlab postgresql is not running"
    fi
    return 1
  fi
}

vm_health_influxdb() {
  local label="$1"
  local ip="$2"
  local health_json=""

  vm_health_reset_state

  if health_json="$(vm_health_ssh "$ip" "curl -sk https://127.0.0.1:8086/health")"; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: influxdb health probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: influxdb health probe failed"
    fi
    return 1
  fi

  if ! jq empty >/dev/null 2>&1 <<< "$health_json"; then
    vm_health_fail "${label}: influxdb health probe returned malformed JSON"
    return 1
  fi

  if ! jq -e '.status == "pass"' >/dev/null 2>&1 <<< "$health_json"; then
    vm_health_fail "${label}: influxdb /health did not report pass"
    return 1
  fi

  if vm_health_ssh "$ip" "find /var/lib/influxdb2/engine -mindepth 1 -print -quit | grep -q ."; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: influxdb engine probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: influxdb engine missing or empty"
    fi
    return 1
  fi
}

vm_health_roon() {
  local label="$1"
  local ip="$2"

  vm_health_reset_state

  if vm_health_ssh "$ip" "find /var/lib/roon-server -mindepth 1 -print -quit | grep -q ."; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: roon data probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: roon database directory missing or empty"
    fi
    return 1
  fi
}

vm_health_verify_vdb_ext4() {
  local label="$1"
  local hosting_node_ip="$2"
  local vmid="$3"
  local storage_pool="${VM_HEALTH_STORAGE_POOL:-${STORAGE_POOL:-vmstore}}"
  local vdb_zvol=""
  local blkid_output=""

  if [[ -z "$hosting_node_ip" || -z "$vmid" ]]; then
    vm_health_fail "${label}: generic health check missing hosting node or VMID"
    return 1
  fi

  # No current backup-backed VM uses this fallback. Keep the existing scsi1
  # probe documented here until vdb identification can be fixed consistently
  # with restore-from-pbs.sh; a partial guess would be riskier than a visible
  # limitation.
  if vdb_zvol="$(vm_health_node_ssh "$hosting_node_ip" \
    "qm config ${vmid} 2>/dev/null | grep '^scsi1:' | sed 's/.*${storage_pool}://' | sed 's/,.*//'")"; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: generic vdb probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: could not determine vdb zvol"
    fi
    return 1
  fi

  if [[ -z "$vdb_zvol" ]]; then
    vm_health_fail "${label}: could not determine vdb zvol"
    return 1
  fi

  if blkid_output="$(vm_health_node_ssh "$hosting_node_ip" \
    "blkid /dev/zvol/${storage_pool}/data/${vdb_zvol} 2>/dev/null")"; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: generic blkid probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: vdb is not ext4"
    fi
    return 1
  fi

  if ! grep -q 'TYPE="ext4"' <<< "$blkid_output"; then
    vm_health_fail "${label}: vdb is not ext4"
    return 1
  fi
}

vm_health_workstation() {
  local label="$1"
  local ip="$2"
  local hosting_node_ip="$3"
  local vmid="$4"
  local probe_script=""

  vm_health_reset_state

  vm_health_verify_vdb_ext4 "$label" "$hosting_node_ip" "$vmid" || return 1

  probe_script="$(vdb_state_probe_script_for_label "$label")"
  if vm_health_ssh "$ip" "$probe_script" >/dev/null; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: workstation state probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: /home has no real state beyond bootstrap"
    fi
    return 1
  fi
}

vm_health_generic() {
  local label="$1"
  local ip="$2"
  local hosting_node_ip="$3"
  local vmid="$4"

  vm_health_reset_state

  vm_health_verify_vdb_ext4 "$label" "$hosting_node_ip" "$vmid" || return 1

  if vm_health_ssh "$ip" "find /var/lib -mindepth 1 ! -name lost+found -print -quit | grep -q ."; then
    :
  else
    local status=$?
    if [[ $status -eq 255 ]]; then
      vm_health_fail "${label}: generic /var/lib probe unreachable" "unreachable"
    else
      vm_health_fail "${label}: /var/lib is empty"
    fi
    return 1
  fi
}

vm_health_check() {
  local vm_key="$1"
  local label="$2"
  local ip="$3"
  local hosting_node_ip="${4:-}"
  local vmid="${5:-}"

  case "$vm_key" in
    vault*)
      vm_health_vault "$label" "$ip"
      ;;
    gitlab)
      vm_health_gitlab "$label" "$ip"
      ;;
    influxdb*)
      vm_health_influxdb "$label" "$ip"
      ;;
    roon*)
      vm_health_roon "$label" "$ip"
      ;;
    workstation*)
      vm_health_workstation "$label" "$ip" "$hosting_node_ip" "$vmid"
      ;;
    *)
      vm_health_generic "$label" "$ip" "$hosting_node_ip" "$vmid"
      ;;
  esac
}
