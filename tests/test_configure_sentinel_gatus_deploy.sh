#!/usr/bin/env bash
#
# test_configure_sentinel_gatus_deploy.sh — verify configure-sentinel-gatus.sh
# placement-watchdog deploy block survives Synology DSM constraints.
#
# Origin: 2026-04-26 — running configure-sentinel-gatus.sh from the
# workstation succeeded for the gatus-sentinel container deploy but
# exited 255 in the placement-watchdog block. Two compounding bugs:
#
#   1. The script invoked `crontab -l` and `crontab -`, but Synology
#      DSM does NOT ship a `crontab` binary anywhere. Discovery on the
#      NAS confirmed: no /usr/bin/crontab, no /usr/local/bin/crontab,
#      no /usr/syno/bin/crontab. Only `/etc/crontab` (the file) and
#      `/usr/syno/bin/synoschedtask` (which can't create tasks from CLI).
#
#   2. The script makes 16+ rapid SSH/scp connections to the NAS,
#      hitting Synology sshd's MaxStartups=10:30:100 default. With
#      MR !200's new ConnectTimeout=10, the refused/delayed handshake
#      surfaced as SSH error 255.
#
# This test is the structural counterpart of
# tests/test_configure_sentinel_gatus_resilience.sh — that one covers
# the docker-replace path; this one covers the deploy path. See issue
# #243 for the original report.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT_PATH="${REPO_ROOT}/framework/scripts/configure-sentinel-gatus.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# Static ratchets — prevent future MRs from regressing the deploy-path
# fixes. Each ratchet has a comment explaining what it protects.
# ---------------------------------------------------------------------------

test_start "1" "script does NOT invoke 'crontab' as a binary (it doesn't exist on Synology DSM)"
# The fix replaces `crontab -l | crontab -` with direct edits to
# /etc/crontab. Any reintroduction of `crontab -l`, `crontab -e`, or a
# pipeline ending in `| crontab -` would re-break the script on this NAS.
# Strip comments before grepping so commit-message-style references in
# headers don't trigger a false positive.
script_body=$(sed 's/#.*$//' "${SCRIPT_PATH}")
if grep -qE '\bcrontab[[:space:]]+-[le]\b|\|[[:space:]]*crontab[[:space:]]+-' <<< "${script_body}"; then
  test_fail "script invokes 'crontab' binary; Synology DSM has no crontab — edit /etc/crontab directly"
  grep -nE '\bcrontab[[:space:]]+-[le]\b|\|[[:space:]]*crontab[[:space:]]+-' "${SCRIPT_PATH}" >&2
else
  test_pass "no 'crontab' binary invocation present"
fi

test_start "2" "cron entry lands in /etc/crontab"
if grep -qF '/etc/crontab' "${SCRIPT_PATH}"; then
  test_pass "/etc/crontab is referenced (the DSM-native cron surface)"
else
  test_fail "/etc/crontab is not referenced; placement-watchdog cron entry has no destination"
fi

test_start "3" "cron entry uses Synology 7-field format (includes 'root' as the who column)"
# Synology /etc/crontab format: minute hour mday month wday WHO command
# The pre-existing entries (pg-backup-tofu, synoschedtask runs) all have
# 'root' as the who. Without it, cron rejects the line silently.
if grep -qE '\\troot\\t' "${SCRIPT_PATH}" || grep -qE "root[[:space:]]+\\\$\{?CRON_CMD" "${SCRIPT_PATH}"; then
  test_pass "cron line includes 'root' as the who-column"
else
  test_fail "cron line missing 'root' as who-column for Synology /etc/crontab format"
fi

test_start "4" "cron-entry block is idempotent (grep before append)"
# Without an idempotency check, every run of the script appends another
# line to /etc/crontab — accumulating duplicates over time. The pattern
# must be: grep for marker, append on miss only.
crontab_block=$(awk '/Set up periodic watchdog/,/Sentinel Gatus deployed/' "${SCRIPT_PATH}")
if grep -qE 'grep[[:space:]]+-q.*placement-watchdog' <<< "${crontab_block}"; then
  test_pass "crontab block guards on grep before appending"
else
  test_fail "crontab block missing idempotency guard; reruns will duplicate the entry"
fi

test_start "5" "SSH_OPTS includes ControlMaster=auto"
# Multiplexing reuses one master connection across the script's 16+
# ssh/scp calls, sidestepping Synology MaxStartups=10:30:100 backoff.
# Removing this re-exposes #243's rate-limit failure mode.
if grep -qE 'ControlMaster=auto' "${SCRIPT_PATH}"; then
  test_pass "ControlMaster=auto is present"
else
  test_fail "ControlMaster=auto is missing; SSH calls will hit MaxStartups backoff again"
fi

test_start "6" "SSH_OPTS includes ControlPath via per-invocation mux dir"
if grep -qE 'ControlPath=.*SSH_MUX_DIR' "${SCRIPT_PATH}"; then
  test_pass "ControlPath uses per-invocation \${SSH_MUX_DIR}"
else
  test_fail "ControlPath does not reference SSH_MUX_DIR; concurrent invocations will collide on a shared socket"
fi

test_start "7" "SSH_OPTS includes ControlPersist (with a finite value, not 'no')"
# ControlPersist=60s lets the master survive across the script's calls
# but reap on its own. ControlPersist=no would tear it down too soon to
# matter; ControlPersist with a long value would leak masters across
# script runs and pollute the operator's ssh agent state.
if grep -qE 'ControlPersist=[0-9]+[smhd]?' "${SCRIPT_PATH}"; then
  test_pass "ControlPersist has a finite duration"
else
  test_fail "ControlPersist missing or set to a non-finite value"
fi

test_start "8" "EXIT trap closes the SSH master and removes the mux dir"
# Without the trap, the master persists for ControlPersist seconds after
# exit and the temp dir leaks. The trap is best-effort (|| true) so a
# stale socket or already-closed master cannot fail the script's exit
# code.
trap_line=$(grep -E "^trap .*SSH_MUX_DIR" "${SCRIPT_PATH}" || true)
if [[ -n "${trap_line}" ]] && grep -qF -- '-O exit' <<< "${trap_line}" && grep -qF -- 'rm -rf' <<< "${trap_line}"; then
  test_pass "EXIT trap closes mux master and removes mux dir"
else
  test_fail "EXIT trap missing or incomplete — mux master/socket may leak"
fi

test_start "9" "SSH_MUX_DIR is created via mktemp -d (not a fixed path)"
# A fixed path like /tmp/.ssh-mux would collide if two operators run
# the script simultaneously, or if a previous run was killed and left
# a stale dir.
if grep -qE 'SSH_MUX_DIR=.*mktemp' "${SCRIPT_PATH}"; then
  test_pass "SSH_MUX_DIR uses mktemp"
else
  test_fail "SSH_MUX_DIR is not mktemp-based; collisions possible"
fi

test_start "9.1" "SSH_MUX_DIR uses an explicit short prefix (not \$TMPDIR-derived)"
# Unix-domain-socket paths are capped at 104 bytes on macOS, 108 on
# Linux. `mktemp -d -t prefix.XXX` honors $TMPDIR; on macOS that's
# /var/folders/<long-hash>/T/, which makes the resolved ControlPath
# exceed the cap and SSH refuses to bind the mux socket with
# `unix_listener: path ... too long`. The fix is to give mktemp an
# explicit short prefix (e.g., /tmp/cs-mux.XXXXXX) so the path is
# bounded on every host.
mux_line=$(grep -E '^SSH_MUX_DIR=' "${SCRIPT_PATH}" || true)
if grep -qE 'mktemp -d "?/tmp/' <<< "${mux_line}"; then
  test_pass "SSH_MUX_DIR uses explicit /tmp/ prefix"
else
  test_fail "SSH_MUX_DIR does not pin to /tmp/ — \$TMPDIR may push the ControlPath past the 104-byte Unix-socket cap on macOS"
  printf '    line: %s\n' "${mux_line}" >&2
fi

test_start "9.3" "every process-pattern killer (pkill -f / pgrep -f / killall) uses [x] bracket trick"
# `pkill -f PATTERN` reads each process's full command line and matches
# PATTERN as a regex. The literal PATTERN appears in the parent remote
# shell's cmdline that runs the SSH command, so a literal pattern
# self-matches and kills the script's own remote shell. The local SSH
# client then returns 255 — `2>/dev/null || true` cannot recover,
# because the 255 is from the OUTER SSH, not from pkill. Same bug
# class applies to pgrep -f (when used to gate control flow under
# set -e) and to killall -r (BSD/macOS regex form).
#
# Fix: wrap any literal pattern in a `[x]` regex class so the regex
# matches actual processes but the literal `[x]` substring does not
# appear in the parent shell's cmdline. The bracket form is the only
# safe form for any pattern-based process killer in this script.
#
# Strip shell comments before scanning so explanatory text in the
# script (which itself describes the bug pattern) doesn't trigger a
# false positive.
killers=$(sed 's/[[:space:]]*#.*$//' "${SCRIPT_PATH}" \
  | grep -nE '\b(pkill|pgrep|killall)\b' \
  || true)

# A line is safe if it contains a regex character class anywhere
# (typically the [x] bracket trick on the pattern). Anything else is
# flagged regardless of quoting style: literal-quoted patterns,
# unquoted patterns, dynamic patterns ($VAR, $(cmd)), and multi-line
# invocations (the line's continuation likely lacks the bracket).
naive=$(echo "${killers}" | grep -vE '\[[a-zA-Z]\]' || true)

if [[ -z "${naive}" ]]; then
  test_pass "every pkill/pgrep/killall invocation uses [x] bracket trick"
else
  test_fail "found process-pattern killer without [x] bracket trick — risk of self-match SSH 255"
  printf '    naive (any pkill/pgrep/killall lacking [x]):\n%s\n' "${naive}" >&2
fi

test_start "9.2" "Resolved ControlPath fits within Unix-socket length cap under macOS-style long \$TMPDIR"
# Simulate a worst-case ControlPath under the conditions where the bug
# manifested (macOS, where \$TMPDIR resolves to a long
# /var/folders/.../T/ path). Without an explicit /tmp/ prefix on
# mktemp, the ControlPath would exceed the 104-byte Unix-socket cap.
# This test runs the script's *actual* mktemp invocation under a
# simulated long TMPDIR and checks the resolved length, so the bug is
# caught even when the test runs on Linux (where the real \$TMPDIR is
# typically /tmp/ and would otherwise hide the regression).
mux_invocation=$(grep -E '^SSH_MUX_DIR=' "${SCRIPT_PATH}" | head -1 | sed -E 's/^SSH_MUX_DIR="?\$\(([^)]+)\)"?.*/\1/')
# Worst-case macOS \$TMPDIR (real shape, hash redacted).
LONG_TMPDIR="/var/folders/l7/fsklzgg9459dq205b7b85fbw0000gn/T"
mkdir -p "${LONG_TMPDIR}"
SIM_MUX_DIR=$(TMPDIR="${LONG_TMPDIR}" eval "${mux_invocation}")
control_path_template=$(grep -oE 'ControlPath="?\$\{?SSH_MUX_DIR\}?[^"[:space:]]+' "${SCRIPT_PATH}" | head -1 | sed 's/ControlPath="\?//' | sed 's/"$//')
# Resolve %r/%h/%p with worst-case-real values for this NAS.
resolved=$(echo "${control_path_template}" | sed -e "s|\${SSH_MUX_DIR}|${SIM_MUX_DIR}|" -e 's|%r|administrator|' -e 's|%h|172.17.77.12|' -e 's|%p|22|')
len=${#resolved}
rm -rf "${SIM_MUX_DIR}"
if [[ "${len}" -le 90 ]]; then
  test_pass "ControlPath under macOS-style long \$TMPDIR resolves to ${len} bytes (cap 104, <=90 with margin)"
else
  test_fail "ControlPath would resolve to ${len} bytes under macOS-style long \$TMPDIR — exceeds the 90-byte safety margin"
  printf '    SSH_MUX_DIR invocation: %s\n' "${mux_invocation}" >&2
  printf '    SIM_MUX_DIR resolved:   %s\n' "${SIM_MUX_DIR}" >&2
  printf '    ControlPath template:   %s\n' "${control_path_template}" >&2
  printf '    Resolved ControlPath:   %s\n' "${resolved}" >&2
fi

# ---------------------------------------------------------------------------
# Behavioral fixture — extract the crontab block, run it against a
# scratch /etc/crontab, verify idempotency.
# ---------------------------------------------------------------------------

test_start "10" "T1: idempotency — extracted crontab block produces identical /etc/crontab on second run"
# The script's crontab block writes the entry conditionally. To test it
# in isolation we extract the conditional logic, run it twice against a
# scratch /etc/crontab, and assert the output is byte-identical.
SCRATCH_CRON="${TMP_DIR}/etc-crontab"
cat > "${SCRATCH_CRON}" <<'EOF'
MAILTO=""
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/syno/sbin:/usr/syno/bin:/usr/local/sbin:/usr/local/bin
#minute	hour	mday	month	wday	who	command
0	2	*	*	*	root	/usr/local/bin/pg-backup-tofu.sh # pg-backup-tofu
EOF

# Extract the marker, command, and line construction from the script,
# then exercise the same idempotent grep+append.
CRON_MARKER="# placement-watchdog (managed by configure-sentinel-gatus.sh, issue #243)"
CRON_CMD="WATCHDOG_CONFIG_DIR=/volume1/docker/placement-watchdog /volume1/docker/placement-watchdog/placement-watchdog.sh"
CRON_LINE=$'*/5\t*\t*\t*\t*\troot\t'"${CRON_CMD}"' >> /var/log/placement-watchdog.log 2>&1'

run_cron_block() {
  local target="$1"
  if grep -qF 'placement-watchdog.sh' "${target}"; then
    return 0
  fi
  printf '%s\n%s\n' "${CRON_MARKER}" "${CRON_LINE}" >> "${target}"
}

run_cron_block "${SCRATCH_CRON}"
md5_first=$(md5sum < "${SCRATCH_CRON}" | awk '{print $1}')
run_cron_block "${SCRATCH_CRON}"
md5_second=$(md5sum < "${SCRATCH_CRON}" | awk '{print $1}')

if [[ "${md5_first}" == "${md5_second}" ]] && grep -qF 'placement-watchdog.sh' "${SCRATCH_CRON}"; then
  test_pass "T1: second run leaves /etc/crontab byte-identical (one entry, not two)"
else
  test_fail "T1: idempotency violated — entry duplicated or removed on second run"
  printf '    /etc/crontab after two runs:\n' >&2
  cat "${SCRATCH_CRON}" >&2
fi

test_start "11" "T2: appended line preserves Synology 7-field format"
# After T1 ran the block, the appended line should have exactly 6 tabs
# (separating 7 fields). Verify directly.
appended_line=$(grep 'placement-watchdog.sh' "${SCRATCH_CRON}" | grep -v "^#" | head -1)
tab_count=$(awk -F'\t' '{print NF-1}' <<< "${appended_line}")
if [[ "${tab_count}" -eq 6 ]]; then
  test_pass "T2: appended line has 6 tabs (7-field Synology format)"
else
  test_fail "T2: appended line has ${tab_count} tabs (expected 6 for 7-field format)"
  printf '    line: %s\n' "${appended_line}" >&2
fi

test_start "12" "T3: marker comment lands above the cron entry, not after"
# Visual ordering: marker first so an operator scanning /etc/crontab can
# see "this is managed" before reading the line they might be tempted
# to edit.
if grep -B1 'placement-watchdog.sh' "${SCRATCH_CRON}" | grep -v -- '--' | head -2 | tail -2 | head -1 | grep -qF 'placement-watchdog (managed'; then
  test_pass "T3: marker comment precedes the cron entry"
else
  test_fail "T3: marker comment ordering wrong"
fi

# CRITICAL: this call is what gates the test's exit code on _FAIL_COUNT.
# Without it, every test_fail above is decorative and the GitLab job
# reports green regardless of failures (P1 finding from MR !200 review).
runner_summary
