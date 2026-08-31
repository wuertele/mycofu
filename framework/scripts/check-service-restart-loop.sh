#!/usr/bin/env bash
# check-service-restart-loop.sh — Detect service crash loops on framework VMs.
#
# For each SSH-introspectable VM in site/config.yaml (.vms) and
# site/applications.yaml (.applications.*.environments.*), enumerate
# active/activating/failed .service units and report any whose NRestarts
# exceeds threshold, whose Result is "oom-kill", whose ActiveState is
# "failed", or whose VM kernel-level OOM count in the current boot
# exceeds threshold.
#
# Background: see
# docs/reports/2026-05-25-testapp-prod-vault-agent-oom-investigation.md.
# testapp-prod ran a vault-agent OOM crash loop for 9 days (NRestarts at
# 1110+) with Gatus reporting healthy, because the probe target was
# independent of vault-agent state. This check closes that gap.
#
# Usage:
#   framework/scripts/check-service-restart-loop.sh
#       [--config <path>]                # site/config.yaml
#       [--apps-config <path>]           # site/applications.yaml
#       [--nrestarts-max <int>]          # default 10
#       [--oom-max <int>]                # default 3
#       [--help|-h]
#
# Exit 0 if no loops detected, 1 if any VM reports a signal over threshold
# or SSH/probe fails, 2 on usage error.
#
# Used by framework/scripts/validate.sh. Closes #391.
# END_USAGE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

# Thresholds chosen so testapp-prod's pre-fix state (NRestarts ~1110+,
# Result=oom-kill, kernel OOM count in the thousands) trips loudly while
# leaving margin for one-off restarts.
NRESTARTS_MAX=10
OOM_MAX=3

# VMs not SSH-introspectable from the CI runner. PBS is a vendor appliance
# (Category C per .claude/rules/pbs-restore.md) accessed via HTTPS API only;
# the runner's pubkey is not authorized on PBS by design (empirically
# verified during issue #391 Phase 1 investigation). Extend this list
# when adding other vendor appliances (e.g., HAOS).
KNOWN_NON_INTROSPECTABLE=("pbs")

# SSH options.
# Deliberately do NOT inherit validate.sh's exported SSH_OPTS — it contains
# `-n` (which redirects ssh stdin from /dev/null) and this helper relies
# on sending the probe body via ssh stdin. Set our own default and use a
# clean local override that tests can replace.
#
# Critical components:
#   (no -n)              — must NOT be present; -n breaks `bash -s <stdin>`.
#   ConnectTimeout=5     — connection-phase bound.
#   ServerAliveInterval=5 + ServerAliveCountMax=3 — session-phase bound:
#                          kills wedged sessions in ~15s.
#   LogLevel=ERROR       — suppress host-key warnings so SSH chatter is
#                          not folded into the probe output stream.
#   StrictHostKeyChecking=no, UserKnownHostsFile=/dev/null — workstation
#                          and CI runner both use ephemeral known_hosts.
#   BatchMode=yes        — never prompt for password.
SSH_CMD="${SSH_CMD:-ssh}"
SSH_OPTS_DEFAULT="-o ConnectTimeout=5 \
-o ServerAliveInterval=5 \
-o ServerAliveCountMax=3 \
-o LogLevel=ERROR \
-o StrictHostKeyChecking=no \
-o UserKnownHostsFile=/dev/null \
-o BatchMode=yes"

# Allow tests to override; otherwise force our default (do NOT inherit
# validate.sh's exported $SSH_OPTS which contains -n).
if [[ -z "${SSH_OPTS_OVERRIDE+x}" ]]; then
  SSH_OPTS="${SSH_OPTS_DEFAULT}"
else
  SSH_OPTS="${SSH_OPTS_OVERRIDE}"
fi

# Bounded remote probe duration. systemctl/journalctl on a healthy VM
# completes well under 5s; 30s gives margin for one slow journalctl pass.
REMOTE_TIMEOUT=30

require_value() {
  local flag="$1"
  local value="${2-__missing__}"
  if [[ "$value" == "__missing__" ]]; then
    echo "ERROR: ${flag} requires a value" >&2
    exit 2
  fi
}

require_nonneg_int() {
  local flag="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${flag} requires a non-negative integer; got '${value}'" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      require_value "$1" "${2-__missing__}"
      CONFIG="$2"; shift 2 ;;
    --apps-config)
      require_value "$1" "${2-__missing__}"
      APPS_CONFIG="$2"; shift 2 ;;
    --nrestarts-max)
      require_value "$1" "${2-__missing__}"
      require_nonneg_int "$1" "$2"
      NRESTARTS_MAX="$2"; shift 2 ;;
    --oom-max)
      require_value "$1" "${2-__missing__}"
      require_nonneg_int "$1" "$2"
      OOM_MAX="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^# END_USAGE$/{
        /^# END_USAGE$/d
        s/^# //
        s/^#$//
        p
      }' "$0"
      exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config not found: $CONFIG" >&2
  exit 2
fi

PROBE_FILE="${LIB_DIR}/restart-loop-probe.sh"
if [[ ! -f "$PROBE_FILE" ]]; then
  echo "ERROR: Probe library not found: $PROBE_FILE" >&2
  exit 2
fi
REMOTE_PROBE="$(cat "$PROBE_FILE")"
# Defense-in-depth: a truncated probe (empty file, NUL byte, etc.) would
# silently make every VM report no findings. Catch that here.
if [[ -z "$REMOTE_PROBE" ]]; then
  echo "ERROR: Probe library at $PROBE_FILE is empty or unreadable" >&2
  exit 2
fi

# Static regression guard for R1 P1.1 (the `-n` no-op bug). Every future
# editor of SSH_OPTS needs to NOT include `-n` (which redirects ssh stdin
# from /dev/null and silently kills the bash -s heredoc delivery). The
# mock SSH in the test suite can't catch this structurally because the
# mock is a shell script, not real OpenSSH. Catch it here at runtime.
if printf '%s' "$SSH_OPTS" | grep -qE '(^|[[:space:]])-n([[:space:]]|$)'; then
  echo "ERROR: SSH_OPTS contains -n. This breaks remote probe delivery." >&2
  echo "       The probe is sent via SSH stdin; -n discards it." >&2
  echo "       See R1/R2 reviews in docs/reports/mycofu-fix-issue-391-*.md" >&2
  exit 2
fi

is_non_introspectable() {
  local name="$1"
  local skip
  for skip in "${KNOWN_NON_INTROSPECTABLE[@]}"; do
    [[ "$name" == "$skip" ]] && return 0
  done
  return 1
}

# Build the list of (label, ip) tuples to check (TAB-separated).
TARGETS_TSV=$(
  {
    yq -r '.vms | to_entries[] | [.key, .value.ip] | @tsv' "$CONFIG"
    if [[ -f "$APPS_CONFIG" ]]; then
      yq -r '
        .applications // {}
        | to_entries[]
        | select(.value.enabled == true)
        | .key as $app
        | .value.environments
        | to_entries[]
        | [$app + "_" + .key, .value.ip]
        | @tsv
      ' "$APPS_CONFIG"
    fi
  } | awk -F'\t' '$2 != "" && $2 != "null" {print}'
)

failures=0
checked=0
skipped=0

while IFS=$'\t' read -r label ip; do
  [[ -z "$label" ]] && continue
  if is_non_introspectable "$label"; then
    echo "SKIP: ${label} (vendor appliance — see KNOWN_NON_INTROSPECTABLE in $(basename "$0"))"
    skipped=$((skipped + 1))
    continue
  fi
  checked=$((checked + 1))

  # Capture stdout and stderr separately. Stdout carries probe output
  # (UNIT/KERNEL/PROBE_OK records). Stderr captures SSH transport errors;
  # with LogLevel=ERROR we expect it empty in the happy path.
  #
  # Only one timeout layer (outer/local). Original design had an inner
  # `timeout 25` on the remote VM too, but `timeout` is a coreutils
  # binary that may not be on PATH for all VM classes the helper might
  # contact in the future. SSH ServerAliveInterval=5/Count=3 + outer
  # local timeout already bound the wall-clock to ~30s. R2 sub-claude P2.2.
  set +e
  STDERR_FILE="$(mktemp)"
  output=$(timeout "$REMOTE_TIMEOUT" "$SSH_CMD" $SSH_OPTS "root@${ip}" \
    "env NRESTARTS_MAX='${NRESTARTS_MAX}' OOM_MAX='${OOM_MAX}' bash -s" \
    <<<"$REMOTE_PROBE" 2>"$STDERR_FILE")
  rc=$?
  ssh_stderr="$(cat "$STDERR_FILE")"
  rm -f "$STDERR_FILE"
  set -e

  if [[ $rc -ne 0 ]]; then
    # SSH transport, remote timeout, or non-zero remote exit. Fail closed
    # per .claude/rules/destruction-safety.md.
    echo "FAIL: ${label} (${ip}): SSH/remote probe failed (rc=${rc})"
    [[ -n "$ssh_stderr" ]] && echo "$ssh_stderr" | head -2 | sed 's/^/       stderr: /'
    [[ -n "$output" ]] && echo "$output" | head -2 | sed 's/^/       stdout: /'
    failures=$((failures + 1))
    continue
  fi

  # PROBE_OK sentinel must be the LAST non-empty line of stdout. Anywhere-
  # in-output match (`grep -qx`) would pass if PROBE_OK appeared inside a
  # unit name or earlier in the stream. The probe contract specifies
  # PROBE_OK as the terminating sentinel.
  last_line=$(printf '%s' "$output" | awk 'NF { last = $0 } END { print last }')
  if [[ "$last_line" != "PROBE_OK" ]]; then
    echo "FAIL: ${label} (${ip}): probe did not complete (no PROBE_OK sentinel)"
    [[ -n "$ssh_stderr" ]] && echo "$ssh_stderr" | head -2 | sed 's/^/       stderr: /'
    [[ -n "$output" ]] && echo "$output" | head -3 | sed 's/^/       stdout: /'
    failures=$((failures + 1))
    continue
  fi

  # Any unrecognized lines on stderr are also a failure: SSH should have
  # been silent under LogLevel=ERROR.
  if [[ -n "$ssh_stderr" ]]; then
    echo "FAIL: ${label} (${ip}): unexpected stderr from SSH/probe"
    echo "$ssh_stderr" | head -3 | sed 's/^/       stderr: /'
    failures=$((failures + 1))
    continue
  fi

  # Strip PROBE_OK and blank lines; only UNIT/KERNEL records remain.
  findings=$(printf '%s\n' "$output" | grep -E '^(UNIT|KERNEL) ' || true)

  if [[ -z "$findings" ]]; then
    continue
  fi

  echo "FAIL: ${label} (${ip}): service-restart-loop signals detected (thresholds: NRestarts>${NRESTARTS_MAX}, Result=oom-kill, ActiveState=failed, kernel_oom_total>=${OOM_MAX})"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "       ${line}"
  done <<<"$findings"
  failures=$((failures + 1))
done <<<"$TARGETS_TSV"

echo ""
echo "Summary: checked ${checked} VM(s), skipped ${skipped}, ${failures} failed."

[[ "$failures" -eq 0 ]] || exit 1
exit 0
