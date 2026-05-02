#!/usr/bin/env bash
# confirm-empty-vdb-first-deploy.sh — Print first-deploy approval syntax.

set -euo pipefail

if [[ $# -lt 1 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $(basename "$0") <vmid> [<vmid> ...]" >&2
  echo "Prints the FIRST_DEPLOY_ALLOW_VMIDS value for an explicit empty-vdb first deploy." >&2
  exit 2
fi

vmids=()
for vmid in "$@"; do
  if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
    echo "ERROR: VMID must be numeric: $vmid" >&2
    exit 1
  fi
  vmids+=("$vmid")
done

joined="$(IFS=,; printf '%s' "${vmids[*]}")"

cat <<EOF
Set this protected CI variable for one manual rerun only:

FIRST_DEPLOY_ALLOW_VMIDS=${joined}

Workstation equivalent:

FIRST_DEPLOY_ALLOW_VMIDS=${joined} framework/scripts/safe-apply.sh <dev|prod>
EOF
