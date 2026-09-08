#!/usr/bin/env bash
# verify-vault-reload.sh — operator-executed real-conditions verification of
# the #642 vault.service ExecReload fix.
#
# Drives a FORCED renewal through the deployed certbot-renew.service on a
# target Vault VM, then verifies:
#
#   1. certbot-renew.service exited 0 (renewal completed)
#   2. The on-disk cert serial changed (new certificate was written)
#   3. Vault's MainPID is unchanged (reload, not restart)
#   4. Vault is still unsealed
#   5. The SERVED cert serial (openssl s_client) polled from
#      https://<vault-ip>:8200 changed to match the new on-disk serial
#      — SIGHUP reload is asynchronous, so we poll until a bounded
#      deadline
#
# (5) is the load-bearing check: exit codes alone cannot prove the reload
# actually happened. Prior to the #642 fix, the deploy hook's
# `systemctl reload vault.service` reported non-zero, certbot ate the
# error, and the served cert stayed frozen — the exact class of failure
# this script exists to detect.
#
# Safety
# ------
# * Requires --env {dev|prod} explicitly. No default.
# * Prod requires --yes-i-mean-prod. A forced renewal on prod consumes one
#   Let's Encrypt duplicate-certificate quota unit (limit: 5/week per
#   hostname). Dev uses step-ca and has no such quota.
# * Refuses to run against a vault VM whose deployed ExecReload does NOT
#   match the #642 fix — running against a stale image would just
#   reproduce the bug and mislead the operator.
# * --dry-run prints the plan without touching the target VM.
#
# See docs/reports/rca-2026-07-18-vault-execreload-access-denied.md for
# the underlying failure model.

set -euo pipefail

# --- Repo locator (same pattern as other framework scripts) ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2
  exit 1
}

REPO_DIR="$(find_repo_root)"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"

# --- Args ---
ENV=""
CONFIRM_PROD=false
DRY_RUN=false
POLL_TIMEOUT=120      # seconds to poll for the SERVED cert serial to change
# Wall-clock budget for the forced DNS-01 renewal itself to complete. DNS-01
# is dominated by propagation sleep + ACME validation polling and takes
# minutes in this environment (measured: ~5-6 min dev, ~400s prod — #679), so
# this is deliberately separate from and much larger than POLL_TIMEOUT. It is
# the single budget for the whole "start the oneshot, wait for it to finish"
# window; nothing on that path uses POLL_TIMEOUT.
RENEWAL_TIMEOUT=600

usage() {
  cat <<EOF
Usage: $0 --env {dev|prod} [--yes-i-mean-prod] [--dry-run]
          [--poll-timeout <sec>] [--renewal-timeout <sec>]

  --env <dev|prod>          Which environment's Vault VM to verify against
  --yes-i-mean-prod         Required for --env prod (LE quota consumer)
  --dry-run                 Print the plan; do not touch the target VM
  --poll-timeout <sec>      How long to poll for the SERVED cert serial to
                            change after the reload (default: 120)
  --renewal-timeout <sec>   Wall-clock budget for the forced DNS-01 renewal
                            to complete (default: 600). DNS-01 takes minutes;
                            do not shrink this below the observed renewal time.

The target VM's IP is read from site/config.yaml (vms.vault_<env>.ip).

Exit codes:
  0   PASS — all five checks passed; the ExecReload fix is verified.
  1   Argument or preflight failure (nothing was mutated).
  2   The verification did NOT confirm success after the forced renewal:
      either a check determined the reload is broken (VERDICT: FAIL) or the
      tool could not complete all five checks (VERDICT: INCOMPLETE — e.g. the
      renewal exceeded --renewal-timeout, or the VM became unreachable). A
      non-zero exit NEVER means success. Fail-closed per
      .claude/rules/destruction-safety.md ("a check that cannot determine the
      answer FAILs, never SKIPs").
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="${2:-}"; shift 2 ;;
    --yes-i-mean-prod) CONFIRM_PROD=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --poll-timeout) POLL_TIMEOUT="${2:-}"; shift 2 ;;
    --renewal-timeout) RENEWAL_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "ERROR: --env must be 'dev' or 'prod'" >&2
  usage >&2
  exit 1
fi

if [[ "$ENV" == "prod" && "$CONFIRM_PROD" != "true" ]]; then
  cat >&2 <<EOF
ERROR: --env prod requires --yes-i-mean-prod.

A forced renewal on prod issues a NEW Let's Encrypt certificate for
vault.prod.<domain>. Let's Encrypt rate-limits duplicate certificates
to 5 per registered domain per week. If you have already burned quota
in the last week, this will fail hard.

Prefer verifying against dev first (step-ca, unmetered). Only run
this on prod if you specifically need to prove the fix on the prod
VM in real conditions.
EOF
  exit 1
fi

if ! [[ "$POLL_TIMEOUT" =~ ^[0-9]+$ ]] || (( POLL_TIMEOUT < 10 || POLL_TIMEOUT > 600 )); then
  echo "ERROR: --poll-timeout must be an integer in [10, 600]" >&2
  exit 1
fi

if ! [[ "$RENEWAL_TIMEOUT" =~ ^[0-9]+$ ]] || (( RENEWAL_TIMEOUT < 30 || RENEWAL_TIMEOUT > 1800 )); then
  echo "ERROR: --renewal-timeout must be an integer in [30, 1800]" >&2
  exit 1
fi

# --- Tool prerequisites (workstation side) ---
# `timeout` is required: vssh/vssh_stdin wrap every SSH call in it. Stock macOS
# ships it as `gtimeout` (coreutils) — if this fails, `brew install coreutils`
# and symlink, or run where GNU timeout is on PATH. Preflighting it here turns
# a confusing mid-run failure into a clear message.
for tool in yq jq ssh openssl awk sed timeout; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required workstation tool missing: $tool" >&2
    exit 1
  fi
done

# --- Resolve VM identity from config.yaml ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found" >&2
  exit 1
fi

VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip // \"\"" "$CONFIG_FILE")
DOMAIN=$(yq -r '.domain // ""' "$CONFIG_FILE")
if [[ -z "$VAULT_IP" || "$VAULT_IP" == "null" ]]; then
  echo "ERROR: vms.vault_${ENV}.ip not set in $CONFIG_FILE" >&2
  exit 1
fi
if [[ -z "$DOMAIN" || "$DOMAIN" == "null" ]]; then
  echo "ERROR: .domain not set in $CONFIG_FILE" >&2
  exit 1
fi

FQDN="vault.${ENV}.${DOMAIN}"

echo "=== verify-vault-reload.sh ==="
echo "  env:      ${ENV}"
echo "  vault:    ${FQDN}  (${VAULT_IP})"
echo "  renewal:  ${RENEWAL_TIMEOUT}s budget for the forced DNS-01 renewal to finish"
echo "  serving:  ${POLL_TIMEOUT}s polling window for the served cert to change"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  DRY-RUN:  no VM state will be mutated"
fi
echo ""

# --- Small SSH helper (always use -n inside functions; see ssh rule) ---
# Every remote command is wrapped in `timeout` on the workstation side so
# a hung TLS handshake inside `openssl s_client` cannot swallow the outer
# `poll_until` deadline. 15s is well above any healthy round-trip.
vssh() {
  timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    "root@${VAULT_IP}" "$@"
}

# stdin variant for delivering short blobs safely without <<< bashisms.
vssh_stdin() {
  timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    "root@${VAULT_IP}" "$@"
}

# --- Poll a probe until it returns a non-empty value or deadline elapses.
#     Prints the final value on stdout; exits nonzero if the deadline is hit
#     without a value. Used for both certbot-renew completion and served-cert
#     change. ---
poll_until() {
  local desc="$1" deadline="$2" interval="$3"
  shift 3
  local now target val
  now=$(date +%s)
  target=$((now + deadline))
  while :; do
    val="$("$@" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then
      echo "$val"
      return 0
    fi
    now=$(date +%s)
    if (( now >= target )); then
      echo "" >&2
      echo "  ✗ timeout after ${deadline}s waiting for: ${desc}" >&2
      return 1
    fi
    sleep "$interval"
  done
}

# --- Probes (return values to poll_until) ------------------------------------

disk_cert_serial() {
  vssh "\
    set -e; \
    openssl_bin=\$(find /nix/store -maxdepth 3 -path '*/bin/openssl' -type f | sort | head -1); \
    [ -n \"\$openssl_bin\" ] || exit 1; \
    \"\$openssl_bin\" x509 -in /etc/letsencrypt/live/${FQDN}/fullchain.pem -noout -serial 2>/dev/null | sed 's/serial=//' \
  "
}

served_cert_serial() {
  vssh "\
    set -e; \
    openssl_bin=\$(find /nix/store -maxdepth 3 -path '*/bin/openssl' -type f | sort | head -1); \
    [ -n \"\$openssl_bin\" ] || exit 1; \
    printf '' | \"\$openssl_bin\" s_client -connect 127.0.0.1:8200 -servername ${FQDN} 2>/dev/null \
      | \"\$openssl_bin\" x509 -noout -serial 2>/dev/null | sed 's/serial=//' \
  "
}

vault_main_pid() {
  vssh 'systemctl show vault.service -p MainPID --value --no-pager 2>/dev/null'
}

vault_sealed_status() {
  # Returns "sealed" or "unsealed", empty on any error.
  vssh "\
    set -e; \
    curl -sk https://127.0.0.1:8200/v1/sys/health \
      | awk 'match(\$0, /\"sealed\":(true|false)/, m) { print (m[1] == \"true\" ? \"sealed\" : \"unsealed\"); exit }' \
  "
}

vault_execreload_line() {
  vssh 'systemctl show vault.service -p ExecReload --no-pager 2>/dev/null'
}

certbot_renew_invocation_id() {
  # The daily timer will typically have already fired certbot-renew today, so
  # `Result=success ExecMainStatus=0` is the DEFAULT state before we do
  # anything. Anchor the "did our forced run complete" check on InvocationID
  # (a fresh systemd UUID per activation) so we cannot mistake the prior
  # timer run for ours.
  vssh 'systemctl show certbot-renew.service -p InvocationID --value --no-pager 2>/dev/null'
}

# Baseline InvocationID captured in preflight; certbot_renew_result compares
# against it so it only reports "done" when a NEW invocation completed.
BASELINE_INVOCATION_ID=""

certbot_renew_result() {
  # Emit "Result|ExecMainStatus" ONLY when a new InvocationID is present AND
  # ActiveState indicates the oneshot has finished. Empty return = still
  # activating, cached prior invocation, or unreadable; poll_until retries.
  local out
  out="$(vssh 'systemctl show certbot-renew.service -p ActiveState -p Result -p ExecMainStatus -p InvocationID --no-pager 2>/dev/null' || true)"
  [[ -z "$out" ]] && return 0
  local active result status invocation
  active="$(awk -F= '/^ActiveState=/{print $2}' <<< "$out")"
  result="$(awk -F= '/^Result=/{print $2}' <<< "$out")"
  status="$(awk -F= '/^ExecMainStatus=/{print $2}' <<< "$out")"
  invocation="$(awk -F= '/^InvocationID=/{print $2}' <<< "$out")"

  # Guard the whole shape. A missing property indicates the remote systemctl
  # call returned garbage; retry rather than treat it as done.
  [[ -z "$active" || -z "$result" || -z "$status" || -z "$invocation" ]] && return 0

  # If the InvocationID has not changed, our forced run has not yet started
  # (or systemd has not yet ticked its state machine after --no-block).
  [[ "$invocation" == "$BASELINE_INVOCATION_ID" ]] && return 0

  case "$active" in
    activating|reloading) return 0 ;;
    *) echo "${result}|${status}" ;;
  esac
}

# --- Preflight against the target VM -----------------------------------------

echo "[1/5] Preflight: contacting ${VAULT_IP} and inspecting deployed vault.service..."

if [[ "$DRY_RUN" == "true" ]]; then
  cat <<EOF
  DRY-RUN plan:
    - ssh-keygen -R ${VAULT_IP} to drop any pre-recreation host key
    - ssh root@${VAULT_IP} to inspect systemctl show vault.service -p ExecReload
    - refuse if ExecReload does not match the #642 form
      (kill -HUP \$MAINPID under coreutils path)
    - capture baseline: MainPID, disk serial, served serial,
      certbot-renew.service InvocationID
    - refuse if /run/certbot-force-renewal.env is already present
    - install EXIT trap: cleanup env file + re-enable certbot-renew.timer,
      and print an explicit PASS/FAIL/INCOMPLETE verdict (fail-closed)
    - stop certbot-renew.timer for the verification window
    - deliver /run/certbot-force-renewal.env with CERTBOT_FORCE_RENEWAL=1
    - systemctl start --no-block certbot-renew.service (returns immediately)
    - poll for a new InvocationID + Result=success ExecMainStatus=0,
      bounded by --renewal-timeout (${RENEWAL_TIMEOUT}s) for the DNS-01 wall clock
    - verify on-disk cert serial changed
    - poll served-cert serial until it matches new disk serial or ${POLL_TIMEOUT}s
    - verify MainPID unchanged, Vault still unsealed
    - EXIT trap runs unconditionally, restoring the timer and removing
      /run/certbot-force-renewal.env even on error paths, and never lets an
      early exit report success without a verdict
EOF
  exit 0
fi

# --- Fail-closed verdict machinery (issue #679) ------------------------------
#
# A verification tool that ends WITHOUT an explicit verdict is a silent
# false-success waiting to happen: the operator sees output stop mid-run and
# has no way to tell "it passed" from "it aborted" except by eyeballing $?,
# which is itself environment-dependent (whether `timeout` is GNU/BSD/absent,
# whether set -e fired). Per .claude/rules/destruction-safety.md, a check that
# cannot determine the answer must FAIL loudly, never trail off. So:
#
#   * VERDICT_EMITTED records that a deliberate PASS or FAIL was printed.
#   * The EXIT trap preserves the true exit code (`rc=$?; ...; exit "$rc"`)
#     and, if the script is exiting non-zero WITHOUT having emitted a
#     deliberate verdict, prints `VERDICT: INCOMPLETE` to stdout so no
#     early-exit path can masquerade as success.
#   * verdict_fail() is used by the checks that DETERMINE the reload is
#     broken (the load-bearing negative signals).
#
# The trap is installed here, before any VM interaction, so every probe and
# the trigger window are covered. VM-side cleanup only runs once we have
# actually started mutating the VM (VM_CLEANUP_ARMED), so a preflight abort
# does not issue pointless remote commands.
VERDICT_EMITTED=""
VM_CLEANUP_ARMED="false"

verdict_fail() {
  # A check determined the reload is broken. Print a FAIL verdict (stdout),
  # mark the verdict emitted, and exit non-zero (2).
  VERDICT_EMITTED="FAIL"
  echo ""
  echo "=== VERDICT: FAIL ==="
  echo "  $1"
  exit 2
}

cleanup_and_verdict() {
  local rc=$?
  set +e
  if [[ "$VM_CLEANUP_ARMED" == "true" ]]; then
    # Best-effort: remove the single-shot env file and re-arm the daily timer.
    vssh 'rm -f /run/certbot-force-renewal.env' >/dev/null 2>&1
    vssh 'systemctl start --quiet certbot-renew.timer' >/dev/null 2>&1
  fi
  if [[ -z "$VERDICT_EMITTED" ]]; then
    # Reached the trap without a deliberate PASS or FAIL. Whatever $rc is, we
    # did NOT confirm the reload — a zero here would be a silent false-success,
    # exactly what #679 forbids. Force a loud, non-zero INCOMPLETE. (No live
    # path reaches this with rc==0 today — the only rc==0 exit sets PASS first,
    # and --help/--dry-run exit before this trap is installed — but this closes
    # the class against any future accidental early `exit 0`.)
    [[ "$rc" -eq 0 ]] && rc=2
    echo ""
    echo "=== VERDICT: INCOMPLETE ==="
    echo "  The verification ended before confirming all five checks (exit ${rc})."
    echo "  A verifier that cannot confirm the reload MUST NOT report success,"
    echo "  so this is a non-zero, loud failure — NOT a pass. Nothing here proves"
    echo "  the #642 fix works on ${FQDN:-the target VM}."
    echo "  Common causes: the forced renewal exceeded --renewal-timeout"
    echo "  (${RENEWAL_TIMEOUT}s), or the VM became unreachable mid-run. Inspect"
    echo "  the last step above, then re-run (raise --renewal-timeout if DNS-01"
    echo "  is simply slow)."
  fi
  exit "$rc"
}
trap cleanup_and_verdict EXIT

# The MR's deploy recreates the Vault VM (image input change), so on first
# post-deploy invocation the workstation's known_hosts still has the pre-
# recreation key. Drop it so `accept-new` can seed the new one. This is the
# canonical destructive-op recovery step from .claude/rules/ssh.md.
ssh-keygen -R "${VAULT_IP}" >/dev/null 2>&1 || true

if ! vssh true; then
  echo "  ✗ cannot ssh root@${VAULT_IP}" >&2
  exit 1
fi
echo "  ✓ ssh reachable"

deployed_reload="$(vault_execreload_line || true)"
if [[ -z "$deployed_reload" ]]; then
  echo "  ✗ vault.service not present on ${VAULT_IP}" >&2
  exit 1
fi
# The rendered ExecReload systemd line looks like:
#   ExecReload={ path=/nix/store/.../bin/kill ; argv[]=/nix/store/.../bin/kill -HUP $MAINPID ; ... }
# systemctl show reports the CONFIGURED command, not the expanded runtime
# argv, so the third token after -HUP is the literal `$MAINPID` (or, on some
# systemd versions, an already-expanded numeric pid). Accept both. The
# systemctl-invoking bad shape is rejected explicitly on the next check.
if ! grep -Eq 'argv\[\]=[^;]*/bin/kill[[:space:]]+-HUP[[:space:]]+(\$MAINPID|[0-9]+)' <<< "$deployed_reload"; then
  echo "  ✗ deployed ExecReload does NOT look like the #642 fix:" >&2
  echo "    ${deployed_reload}" >&2
  echo "" >&2
  echo "    Deploy the fix (merge issue-642 branch into dev, let the pipeline" >&2
  echo "    recreate ${FQDN}) before running this verification." >&2
  exit 1
fi
if grep -Eq 'argv\[\]=[^;]*systemctl' <<< "$deployed_reload"; then
  echo "  ✗ deployed ExecReload still contains 'systemctl' (regressed):" >&2
  echo "    ${deployed_reload}" >&2
  exit 1
fi
echo "  ✓ deployed ExecReload is the kill -HUP form"

baseline_pid="$(vault_main_pid || true)"
if ! [[ "$baseline_pid" =~ ^[1-9][0-9]*$ ]]; then
  echo "  ✗ vault.service MainPID is not a positive integer: '${baseline_pid}'" >&2
  exit 1
fi
echo "  ✓ vault.service MainPID = ${baseline_pid}"

baseline_sealed="$(vault_sealed_status || true)"
if [[ "$baseline_sealed" != "unsealed" ]]; then
  echo "  ✗ Vault is not unsealed (status: '${baseline_sealed}'); refusing to renew" >&2
  exit 1
fi
echo "  ✓ Vault is unsealed"

baseline_disk_serial="$(disk_cert_serial || true)"
baseline_served_serial="$(served_cert_serial || true)"
if [[ -z "$baseline_disk_serial" || -z "$baseline_served_serial" ]]; then
  echo "  ✗ could not read baseline cert serials (disk='${baseline_disk_serial}', served='${baseline_served_serial}')" >&2
  exit 1
fi
echo "  ✓ baseline disk serial:   ${baseline_disk_serial}"
echo "  ✓ baseline served serial: ${baseline_served_serial}"

# This baseline is the race guard for the --no-block poll below: a completed
# result is only accepted when its InvocationID differs from this value. If the
# probe FAILS (ssh error), an empty baseline would let the poll accept a prior
# timer run's stale success as "ours", so fail closed on probe failure. An
# empty value from a SUCCESSFUL probe is legitimate (the service genuinely
# never ran) — the first real completion then has a non-empty, differing ID.
if ! BASELINE_INVOCATION_ID="$(certbot_renew_invocation_id)"; then
  echo "  ✗ could not read certbot-renew.service baseline InvocationID from ${VAULT_IP}" >&2
  echo "    Cannot establish the completion race guard; refusing to proceed." >&2
  exit 1
fi
echo "  ✓ certbot-renew baseline InvocationID: ${BASELINE_INVOCATION_ID:-<none, never run>}"

# Refuse to proceed if a stale env file is already present. It could have
# been left by a crashed prior verify run (before this fix's EXIT trap
# landed) and would burn LE quota the next time the timer fires. Fail
# closed per .claude/rules/destruction-safety.md.
if vssh 'test -e /run/certbot-force-renewal.env' 2>/dev/null; then
  echo "  ✗ /run/certbot-force-renewal.env already exists on ${VAULT_IP}" >&2
  echo "    A prior forced-renew attempt did not clean up. Investigate before proceeding:" >&2
  echo "      ssh root@${VAULT_IP} cat /run/certbot-force-renewal.env" >&2
  echo "    Remove it manually only after confirming no forced renewal is in progress." >&2
  exit 1
fi

# --- Trigger the forced renewal ---------------------------------------------

echo ""
echo "[2/5] Triggering FORCED renewal through certbot-renew.service..."

# The unified cleanup+verdict EXIT trap (cleanup_and_verdict) is already
# installed above. Arm its VM-side cleanup now: from this point a failure
# must remove the single-shot env file and re-enable the daily timer.
VM_CLEANUP_ARMED="true"

# Stop the daily timer for the duration of the verification. Otherwise the
# 24h + 12h-random schedule could fire between file-delivery and our start,
# consume the env, and burn LE quota. `systemctl stop <timer>` is idempotent.
# If it FAILS we cannot guarantee the timer won't fire mid-window, so fail
# closed rather than risk a stray LE issuance — the EXIT trap re-enables the
# timer on the way out.
if ! vssh 'systemctl stop certbot-renew.timer' >/dev/null 2>&1; then
  echo "  ✗ could not stop certbot-renew.timer on ${VAULT_IP}" >&2
  echo "    Refusing to force a renewal while the daily timer might fire and" >&2
  echo "    burn Let's Encrypt quota. Investigate the VM and re-run." >&2
  exit 1
fi

# Deliver a single-shot env file. `printf | ssh 'install ...'` avoids the
# bash-only `<<<` here-string.
printf 'CERTBOT_FORCE_RENEWAL=1\n' \
  | vssh_stdin 'install -m 0600 /dev/stdin /run/certbot-force-renewal.env'
echo "  ✓ delivered /run/certbot-force-renewal.env"

# Reset any prior failed state so systemctl start is not short-circuited.
vssh 'systemctl reset-failed certbot-renew.service' >/dev/null 2>&1 || true

# Kick the oneshot with --no-block and return immediately. We deliberately do
# NOT block the SSH call on the renewal finishing: DNS-01 takes minutes, and a
# long-blocking `systemctl start` inherits two structurally-too-short timeouts
# (the VM-side `timeout` and vssh's own workstation-side `timeout`), which is
# exactly what killed real renewals mid-flight and left no verdict (#679). The
# completion wait is done by polling below, bounded by RENEWAL_TIMEOUT, with
# each SSH probe short and safely under vssh's connect timeout. The
# BASELINE_INVOCATION_ID race-guard captured in preflight is what makes this
# poll safe — we only accept a NEW invocation's result.
vssh 'systemctl start --no-block certbot-renew.service'
echo "  ✓ certbot-renew.service start requested (--no-block); awaiting completion"

# --- Wait for the renewal to complete ----------------------------------------

echo ""
echo "[3/5] Reading certbot-renew.service completion state..."

# We started the oneshot with --no-block, so poll for it to complete here,
# bounded by the full DNS-01 renewal budget. certbot_renew_result requires
# InvocationID != baseline (rejects the prior timer-driven run) and all
# properties non-empty (rejects garbage from a partial systemctl response),
# and only emits once ActiveState has settled past activating/reloading. Each
# probe is a short SSH call, so RENEWAL_TIMEOUT bounds the wait without any
# single long-blocking connection.
if ! renew_summary="$(poll_until 'certbot-renew to complete a new invocation' "$RENEWAL_TIMEOUT" 5 certbot_renew_result)"; then
  vssh 'journalctl -u certbot-renew.service -n 40 --no-pager 2>/dev/null' >&2 || true
  echo "  ✗ certbot-renew.service did not complete within ${RENEWAL_TIMEOUT}s" >&2
  echo "    DNS-01 renewals take minutes; if this VM is simply slow, re-run with" >&2
  echo "    a larger --renewal-timeout. The tool cannot confirm the reload until" >&2
  echo "    the renewal finishes, so it fails closed (INCOMPLETE) rather than" >&2
  echo "    claim success." >&2
  exit 2   # -> EXIT trap prints VERDICT: INCOMPLETE (could not determine)
fi

renew_result="${renew_summary%%|*}"
renew_status="${renew_summary##*|}"
if [[ "$renew_result" != "success" || "$renew_status" != "0" ]]; then
  echo "  ✗ certbot-renew.service finished non-successfully: Result=${renew_result} ExecMainStatus=${renew_status}" >&2
  vssh 'journalctl -u certbot-renew.service -n 40 --no-pager 2>/dev/null' >&2 || true
  verdict_fail "The forced renewal itself failed (Result=${renew_result} ExecMainStatus=${renew_status}); cannot verify the reload."
fi
echo "  ✓ certbot-renew.service exited Result=success ExecMainStatus=0"

# --- Verify the on-disk cert was actually replaced ---------------------------

echo ""
echo "[4/5] Verifying on-disk certificate changed..."

new_disk_serial="$(disk_cert_serial || true)"
if [[ -z "$new_disk_serial" ]]; then
  echo "  ✗ failed to read on-disk cert serial after renewal" >&2
  exit 2
fi
if [[ "$new_disk_serial" == "$baseline_disk_serial" ]]; then
  echo "  ✗ on-disk cert serial DID NOT change:" >&2
  echo "      before: ${baseline_disk_serial}" >&2
  echo "      after:  ${new_disk_serial}" >&2
  echo "    Certbot may have decided the cert did not need renewal." >&2
  echo "    Check journalctl -u certbot-renew.service on ${VAULT_IP}." >&2
  exit 2
fi
echo "  ✓ on-disk serial changed: ${baseline_disk_serial} → ${new_disk_serial}"

# --- Poll the served cert until it matches the new on-disk cert --------------

echo ""
echo "[5/5] Polling served cert on https://${VAULT_IP}:8200 for SIGHUP-driven reload (up to ${POLL_TIMEOUT}s)..."
echo "      This is the load-bearing check: exit codes cannot prove reload happened."

served_matches_disk() {
  local s
  s="$(served_cert_serial || true)"
  [[ -z "$s" ]] && return 0
  if [[ "$s" == "$new_disk_serial" ]]; then
    echo "$s"
  fi
}

if ! observed_served="$(poll_until "served cert serial to match ${new_disk_serial}" "$POLL_TIMEOUT" 2 served_matches_disk)"; then
  final_served="$(served_cert_serial || echo '<unreadable>')"
  echo "" >&2
  echo "  ✗ served cert never changed to match on-disk cert." >&2
  echo "      disk (new):     ${new_disk_serial}" >&2
  echo "      served (final): ${final_served}" >&2
  echo "" >&2
  echo "    The renewal wrote a new cert to disk but Vault did NOT reload it." >&2
  echo "    This is the #642 failure mode. The ExecReload fix is NOT working" >&2
  echo "    against this VM." >&2
  echo "" >&2
  echo "    Investigate: journalctl -u vault.service --since '2 min ago' on ${VAULT_IP}." >&2
  verdict_fail "Served cert never matched the new on-disk serial within ${POLL_TIMEOUT}s — Vault did not reload the renewed cert (#642 failure mode)."
fi
echo "  ✓ served cert now: ${observed_served}"

# --- Final: reload was in-place, not restart ---------------------------------

final_pid="$(vault_main_pid || true)"
if [[ "$final_pid" != "$baseline_pid" ]]; then
  echo "  ✗ Vault MainPID CHANGED: ${baseline_pid} → ${final_pid}" >&2
  echo "    That is a restart, not a reload — the fix would still be a bug." >&2
  verdict_fail "Vault MainPID changed (${baseline_pid} → ${final_pid}) — that is a restart, not a reload."
fi
echo "  ✓ Vault MainPID unchanged (${final_pid}) — this was a reload, not a restart"

final_sealed="$(vault_sealed_status || true)"
if [[ "$final_sealed" != "unsealed" ]]; then
  echo "  ✗ Vault is no longer unsealed after reload (status: '${final_sealed}')" >&2
  verdict_fail "Vault is no longer unsealed after the reload (status: '${final_sealed}')."
fi
echo "  ✓ Vault still unsealed"

VERDICT_EMITTED="PASS"
echo ""
echo "=== VERDICT: PASS ==="
echo "  ExecReload fix verified in real conditions on ${FQDN}:"
echo "    certbot renewal succeeded, deploy hook reloaded Vault,"
echo "    Vault re-read TLS material without restarting, and clients now"
echo "    receive the new serial ${new_disk_serial}."
