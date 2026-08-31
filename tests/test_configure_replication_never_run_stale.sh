#!/usr/bin/env bash
# test_configure_replication_never_run_stale.sh — #536 regression.
#
# The stale-detection phase of configure-replication.sh previously marked a
# job stale only when `FailCount > 0`. A managed job that has NEVER run
# (`LastSync=-`, `FailCount=0`) was ignored. The create-phase then SKIPed it
# ("already exists"), CREATED stayed 0, and the #502 initial-sync wait block
# never ran — a presence-based false-pass shape.
#
# Fix (in configure-replication.sh stale-detection loop): also read column 4
# (LastSync) and treat `LastSync="-"` OR `FailCount>0` as stale. The
# recreate then flows through the existing #502 wait block.
#
# This test:
#   - Structural: the loop reads column 4 AND compares against "-".
#   - Behavioral (positive): a job with LastSync="-", FailCount=0 is
#     `CLEAN`ed and `pvesh delete /cluster/replication/<jobid>` is issued.
#   - Behavioral (negative): a healthy job (LastSync=<ts>, FailCount=0) is
#     NOT marked stale — no delete is issued.
# shellcheck disable=SC2016

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIGURE="${REPO_ROOT}/framework/scripts/configure-replication.sh"

# --- Structural guards --------------------------------------------------

stale_block() {
  awk '
    /Checking for stale replication jobs/ { in_blk=1 }
    in_blk { print }
    in_blk && /Cleaned .* stale jobs|No stale replication jobs found/ { exit }
  ' "$CONFIGURE"
}
BLK="$(stale_block)"

test_start "536.a" "stale-detection loop reads pvesr column 4 (LastSync)"
if grep -Eq 'awk .*\{print \$4\}' <<< "$BLK"; then
  test_pass "column 4 (LastSync) is read"
else
  test_fail "column 4 (LastSync) is NOT read"; printf '%s\n' "$BLK" >&2
fi

test_start "536.b" "stale predicate treats LastSync=- as stale (in addition to FailCount>0)"
# Look for either bash form: `[[ ... "-" ]]` or `[[ ... = "-" ]]`.
if grep -Eq '== *"-"|= *"-"' <<< "$BLK"; then
  test_pass "LastSync=- is compared"
else
  test_fail "LastSync=- comparison missing"; printf '%s\n' "$BLK" >&2
fi

test_start "536.c" "nonzero-FailCount detection is preserved (regression floor for #502-adjacent behavior)"
# The nonzero check may take either shape:
#   -  arithmetic:  [[ "$fail_count" -gt 0 ]]      (original)
#   -  string-match: [[ ! "$fail_count" =~ ^0+$ ]] (#594 octal-safe form)
# Both are equivalent given the earlier `^[0-9]+$` shape guard.
if grep -Eq 'fail_count.*-gt 0|!.*"[^"]*fail_count[^"]*".*=~.*\^0\+\$' <<< "$BLK"; then
  test_pass "nonzero-FailCount predicate is preserved (arithmetic or string-match form)"
else
  test_fail "nonzero-FailCount predicate missing (#502-adjacent regression floor)"
  printf '%s\n' "$BLK" >&2
fi

# --- #594 structural guards --------------------------------------------
# The FailCount arithmetic was previously `[[ "${fail_count:-0}" -gt 0 ]]`.
# If a `pvesr` row emitted a non-numeric column 7, bash arithmetic context
# tried to resolve the word as a variable name, and `set -u` aborted the
# whole script. Regression floor: the predicate must (a) contain a numeric
# shape test on fail_count that fires BEFORE the `-gt` arithmetic, and
# (b) treat a non-numeric FailCount as stale (fail-closed), matching the
# same convention the wait-loop uses at its `r_fail` check.

test_start "594.a" "stale predicate guards FailCount arithmetic with a numeric-shape test (#594)"
# The guard must appear inside the stale-detection block. It looks like:
#   [[ ! "${fail_count:-}" =~ ^[0-9]+$ ]]
# or an equivalent shape that binds to `fail_count` and asserts numeric.
if grep -Eq 'fail_count[^=]*=~[^"]*\^\[0-9\]\+\$' <<< "$BLK"; then
  test_pass "numeric-shape guard on fail_count is present"
else
  test_fail "(#594) no numeric-shape guard on fail_count — arithmetic can crash under set -u"
  printf '%s\n' "$BLK" >&2
fi

test_start "594.b" "the numeric guard uses fail-closed polarity: non-numeric OR unset → stale (#594)"
# The `! ... =~` polarity is what makes a non-numeric FailCount mark the
# row stale rather than skip it. Fail-open (missing `!`) would let a
# malformed row appear healthy — the same false-pass shape the #536 fix
# and the #502 wait block work against.
if grep -Eq '!\s+"[^"]*fail_count[^"]*"\s*=~' <<< "$BLK"; then
  test_pass "guard is fail-closed (negated numeric match adds to the stale set)"
else
  test_fail "(#594) guard is not fail-closed — malformed FailCount would be treated as healthy"
  printf '%s\n' "$BLK" >&2
fi

# --- #596 structural: every ssh invocation in the script must bound its
# connect time. Without `-o ConnectTimeout=<N>` a hung TCP connect to an
# unreachable node can stall the script for the OS-default (~2 minutes
# on many systems). The wait-block already uses ConnectTimeout=5; this
# guard requires the rest of the file to match. Scans the whole script,
# not just the stale block — an orphan-zvol / delete / create / refresh
# ssh call without the bound is the same class of hang.

test_start "596.a" "every ssh invocation in the script uses -o ConnectTimeout=<N> (#596)"
# Look for any line that begins an ssh call (not a shell comment, not
# a here-doc fragment) that lacks ConnectTimeout. The pattern binds to
# the ssh word being followed by root@ or by an option/flag rather than
# to `$ssh` or similar embedded references.
# `set -e` in the test runner would otherwise kill on a grep with no
# match; guard each stage with `|| true`. Note that comment lines with
# `#   ssh …` are stripped by the trailing `grep -Ev` step.
#
# NOTE (adversarial-review acknowledgement — codex P3 / claude-fork-1
# P2.2 / claude-fork-2 P3-3): this structural regex requires ConnectTimeout
# to appear on the same logical line as the `ssh` token. It has a blind
# spot for the not-currently-used shape `SSH_OPTS=(-n -o ConnectTimeout=5);
# ssh "${SSH_OPTS[@]}" ...` — the option is stored in a variable and this
# regex would silently pass regardless of whether ConnectTimeout is set.
# If a future refactor introduces variable-held ssh options, this test
# must be widened to inspect the SSH_OPTS definition too. Today no such
# variable exists in this file (`grep -n SSH_OPTS
# framework/scripts/configure-replication.sh` returns empty), so the guard
# binds to the shape actually used.
UNBOUNDED=$(grep -nE '(^|[[:space:]]|=\(|\|)ssh([[:space:]]+-[^ ]+)*[[:space:]]+("root@|-o|-i|-p )' "$CONFIGURE" \
  | grep -v ConnectTimeout \
  | grep -Ev ':[[:space:]]*#' || true)
if [[ -z "$UNBOUNDED" ]]; then
  test_pass "no ssh invocation lacks ConnectTimeout"
else
  test_fail "(#596) ssh invocations without ConnectTimeout:"$'\n'"$UNBOUNDED"
fi

# --- End-to-end harness -------------------------------------------------
# Same shape as tests/test_configure_replication_sync_status.sh: shim
# ssh/yq/sleep, drive pvesr status per source node via a fixture file,
# and use a state file to record which pvesh operations were issued.

make_harness() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "$dir/yq" <<'YQ'
#!/usr/bin/env bash
if [[ "${1:-}" == "-o=json" ]]; then
  target="${!#}"
  case "$target" in
    *applications.yaml) echo '{"applications":{}}' ;;
    *) echo '{"vms":{"gitlab":{"vmid":150,"backup":true}}}' ;;
  esac
  exit 0
fi
q="$*"
case "$q" in
  *".nodes[0].mgmt_ip"*)          echo "10.0.0.1" ;;
  *".nodes[].name"*)              printf '%s\n' pve01 pve02 pve03 ;;
  *".proxmox.storage_pool"*)      echo "vmstore" ;;
  *'select(.name == "pve01")'*)   echo "10.0.0.1" ;;
  *'select(.name == "pve02")'*)   echo "10.0.0.2" ;;
  *'select(.name == "pve03")'*)   echo "10.0.0.3" ;;
  *) echo "" ;;
esac
YQ

  # ssh stub:
  #   - `pvesr status` on <ip> -> emit fixture file pvesr_<lastoctet>.txt
  #   - `pvesh get /cluster/resources`: managed VM 150 on pve01
  #   - `pvesh get /cluster/replication`: return $SHIM_DIR/cluster_replication.json
  #     BEFORE any delete has been recorded; after delete of a job id, drop that
  #     job from the returned list so the STILL_PRESENT wait loop exits.
  #   - `pvesh delete /cluster/replication/<jobid>`: record jobid to deletes.log
  #   - `pvesh create /cluster/replication/<jobid>`: record to creates.log
  #   - `zfs list|destroy`: no-op success.
  cat > "$dir/ssh" <<'SSH'
#!/usr/bin/env bash
host=""; for a in "$@"; do case "$a" in root@*) host="${a#root@}";; esac; done
remote="${!#}"
octet="${host##*.}"

record() { printf '%s\n' "$1" >> "${SHIM_DIR}/$2"; }

case "$remote" in
  *"pvesr status"*)
    f="${SHIM_DIR}/pvesr_${octet}.txt"
    if [[ -f "$f" ]]; then cat "$f"; else exit 0; fi
    ;;
  *"pvesh get /cluster/resources"*)
    echo '[{"vmid":150,"name":"gitlab","node":"pve01"}]'
    ;;
  *"pvesh get /cluster/replication"*)
    # Emit the current job list minus any that were deleted this run.
    src="${SHIM_DIR}/cluster_replication.json"
    del="${SHIM_DIR}/deletes.log"
    if [[ -f "$src" ]]; then
      if [[ -s "${del:-/dev/null}" ]]; then
        python3 - "$src" "$del" <<'PY'
import json, sys
with open(sys.argv[1]) as f: jobs = json.load(f)
with open(sys.argv[2]) as f: deleted = {ln.strip() for ln in f if ln.strip()}
print(json.dumps([j for j in jobs if j.get('id') not in deleted]))
PY
      else
        cat "$src"
      fi
    else
      echo '[]'
    fi
    ;;
  *"pvesh delete /cluster/replication/"*)
    # Extract job id from "pvesh delete /cluster/replication/150-0"
    jid=$(printf '%s\n' "$remote" | sed -E 's|.*/cluster/replication/([^ ]+).*|\1|')
    record "$jid" deletes.log
    ;;
  *"pvesh create /cluster/replication"*)
    # Real call form: `pvesh create /cluster/replication --id <jobid> --target ...`
    # (no trailing slash after `replication`). Extract jobid from the `--id` arg.
    jid=$(printf '%s\n' "$remote" | sed -E 's|.*--id[[:space:]]+([^[:space:]]+).*|\1|')
    record "$jid" creates.log
    echo "created"
    ;;
  *"zfs list"*)  exit 0 ;;
  *"zfs destroy"*) exit 0 ;;
  *) exit 0 ;;
esac
SSH

  cat > "$dir/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP

  chmod +x "$dir/yq" "$dir/ssh" "$dir/sleep"
}

run_e2e() {
  local dir="$1" rc=0
  SHIM_DIR="$dir" PATH="$dir:$PATH" \
    "$CONFIGURE" "*" >"$dir/stdout.txt" 2>"$dir/stderr.txt" || rc=$?
  echo "$rc"
}

HEADER='JobID  Enabled  Target       LastSync             NextSync             Duration  FailCount  State'

# --- 536.d: positive — LastSync=-, FailCount=0 must be CLEANed ----------

test_start "536.d" "a never-run job (LastSync=-, FailCount=0) is picked up and CLEANed"
d="$(mktemp -d)"; make_harness "$d"

# Present the pre-existing job 150-0 -> pve02.
cat > "$d/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"type":"vm"}
]
JSON

# pvesr status on pve01: 150-0 with LastSync=-, FailCount=0, State=-.
{
  echo "$HEADER"
  printf '150-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '-' '2026-07-15_12:34:56' '-' '0' '-'
} > "$d/pvesr_1.txt"
: > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"

_rc="$(run_e2e "$d")"

# The final exit code depends on downstream phases (create + wait) that
# don't matter here. What matters is that the CLEAN step fired.
CLEAN_SEEN=0
grep -q 'CLEAN: 150-0' "$d/stdout.txt" && CLEAN_SEEN=1
DEL_SEEN=0
[[ -s "$d/deletes.log" ]] && grep -qx '150-0' "$d/deletes.log" && DEL_SEEN=1

if [[ "$CLEAN_SEEN" -eq 1 ]] && [[ "$DEL_SEEN" -eq 1 ]]; then
  test_pass "CLEAN: 150-0 logged AND pvesh delete /cluster/replication/150-0 issued"
else
  test_fail "CLEAN=$CLEAN_SEEN DEL=$DEL_SEEN — never-run job was NOT cleaned"
  echo "--- stdout tail ---" >&2; tail -30 "$d/stdout.txt" >&2
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
  echo "--- deletes.log ---" >&2; cat "$d/deletes.log" 2>/dev/null >&2
fi

# 536.d2: after the delete, the create phase runs and issues
# `pvesh create /cluster/replication --id 150-0 ...` — that is the
# tail of the #536 fix shape (delete → recreate → feeds the #502 wait
# block). Assert the recreate happened.
test_start "536.d2" "after CLEAN, the create phase issues pvesh create --id 150-0 (the recreate that feeds the #502 wait block)"
CREATE_SEEN=0
[[ -f "$d/creates.log" ]] && grep -qx '150-0' "$d/creates.log" && CREATE_SEEN=1
if [[ "$CREATE_SEEN" -eq 1 ]]; then
  test_pass "pvesh create /cluster/replication --id 150-0 was issued after cleanup"
else
  test_fail "recreate for 150-0 was NOT issued (creates.log missing or empty)"
  echo "--- creates.log ---" >&2; cat "$d/creates.log" 2>/dev/null >&2 || echo "(no creates.log)" >&2
  echo "--- stdout tail ---" >&2; tail -40 "$d/stdout.txt" >&2
fi
rm -rf "$d"

# --- 536.e: negative — a genuinely-synced job is NOT marked stale --------

test_start "536.e" "a healthy job (LastSync=<ts>, FailCount=0) is NOT marked stale"
d="$(mktemp -d)"; make_harness "$d"

cat > "$d/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"type":"vm"}
]
JSON

# pvesr status on pve01: 150-0 with a real LastSync, FailCount=0, State=OK.
{
  echo "$HEADER"
  printf '150-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '2026-07-15_12:00:00' '2026-07-15_12:01:00' '3.20' '0' 'OK'
} > "$d/pvesr_1.txt"
: > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"

_rc="$(run_e2e "$d")"

CLEAN_SEEN=0
grep -q 'CLEAN: 150-0' "$d/stdout.txt" && CLEAN_SEEN=1
DEL_SEEN=0
[[ -f "$d/deletes.log" ]] && grep -qx '150-0' "$d/deletes.log" && DEL_SEEN=1
NO_STALE=0
grep -q 'No stale replication jobs found' "$d/stdout.txt" && NO_STALE=1

if [[ "$CLEAN_SEEN" -eq 0 ]] && [[ "$DEL_SEEN" -eq 0 ]] && [[ "$NO_STALE" -eq 1 ]]; then
  test_pass "healthy job was left alone (no CLEAN, no delete, 'No stale replication jobs found')"
else
  test_fail "healthy job was misclassified (CLEAN=$CLEAN_SEEN DEL=$DEL_SEEN NO_STALE=$NO_STALE)"
  echo "--- stdout tail ---" >&2; tail -30 "$d/stdout.txt" >&2
  echo "--- deletes.log ---" >&2; cat "$d/deletes.log" 2>/dev/null >&2
fi
rm -rf "$d"

# --- 594.c: behavioral — non-numeric FailCount must not crash the script
# and must be treated as stale (fail-closed). Fixture: pvesr emits a row
# whose column 7 is a bareword ("OK") — the exact shape from the #594
# reproducer. Under the previous predicate this aborted the script with
# `bash: OK: unbound variable`. Under the fixed predicate the row is
# marked stale (CLEAN fires, delete fires).

test_start "594.c" "a row with a non-numeric FailCount does not crash the script and is CLEANed"
d="$(mktemp -d)"; make_harness "$d"

cat > "$d/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"type":"vm"}
]
JSON

# pvesr status on pve01: 150-0 with a bareword ("OK") in column 7 where
# a number is expected. The rest of the columns are shape-valid so the
# early filters (^JobID, job-id regex) let this row through and the fix
# is what has to catch it.
{
  echo "$HEADER"
  printf '150-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '2026-07-15_12:00:00' '2026-07-15_12:01:00' '3.20' 'OK' 'STATE'
} > "$d/pvesr_1.txt"
: > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"

_rc="$(run_e2e "$d")"

# We do not care about the exit code (downstream create+wait phases run
# and their outcome depends on the shim's steady state). What we care
# about:
#   1. The script did NOT die at the stale-detection predicate with
#      `bash: OK: unbound variable`. Under `set -u` that dies with a
#      distinctive stderr message.
#   2. The row was marked stale (CLEAN + delete).
UNBOUND_SEEN=0
grep -qE 'unbound variable' "$d/stderr.txt" && UNBOUND_SEEN=1
CLEAN_SEEN=0
grep -q 'CLEAN: 150-0' "$d/stdout.txt" && CLEAN_SEEN=1
DEL_SEEN=0
[[ -f "$d/deletes.log" ]] && grep -qx '150-0' "$d/deletes.log" && DEL_SEEN=1

if [[ "$UNBOUND_SEEN" -eq 0 ]] && [[ "$CLEAN_SEEN" -eq 1 ]] && [[ "$DEL_SEEN" -eq 1 ]]; then
  test_pass "no unbound-variable crash AND non-numeric FailCount marked stale"
else
  test_fail "(#594) UNBOUND=$UNBOUND_SEEN CLEAN=$CLEAN_SEEN DEL=$DEL_SEEN — non-numeric FailCount not handled"
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
  echo "--- stdout tail ---" >&2; tail -30 "$d/stdout.txt" >&2
  echo "--- deletes.log ---" >&2; cat "$d/deletes.log" 2>/dev/null >&2
fi
rm -rf "$d"

# --- 594.d: behavioral — a FailCount with a leading zero ("08") must be
# marked stale, not misclassified as OK by a bash arithmetic surprise.
# The original `[[ "$fail_count" -gt 0 ]]` crashed at runtime with `08:
# value too great for base` and — because the `[[` returned non-zero
# inside an `||` chain — silently fell through to the LastSync clause,
# reporting the row healthy when FailCount was actually 8. The
# adversarial-review refinement in this MR uses `[[ ! "$fail_count" =~
# ^0+$ ]]` (all-string, no arithmetic) instead. Fixture: pvesr emits
# FailCount="08" with a valid LastSync — under the arithmetic form
# the row would be misclassified OK; under the new form the row is
# stale (CLEAN + delete).
test_start "594.d" "a FailCount with a leading zero ('08') is marked stale, not swallowed by arithmetic (#594)"
d="$(mktemp -d)"; make_harness "$d"

cat > "$d/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"type":"vm"}
]
JSON

{
  echo "$HEADER"
  printf '150-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '2026-07-15_12:00:00' '2026-07-15_12:01:00' '3.20' '08' 'STATE'
} > "$d/pvesr_1.txt"
: > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"

_rc="$(run_e2e "$d")"

# The row must be marked stale. Additionally, the "value too great for
# base" stderr noise that the old arithmetic form emitted must NOT
# appear — the new form uses no arithmetic on fail_count.
BASE_ERR_SEEN=0
grep -qE 'value too great for base' "$d/stderr.txt" && BASE_ERR_SEEN=1
CLEAN_SEEN=0
grep -q 'CLEAN: 150-0' "$d/stdout.txt" && CLEAN_SEEN=1
DEL_SEEN=0
[[ -f "$d/deletes.log" ]] && grep -qx '150-0' "$d/deletes.log" && DEL_SEEN=1

if [[ "$BASE_ERR_SEEN" -eq 0 ]] && [[ "$CLEAN_SEEN" -eq 1 ]] && [[ "$DEL_SEEN" -eq 1 ]]; then
  test_pass "octal-safe: 08 marked stale AND no arithmetic error on stderr"
else
  test_fail "(#594) BASE_ERR=$BASE_ERR_SEEN CLEAN=$CLEAN_SEEN DEL=$DEL_SEEN — leading-zero FailCount not handled"
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
  echo "--- stdout tail ---" >&2; tail -30 "$d/stdout.txt" >&2
  echo "--- deletes.log ---" >&2; cat "$d/deletes.log" 2>/dev/null >&2
fi
rm -rf "$d"

# --- #595 structural + behavioral: `ssh | while read` under pipefail ----
# Previous shape:
#   ssh ... | while IFS= read -r line; do ... done
# Under `set -euo pipefail`, if ssh returns non-zero (unreachable source
# node, auth failure), the pipeline is non-zero and `set -e` kills the
# script. Fix: capture ssh output into a variable with `|| true`, then
# iterate with `<<<`. Regression floor:
#   (a) structural — no `ssh | while` construction survives in the
#       stale-detection block
#   (b) behavioral — the script completes normally when the ssh to a
#       source node fails (exit 255-ish)

test_start "595.a" "stale-detection block does not feed ssh output through a pipe into 'while read'"
# Look for the pattern `ssh ... | while ...` on non-comment lines.
# The block includes a fix-narrative comment that legitimately quotes the
# broken pattern; strip comment lines before matching so the guard binds
# to actual code, not to documentation of what it forbids.
BLK_CODE="$(printf '%s\n' "$BLK" | grep -Ev '^\s*#')"
if grep -Eq 'ssh[^|]*\|[[:space:]]*while' <<< "$BLK_CODE"; then
  test_fail "'ssh | while read' pattern still present — pipefail will kill the script on unreachable node"
  printf '%s\n' "$BLK_CODE" >&2
else
  test_pass "no 'ssh | while' pipeline — pipefail cannot kill the loop"
fi

test_start "595.b" "the loop reads the ssh capture via a here-string or a file redirect (not a pipe)"
# The variable-capture idiom uses `done <<< "$var"` or `done < <(cmd)`;
# both are equivalent from pipefail's perspective (no pipeline in scope).
if grep -Eq 'done[[:space:]]*<<<[[:space:]]*"\$pvesr_status"' <<< "$BLK" \
   || grep -Eq 'done[[:space:]]*<[[:space:]]*<\(' <<< "$BLK"; then
  test_pass "loop reads from a variable capture (pipefail-safe)"
else
  test_fail "loop does not read from a here-string / process substitution — cannot confirm the pipefail fix"
  printf '%s\n' "$BLK" >&2
fi

# 595.c: behavioral — an ssh failure to a source node during
# stale-detection must not kill the script. Under the old shape
# `ssh ... | while read` returned non-zero from the pipe (pipefail),
# `set -e` killed the script mid-loop, and the stale-detection block
# never printed its "No stale replication jobs found" / "Cleaned N stale
# jobs" tail. Under the fix the ssh capture is `|| true`'d, the empty
# capture triggers the "continue" branch, and the block reaches its tail
# — even though the downstream wait phase may later still fail-closed
# for other reasons.
#
# Fixture shape:
#   - pve01 is unreachable — every ssh call to it fails with rc=255.
#   - pve02 and pve03 (also used by the delete/create/refresh calls)
#     return normal responses.
#   - VM 150 already has replication jobs to pve02 AND pve03 in the
#     cluster replication list, so the create phase issues no new jobs
#     (SKIPPED path), CREATED=0, and the initial-sync wait block does
#     not run. The stale phase's ssh-to-pve01 failure is what has to
#     be tolerated.
#   - VM 150's `pvesh delete /cluster/replication/...` and the refresh
#     `pvesh get /cluster/replication` go through FIRST_NODE_IP (pve01
#     in the harness's yq stub). We route those through the "normal"
#     path by dispatching on the request suffix, not the target host.
test_start "595.c" "an ssh failure to a source node during stale-detection does not kill the script"
d="$(mktemp -d)"; make_harness "$d"

# Override the ssh stub. `pvesr status` targets pve01 (source node for
# VM 150) — that's the call we make fail. Everything else answers as
# in the base harness. `pvesh get /cluster/replication` and
# `pvesh get /cluster/resources` also go through pve01 (FIRST_NODE_IP);
# to preserve their normal behavior we dispatch on the remote command
# suffix rather than the target host.
cat > "$d/ssh" <<'SSH'
#!/usr/bin/env bash
host=""; for a in "$@"; do case "$a" in root@*) host="${a#root@}";; esac; done
remote="${!#}"

record() { printf '%s\n' "$1" >> "${SHIM_DIR}/$2"; }

case "$remote" in
  *"pvesr status"*)
    # Simulate an unreachable source node for the stale-detection scan.
    exit 255
    ;;
  *"pvesh get /cluster/resources"*)
    echo '[{"vmid":150,"name":"gitlab","node":"pve01"}]'
    ;;
  *"pvesh get /cluster/replication"*)
    src="${SHIM_DIR}/cluster_replication.json"
    if [[ -f "$src" ]]; then cat "$src"; else echo '[]'; fi
    ;;
  *"pvesh delete /cluster/replication/"*)
    jid=$(printf '%s\n' "$remote" | sed -E 's|.*/cluster/replication/([^ ]+).*|\1|')
    record "$jid" deletes.log
    ;;
  *"pvesh create /cluster/replication"*)
    jid=$(printf '%s\n' "$remote" | sed -E 's|.*--id[[:space:]]+([^[:space:]]+).*|\1|')
    record "$jid" creates.log
    echo "created"
    ;;
  *"zfs list"*)  exit 0 ;;
  *"zfs destroy"*) exit 0 ;;
  *) exit 0 ;;
esac
SSH
chmod +x "$d/ssh"

# Pre-existing healthy replication for VM 150 to both replicas — so the
# create phase SKIPs both, CREATED=0, and the initial-sync wait block
# does not run. This isolates the stale-detection ssh-failure path.
cat > "$d/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"type":"vm"},
  {"id":"150-1","source":"pve01","target":"pve03","guest":150,"type":"vm"}
]
JSON

_rc="$(run_e2e "$d")"

# Under the fix the stale block must reach its "No stale replication
# jobs found" line despite the ssh(pvesr) failure. Under the old shape
# `set -e` killed the script inside the loop and this line was never
# printed.
NO_STALE=0
grep -q 'No stale replication jobs found' "$d/stdout.txt" && NO_STALE=1
# The script must also reach the create phase's summary (all SKIPPED).
REACHED_SKIP=0
grep -qE 'SKIP: gitlab .* pve02 \(already exists\)|SKIP: gitlab .* pve0[23] \(already exists\)' "$d/stdout.txt" && REACHED_SKIP=1
# Adversarial-review refinement: the ssh failure must produce a WARN on
# stderr naming the source node so the operator can see what was
# skipped. The empty-capture case (rc=0, no output) stays silent.
WARN_SEEN=0
grep -qE 'WARN:.*could not read pvesr status from pve01' "$d/stderr.txt" && WARN_SEEN=1

if [[ "$NO_STALE" -eq 1 ]] && [[ "$REACHED_SKIP" -eq 1 ]] && [[ "$WARN_SEEN" -eq 1 ]]; then
  test_pass "stale block completed AND WARN emitted for unreachable source (rc=$_rc)"
else
  test_fail "(#595) NO_STALE=$NO_STALE REACHED_SKIP=$REACHED_SKIP WARN=$WARN_SEEN rc=$_rc — script died or WARN missing"
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
  echo "--- stdout tail ---" >&2; tail -30 "$d/stdout.txt" >&2
fi
rm -rf "$d"

runner_summary
