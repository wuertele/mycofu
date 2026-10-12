#!/usr/bin/env bash
# regreen-cluster.sh — Sequential fail-fast orchestrator for hil-boot PXE regreening.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG=""
TARGET="all"
DRY_RUN=0
RUN_DIR="${MYCOFU_REGREENER_RUN_DIR:-${REPO_DIR}/build/regreen}"
STATUS_JSON="${RUN_DIR}/status.json"

usage() {
  cat <<'EOF'
Usage:
  regreen-cluster.sh [all|NODE] [--config CONFIG] [--dry-run]
  regreen-cluster.sh --node NODE [--config CONFIG] [--dry-run]

Runs enabled nodes sequentially and stops on the first failure.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

default_config() {
  find "${REPO_DIR}/tests/hil" -mindepth 2 -maxdepth 2 -name config.yaml 2>/dev/null | sort | head -1
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
}

validate_site_config_for_regreener() {
  local apps_config
  apps_config="$(dirname "$CONFIG")/applications.yaml"
  VALIDATE_SITE_CONFIG_CONFIG="$CONFIG" \
  VALIDATE_SITE_CONFIG_APPS_CONFIG="$apps_config" \
    "${SCRIPT_DIR}/validate-site-config.sh"
}

node_cfg() {
  local node="$1" expr="$2"
  NODE="$node" yq -r ".nodes[] | select(.name == strenv(NODE)) | ${expr}" "$CONFIG"
}

write_initial_status() {
  local started_at="$1"
  local hil_boot_ip
  hil_boot_ip="$(yq -r '.vms.hil_boot.ip // ""' "${REPO_DIR}/site/config.yaml")"
  jq -n \
    --arg started_at "$started_at" \
    --arg target "$TARGET" \
    --arg config "$CONFIG" \
    --arg hil_boot_ip "$hil_boot_ip" \
    --argjson dry_run "$DRY_RUN" \
    '{
      version: 1,
      started_at: $started_at,
      target: $target,
      config: $config,
      dry_run: ($dry_run == 1),
      hil_boot: { ip: $hil_boot_ip, status: "pending" },
      nodes: {},
      outcome: "running"
    }' > "$STATUS_JSON"
}

json_set_hil_boot_status() {
  local status="$1" tmp
  tmp="${STATUS_JSON}.tmp"
  jq --arg status "$status" '.hil_boot.status = $status' "$STATUS_JSON" > "$tmp"
  mv "$tmp" "$STATUS_JSON"
}

json_set_node() {
  local node="$1" state="$2" elapsed="$3" exit_code="$4" tmp
  local mgmt_ip amt_ip
  mgmt_ip="$(node_cfg "$node" '.mgmt_ip')"
  amt_ip="$(node_cfg "$node" '.amt_ip // ""')"
  tmp="${STATUS_JSON}.tmp"
  jq \
    --arg node "$node" \
    --arg state "$state" \
    --arg mgmt_ip "$mgmt_ip" \
    --arg amt_ip "$amt_ip" \
    --argjson elapsed "$elapsed" \
    --argjson exit_code "$exit_code" \
    '.nodes[$node] = {
      state: $state,
      exit_code: $exit_code,
      elapsed_seconds: $elapsed,
      mgmt_ip: $mgmt_ip,
      amt_ip: $amt_ip
    }' "$STATUS_JSON" > "$tmp"
  mv "$tmp" "$STATUS_JSON"
}

json_set_outcome() {
  local outcome="$1" tmp
  tmp="${STATUS_JSON}.tmp"
  jq --arg outcome "$outcome" '.outcome = $outcome' "$STATUS_JSON" > "$tmp"
  mv "$tmp" "$STATUS_JSON"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --node) TARGET="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

[[ -n "$CONFIG" ]] || CONFIG="$(default_config)"
[[ -n "$CONFIG" ]] || die "no default HIL config found under tests/hil"
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"

require_tool yq
require_tool jq
require_tool date
if ! validate_site_config_for_regreener; then
  die "config validation failed: $CONFIG"
fi

NODES=()
if [[ "$TARGET" == "all" || -z "$TARGET" ]]; then
  while IFS= read -r node; do
    [[ -n "$node" ]] && NODES+=("$node")
  done < <(yq -r '.nodes[] | select(.regreen_enabled == true) | .name' "$CONFIG")
  TARGET="all"
else
  if ! NODE="$TARGET" yq -e '.nodes[] | select(.name == strenv(NODE))' "$CONFIG" >/dev/null 2>&1; then
    die "node '${TARGET}' not found in $CONFIG"
  fi
  enabled="$(node_cfg "$TARGET" '.regreen_enabled // false')"
  [[ "$enabled" == "true" ]] || die "node ${TARGET} is not regreen_enabled"
  NODES+=("$TARGET")
fi

[[ "${#NODES[@]}" -gt 0 ]] || die "no nodes have regreen_enabled: true"

mkdir -p "$RUN_DIR"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_initial_status "$STARTED_AT"

echo "=== Regreening ${#NODES[@]} node(s) ==="

GREEN=0
FAILED=0

for idx in "${!NODES[@]}"; do
  node="${NODES[$idx]}"
  echo "${node}: starting"
  start_epoch="$(date +%s)"

  set +e
  MYCOFU_REGREENER_RUN_DIR="$RUN_DIR" \
    "${MYCOFU_INSTALL_PVE_NODE:-${SCRIPT_DIR}/install-pve-node.sh}" \
      --config "$CONFIG" \
      --node "$node" \
      $([[ "$DRY_RUN" -eq 1 ]] && printf '%s' "--dry-run")
  rc=$?
  set -e

  elapsed=$(( $(date +%s) - start_epoch ))
  json_set_hil_boot_status "checked"

  if [[ "$rc" -eq 0 ]]; then
    GREEN=$((GREEN + 1))
    json_set_node "$node" green "$elapsed" 0
    echo "${node}: green"
  else
    FAILED=$((FAILED + 1))
    json_set_node "$node" failed "$elapsed" "$rc"
    for (( j = idx + 1; j < ${#NODES[@]}; j++ )); do
      json_set_node "${NODES[$j]}" not-attempted 0 0
    done
    json_set_outcome "failed"
    echo "${node}: failed (exit ${rc})" >&2
    echo "Status: ${STATUS_JSON}"
    echo "Results: ${GREEN} green, ${FAILED} failed"
    exit "$rc"
  fi
done

json_set_outcome "green"
echo "Status: ${STATUS_JSON}"
echo "Results: ${GREEN} green, ${FAILED} failed"
