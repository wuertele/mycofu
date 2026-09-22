#!/usr/bin/env bash
# probe-m1-holder-decrypt.sh — Per-holder decrypt probe for the M1 SOPS age
# recipient rotation.
#
# Called by DRT-009 `run_m1_holder_probes`. Reads DRT009_HOLDER_NAME and
# DRT009_HOLDER_DELIVERY (set by the caller) and asserts the holder can
# decrypt site/sops/secrets.yaml using the age key at THAT holder's
# delivered location — the same path the runtime consumer will use.
#
# Why not `recover-secrets.sh` (the pre-#813 M1 probe): recover-secrets.sh
# is a git-history recovery helper that NO-OPs when secrets.yaml exists
# (framework/scripts/recover-secrets.sh:35-38). It never touched the age
# key on either holder, so it was a false-green in every DRT-009 attempt.
# Codex RCA of G3 attempt 8 called this out; #813 defect 2 tracks the fix.
#
# Path contract:
#   workstation:local-file   → ${REPO_DIR}/operator.age.key (canonical)
#   cicd:register-runner     → /var/lib/mycofu-secrets/age-key on cicd via SSH
# Anything else fails closed — the caller (DRT-009) is expected to run us
# once per holder row in the M1 manifest entry; unknown holders are the
# rotation manifest gaining a new holder without probe support.
#
# The probe is a WHOLE-FILE `sops -d` on secrets.yaml. Per the V2.7
# prove-negative-redirection ratchet (tests/test_rotate_scripts_path_only.sh),
# whole-file decrypts MUST redirect stdout to /dev/null so accidental success
# doesn't dump cleartext into the caller's log capture. Both paths below do.

set -euo pipefail

find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: probe-m1-holder-decrypt: could not find repo root" >&2
  exit 1
}

REPO_DIR="${PROBE_M1_REPO_DIR:-$(find_repo_root)}"
SECRETS_FILE="${PROBE_M1_SECRETS_FILE:-${REPO_DIR}/site/sops/secrets.yaml}"
CONFIG_FILE="${PROBE_M1_CONFIG_FILE:-${REPO_DIR}/site/config.yaml}"
CANONICAL_KEY_PATH="${PROBE_M1_CANONICAL_KEY_PATH:-${REPO_DIR}/operator.age.key}"
CICD_AGE_KEY_PATH="${PROBE_M1_CICD_AGE_KEY_PATH:-/var/lib/mycofu-secrets/age-key}"

holder="${DRT009_HOLDER_NAME:-}"
delivery="${DRT009_HOLDER_DELIVERY:-}"

if [[ -z "$holder" || -z "$delivery" ]]; then
  echo "ERROR: probe-m1-holder-decrypt: DRT009_HOLDER_NAME and DRT009_HOLDER_DELIVERY must be set" >&2
  exit 1
fi

for tool in sops yq ssh scp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: probe-m1-holder-decrypt: required tool not found: ${tool}" >&2
    exit 1
  fi
done

if [[ ! -r "$SECRETS_FILE" ]]; then
  echo "ERROR: probe-m1-holder-decrypt: SOPS ciphertext not readable: ${SECRETS_FILE}" >&2
  exit 1
fi

case "${holder}:${delivery}" in
  workstation:local-file)
    if [[ ! -s "$CANONICAL_KEY_PATH" ]]; then
      echo "ERROR: probe-m1-holder-decrypt: workstation age key missing at ${CANONICAL_KEY_PATH}" >&2
      exit 1
    fi
    if ! SOPS_AGE_KEY_FILE="$CANONICAL_KEY_PATH" sops -d "$SECRETS_FILE" >/dev/null 2>&1; then
      echo "ERROR: probe-m1-holder-decrypt: workstation key at ${CANONICAL_KEY_PATH} cannot decrypt ${SECRETS_FILE}" >&2
      exit 1
    fi
    ;;
  cicd:register-runner)
    if [[ ! -r "$CONFIG_FILE" ]]; then
      echo "ERROR: probe-m1-holder-decrypt: site config not readable: ${CONFIG_FILE}" >&2
      exit 1
    fi
    cicd_ip="$(yq -r '.vms.cicd.ip // ""' "$CONFIG_FILE" 2>/dev/null || printf '')"
    if [[ -z "$cicd_ip" || "$cicd_ip" == "null" ]]; then
      echo "ERROR: probe-m1-holder-decrypt: cicd IP missing from ${CONFIG_FILE}" >&2
      exit 1
    fi
    # SCP the ciphertext to a per-run temp path on cicd, decrypt with the
    # DELIVERED key at CICD_AGE_KEY_PATH, then clean up. Stdout of `sops -d`
    # goes to /dev/null (V2.7 prove-negative-redirection). Exit code is
    # propagated back so ssh returns non-zero on decrypt failure, and the
    # cleanup step still runs via `trap` inside the ssh command.
    remote_tmp="/tmp/mycofu-probe-m1-decrypt.$$.yaml"
    if ! scp -q -o StrictHostKeyChecking=accept-new "$SECRETS_FILE" "root@${cicd_ip}:${remote_tmp}" >/dev/null 2>&1; then
      echo "ERROR: probe-m1-holder-decrypt: could not scp ciphertext to cicd ${cicd_ip}" >&2
      exit 1
    fi
    if ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
         "root@${cicd_ip}" \
         "trap 'rm -f ${remote_tmp}' EXIT; SOPS_AGE_KEY_FILE='${CICD_AGE_KEY_PATH}' sops -d '${remote_tmp}' >/dev/null 2>&1"; then
      # Best-effort cleanup on the remote in case the connection failed
      # BEFORE the remote trap fired (e.g. TCP reset during handshake).
      # A second ssh may also fail, in which case the ciphertext lingers
      # in /tmp until cicd's next tmp reaper — acceptable, still tries.
      ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "root@${cicd_ip}" "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
      echo "ERROR: probe-m1-holder-decrypt: cicd holder cannot decrypt ${SECRETS_FILE} with delivered key at ${CICD_AGE_KEY_PATH}" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: probe-m1-holder-decrypt: unsupported holder/delivery: ${holder}:${delivery}" >&2
    echo "  Add a case here (framework/scripts/probe-m1-holder-decrypt.sh) when a new M1 holder ships." >&2
    exit 1
    ;;
esac
