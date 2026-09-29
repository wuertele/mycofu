#!/usr/bin/env bash
# pdu-cycle.sh — APC PDU power-of-last-resort primitive for HIL nodes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG=""
NODE=""
OUTLET=""
CHECK=0
EXPECT_HELPER="${MYCOFU_PDU_EXPECT:-${SCRIPT_DIR}/pdu-cycle.exp}"

usage() {
  cat <<'EOF'
Usage:
  pdu-cycle.sh NODE [--config CONFIG]
  pdu-cycle.sh --outlet OUTLET [--config CONFIG]
  pdu-cycle.sh --check [--config CONFIG]

Cycles the configured PDU outlet for a HIL node. Use only when AMT
soft power control has failed or the node is unreachable out of band.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

log() {
  printf '[pdu-cycle] %s\n' "$*" >&2
}

default_config() {
  find "${REPO_DIR}/tests/hil" -mindepth 2 -maxdepth 2 -name config.yaml 2>/dev/null | sort | head -1
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
}

cfg() {
  yq -r "$1" "$CONFIG"
}

node_cfg() {
  NODE="$NODE" yq -r ".nodes[] | select(.name == strenv(NODE)) | $1" "$CONFIG"
}

sops_path() {
  printf '%s/sops/secrets.yaml\n' "$(dirname "$CONFIG")"
}

read_sops_key() {
  local key="$1" path value
  path="$(sops_path)"
  [[ -f "$path" ]] || die "SOPS file not found: $path"
  value="$(sops -d --extract "[\"${key}\"]" "$path" 2>/dev/null || true)"
  [[ -n "$value" && "$value" != "null" ]] || return 1
  printf '%s\n' "$value"
}

validate_site_config_for_pdu() {
  local apps_config
  apps_config="$(dirname "$CONFIG")/applications.yaml"
  VALIDATE_SITE_CONFIG_CONFIG="$CONFIG" \
  VALIDATE_SITE_CONFIG_APPS_CONFIG="$apps_config" \
    "${SCRIPT_DIR}/validate-site-config.sh"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --outlet) OUTLET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$NODE" ]]; then
        NODE="$1"
        shift
      else
        echo "ERROR: unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "$CONFIG" ]] || CONFIG="$(default_config)"
[[ -n "$CONFIG" ]] || die "no default HIL config found under tests/hil"
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"

require_tool yq
require_tool sops
if [[ -z "${MYCOFU_PDU_EXPECT:-}" ]]; then
  require_tool expect
fi
[[ -x "$EXPECT_HELPER" ]] || die "expect helper is not executable: $EXPECT_HELPER"

if ! validate_site_config_for_pdu; then
  die "config validation failed: $CONFIG"
fi

if [[ "$CHECK" -eq 1 && -n "$NODE" ]]; then
  die "--check does not accept a node argument"
fi
if [[ -n "$NODE" && -n "$OUTLET" ]]; then
  die "choose either NODE or --outlet, not both"
fi

PDU_HOST="$(cfg '.pdu.host // ""')"
PDU_USER="$(cfg '.pdu.user // ""')"
PDU_REF="$(cfg '.pdu.password_ref // ""')"
[[ -n "$PDU_HOST" && "$PDU_HOST" != "null" ]] || die "pdu.host is required"
[[ -n "$PDU_USER" && "$PDU_USER" != "null" ]] || die "pdu.user is required"
[[ -n "$PDU_REF" && "$PDU_REF" != "null" ]] || die "pdu.password_ref is required"

if [[ -n "$NODE" ]]; then
  if ! NODE="$NODE" yq -e '.nodes[] | select(.name == strenv(NODE))' "$CONFIG" >/dev/null 2>&1; then
    die "node '${NODE}' not found in $CONFIG"
  fi
  OUTLET="$(node_cfg '.pdu_outlet // ""')"
  [[ -n "$OUTLET" && "$OUTLET" != "null" ]] || die "node ${NODE} missing pdu_outlet"
fi

if [[ "$CHECK" -eq 0 ]]; then
  [[ -n "$OUTLET" ]] || die "node or --outlet is required unless --check is used"
  [[ "$OUTLET" =~ ^[1-9][0-9]*$ ]] || die "outlet must be a positive integer"
else
  OUTLET="all"
fi

PDU_PASSWORD="$(read_sops_key "$PDU_REF")" || die "SOPS key ${PDU_REF} missing or empty"

ACTION="Reboot"
if [[ "$CHECK" -eq 1 ]]; then
  ACTION="Status"
  log "Querying PDU outlet status via ${PDU_HOST}"
else
  log "Power-cycling outlet ${OUTLET}${NODE:+ (${NODE})} via ${PDU_HOST}"
fi

PDU_PASSWORD="$PDU_PASSWORD" "$EXPECT_HELPER" "$PDU_HOST" "$PDU_USER" "$OUTLET" "$ACTION"

if [[ "$CHECK" -eq 1 ]]; then
  log "Status query complete"
else
  log "Reboot command dispatched"
fi
