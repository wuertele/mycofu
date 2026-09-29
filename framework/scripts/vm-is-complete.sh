#!/usr/bin/env bash
# vm-is-complete.sh — CLI wrapper for vm_is_complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/vm-topology-lib.sh"

VMID=""
EXPECTED_DISKS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") <vmid> [--expected-disks <csv>]

Checks that a VM has its expected disk topology attached.
Exit codes: 0 complete, 2 verified-incomplete, 3 topology-unverifiable.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-disks)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --expected-disks requires a value" >&2
        usage >&2
        exit 64
      fi
      EXPECTED_DISKS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
    *)
      if [[ -n "$VMID" ]]; then
        echo "ERROR: unexpected argument: $1" >&2
        usage >&2
        exit 64
      fi
      VMID="$1"
      shift
      ;;
  esac
done

if [[ -z "$VMID" ]]; then
  echo "ERROR: <vmid> is required" >&2
  usage >&2
  exit 64
fi

set +e
vm_is_complete "$VMID" "$EXPECTED_DISKS"
rc=$?
set -e
exit "$rc"
