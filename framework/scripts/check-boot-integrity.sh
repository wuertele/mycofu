#!/usr/bin/env bash
# check-boot-integrity.sh — Verify GRUB will find its kernel on cold boot.
#
# For each framework NixOS VM, SSH in, read /boot/grub/grub.cfg, and
# assert every ($drive*)/PATH referenced by `linux` and `initrd`
# directives resolves to a file that exists on the guest disk.
#
# This is the class-closer for #339: on overlay-root NixOS VMs,
# install-grub.pl can silently emit `($drive2)/store/...` (missing the
# /nix prefix). The framework's post-switch sed workaround at
# converge-lib.sh:212 fixes this, but the sed can be missed by a
# variant, a race, or a control-flow bug — and a broken grub.cfg
# is invisible until the next cold boot bricks the VM.
#
# This probe catches the class regardless of *how* grub.cfg was broken.
# It runs on the normal validate.sh cadence, so no VM can accumulate
# the defect silently between validation cycles.
#
# Usage:
#   framework/scripts/check-boot-integrity.sh              # all framework VMs
#   framework/scripts/check-boot-integrity.sh --scope control-plane
#   framework/scripts/check-boot-integrity.sh --host cicd  # single VM (diag)
#
# Exit codes:
#   0 — every checked VM's grub.cfg resolves cleanly
#   1 — at least one VM has grub.cfg referencing missing paths
#   2 — check could not complete (SSH failures, missing config, etc.)
#
# See also:
#   - #339 — this issue
#   - #497 — retire the sed workaround at the install-grub source
#   - #496 — 2026-07-06 cicd incident recovered via the workaround
#   - converge_fix_grub_paths() in framework/scripts/converge-lib.sh
#   - docs/reports/2026-07-06-cicd-cold-boot-kernel-missing-drt001-block.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
VM_SCOPE_SCRIPT="${SCRIPT_DIR}/vm-scope.sh"

SSH_OPTS=(
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

SCOPE="all-nixos"
SINGLE_HOST=""

usage() {
  cat <<'EOF'
Usage:
  framework/scripts/check-boot-integrity.sh [--scope <scope>] [--host <name>]

Options:
  --scope <scope>     "all-nixos" (default) or "control-plane"
  --host  <name>      Check a single host by name (overrides --scope)
  --help              Show this help

Exit codes:
  0 — all clean
  1 — at least one VM references missing paths in grub.cfg
  2 — check could not complete
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)      SCOPE="$2"; shift 2 ;;
    --host)       SINGLE_HOST="$2"; shift 2 ;;
    --help|-h)    usage; exit 0 ;;
    *)            echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in ssh yq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    exit 2
  fi
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 2
fi

# host_ip mirrors check-control-plane-drift.sh so the framework has a
# single behavior for "given a host name, what IP do I SSH to?" —
# tracks both site/config.yaml (vms.<name>.ip) and
# site/applications.yaml (applications.<name>.environments.<env>.ip).
host_ip() {
  local host="$1"
  local ip=""

  ip="$(yq -r ".vms.${host}.ip // \"\"" "$CONFIG" 2>/dev/null || true)"
  if [[ -n "$ip" && "$ip" != "null" ]]; then
    echo "$ip"
    return 0
  fi

  # Try applications.<name>.environments.<env>.ip — take the first env
  # that has an IP. host names in applications embed the env suffix
  # (e.g., "roon_prod"), so we split here.
  local base env
  if [[ "$host" == *_prod || "$host" == *_dev ]]; then
    base="${host%_*}"
    env="${host##*_}"
    ip="$(yq -r ".applications.${base}.environments.${env}.ip // \"\"" \
      "$APPS_CONFIG" 2>/dev/null || true)"
    if [[ -n "$ip" && "$ip" != "null" ]]; then
      echo "$ip"
      return 0
    fi
  fi

  return 1
}

collect_all_nixos_hosts() {
  # Every VM in .vms plus every enabled app × env, deduplicated.
  # Excludes vendor appliances (pbs) that don't run NixOS or don't
  # ship with a NixOS-shape /boot/grub/grub.cfg — matches
  # check-control-plane-drift.sh's collect_all_nixos_hosts exclusion.
  local -a hosts=()
  while IFS= read -r h; do
    [[ -n "$h" ]] && [[ "$h" != "pbs" ]] && hosts+=("$h")
  done < <(yq -r '.vms | keys | .[]' "$CONFIG" 2>/dev/null || true)

  local -a app_hosts=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && app_hosts+=("$line")
  done < <(
    yq -r '.applications // {} | to_entries[]
             | select(.value.enabled == true)
             | .key as $app
             | (.value.environments // {} | keys[]) as $env
             | "\($app)_\($env)"' "$APPS_CONFIG" 2>/dev/null || true
  )

  printf '%s\n' "${hosts[@]}" "${app_hosts[@]}" | awk 'NF' | sort -u
}

collect_hosts() {
  if [[ -n "$SINGLE_HOST" ]]; then
    printf '%s\n' "$SINGLE_HOST"
    return
  fi
  case "$SCOPE" in
    all-nixos)     collect_all_nixos_hosts ;;
    control-plane) "$VM_SCOPE_SCRIPT" control-plane-built-roles ;;
    *) echo "ERROR: unknown scope: $SCOPE" >&2; exit 2 ;;
  esac
}

# Probe run remotely on each VM. Full logic and rationale live in
# framework/scripts/lib/boot-integrity-probe.sh — we read it here and
# pipe over SSH so a single source of truth is exercised by both this
# script's live runs and by tests/test_check_boot_integrity.sh's
# hermetic fixtures.
#
# Delivery pattern (matters for correctness — the shipped bytes and the
# tested bytes must run under the same interpreter):
#   - the probe body is passed as stdin to `bash -s` on the remote
#   - the remote command is `unset ROOT_PREFIX; exec bash -s`
#     (unset defends against an inherited env var leaking into the live
#     check; the shipped test-only hook must never redirect production
#     probing)
# The old pattern `ssh root@ip "$REMOTE_PROBE"` had two subtle problems:
# (1) sshd ran the string through the account's default shell, not the
# `#!/usr/bin/env bash` shebang, so a future bash-ism in the probe would
# pass tests but fail live; (2) the tests' ROOT_PREFIX contract could
# in principle leak into a live run.
PROBE_LIB="${SCRIPT_DIR}/lib/boot-integrity-probe.sh"
if [[ ! -f "$PROBE_LIB" ]]; then
  echo "ERROR: probe library not found: $PROBE_LIB" >&2
  exit 2
fi
REMOTE_PROBE=$(cat "$PROBE_LIB")

HOSTS=()
while IFS= read -r host; do
  [[ -z "$host" ]] && continue
  HOSTS+=("$host")
done < <(collect_hosts)

if [[ "${#HOSTS[@]}" -eq 0 ]]; then
  echo "ERROR: No hosts selected for boot-integrity check" >&2
  exit 2
fi

echo "=== Checking grub.cfg boot-chain integrity ==="
if [[ -n "$SINGLE_HOST" ]]; then
  echo "Scope: single host ($SINGLE_HOST)"
else
  echo "Scope: $SCOPE"
fi
echo ""

BROKEN=0
CHECK_ERROR=0

for host in "${HOSTS[@]}"; do
  ip=""
  if ! ip="$(host_ip "$host")"; then
    # Unresolvable host in a scope that includes it is a config error,
    # not a benign skip. Sibling scripts (check-control-plane-drift.sh)
    # treat this the same way. A typo like `vms.dsn1_prod:` would
    # silently pass otherwise.
    echo "ERROR: ${host} (no IP in config)" >&2
    CHECK_ERROR=1
    continue
  fi

  set +e
  probe_out=$(ssh "${SSH_OPTS[@]}" "root@${ip}" \
    "unset ROOT_PREFIX; exec bash -s" <<< "$REMOTE_PROBE" 2>&1)
  probe_rc=$?
  set -e

  case "$probe_rc" in
    0)
      if [[ -n "$probe_out" ]]; then
        # SKIP: no /boot/grub/grub.cfg
        echo "OK: ${host} (${ip}) — ${probe_out}"
      else
        echo "OK: ${host} (${ip})"
      fi
      ;;
    1)
      echo "BROKEN: ${host} (${ip})"
      # probe_out contains one MISSING: line per broken path
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "  ${line}"
      done <<< "$probe_out"
      BROKEN=1
      ;;
    *)
      echo "ERROR: ${host} (${ip}) — probe exit ${probe_rc}"
      [[ -n "$probe_out" ]] && echo "  ${probe_out}"
      CHECK_ERROR=1
      ;;
  esac
done

echo ""

if [[ "$CHECK_ERROR" -ne 0 ]]; then
  echo "Boot-integrity check incomplete — resolve the errors above and retry." >&2
  exit 2
fi

if [[ "$BROKEN" -ne 0 ]]; then
  echo "grub.cfg references missing paths on at least one VM."
  echo "Recovery: re-run converge-vm.sh (or a full deploy) against the"
  echo "affected VMs so converge_step_closure → converge_fix_grub_paths"
  echo "rewrites grub.cfg through the framework. This is the sanctioned"
  echo "path — see .claude/rules/no-manual-fixes.md."
  echo ""
  echo "If the framework itself cannot converge the affected VM, treat"
  echo "the situation as an incident and follow the RCA process; do not"
  echo "attempt an ad-hoc guest-side edit as a normal recovery step."
  exit 1
fi

echo "All grub.cfg-referenced paths resolve on every checked VM."
