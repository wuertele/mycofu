#!/usr/bin/env bash
# register-runner.sh — Register the GitLab Runner with GitLab.
#
# Reads the runner token from SOPS, SSHs to the runner VM, and registers
# with GitLab. Verifies the runner appears online.
#
# Usage:
#   framework/scripts/register-runner.sh                  # register + verify + deliver secrets
#   framework/scripts/register-runner.sh --verify         # verify only (no mutations)
#   framework/scripts/register-runner.sh --deliver-secrets
#   framework/scripts/register-runner.sh --deliver-secrets --sync-timeout 300
#         # deliver-only: run deliver_runner_secrets() and exit; no
#         # registration or GitLab API calls. Two named consumers
#         # (design taste P1):
#         #   1. Pre-cutover attended delivery before the SPRINT-049 MR-3
#         #      merge, so the runner's /var/lib/mycofu-secrets/age-key
#         #      exists BEFORE the MR pipeline runs sops-decrypting jobs
#         #      (deliver-before-consume — the merge itself recreates
#         #      cicd, and register-runner will re-deliver idempotently
#         #      on the new VM).
#         #   2. DRT-009's M1 rotation leg (ships MR-5): after the M1
#         #      driver rotates the sops_age_key on the workstation, this
#         #      mode re-delivers the new age key to cicd without
#         #      touching the runner's GitLab registration.
#         #   #737: after delivery, the mode triggers cicd's pvesr jobs
#         #      and waits for LastSync to advance past the delivery
#         #      timestamp before reporting "Delivery Complete".
#
# Idempotent: skips registration if runner is already configured.

set -euo pipefail

# --- Locate repo root ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2; exit 1
}

REPO_DIR="$(find_repo_root)"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"
RUNNER_SECRET_DIR="/var/lib/mycofu-secrets"
RUNNER_AGE_KEY_PATH="${RUNNER_SECRET_DIR}/age-key"
RUNNER_SSH_PRIVKEY_PATH="${RUNNER_SECRET_DIR}/framework-deploy-ssh-privkey"
RUNNER_PROBE_CIPHERTEXT_PATH="${RUNNER_SECRET_DIR}/sops-probe-secrets.yaml"
RUNNER_SSH_PRIVKEY_CIPHERTEXT_PATH="${RUNNER_SECRET_DIR}/ssh-privkey-secrets.yaml"
RUNNER_SSH_PRIVKEY_EXTRACT='["ssh_privkey"]'
# DELIVER_SECRETS_SYNC_TIMEOUT — how long to wait for cicd's pvesr LastSync to
# advance past the delivery timestamp on ALL replicated targets.
#
# Derivation (issue #812): cicd is the ~320 GB 24h-cadence VM. Measured job
# durations on the dev cluster were 413s (job 160-0) and 403s (job 160-1) —
# both healthy runs, both taking > 300s. The pre-#812 default of 300s aborted
# DRT-009 G3 attempt 8 AFTER a successful delivery, exactly at the 300s mark,
# with no fault present (register-runner.sh:307-311 timeout hit).
#
# New default 1200s (20 min) = ~3× the measured maximum, matching the "measured
# reality with margin" pattern (issue #812 fix 1). Operators observing longer
# job durations should override with --sync-timeout rather than editing here;
# a persistent lift is a signal to investigate cicd's replication throughput.
DELIVER_SECRETS_SYNC_TIMEOUT=1200

# --- Check prerequisites ---
for tool in yq sops ssh scp curl jq; do
  command -v "$tool" &>/dev/null || { echo "ERROR: $tool not found" >&2; exit 1; }
done

if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "${REPO_DIR}/operator.age.key" ]]; then
  export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
fi

# --- Read config ---
CICD_IP=$(yq -r '.vms.cicd.ip' "$CONFIG_FILE")
CICD_VMID=$(yq -r '.vms.cicd.vmid' "$CONFIG_FILE")
CICD_NODE=$(yq -r '.vms.cicd.node // ""' "$CONFIG_FILE")
GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG_FILE")
BASE_DOMAIN=$(yq -r '.domain' "$CONFIG_FILE")
GITLAB_URL="https://gitlab.prod.${BASE_DOMAIN}"

echo "Runner IP:  $CICD_IP"
echo "GitLab URL: $GITLAB_URL"

# --- SSH helper ---
runner_ssh() {
  ssh -n -o StrictHostKeyChecking=accept-new "root@${CICD_IP}" "$@"
}

runner_scp() {
  scp -q -o StrictHostKeyChecking=accept-new "$@"
}

runner_secret_file_ok() {
  local path="$1"
  runner_ssh "test -s '${path}' && mode_owner=\$(stat -c '%a %U' '${path}') && [ \"\$mode_owner\" = '400 root' ]"
}

verify_runner_secret_file() {
  local dest="$1"
  local label="$2"

  if ! runner_secret_file_ok "$dest"; then
    echo "ERROR: ${label} delivery verification failed at ${dest}" >&2
    return 1
  fi
}

# SPRINT-049 MR-3 persistence probe (G2-verification reboot regression fence):
# assert the delivered file's backing store is a non-ephemeral filesystem.
# `stat -f -c %T` reports the filesystem type at the file's mount point.
# On ext4 it reports "ext2/ext3" (all ext variants share the magic); on
# tmpfs/overlayfs it reports the ephemeral name. If either bad type is
# seen — meaning the gitlab-runner.nix fileSystems bind to
# /nix/persist/mycofu-secrets is not active — FAIL loudly with the exact
# fs type observed. This is the exact defect the bind fixes, ratcheted
# so a future regression (module removed, bind ordering broken) fails
# delivery instead of silently landing on the overlay to be wiped on
# next reboot.
verify_runner_secret_persistent() {
  local dest="$1"
  local label="$2"
  local fs_type
  if ! fs_type=$(runner_ssh "stat -f -c %T '${dest}' 2>/dev/null" 2>/dev/null); then
    echo "ERROR: ${label} persistence probe could not stat ${dest} on cicd" >&2
    return 1
  fi
  case "$fs_type" in
    tmpfs|overlayfs|overlay)
      echo "ERROR: ${label} at ${dest} landed on ephemeral filesystem '${fs_type}' — reboot will wipe it. Expected the gitlab-runner.nix bind-mount to /nix/persist/mycofu-secrets to be active." >&2
      return 1
      ;;
    "")
      echo "ERROR: ${label} at ${dest} — stat returned empty filesystem type" >&2
      return 1
      ;;
    *)
      # ext2/ext3/ext4 all report as "ext2/ext3" via stat -f -c %T. Any
      # non-ephemeral type is accepted; the negative list above is the
      # authority for what's rejected.
      return 0
      ;;
  esac
}

copy_runner_secret_file() {
  local src="$1"
  local dest="$2"
  local label="$3"
  local tmp="${dest}.tmp"

  if [[ ! -f "$src" || ! -s "$src" ]]; then
    echo "ERROR: ${label} source is missing or empty: ${src}" >&2
    return 1
  fi

  runner_ssh "mkdir -p '${RUNNER_SECRET_DIR}' && chmod 700 '${RUNNER_SECRET_DIR}' && rm -f '${tmp}'"
  runner_scp "$src" "root@${CICD_IP}:${tmp}"
  runner_ssh "install -o root -g root -m 0400 '${tmp}' '${dest}' && rm -f '${tmp}'"
  verify_runner_secret_file "$dest" "$label"
  echo "  Delivered ${label} to ${dest}"
}

probe_runner_age_key_decrypt() {
  runner_scp "$SECRETS_FILE" "root@${CICD_IP}:${RUNNER_PROBE_CIPHERTEXT_PATH}"
  if runner_ssh "SOPS_AGE_KEY_FILE='${RUNNER_AGE_KEY_PATH}' sops -d '${RUNNER_PROBE_CIPHERTEXT_PATH}' >/dev/null; rc=\$?; rm -f '${RUNNER_PROBE_CIPHERTEXT_PATH}'; exit \$rc"; then
    return 0
  fi
  runner_ssh "rm -f '${RUNNER_PROBE_CIPHERTEXT_PATH}'" 2>/dev/null || true
  return 1
}

probe_runner_age_key() {
  if probe_runner_age_key_decrypt; then
    echo "  Delivered age-key to ${RUNNER_AGE_KEY_PATH} (probe OK)"
    return 0
  fi
  echo "ERROR: Delivered age-key failed SOPS decrypt probe on cicd" >&2
  return 1
}

deliver_framework_deploy_ssh_privkey() {
  runner_ssh "mkdir -p '${RUNNER_SECRET_DIR}' && chmod 700 '${RUNNER_SECRET_DIR}' && rm -f '${RUNNER_SSH_PRIVKEY_CIPHERTEXT_PATH}'"
  if ! runner_scp "$SECRETS_FILE" "root@${CICD_IP}:${RUNNER_SSH_PRIVKEY_CIPHERTEXT_PATH}"; then
    runner_ssh "rm -f '${RUNNER_SSH_PRIVKEY_CIPHERTEXT_PATH}'" 2>/dev/null || true
    echo "ERROR: Could not copy framework deploy ssh-privkey ciphertext to cicd" >&2
    return 1
  fi
  if ! runner_ssh "tmp='/tmp/mycofu-runner-ssh-privkey.'\$\$ && trap 'rm -f \"\$tmp\" \"${RUNNER_SSH_PRIVKEY_CIPHERTEXT_PATH}\"' EXIT && SOPS_AGE_KEY_FILE='${RUNNER_AGE_KEY_PATH}' sops -d --extract '${RUNNER_SSH_PRIVKEY_EXTRACT}' '${RUNNER_SSH_PRIVKEY_CIPHERTEXT_PATH}' > \"\$tmp\" && test -s \"\$tmp\" && install -o root -g root -m 0400 \"\$tmp\" '${RUNNER_SSH_PRIVKEY_PATH}'"; then
    runner_ssh "rm -f '${RUNNER_SSH_PRIVKEY_CIPHERTEXT_PATH}' /tmp/mycofu-runner-ssh-privkey.*" 2>/dev/null || true
    echo "ERROR: framework deploy ssh-privkey remote decrypt/install failed" >&2
    return 1
  fi
  verify_runner_secret_file "$RUNNER_SSH_PRIVKEY_PATH" "framework deploy ssh-privkey"
  echo "  Delivered framework deploy ssh-privkey to ${RUNNER_SSH_PRIVKEY_PATH}"
}

deliver_runner_secrets() {
  local delivery_start_epoch
  delivery_start_epoch="$(date +%s)"
  echo ""
  echo "=== Step 1.7: Deliver runner secrets ==="
  copy_runner_secret_file "${SOPS_AGE_KEY_FILE:-}" "$RUNNER_AGE_KEY_PATH" "age-key"
  probe_runner_age_key
  deliver_framework_deploy_ssh_privkey
  # Persistence ratchet — fails closed on the G2-verification defect class
  # (files land on overlay tmpfs and are wiped by the next reboot). Runs
  # AFTER install/verify so a bind-mount regression is caught before the
  # runner service is restarted with the doomed state.
  verify_runner_secret_persistent "$RUNNER_AGE_KEY_PATH" "age-key"
  verify_runner_secret_persistent "$RUNNER_SSH_PRIVKEY_PATH" "framework deploy ssh-privkey"
  runner_ssh "systemctl restart gitlab-runner-ssh-setup"
  # Issue #737 sync gate belongs to the delivery primitive so both
  # --deliver-secrets and full register mode close the stale-replica window.
  wait_for_runner_secret_replication "$delivery_start_epoch" "$DELIVER_SECRETS_SYNC_TIMEOUT"
  echo "  Runner secret delivery complete"
}

node_ip_for_name() {
  local node_name="$1"
  yq -r ".nodes[] | select(.name == \"${node_name}\") | .mgmt_ip" "$CONFIG_FILE"
}

timestamp_to_epoch() {
  local stamp="$1"
  local normalized="${stamp//_/ }"
  if date -d "$normalized" +%s >/dev/null 2>&1; then
    date -d "$normalized" +%s
    return 0
  fi
  if date -j -f '%Y-%m-%d %H:%M:%S' "$normalized" +%s >/dev/null 2>&1; then
    date -j -f '%Y-%m-%d %H:%M:%S' "$normalized" +%s
    return 0
  fi
  python3 - "$normalized" <<'PY'
import datetime
import sys

value = sys.argv[1]
try:
    dt = datetime.datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
except ValueError:
    raise SystemExit(1)
print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))
PY
}

cicd_replication_rows() {
  local source_ip="$1"
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${source_ip}" "pvesr status 2>/dev/null" 2>/dev/null \
    | awk -v vmid="${CICD_VMID}" 'NR == 1 && /^JobID/ {next} $1 ~ ("^" vmid "-") {
        state=""; for (i=8;i<=NF;i++) state=state (i>8?" ":"") $i;
        printf "%s\t%s\t%s\t%s\n", $1, $3, $4, $7
      }'
}

wait_for_runner_secret_replication() {
  local delivery_epoch="$1"
  local timeout="$2"
  local source_ip rows jobs_file start_epoch now_epoch unsynced job_id target last_sync fail_count last_epoch
  local poll_interval="${SYNC_POLL_INTERVAL:-5}"
  # SYNC_POLL_INTERVAL is an env-var override (default 5s) so hermetic fixtures
  # can shrink the wall-clock cost of the timeout-wait fixture in
  # tests/test_register_runner_secret_delivery.sh without changing production
  # behavior. Not a public flag — no CLI surface, no config field.

  if [[ -z "${CICD_VMID:-}" || "$CICD_VMID" == "null" || -z "${CICD_NODE:-}" || "$CICD_NODE" == "null" ]]; then
    echo "ERROR: cicd VMID/node missing from ${CONFIG_FILE}; cannot verify secret replication" >&2
    return 1
  fi
  source_ip="$(node_ip_for_name "$CICD_NODE")"
  if [[ -z "$source_ip" || "$source_ip" == "null" ]]; then
    echo "ERROR: cannot resolve Proxmox node IP for cicd host ${CICD_NODE}" >&2
    return 1
  fi

  rows="$(cicd_replication_rows "$source_ip" || true)"
  if [[ -z "$rows" ]]; then
    echo "ERROR: no pvesr jobs found for cicd VMID ${CICD_VMID} on ${CICD_NODE}" >&2
    return 1
  fi

  jobs_file="$(mktemp "${TMPDIR:-/tmp}/runner-secret-repl-jobs.XXXXXX")"
  printf '%s\n' "$rows" > "$jobs_file"
  echo "  cicd replication jobs carrying /nix/persist:"
  while IFS=$'\t' read -r job_id target last_sync fail_count; do
    [[ -n "$job_id" ]] || continue
    echo "    ${job_id}: source=${CICD_NODE} target=${target} LastSync=${last_sync} FailCount=${fail_count}"
    ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${source_ip}" "pvesr schedule-now ${job_id}" >/dev/null
  done < "$jobs_file"

  # Snapshot the INITIAL LastSync per job (from `jobs_file`, which is the
  # pre-loop pvesr status fetch). The timeout classifier compares the last
  # observed LastSync against this initial value — the ONLY reliable proxy
  # for "job actually advanced during our wait window" (codex R1 finding:
  # pre-fix classifier used "has any real LastSync value" which is true
  # even for a stale historical timestamp that never advanced).
  # File-backed for bash 3.2 compat: format `<job_id>\t<initial_last_sync>`.
  initial_last_sync_file="$(mktemp "${TMPDIR:-/tmp}/runner-secret-repl-initsnap.XXXXXX")"
  while IFS=$'\t' read -r _init_jid _init_target _init_ls _init_fc; do
    [[ -n "$_init_jid" ]] || continue
    printf '%s\t%s\n' "$_init_jid" "$_init_ls" >> "$initial_last_sync_file"
  done < "$jobs_file"

  # last_status_file accumulates the most recent per-job snapshot so the
  # timeout diagnostic (issue #812 fix 3) can distinguish three cases the
  # pre-#812 message conflated:
  #   - "did not advance" (LastSync unchanged since the wait started, or
  #     still `-`) → possible replication fault worth investigating.
  #   - "advancing but slower than --sync-timeout" (LastSync's numeric
  #     value differs from the initial snapshot, no FailCount>0 seen)
  #     → healthy replica behind budget; raise --sync-timeout.
  #   - "reported failures" (any FailCount>0 in the last observation)
  #     → replication fault at the pvesr layer (agy P2-1 finding).
  # File-backed rather than in-memory (declare -A) so this stays compatible
  # with the bash 3.2 that ships on the operator's macOS workstation — the
  # framework's coding standard (see enable-app.sh:119 comment).
  # Format: one line per job — `<job_id>\ttarget=<t> LastSync=<ls> FailCount=<fc>`
  last_status_file="$(mktemp "${TMPDIR:-/tmp}/runner-secret-repl-lastsnap.XXXXXX")"
  start_epoch="$(date +%s)"
  while true; do
    unsynced=0
    rows="$(cicd_replication_rows "$source_ip" || true)"
    : > "$last_status_file"
    while IFS=$'\t' read -r job_id target _initial_last _initial_fail; do
      [[ -n "$job_id" ]] || continue
      line="$(awk -F'\t' -v id="$job_id" '$1 == id {print; found=1; exit} END {if (!found) exit 1}' <<< "$rows" || true)"
      if [[ -z "$line" ]]; then
        unsynced=$((unsynced + 1))
        printf '%s\ttarget=%s LastSync=<missing> FailCount=<missing>\n' "$job_id" "$target" >> "$last_status_file"
        continue
      fi
      last_sync="$(awk -F'\t' '{print $3}' <<< "$line")"
      fail_count="$(awk -F'\t' '{print $4}' <<< "$line")"
      printf '%s\ttarget=%s LastSync=%s FailCount=%s\n' "$job_id" "$target" "$last_sync" "$fail_count" >> "$last_status_file"
      if [[ "$last_sync" == "-" || -z "$last_sync" || ! "$fail_count" =~ ^0+$ ]]; then
        unsynced=$((unsynced + 1))
        continue
      fi
      last_epoch="$(timestamp_to_epoch "$last_sync" 2>/dev/null || echo 0)"
      if [[ ! "$last_epoch" =~ ^[0-9]+$ || "$last_epoch" -le "$delivery_epoch" ]]; then
        unsynced=$((unsynced + 1))
      fi
    done < "$jobs_file"

    if [[ "$unsynced" -eq 0 ]]; then
      rm -f "$jobs_file" "$last_status_file" "$initial_last_sync_file"
      echo "  cicd secret delivery replication sync complete after $(( $(date +%s) - start_epoch ))s"
      return 0
    fi
    now_epoch="$(date +%s)"
    if [[ $((now_epoch - start_epoch)) -ge "$timeout" ]]; then
      local elapsed=$((now_epoch - start_epoch))
      local any_advanced=0 any_stuck=0 any_failing=0
      # Classify each still-unsynced job. Codex R1 finding: pre-R1 logic
      # used "has any real LastSync value" as the advancement proxy, which
      # falsely reports advancement for a job whose LastSync is old and
      # unchanged. Correct proxy: compare CURRENT LastSync against the
      # value captured at wait start (initial_last_sync_file).
      # Agy P2-1: nonzero FailCount is fault evidence and must override
      # the "advancing" classification.
      local jid target ls fc initial
      while IFS=$'\t' read -r jid status; do
        [[ -n "$jid" ]] || continue
        target="$(echo "$status" | sed -n 's/^target=\([^ ]*\).*/\1/p')"
        ls="$(echo "$status" | sed -n 's/.*LastSync=\([^ ]*\).*/\1/p')"
        fc="$(echo "$status" | sed -n 's/.*FailCount=\([^ ]*\).*/\1/p')"
        # Nonzero FailCount (numeric) always flags a fault, even if the
        # LastSync advanced. FailCount=0 or `<missing>` is not a fault.
        if [[ "$fc" =~ ^[0-9]+$ && "$fc" -gt 0 ]]; then
          any_failing=1
          continue
        fi
        # Not advanced if LastSync is `-`, missing, or byte-equal to the
        # initial value we captured at wait start.
        initial="$(awk -F'\t' -v id="$jid" '$1 == id {print $2; exit}' "$initial_last_sync_file")"
        if [[ "$ls" == "-" || "$ls" == "<missing>" || "$ls" == "$initial" ]]; then
          any_stuck=1
          continue
        fi
        # LastSync changed from initial — genuine advancement within the
        # wait window, but not yet past delivery_epoch (that's why we're
        # still in the unsynced branch).
        any_advanced=1
      done < "$last_status_file"
      local classification
      if [[ "$any_failing" -eq 1 ]]; then
        classification="one or more jobs reported FailCount>0 (replication fault — check pvesr status / journalctl on the source node)"
      elif [[ "$any_stuck" -eq 1 && "$any_advanced" -eq 0 ]]; then
        classification="jobs did not advance since the wait started (possible replication fault — check pvesr status / journalctl on the source node)"
      elif [[ "$any_advanced" -eq 1 && "$any_stuck" -eq 0 ]]; then
        classification="jobs are advancing but slower than --sync-timeout (healthy replica behind budget; consider raising --sync-timeout above measured job duration)"
      else
        classification="mixed — some jobs advancing, some not (inspect each job below)"
      fi
      echo "ERROR: cicd secret delivery replication did not sync within timeout" >&2
      echo "  measured elapsed=${elapsed}s  timeout=${timeout}s  poll_interval=${poll_interval}s  delivery_epoch=${delivery_epoch}" >&2
      echo "  classification: ${classification}" >&2
      echo "  last observed per-job status:" >&2
      while IFS=$'\t' read -r jid status; do
        [[ -n "$jid" ]] || continue
        initial="$(awk -F'\t' -v id="$jid" '$1 == id {print $2; exit}' "$initial_last_sync_file")"
        echo "    ${jid}: ${status}  initial_LastSync=${initial}" >&2
      done < "$last_status_file"
      rm -f "$jobs_file" "$last_status_file" "$initial_last_sync_file"
      return 1
    fi
    sleep "$poll_interval"
  done
}

MODE="register"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      MODE="verify"
      shift
      ;;
    --deliver-secrets)
      MODE="deliver-secrets"
      shift
      ;;
    --sync-timeout)
      DELIVER_SECRETS_SYNC_TIMEOUT="$2"
      shift 2
      ;;
    --sync-timeout=*)
      DELIVER_SECRETS_SYNC_TIMEOUT="${1#--sync-timeout=}"
      shift
      ;;
    "")
      shift
      ;;
    *)
      echo "ERROR: unknown flag '$1' (see script header for usage)" >&2
      exit 2
      ;;
  esac
done

if [[ ! "$DELIVER_SECRETS_SYNC_TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --sync-timeout must be an integer number of seconds" >&2
  exit 2
fi

if [[ "$MODE" == "deliver-secrets" ]]; then
  # Deliver-only path (see script header). Runs the delivery step against a
  # runner VM whose GitLab registration may already exist; must not touch
  # GitLab API, must not read the SOPS runner token, must not restart the
  # gitlab-runner service — only the ssh-setup unit that consumes the new
  # secret paths. Fail-closed: any failure inside deliver_runner_secrets()
  # propagates via `set -euo pipefail`.
  echo "=== register-runner.sh --deliver-secrets ==="
  echo "  Target: cicd VM at ${CICD_IP}"
  deliver_runner_secrets
  echo ""
  echo "=== Delivery Complete ==="
  exit 0
fi

if [[ "$MODE" == "verify" ]]; then
  echo ""
  echo "=== Verification ==="
  PASS=0; FAIL=0

  # 1. Runner VM accessible
  echo -n "  Runner SSH accessible: "
  if runner_ssh "true" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi

  # 2. Runner registered
  echo -n "  Runner config exists:  "
  if runner_ssh "test -f /etc/gitlab-runner/config.toml" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi

  # 3. Runner service running
  echo -n "  Runner service active: "
  if runner_ssh "systemctl is-active gitlab-runner" 2>/dev/null | grep -q active; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi

  # 4. Tools available
  echo -n "  Build tools present:   "
  if runner_ssh "nix --version && tofu version && sops --version" &>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi

  # 5. Persistent age key
  echo -n "  Persistent age-key:   "
  if runner_secret_file_ok "$RUNNER_AGE_KEY_PATH" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi

  # 6. Persistent framework deploy private key
  echo -n "  Persistent SSH key:   "
  if runner_secret_file_ok "$RUNNER_SSH_PRIVKEY_PATH" 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi

  # 7. Delivered age key can decrypt the SOPS ciphertext on cicd
  echo -n "  Age-key decrypt probe: "
  if probe_runner_age_key_decrypt 2>/dev/null; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi

  # 8. Persistent-backing-store probe (SPRINT-049 MR-3 G2-verification fence):
  #    if either persistent secret file's mount is overlay tmpfs, the next
  #    reboot wipes it. --verify must catch that regression.
  echo -n "  Persistent age-key backing:  "
  if verify_runner_secret_persistent "$RUNNER_AGE_KEY_PATH" "age-key" >/dev/null 2>&1; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi
  echo -n "  Persistent SSH key backing:  "
  if verify_runner_secret_persistent "$RUNNER_SSH_PRIVKEY_PATH" "framework deploy ssh-privkey" >/dev/null 2>&1; then
    echo "PASS"; PASS=$((PASS + 1))
  else
    echo "FAIL"; FAIL=$((FAIL + 1))
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

# --- Register mode ---

# --- GitLab API helper ---
gitlab_api_token() {
  local root_pw
  root_pw=$(sops -d --extract '["gitlab_root_password"]' "$SECRETS_FILE" 2>/dev/null || true)
  [[ -z "$root_pw" ]] && return 1
  curl -sk -X POST "${GITLAB_URL}/oauth/token" \
    -d "grant_type=password&username=root&password=${root_pw}" 2>/dev/null \
    | jq -r '.access_token // empty'
}

# Read runner token from SOPS
RUNNER_TOKEN=$(sops -d --extract '["gitlab_runner_registration_token"]' "$SECRETS_FILE" 2>/dev/null || true)
if [[ -z "$RUNNER_TOKEN" ]]; then
  echo "ERROR: No runner registration token in SOPS" >&2
  echo "Run configure-gitlab.sh first to generate the token." >&2
  exit 1
fi

# Check if already registered
echo ""
echo "=== Step 1: Check registration ==="
SKIP_REGISTRATION=false
if runner_ssh "test -f /etc/gitlab-runner/config.toml && grep -q token /etc/gitlab-runner/config.toml" 2>/dev/null; then
  # Verify the token is actually accepted by GitLab
  EXISTING_TOKEN=$(runner_ssh "grep 'token = ' /etc/gitlab-runner/config.toml | head -1 | sed 's/.*token = \"//;s/\"//' " 2>/dev/null || true)
  VERIFY_RESULT=$(curl -sk --tls-max 1.2 -X POST "${GITLAB_URL}/api/v4/runners/verify" -F "token=${EXISTING_TOKEN}" 2>/dev/null)
  if echo "$VERIFY_RESULT" | jq -e '.id' &>/dev/null; then
    echo "  Runner already registered — skipping"
    SKIP_REGISTRATION=true
  else
    echo "  config.toml exists but token is rejected by GitLab — removing stale config"
    runner_ssh "rm -f /etc/gitlab-runner/config.toml" 2>/dev/null
  fi
fi

if [[ "$SKIP_REGISTRATION" == "true" ]]; then
  : # skip to TLS trust step
else
  echo "  Registering runner..."

  # The runner uses the system CA bundle for TLS trust (no pinned cert).
  # The system bundle includes ISRG Root X1 (Let's Encrypt) and, on dev
  # VMs, the step-ca root (added by extra-ca-bundle service). This
  # eliminates stale trust when GitLab's cert changes.
  runner_ssh "mkdir -p /etc/gitlab-runner"

  # Build registration command helper
  build_register_cmd() {
    local token="$1"
    echo "GITLAB_RUNNER=\$(which gitlab-runner 2>/dev/null || find /nix/store -maxdepth 3 -name gitlab-runner -type f 2>/dev/null | head -1) && \
      \$GITLAB_RUNNER register \
      --non-interactive \
      --url '${GITLAB_URL}' \
      --token '${token}' \
      --executor shell"
  }

  REGISTER_OUTPUT=$(runner_ssh "$(build_register_cmd "$RUNNER_TOKEN")" 2>&1) || true
  echo "$REGISTER_OUTPUT"

  if echo "$REGISTER_OUTPUT" | grep -q "is valid"; then
    : # Success — fall through to "Runner registered"
  elif echo "$REGISTER_OUTPUT" | grep -q "is not valid"; then
    # Token rejected by GitLab — stale token (PBS restore or already consumed).
    # Delete stale runners, create fresh registration, retry.
    echo "  SOPS token rejected by GitLab — recovering..."
    ACCESS_TOKEN=$(gitlab_api_token)
    if [[ -z "$ACCESS_TOKEN" ]]; then
      echo "ERROR: Cannot authenticate to GitLab API for runner recovery" >&2
      exit 1
    fi

    # Delete all existing runners (stale from PBS restore)
    STALE_IDS=$(curl -sk -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${GITLAB_URL}/api/v4/runners/all" 2>/dev/null | jq -r '.[].id')
    for rid in $STALE_IDS; do
      echo "  Deleting stale runner ID ${rid}..."
      curl -sk -X DELETE -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${GITLAB_URL}/api/v4/runners/${rid}" 2>/dev/null
    done

    # Create a fresh runner registration token
    echo "  Creating fresh runner registration..."
    RUNNER_RESPONSE=$(curl -sk -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"runner_type": "instance_type", "tag_list": ["infra", "deploy"], "description": "Infrastructure runner"}' \
      "${GITLAB_URL}/api/v4/user/runners" 2>/dev/null)
    RUNNER_TOKEN=$(echo "$RUNNER_RESPONSE" | jq -r '.token // empty')
    if [[ -z "$RUNNER_TOKEN" ]]; then
      echo "ERROR: Failed to create runner. Response:" >&2
      echo "$RUNNER_RESPONSE" | jq . >&2
      exit 1
    fi

    # Update SOPS with the new token
    sops --set "[\"gitlab_runner_registration_token\"] \"${RUNNER_TOKEN}\"" "$SECRETS_FILE"
    echo "  Fresh token stored in SOPS"

    # Retry registration with the new token
    if ! runner_ssh "$(build_register_cmd "$RUNNER_TOKEN")" 2>&1; then
      echo "ERROR: Registration failed even with fresh token" >&2
      exit 1
    fi
  else
    # Unknown failure (not a token issue)
    echo "ERROR: Runner registration failed unexpectedly" >&2
    echo "$REGISTER_OUTPUT" >&2
    exit 1
  fi
  echo "  Runner registered"
fi

# Remove any legacy pinned CA cert from config.toml. The runner now uses
# the system CA bundle (see comment in registration section above).
if runner_ssh "grep -q 'tls-ca-file' /etc/gitlab-runner/config.toml" 2>/dev/null; then
  runner_ssh "sed -i '/tls-ca-file/d' /etc/gitlab-runner/config.toml"
  echo "  Removed legacy tls-ca-file from config.toml (using system CA bundle)"
fi

# Set builds_dir to /nix/var/gitlab-runner/builds so CI builds use the
# real ext4 partition instead of the overlay tmpfs. Without this, image
# builds exhaust the 256MB overlay.
if ! runner_ssh "grep -q 'builds_dir' /etc/gitlab-runner/config.toml" 2>/dev/null; then
  runner_ssh "sed -i '/^\[\[runners\]\]/a\\  builds_dir = \"/nix/var/gitlab-runner/builds\"' /etc/gitlab-runner/config.toml"
  echo "  Set builds_dir to /nix/var/gitlab-runner/builds (overlay-root safe)"
fi

# Set NIX_CONFIG so nix sandbox builds also use the ext4 partition.
# On overlay-root VMs, /etc/nix/nix.conf is a symlink to the nix store —
# writing to it corrupts the immutable store path. NIX_CONFIG via the
# runner environment is the safe way to override nix settings at runtime.
if ! runner_ssh "grep -q 'NIX_CONFIG' /etc/gitlab-runner/config.toml" 2>/dev/null; then
  runner_ssh "sed -i '/^\[\[runners\]\]/a\\  environment = [\"NIX_CONFIG=build-dir = /nix/tmp\"]' /etc/gitlab-runner/config.toml"
  echo "  Set NIX_CONFIG=build-dir for overlay-root nix sandbox builds"
fi

echo ""
echo "=== Step 1.5: Wait for runner concurrency normalization ==="
WAIT=0
TIMEOUT=30
while [[ $WAIT -lt $TIMEOUT ]]; do
  # The budget service owns `concurrent` now. At the balloon floor a
  # survivor legitimately serializes to 1, so the old exact-8 assertion would
  # fail healthy registrations. Convergence is a valid top-level budget value.
  OBSERVED_CONCURRENT="$(runner_ssh "head -1 /etc/gitlab-runner/config.toml | sed -n 's/^concurrent = \([0-9][0-9]*\)$/\1/p'" 2>/dev/null || true)"
  if [[ "$OBSERVED_CONCURRENT" =~ ^[0-9]+$ ]] && [[ "$OBSERVED_CONCURRENT" -ge 1 ]] && [[ "$OBSERVED_CONCURRENT" -le 16 ]]; then
    echo "  Concurrent budget value observed: concurrent = ${OBSERVED_CONCURRENT}"
    break
  fi
  sleep 1
  WAIT=$((WAIT + 1))
done
if [[ $WAIT -ge $TIMEOUT ]]; then
  echo "ERROR: /etc/gitlab-runner/config.toml did not converge to a top-level concurrent value in 1..16 within ${TIMEOUT}s" >&2
  runner_ssh "head -5 /etc/gitlab-runner/config.toml" >&2 || true
  exit 1
fi

# Persist config.toml to /nix/persist so it survives overlay reboots.
# The gitlab-runner-restore-config service copies it back on boot.
if runner_ssh "test -d /nix/persist/gitlab-runner" 2>/dev/null; then
  runner_ssh "cp /etc/gitlab-runner/config.toml /nix/persist/gitlab-runner/config.toml"
  echo "  Config persisted to /nix/persist/gitlab-runner/"
fi

deliver_runner_secrets

# Start/restart the runner service
echo ""
echo "=== Step 2: Start runner service ==="
runner_ssh "systemctl restart gitlab-runner" 2>/dev/null || true
sleep 2

if runner_ssh "systemctl is-active gitlab-runner" 2>/dev/null | grep -q active; then
  echo "  Runner service is active"
else
  echo "  ERROR: Runner service is not active" >&2
  runner_ssh "journalctl -u gitlab-runner --no-pager -n 20" 2>/dev/null || true
  exit 1
fi

# Verify runner is online in GitLab
echo ""
echo "=== Step 3: Verify runner in GitLab ==="
ROOT_PASSWORD=$(sops -d --extract '["gitlab_root_password"]' "$SECRETS_FILE" 2>/dev/null || true)
if [[ -n "$ROOT_PASSWORD" ]]; then
  # Obtain OAuth token (GitLab API requires token auth, not raw password)
  OAUTH_RESPONSE=$(curl -sk -X POST "${GITLAB_URL}/oauth/token" \
    -d "grant_type=password&username=root&password=${ROOT_PASSWORD}" 2>/dev/null)
  ACCESS_TOKEN=$(echo "$OAUTH_RESPONSE" | jq -r '.access_token // empty')
  if [[ -n "$ACCESS_TOKEN" ]]; then
    RUNNERS=$(curl -sk -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${GITLAB_URL}/api/v4/runners/all" 2>/dev/null)
    ONLINE=$(echo "$RUNNERS" | jq -r '[.[] | select(.status == "online")] | length')
    echo "  Online runners: $ONLINE"
    echo "$RUNNERS" | jq -r '.[] | "  - ID: \(.id), Status: \(.status), Tags: \(.tag_list // [] | join(","))"'
    if [[ "$ONLINE" -eq 0 ]]; then
      echo "  ERROR: No runners online in GitLab — pipeline jobs will not execute" >&2
      exit 1
    fi
  else
    echo "  WARNING: Cannot verify (OAuth token request failed) — runner may not be online"
  fi
else
  echo "  WARNING: Cannot verify (no root password in SOPS) — runner may not be online"
fi

echo ""
echo "=== Registration Complete ==="
