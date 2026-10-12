#!/usr/bin/env bash
# pre-deploy-vm-completeness-gate.sh — detect incomplete precious VMs before backup.
#
# Usage:
#   pre-deploy-vm-completeness-gate.sh --env dev --repair-pin build/repair-pin-dev.json
#
# CI wires this gate only into deploy:dev per Sprint 041 addendum F4; prod
# repair remains an explicit operator/workstation action unless a later sprint
# broadens the deploy contract.
#
# STATUS — Autonomous CI convergence (Move 3a Path B) is NOT delivered (#450).
# This gate detects incompleteness correctly and emits the right diagnostic,
# but the convergence path that would route pre-existing-damage through
# `converge_incomplete_vm` cannot actually fire in production CI because
# `build/repair-pin-${env}.json` is gitignored and there is no CI mechanism to
# deliver an operator-supplied pin into the runner's workspace. The gate
# always hits the no-pin refuse below. Recovery for pre-existing damage is
# WORKSTATION-driven: place build/restore-pin-${env}.json locally and run
# `framework/scripts/safe-apply.sh dev`. The in-run rc=2 convergence path
# (Move 3a Path A) in `safe-apply.sh:handle_incomplete_restore_rc2` IS
# delivered and operates on the pipeline's own freshly-written restore-pin.
# Track autonomous Path B re-design: GitLab issue #450 (auto-discovered
# last-good-pin ledger that eliminates the operator pin file entirely).
# Superseded delivery-gap report: #459 (closed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/lib/converge-incomplete-vm.sh"

ENV_NAME=""
REPAIR_PIN_FILE=""

usage() {
  sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_NAME="$2"
      shift 2
      ;;
    --repair-pin)
      REPAIR_PIN_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$ENV_NAME" != "dev" && "$ENV_NAME" != "prod" ]]; then
  echo "ERROR: --env must be dev or prod" >&2
  exit 2
fi
if [[ -z "$REPAIR_PIN_FILE" ]]; then
  REPAIR_PIN_FILE="${REPO_DIR}/build/repair-pin-${ENV_NAME}.json"
elif [[ "$REPAIR_PIN_FILE" != /* ]]; then
  REPAIR_PIN_FILE="${REPO_DIR}/${REPAIR_PIN_FILE}"
fi

failures=0
while IFS=$'\t' read -r vmid label _env; do
  [[ -z "$vmid" ]] && continue
  set +e
  topology_output="$("${SCRIPT_DIR}/vm-is-complete.sh" "$vmid" 2>&1)"
  topology_rc=$?
  set -e
  if [[ "$topology_rc" -eq 0 ]]; then
    echo "OK: ${label} (VMID ${vmid}) topology complete"
    continue
  fi
  if [[ "$topology_rc" -ne 2 ]]; then
    echo "UNVERIFIABLE: ${label} (VMID ${vmid}) topology could not be verified" >&2
    [[ -n "$topology_output" ]] && echo "$topology_output" >&2
    failures=$((failures + 1))
    continue
  fi

  echo "INCOMPLETE: ${label} (VMID ${vmid})"
  pin=""
  if [[ -f "$REPAIR_PIN_FILE" ]]; then
    pin="$(jq -r --arg vmid "$vmid" '(.pins[$vmid] // "") | if type == "object" then (.volid // "") else . end' "$REPAIR_PIN_FILE")"
  fi

  if [[ -z "$pin" ]]; then
    cat >&2 <<EOF
VM ${vmid} is incomplete; no exact repair pin available in ${REPAIR_PIN_FILE}. This needs full recreate because vdb-only restore cannot repair missing boot topology.

NOTE — autonomous CI repair-pin convergence (Move 3a Path B) is NOT
delivered in production CI (see GitLab issue #450; superseded report
#459). The gitignored build/repair-pin-${ENV_NAME}.json file cannot be
populated by an operator in a real incident because there is no CI
mechanism that delivers the operator-supplied pin into the runner
workspace. The gate will always reach this refuse for pre-existing damage
until #450 lands.

Recovery — workstation-driven (the actually-delivered path):
  1. Identify the exact PBS volid you want to restore from:
     \`ssh root@<node> "pvesh get /nodes/<node>/storage/pbs-nas/content --output-format json"\`
  2. On the workstation, write build/restore-pin-${ENV_NAME}.json
     (note: restore-pin, NOT repair-pin — safe-apply.sh reads restore-pin):
       { "pins": { "${vmid}": "pbs-nas:backup/vm/${vmid}/<TIMESTAMP>" } }
  3. Run \`framework/scripts/safe-apply.sh ${ENV_NAME}\` from the
     workstation. Phase 1 stopped apply recreates the VM; restore-before-start
     reads your pin and restores vdb; Phase 2 starts the VM. If
     restore-before-start returns rc=2 for an incomplete-precious VM,
     the in-run rc=2 handler converges in-place using your pin.

Direct alternative if you only need vendor-restore (no in-place convergence):
\`qmrestore ${REPAIR_PIN_FILE} ${vmid} --force\` (whole-VM; requires operator
approval per .claude/rules/destructive-operations.md) and re-run the pipeline.
EOF
    failures=$((failures + 1))
    continue
  fi

  # Defensive: in practice this branch is unreachable in production CI as of
  # Sprint 041 because the no-pin refuse above fires first (#450 not yet
  # delivered). Kept for parity with the workstation invocation path where
  # an operator might supply --repair-pin explicitly.
  if converge_incomplete_vm "$ENV_NAME" "$vmid" "$pin"; then
    echo "CONVERGED: ${label} (VMID ${vmid}) from ${pin}"
  else
    cat >&2 <<EOF
VM ${vmid} (${label}) convergence failed. This needs full recreate because
vdb-only restore cannot repair missing boot topology. Recover with
\`qmrestore ${pin} ${vmid} --force\` (whole-VM; requires operator approval
per .claude/rules/destructive-operations.md) and re-run the pipeline.
EOF
    failures=$((failures + 1))
  fi
done < <("${SCRIPT_DIR}/list-backup-backed-vmids.sh" --format tsv "$ENV_NAME")

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
