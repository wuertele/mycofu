#!/usr/bin/env bash
# V2.3: rotate-sops-recipient.sh full-driver hermetic fixture.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

ROTATE_SCRIPT="${REPO_ROOT}/framework/scripts/rotate-sops-recipient.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

RUN_OUTPUT=""
RUN_STATUS=0
UTC_STAMP="20260726T120000Z"
OLD_PRIVATE="SENTINEL_OLD_SOPS_PRIVATE_KEY"
NEW_PRIVATE="SENTINEL_NEW_SOPS_PRIVATE_KEY"

stat_mode() {
  local path="$1"
  if stat -f %Lp "$path" >/dev/null 2>&1; then
    stat -f %Lp "$path"
  else
    stat -c %a "$path"
  fi
}

first_line_number() {
  local pattern="$1"
  local file="$2"
  grep -Fn "$pattern" "$file" | head -1 | cut -d: -f1 || true
}

make_fixture() {
  local name="$1"
  local fixture="${TMP_DIR}/${name}"
  local repo="${fixture}/repo"
  local shims="${fixture}/shims"

  mkdir -p \
    "${repo}/framework/scripts" \
    "${repo}/site/sops" \
    "${repo}/tests/hil/bfnet/sops" \
    "${repo}/site" \
    "$shims" \
    "${fixture}/home" \
    "${fixture}/escrow"

  cp "$ROTATE_SCRIPT" "${repo}/framework/scripts/rotate-sops-recipient.sh"
  chmod +x "${repo}/framework/scripts/rotate-sops-recipient.sh"
  printf '%s\n' 'fixture flake' > "${repo}/flake.nix"
  cat > "${repo}/.sops.yaml" <<'EOF'
creation_rules:
  - path_regex: site/sops/.*\.yaml$
    age: age1oldfixture
  - path_regex: tests/hil/bfnet/sops/.*\.yaml$
    age: age1oldfixture
EOF
  cat > "${repo}/site/sops/secrets.yaml" <<'EOF'
sops:
  fixture: true
encrypted: site
EOF
  cat > "${repo}/tests/hil/bfnet/sops/secrets.yaml" <<'EOF'
sops:
  fixture: true
encrypted: hil
EOF
  cat > "${repo}/site/rotation-manifest.yaml" <<'EOF'
- match: sops_age_key
  holders:
    - name: workstation
      delivery: local-file
    - name: cicd
      delivery: register-runner
EOF
  {
    printf '%s\n' '# public key: age1oldfixture'
    printf '%s\n' "$OLD_PRIVATE"
  } > "${repo}/operator.age.key"
  chmod 0400 "${repo}/operator.age.key"

  cat > "${repo}/framework/scripts/check-rotation-manifest.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'check-rotation-manifest' >> "$EVENT_LOG"
exit 0
EOF
  chmod +x "${repo}/framework/scripts/check-rotation-manifest.sh"

  cat > "${repo}/framework/scripts/register-runner.sh" <<'EOF'
#!/usr/bin/env bash
printf 'register-runner|%s\n' "$*" >> "$EVENT_LOG"
exit 0
EOF
  chmod +x "${repo}/framework/scripts/register-runner.sh"

  # tofu-wrapper.sh shim. The pre-#817 driver invoked this to assert
  # `plan -detailed-exitcode` returned rc 0. That contract is unsatisfiable
  # on any real cluster with pre-existing dev/prod image drift — real tofu
  # exits 2 on drift, and under the driver's `set -e` that aborted the
  # rotation. FAKE_TOFU_PLAN_RC (default 0 for existing tests; 2 for the
  # #817 antibody scenario) models that real-cluster contract so a driver
  # regression that re-adds the plan call is caught end-to-end.
  cat > "${repo}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
printf 'tofu-wrapper|%s\n' "$*" >> "$EVENT_LOG"
exit "${FAKE_TOFU_PLAN_RC:-0}"
EOF
  chmod +x "${repo}/framework/scripts/tofu-wrapper.sh"

  cat > "${shims}/yq" <<'EOF'
#!/usr/bin/env bash
mode=""
if [[ "${1:-}" == "-r" || "${1:-}" == "-e" ]]; then
  mode="$1"
  expr="${2:-}"
else
  expr="${1:-}"
fi
case "$expr" in
  '.creation_rules[] | .path_regex // ""')
    printf '%s\n' 'site/sops/.*\.yaml$'
    printf '%s\n' 'tests/hil/bfnet/sops/.*\.yaml$'
    ;;
  'has("sops")')
    exit 0
    ;;
  '.[] | select(.match == "sops_age_key") | .holders[]? | [.name, .delivery] | @tsv')
    printf 'workstation\tlocal-file\n'
    printf 'cicd\tregister-runner\n'
    ;;
  '.vms.cicd.ip // ""')
    printf '%s\n' '203.0.113.9'
    ;;
  *)
    echo "yq shim: unexpected expression: $expr" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${shims}/yq"

  # site/config.yaml stub so `-r` yq reads (delegated to the shim above) do
  # not hit a missing file. The shim resolves the CIDR by expression, not by
  # parsing this content — the file just needs to be readable.
  printf '%s\n' 'vms:' 'stub: true' > "${repo}/site/config.yaml"

  # ssh shim: the transactional preflight probes cicd SSH reachability with
  # `ssh -n root@<cicd-ip> true`. This shim satisfies that probe without
  # touching the network. Behavior is toggleable via FAKE_SSH_MODE:
  #   ok      — exit 0 (default; used by success/abort scenarios)
  #   unreach — exit 255 (used to prove the driver fails closed at preflight
  #              when cicd is not reachable)
  cat > "${shims}/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-probe|%s\n' "$*" >> "$EVENT_LOG"
case "${FAKE_SSH_MODE:-ok}" in
  ok)      exit 0 ;;
  unreach) exit 255 ;;
  *)       echo "ssh shim: unknown FAKE_SSH_MODE ${FAKE_SSH_MODE}" >&2; exit 1 ;;
esac
EOF
  chmod +x "${shims}/ssh"

  cat > "${shims}/age-keygen" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || { echo "age-keygen shim: missing -o" >&2; exit 1; }
{
  printf '%s\n' '# public key: age1newfixture'
  printf '%s\n' 'SENTINEL_NEW_SOPS_PRIVATE_KEY'
} > "$out"
EOF
  chmod +x "${shims}/age-keygen"

  cat > "${shims}/sops" <<'EOF'
#!/usr/bin/env bash
# V2.3 sops shim — strict about SOPS_AGE_KEY_FILE on EVERY subcommand.
#
# Issue #802 fixture requirement: reproduce the mid-run path invalidation
# where the driver relies on ambient SOPS_AGE_KEY_FILE for a mutating call
# after Step 4 has moved the file that SOPS_AGE_KEY_FILE points at. This
# shim fails closed if SOPS_AGE_KEY_FILE is unset OR points at a
# non-existent/empty file — that is the exact live-run symptom.
set -euo pipefail
repo="${FAKE_REPO_ROOT}"
arg_string="$*"
sub="${1:-}"

require_key_present() {
  local key="${SOPS_AGE_KEY_FILE:-}"
  if [[ -z "$key" ]]; then
    printf 'sops-shim-error|%s|SOPS_AGE_KEY_FILE unset\n' "$sub" >> "$EVENT_LOG"
    echo "sops shim: SOPS_AGE_KEY_FILE unset for sub-command '${sub}'" >&2
    exit 1
  fi
  if [[ ! -s "$key" ]]; then
    printf 'sops-shim-error|%s|SOPS_AGE_KEY_FILE stale: %s\n' "$sub" "$key" >> "$EVENT_LOG"
    echo "sops shim: SOPS_AGE_KEY_FILE points at missing/empty file: ${key}" >&2
    exit 1
  fi
}

require_key_material_matches_state() {
  # Given a valid $SOPS_AGE_KEY_FILE, verify the recipient state in .sops.yaml
  # is compatible with this key. Used by mutating calls (updatekeys/set) so a
  # driver that passes a moved/stale path is rejected here too — not just by
  # the existence check above.
  local key="$SOPS_AGE_KEY_FILE"
  if grep -Fq 'SENTINEL_NEW_SOPS_PRIVATE_KEY' "$key"; then
    grep -Fq 'age1newfixture' "${repo}/.sops.yaml" || {
      echo "sops shim: new key presented but new recipient not in .sops.yaml" >&2; exit 1; }
    return 0
  fi
  if grep -Fq 'SENTINEL_OLD_SOPS_PRIVATE_KEY' "$key"; then
    grep -Fq 'age1oldfixture' "${repo}/.sops.yaml" || {
      echo "sops shim: old key presented after old recipient retired" >&2; exit 1; }
    return 0
  fi
  echo "sops shim: unknown key material in ${key}" >&2
  exit 1
}

case "$sub" in
  updatekeys)
    require_key_present
    require_key_material_matches_state
    file="${@: -1}"
    rel="${file#${repo}/}"
    if grep -Fq 'age1newfixture' "${repo}/.sops.yaml" && grep -Fq 'age1oldfixture' "${repo}/.sops.yaml"; then
      printf 'updatekeys-both|%s\n' "$rel" >> "$EVENT_LOG"
    elif grep -Fq 'age1newfixture' "${repo}/.sops.yaml" && ! grep -Fq 'age1oldfixture' "${repo}/.sops.yaml"; then
      printf 'updatekeys-newonly|%s\n' "$rel" >> "$EVENT_LOG"
    else
      printf 'updatekeys-other|%s\n' "$rel" >> "$EVENT_LOG"
    fi
    exit 0
    ;;
  set)
    require_key_present
    require_key_material_matches_state
    # Issue #806 contract: real SOPS requires the value to be a JSON-encoded
    # string. Pre-#806, the shim accepted `--value-file` with a raw path — the
    # exact reason six review rounds missed the raw-value defect. The r3
    # fixture matches the driver's portable form:
    #   * `sops set --value-file <secrets> <index> /dev/stdin` (positional
    #     `/dev/stdin` — this form is portable to older sops that lack the
    #     newer `--value-stdin` flag),
    #   * stdin content parsed as JSON, exit 7 with SOPS's exact stderr on
    #     non-JSON (matches real `sops set` reproduced 2026-07-30 on
    #     sops 3.12.1 AND the CI runner's older sops version).
    # A driver regression to a raw value file (`--value-file <secrets>
    # <index> <raw_file>`) fails here with `sops shim: set value must be
    # /dev/stdin` even if it never opens the file.
    if [[ "${2:-}" != "--value-file" ]]; then
      echo "sops shim: set requires --value-file (issue #806)" >&2
      exit 1
    fi
    if [[ "${5:-}" != "/dev/stdin" ]]; then
      echo "sops shim: set value must be /dev/stdin (issue #806 — jq -Rs pipe)" >&2
      exit 1
    fi
    stdin_bytes="$(cat)"
    if ! printf '%s' "$stdin_bytes" | jq empty >/dev/null 2>&1; then
      echo "Value for --set is not valid JSON" >&2
      exit 7
    fi
    [[ -f "${EXPECTED_ESCROW}" ]] || { echo "sops shim: old key was not escrowed before set" >&2; exit 1; }
    printf 'sops-set|%s|escrow-present\n' "${4:-}" >> "$EVENT_LOG"
    exit 0
    ;;
  -d)
    require_key_present
    file="${2:-}"
    key_file="$SOPS_AGE_KEY_FILE"
    if grep -Fq 'SENTINEL_NEW_SOPS_PRIVATE_KEY' "$key_file"; then
      if [[ "${FAKE_WORKSTATION_PROBE_FAIL:-0}" == "1" && "$key_file" == "${repo}/operator.age.key" ]]; then
        echo "sops shim: injected new-key probe failure" >&2
        exit 47
      fi
      grep -Fq 'age1newfixture' "${repo}/.sops.yaml" || { echo "sops shim: new recipient missing" >&2; exit 1; }
      printf 'decrypt-new|%s\n' "${file#${repo}/}" >> "$EVENT_LOG"
      exit 0
    fi
    if grep -Fq 'SENTINEL_OLD_SOPS_PRIVATE_KEY' "$key_file"; then
      grep -Fq 'age1oldfixture' "${repo}/.sops.yaml" || { echo "sops shim: old recipient retired" >&2; exit 1; }
      printf 'decrypt-old|%s\n' "${file#${repo}/}" >> "$EVENT_LOG"
      exit 0
    fi
    echo "sops shim: unknown key material" >&2
    exit 1
    ;;
  *)
    echo "sops shim: unexpected args: $arg_string" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${shims}/sops"

  cat > "${shims}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-C" ]]; then
  shift 2
fi
cmd="${1:-}"
shift || true
case "$cmd" in
  status)
    # `git status --porcelain -- <paths>` is used by the #813 post-commit
    # assertion (assert_commit_paths_clean). Emit lines from
    # FAKE_GIT_STATUS_PORCELAIN if set, otherwise a clean tree (empty).
    # The scoping `-- <paths>` is not modelled here; the fixture assumes
    # the injected lines correspond to paths the driver committed.
    if [[ -n "${FAKE_GIT_STATUS_PORCELAIN:-}" ]]; then
      printf '%s\n' "$FAKE_GIT_STATUS_PORCELAIN"
    fi
    exit 0
    ;;
  add)
    printf 'git-add|%s\n' "$*" >> "$EVENT_LOG"
    exit 0
    ;;
  diff)
    # Distinguish three calls the driver now makes:
    #   1. `diff --cached --quiet`                        — R1: pre-stage detection
    #   2. `diff --cached --quiet -- <paths>`             — commit-gate after add
    #   3. `diff --quiet HEAD -- <paths>`                 — preflight tracked-mod
    has_cached=0
    has_head=0
    has_double_dash=0
    for arg in "$@"; do
      case "$arg" in
        --cached) has_cached=1 ;;
        HEAD) has_head=1 ;;
        --) has_double_dash=1 ;;
      esac
    done
    if [[ "$has_cached" -eq 1 && "$has_double_dash" -eq 0 && "$has_head" -eq 0 ]]; then
      # (1) Pre-stage detection. Default clean (exit 0);
      # FAKE_GIT_HAS_PRESTAGED=1 forces exit 1 (has staged content).
      if [[ "${FAKE_GIT_HAS_PRESTAGED:-0}" == "1" ]]; then
        exit 1
      fi
      exit 0
    fi
    if [[ "$has_cached" -eq 1 ]]; then
      # (2) Post-add commit gate — pretend there are staged changes so the
      # `if git diff --cached --quiet -- ...; then no-op; else commit;`
      # branch in git_commit_if_needed proceeds to commit.
      exit 1
    fi
    # (3) Preflight tracked-mod check on specific paths. Default clean
    # (exit 0); FAKE_GIT_DIFF_HEAD_DIRTY=1 forces a "dirty" report.
    if [[ "${FAKE_GIT_DIFF_HEAD_DIRTY:-0}" == "1" ]]; then
      exit 1
    fi
    exit 0
    ;;
  ls-files)
    # `git ls-files --error-unmatch -- <rel>` is used by the R1 preflight
    # to reject untracked SOPS-shaped files caught by
    # enumerate_sops_files's find. Log the check so fixtures can assert.
    # Default exit 0 (tracked); if the last positional arg matches a
    # substring of FAKE_GIT_UNTRACKED_PATH, exit 1 (untracked).
    printf 'git-ls-files|%s\n' "$*" >> "$EVENT_LOG"
    if [[ -n "${FAKE_GIT_UNTRACKED_PATH:-}" ]]; then
      # Match on the final positional argument (the path).
      last_arg=""
      for arg in "$@"; do
        last_arg="$arg"
      done
      case "$last_arg" in
        *"${FAKE_GIT_UNTRACKED_PATH}"*) exit 1 ;;
      esac
    fi
    exit 0
    ;;
  commit)
    printf 'git-commit|%s\n' "$*" >> "$EVENT_LOG"
    exit 0
    ;;
  rev-parse)
    printf '%s\n' '049-rotation-drivers'
    ;;
  *)
    echo "git shim: unexpected command: $cmd $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${shims}/git"

  : > "${fixture}/events.log"
  printf '%s\n' "$fixture"
}

run_rotate() {
  local fixture="$1"
  local fail_probe="${2:-0}"
  local args="${3-__default__}"
  local ambient_mode="${4:-unset}"   # unset | canonical  (issue #802 (a) vs (b))
  local ssh_mode="${5:-ok}"          # ok | unreach
  local repo="${fixture}/repo"
  local escrow="${fixture}/escrow/${UTC_STAMP}/operator.age.key"
  [[ "$args" == "__default__" ]] && args="--i-mean-it"

  local -a env_pairs=(
    PATH="${fixture}/shims:${PATH}"
    HOME="${fixture}/home"
    FAKE_REPO_ROOT="$repo"
    FAKE_SSH_MODE="$ssh_mode"
    EVENT_LOG="${fixture}/events.log"
    EXPECTED_ESCROW="$escrow"
    FAKE_WORKSTATION_PROBE_FAIL="$fail_probe"
    ROTATE_ESCROW_BASE="${fixture}/escrow"
    ROTATE_UTC_STAMP="$UTC_STAMP"
    ROTATE_EVIDENCE_DIR="${fixture}/evidence"
  )
  # Issue #802 (b): mimic the DRT-009 export of SOPS_AGE_KEY_FILE at the
  # canonical path — the path Step 4 will move mid-run. The driver must not
  # depend on this env being valid after the move.
  if [[ "$ambient_mode" == "canonical" ]]; then
    env_pairs+=( SOPS_AGE_KEY_FILE="${repo}/operator.age.key" )
  fi
  # Scenario (a): SOPS_AGE_KEY_FILE unset entirely. `env -i` would strip too
  # much (breaking PATH lookups); instead use `env -u` to unset just this var.
  local env_bin
  if [[ "$ambient_mode" == "unset" ]]; then
    env_bin=(env -u SOPS_AGE_KEY_FILE)
  else
    env_bin=(env)
  fi

  : > "${fixture}/events.log"
  set +e
  RUN_OUTPUT="$(
    "${env_bin[@]}" "${env_pairs[@]}" \
      bash -c 'cd "$1" && framework/scripts/rotate-sops-recipient.sh $2' bash "$repo" "$args" 2>&1
  )"
  RUN_STATUS=$?
  set -e
}

NO_FLAG_FIXTURE="$(make_fixture no-flag)"
run_rotate "$NO_FLAG_FIXTURE" 0 ""

test_start "V2.3-i-mean-it" "--i-mean-it is required before mutation"
if [[ "$RUN_STATUS" -eq 2 ]] &&
   grep -Fq 'Plan: rotate the M1 SOPS age recipient' <<< "$RUN_OUTPUT" &&
   [[ ! -s "${NO_FLAG_FIXTURE}/events.log" ]] &&
   grep -Fq 'age1oldfixture' "${NO_FLAG_FIXTURE}/repo/.sops.yaml"; then
  test_pass "missing --i-mean-it prints plan and mutates nothing"
else
  test_fail "missing --i-mean-it did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

SUCCESS_FIXTURE="$(make_fixture success)"
run_rotate "$SUCCESS_FIXTURE"

test_start "V2.3-success-order" "driver order is add-recipient, updatekeys, escrow, distribute, retire"
EVENTS="${SUCCESS_FIXTURE}/events.log"
BOTH_LINE="$(first_line_number 'updatekeys-both|site/sops/secrets.yaml' "$EVENTS")"
SET_LINE="$(first_line_number 'sops-set|["sops_age_key"]|escrow-present' "$EVENTS")"
# The workstation probe is the LAST decrypt-new|site/sops/... — it runs
# AFTER Step 5's install and AFTER the assert_operative_key_can_decrypt
# probes issued by the phase-aware fix for issue #802 (defect 2).
WORKSTATION_LINE="$(grep -Fn 'decrypt-new|site/sops/secrets.yaml' "$EVENTS" | tail -1 | cut -d: -f1 || true)"
REGISTER_LINE="$(first_line_number 'register-runner|--deliver-secrets' "$EVENTS")"
COMMIT_LINE="$(first_line_number 'git-commit|-m rotation: add new SOPS age recipient' "$EVENTS")"
RETIRE_LINE="$(first_line_number 'updatekeys-newonly|site/sops/secrets.yaml' "$EVENTS")"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ -n "$BOTH_LINE" && -n "$SET_LINE" && -n "$WORKSTATION_LINE" && -n "$REGISTER_LINE" && -n "$COMMIT_LINE" && -n "$RETIRE_LINE" ]] &&
   [[ "$BOTH_LINE" -lt "$SET_LINE" ]] &&
   [[ "$SET_LINE" -lt "$WORKSTATION_LINE" ]] &&
   [[ "$WORKSTATION_LINE" -lt "$REGISTER_LINE" ]] &&
   [[ "$REGISTER_LINE" -lt "$COMMIT_LINE" ]] &&
   [[ "$COMMIT_LINE" -lt "$RETIRE_LINE" ]] &&
   grep -Fq 'updatekeys-both|tests/hil/bfnet/sops/secrets.yaml' "$EVENTS" &&
   grep -Fq 'updatekeys-newonly|tests/hil/bfnet/sops/secrets.yaml' "$EVENTS"; then
  test_pass "event log proves the full ordered ladder across both creation-rule files"
else
  test_fail "success path order did not match the M1 ladder"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$EVENTS" >&2
fi

test_start "V2.3-escrow-and-proof" "old key is escrowed 0400 and prove-negative captures non-zero stderr only"
ESCROW_OLD="${SUCCESS_FIXTURE}/escrow/${UTC_STAMP}/operator.age.key"
EVIDENCE="${SUCCESS_FIXTURE}/evidence/prove-negative.txt"
if [[ -f "$ESCROW_OLD" ]] &&
   [[ "$(stat_mode "$ESCROW_OLD")" == "400" ]] &&
   [[ ! -f "${SUCCESS_FIXTURE}/repo/operator.age.key" || "$(grep -F "$NEW_PRIVATE" "${SUCCESS_FIXTURE}/repo/operator.age.key" || true)" == "$NEW_PRIVATE" ]] &&
   grep -Fq 'exit=1' "$EVIDENCE" &&
   grep -Fq 'stderr=' "$EVIDENCE" &&
   ! grep -Fq "$OLD_PRIVATE" "$EVIDENCE" &&
   grep -Fq 'SOPS_AGE_KEY_FILE="$ESCROW_OLD_KEY" sops -d "$SECRETS_FILE" >/dev/null 2>"$stderr_file"' "$ROTATE_SCRIPT"; then
  test_pass "escrow mode and prove-negative stdout redirection are pinned"
else
  test_fail "escrow/prove-negative assertions failed"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "V2.3-sentinel-leak" "sentinel private key material never appears in captured output or logs"
if ! grep -Fq "$OLD_PRIVATE" <<< "$RUN_OUTPUT" &&
   ! grep -Fq "$NEW_PRIVATE" <<< "$RUN_OUTPUT" &&
   ! grep -Fq "$OLD_PRIVATE" "$EVENTS" &&
   ! grep -Fq "$NEW_PRIVATE" "$EVENTS"; then
  test_pass "driver stdout/stderr and fixture logs contain no sentinel private bytes"
else
  test_fail "sentinel private key material leaked to captured output or logs"
fi

ABORT_FIXTURE="$(make_fixture abort-probe)"
run_rotate "$ABORT_FIXTURE" 1

test_start "V2.3-abort-preserves-both-keys" "probe failure aborts before old-recipient removal"
ABORT_EVENTS="${ABORT_FIXTURE}/events.log"
ABORT_ESCROW="${ABORT_FIXTURE}/escrow/${UTC_STAMP}/operator.age.key"
set +e
env PATH="${ABORT_FIXTURE}/shims:${PATH}" \
  FAKE_REPO_ROOT="${ABORT_FIXTURE}/repo" \
  EVENT_LOG="${ABORT_FIXTURE}/events.log" \
  EXPECTED_ESCROW="$ABORT_ESCROW" \
  SOPS_AGE_KEY_FILE="$ABORT_ESCROW" \
  sops -d "${ABORT_FIXTURE}/repo/site/sops/secrets.yaml" >/dev/null 2>"${ABORT_FIXTURE}/post-abort-probe.stderr"
POST_ABORT_PROBE=$?
set -e
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'age1oldfixture' "${ABORT_FIXTURE}/repo/.sops.yaml" &&
   grep -Fq 'age1newfixture' "${ABORT_FIXTURE}/repo/.sops.yaml" &&
   ! grep -Fq 'updatekeys-newonly' "$ABORT_EVENTS" &&
   [[ "$POST_ABORT_PROBE" -eq 0 ]]; then
  test_pass "aborted tree keeps both recipients and old-key rollback decrypt still works"
else
  test_fail "abort path retired old recipient or lost decryptability"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$ABORT_EVENTS" >&2
  cat "${ABORT_FIXTURE}/post-abort-probe.stderr" >&2
fi

# === Issue #802 defect coverage ===
# The scenarios below reproduce the failure modes described in
# https://gitlab.prod.wuertele.com/root/mycofu/-/issues/802 :
#   (a) SOPS_AGE_KEY_FILE unset — driver must succeed on its own
#   (b) SOPS_AGE_KEY_FILE set to the canonical path Step 4 will MOVE —
#       driver must NOT crash after the move (mid-run path invalidation).
#       The sops shim requires SOPS_AGE_KEY_FILE=<existing file> on every
#       sub-command, so a driver that leaves the ambient env pointing at
#       the moved canonical path is rejected by the shim — reproducing
#       the DRT-009-20260730-132641.log failure signature end-to-end.
# The preflight scenario at the end also exercises the transactional
# fail-closed contract (issue #802 scope item 3).

I802A_FIXTURE="$(make_fixture i802-a-env-unset)"
run_rotate "$I802A_FIXTURE" 0 "__default__" unset ok

test_start "802-a-env-unset" "driver succeeds with SOPS_AGE_KEY_FILE unset in the ambient env"
I802A_EVENTS="${I802A_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   ! grep -Fq 'sops-shim-error' "$I802A_EVENTS" &&
   grep -Fq 'updatekeys-both|site/sops/secrets.yaml' "$I802A_EVENTS" &&
   grep -Fq 'updatekeys-newonly|site/sops/secrets.yaml' "$I802A_EVENTS" &&
   grep -Fq 'sops-set|["sops_age_key"]|escrow-present' "$I802A_EVENTS"; then
  test_pass "driver ran the full ladder without SOPS_AGE_KEY_FILE in its environment"
else
  test_fail "driver failed or shim rejected a sops call when SOPS_AGE_KEY_FILE was unset"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$I802A_EVENTS" >&2
fi

I802B_FIXTURE="$(make_fixture i802-b-canonical-then-moved)"
run_rotate "$I802B_FIXTURE" 0 "__default__" canonical ok

test_start "802-b-mid-run-path-invalidation" "driver survives Step 4 moving the ambient SOPS_AGE_KEY_FILE path"
I802B_EVENTS="${I802B_FIXTURE}/events.log"
I802B_ESCROW="${I802B_FIXTURE}/escrow/${UTC_STAMP}/operator.age.key"
# The shim rejects any sops call whose SOPS_AGE_KEY_FILE points at a
# non-existent path. After Step 4's `mv ${repo}/operator.age.key ${escrow}`,
# the ambient SOPS_AGE_KEY_FILE (set by scenario (b)) points at a file that
# no longer exists. If the driver had NOT re-pointed to OPERATIVE_KEY on
# Step 5's `sops set` (or Step 7's `sops updatekeys`), the shim would log a
# 'sops-shim-error' entry naming SOPS_AGE_KEY_FILE. Passing requires:
#   - exit status 0 (no crash),
#   - zero sops-shim-error entries in the event log,
#   - the driver reached the retire-old step (updatekeys-newonly seen),
#   - the escrow file exists (proving Step 4 mv ran and invalidated the
#     ambient path — this is the real failure mode being reproduced).
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ -f "$I802B_ESCROW" ]] &&
   ! grep -Fq 'sops-shim-error' "$I802B_EVENTS" &&
   grep -Fq 'updatekeys-newonly|site/sops/secrets.yaml' "$I802B_EVENTS"; then
  test_pass "post-escrow sops calls used OPERATIVE_KEY, not the invalidated ambient env"
else
  test_fail "driver invalidated its own key path mid-run (issue #802 defect 2)"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$I802B_EVENTS" >&2
fi

# Scenario (c) intentionally omitted: scenario (b) above already carries the
# end-to-end coverage that the phase-aware operative-key assertion is doing
# real work. A separate source-string grep for the assertion text would fire
# on benign refactor movement (renaming the reason string, inlining the
# assertion into a helper) — failing count (c) of the Principle 11
# three-count test in .claude/rules/design-taste.md. Round-1 review agreed.

I802R_FIXTURE="$(make_fixture i802-preflight-cicd-unreach)"
run_rotate "$I802R_FIXTURE" 0 "__default__" canonical unreach

test_start "802-preflight-cicd-ssh" "preflight fails closed when the cicd holder is not reachable"
I802R_EVENTS="${I802R_FIXTURE}/events.log"
# Preflight runs BEFORE any mutation. When cicd SSH is unreachable, the
# driver must exit non-zero without touching .sops.yaml or writing to the
# escrow directory. This is the transactionality contract of issue #802 (3).
if [[ "$RUN_STATUS" -ne 0 ]] &&
   ! grep -Fq 'updatekeys-both' "$I802R_EVENTS" &&
   ! grep -Fq 'updatekeys-newonly' "$I802R_EVENTS" &&
   ! grep -Fq 'sops-set' "$I802R_EVENTS" &&
   grep -Fq 'age1oldfixture' "${I802R_FIXTURE}/repo/.sops.yaml" &&
   ! grep -Fq 'age1newfixture' "${I802R_FIXTURE}/repo/.sops.yaml"; then
  test_pass "preflight aborted before touching .sops.yaml or invoking sops updatekeys/set"
else
  test_fail "preflight failed to fail closed on cicd SSH unreachable"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$I802R_EVENTS" >&2
fi

# --------------------------------------------------------------------------
# Issue #806 real-SOPS round-trip antibody.
#
# The shim assertions above catch a driver regression BY MODELLING the
# real SOPS contract (JSON stdin → exit 7 on non-JSON, matching the live
# reproduction on sops 3.12.1). But models drift. This assertion runs the
# exact pipeline pattern the driver uses (`jq -Rs . < FILE | sops set
# --value-stdin ...`) against a real sops binary and a real age recipient,
# so any pipeline that fails end-to-end fails here — even if the shim has
# been weakened to accept it. The value chosen has a trailing newline
# (matches the drivers' escrow files) and an embedded quote (would break
# a naive `"${var}"` interpolation), so a lossless round-trip is a real
# check, not a placeholder.
# --------------------------------------------------------------------------
test_start "806-realsops-roundtrip" "issue #806: jq -Rs | sops set --value-file /dev/stdin round-trips a raw multi-byte value losslessly"
# The antibody uses `sops set --value-file` — added in sops 3.10 (see
# getsops/sops changelog). The cicd runner currently ships sops 3.9.4
# (verified live 2026-07-31 during pipeline #1926 debug), which lacks
# BOTH --value-file and --value-stdin. Rotation drivers never RUN on
# cicd — they are operator-workstation attended operations, and the
# operator workstation has sops 3.12.1 — so the drivers themselves stay
# on the portable --value-file /dev/stdin form. The antibody can only
# run where sops has the flag, so skip cleanly on older sops with a WARN
# rather than fail-red the pipeline. Follow-up to bump cicd's sops so
# CI regains real-sops coverage: filed as #809.
# Capture sops help text in one shot before pattern-matching so `grep -q`'s
# early-exit SIGPIPE to sops (under `set -o pipefail`) can't be mistaken for
# "flag absent" — the exact false-SKIP that hid the CI failure once. Any
# error running sops itself (nonexistent, permission denied) also collapses
# to a SKIP with a clear reason.
sops_help_out="$(sops set --help 2>&1 || true)"
if [[ "$sops_help_out" != *'--value-file'* ]]; then
  test_skip "sops on this host predates --value-file (rotation drivers run on operator workstation only, where sops is newer; see #809 to bump cicd's sops)"
else
  REAL_DIR="$(mktemp -d)"
  (
    cd "$REAL_DIR"
    age-keygen -o key.txt >/dev/null 2>&1
    pub="$(grep -F 'public key:' key.txt | awk '{print $NF}')"
    cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: ^secrets\.yaml$
    age: ${pub}
EOF
    printf '%s\n' 'seed: bootstrap' > secrets.yaml
    SOPS_AGE_KEY_FILE=key.txt sops -e -i secrets.yaml
    # Value with newline + double quote — the two byte classes that break
    # naive `sops set "$key" "\"$val\""` interpolation. jq -Rs handles both.
    printf 'line1\nquote"here\n' > payload
    jq -Rs . < payload \
      | SOPS_AGE_KEY_FILE=key.txt sops set --value-file secrets.yaml '["payload"]' /dev/stdin >/dev/null
    extracted="$(SOPS_AGE_KEY_FILE=key.txt sops -d --extract '["payload"]' secrets.yaml)"
    expected="$(cat payload)"
    [[ "$extracted" == "$expected" ]]
  )
  REAL_RC=$?
  rm -rf "$REAL_DIR"
  if [[ "$REAL_RC" -eq 0 ]]; then
    test_pass "real sops round-trip is lossless with the driver's jq -Rs / --value-file /dev/stdin pipeline"
  else
    test_fail "real sops round-trip diverged; driver pipeline is not lossless (issue #806 antibody)"
  fi
fi

# ==========================================================================
# Issue #813 defect 1 — commit-set is derived from SOPS_FILE_LIST, not
# hardcoded to two paths.
#
# Pre-#813: git_commit_if_needed staged exactly `.sops.yaml` and
# `site/sops/secrets.yaml`, even though `sops updatekeys` re-encrypted
# every path matched by `.sops.yaml` creation_rules (SOPS_FILE_LIST).
# On this site that list also carries `tests/hil/bfnet/sops/secrets.yaml`
# — re-encrypted, but silently uncommitted, leaving the tree dirty
# after a "successful" rotation.
#
# The reused SUCCESS_FIXTURE above ran the full ladder; the git shim
# logged every `git add ...` invocation. Assert both SOPS files appear
# in a single git-add line (proving the new stage_paths derivation
# includes the hil path).
# ==========================================================================
test_start "#813-defect1-full-stage-set" "both SOPS_FILE_LIST paths are git-added on rotation commits"
# Fixture paths are absolute (fixture-scoped tempdir). Assert the three
# expected suffixes appear on a single git-add line — same trailing
# components (.sops.yaml, site/sops/secrets.yaml, tests/hil/bfnet/sops/
# secrets.yaml) as `SOPS_FILE_LIST` produced.
if grep -E 'git-add\|.*/\.sops\.yaml .*/site/sops/secrets\.yaml .*/tests/hil/bfnet/sops/secrets\.yaml($| )' \
     "${SUCCESS_FIXTURE}/events.log" >/dev/null; then
  test_pass "git add covers .sops.yaml plus every SOPS_FILE_LIST path (site + hil)"
else
  test_fail "#813 defect 1 regressed: git add did not include tests/hil/bfnet/sops/secrets.yaml"
  grep -F 'git-add' "${SUCCESS_FIXTURE}/events.log" >&2 || true
fi

# Fixture: simulate the post-commit divergence the fix guards against.
# Inject a FAKE_GIT_STATUS_PORCELAIN line naming the hil file as modified
# after the rotation commits — as if a hypothetical broken commit had
# updatekeys'd it but not staged it. assert_commit_paths_clean must
# detect this and fail closed.
DIRTY_POST_FIXTURE="$(make_fixture defect1-dirty-after-commit)"
FAKE_GIT_STATUS_PORCELAIN=" M tests/hil/bfnet/sops/secrets.yaml" \
  run_rotate "$DIRTY_POST_FIXTURE"

test_start "#813-defect1-post-commit-dirty-detected" "assert_commit_paths_clean fails closed when a rotation path remains dirty after commits"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'rotation left uncommitted mutations in rotation-commit paths' <<< "$RUN_OUTPUT" &&
   grep -Fq 'tests/hil/bfnet/sops/secrets.yaml' <<< "$RUN_OUTPUT"; then
  test_pass "post-commit assertion catches a hypothetical hardcoded-stage-set omission"
else
  test_fail "#813 defect 1 post-commit assertion did not fail on injected dirty path"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

# ==========================================================================
# Issue #800 secondary — untracked scratch tolerated; tracked mods on
# rotation paths rejected.
#
# Pre-#800: preflight used `git status --porcelain` which fails on ANY
# untracked path, blocking the operator's normal working state (session
# logs, review artifacts, MR body files). The correctness need is:
# reject only what would enter our explicit `git add`.
#
# Post-#800: preflight is `git diff --quiet HEAD -- <rotation paths>`.
# The git shim's default `diff` exit is now 0; FAKE_GIT_DIFF_HEAD_DIRTY=1
# forces exit 1 (a tracked mod on a rotation path).
# ==========================================================================
test_start "#800-untracked-scratch-tolerated" "clean-tree preflight accepts untracked scratch (status --porcelain would reject it)"
# The SUCCESS_FIXTURE above ran to completion — the new preflight is
# `git diff --quiet HEAD -- <paths>`. With no FAKE_GIT_DIFF_HEAD_DIRTY,
# the shim returns exit 0 and the rotation proceeds. The shim does NOT
# model untracked files as tracked-diff, so this is a mechanical proxy
# for "untracked files no longer block the driver".
if [[ -n "$(grep -F 'sops-set|["sops_age_key"]|escrow-present' "${SUCCESS_FIXTURE}/events.log" | head -1)" ]]; then
  test_pass "successful rotation reached sops-set — preflight no longer rejects on git shim's default (untracked-tolerant)"
else
  test_fail "#800 untracked-scratch preflight regressed: rotation did not reach sops-set"
fi

test_start "#800-tracked-modification-rejected" "clean-tree preflight rejects a tracked modification on a rotation path"
DIRTY_PRE_FIXTURE="$(make_fixture i800-tracked-dirty-preflight)"
FAKE_GIT_DIFF_HEAD_DIRTY=1 \
  run_rotate "$DIRTY_PRE_FIXTURE"
DIRTY_PRE_EVENTS="${DIRTY_PRE_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'rotation-commit paths have pending tracked modifications' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'sops-set' "$DIRTY_PRE_EVENTS" &&
   ! grep -Fq 'updatekeys-both' "$DIRTY_PRE_EVENTS"; then
  test_pass "tracked modification on a rotation path fails preflight before any sops mutation"
else
  test_fail "#800 tracked-mod preflight regressed: driver did not fail closed or reached mutation"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$DIRTY_PRE_EVENTS" >&2
fi

# R1 codex P1: pre-staged content anywhere in the tree would bundle into
# an unscoped `git commit` even if the preflight only checks rotation
# paths. Fix is a global `git diff --cached --quiet` preflight PLUS
# scoping `git commit -- <paths>`. This fixture proves the preflight
# rejects pre-staged content up front.
test_start "R1-prestage-rejected" "preflight rejects any pre-existing staged content (unscoped commit hazard)"
PRESTAGED_FIXTURE="$(make_fixture R1-prestaged-content)"
FAKE_GIT_HAS_PRESTAGED=1 \
  run_rotate "$PRESTAGED_FIXTURE"
PRESTAGED_EVENTS="${PRESTAGED_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'pre-existing staged changes' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'sops-set' "$PRESTAGED_EVENTS" &&
   ! grep -Fq 'updatekeys-both' "$PRESTAGED_EVENTS"; then
  test_pass "pre-staged content fails preflight before any sops mutation"
else
  test_fail "R1 pre-staged content preflight did not fire"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$PRESTAGED_EVENTS" >&2
fi

# R1 codex P1 second half: enumerate_sops_files uses `find`, which
# includes untracked files under a `.sops.yaml` regex. Post-#813 those
# would silently enter the commit set. Preflight must reject them and
# force an explicit git-add or gitignore.
test_start "R1-untracked-sops-rejected" "preflight rejects an untracked SOPS-shaped file matched by a .sops.yaml creation_rule"
UNTRACKED_SOPS_FIXTURE="$(make_fixture R1-untracked-sops-file)"
# Match the bfnet path — the fixture's enumerate_sops_files run will
# see tests/hil/bfnet/sops/secrets.yaml; the shim reports it as
# untracked for THIS fixture only.
FAKE_GIT_UNTRACKED_PATH="tests/hil/bfnet/sops/secrets.yaml" \
  run_rotate "$UNTRACKED_SOPS_FIXTURE"
UNTRACKED_SOPS_EVENTS="${UNTRACKED_SOPS_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'not tracked in git' <<< "$RUN_OUTPUT" &&
   grep -Fq 'tests/hil/bfnet/sops/secrets.yaml' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'sops-set' "$UNTRACKED_SOPS_EVENTS" &&
   ! grep -Fq 'updatekeys-both' "$UNTRACKED_SOPS_EVENTS" &&
   grep -Fq 'git-ls-files|' "$UNTRACKED_SOPS_EVENTS"; then
  test_pass "untracked SOPS-shaped file fails preflight before sops updatekeys runs"
else
  test_fail "R1 untracked-SOPS preflight did not fire"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$UNTRACKED_SOPS_EVENTS" >&2
fi

# Manifest static assertion — codex P2. The DRT-009 shape fixture builds
# its own mock manifest, so it proves the routing MECHANISM but not that
# the checked-in site manifest's M1 row actually dispatches to the new
# probe. Assert directly on the file so any regression to
# recover-secrets.sh (or any other probe pointer) fails the ratchet.
test_start "#813-defect2-manifest-M1-probe-pinned" "checked-in rotation-manifest M1 row's probe field points at the real per-holder decrypt script"
MANIFEST_M1_PROBE="$(yq -r '.[] | select(.class == "M1" and .match == "sops_age_key") | .probe // ""' "${REPO_ROOT}/site/rotation-manifest.yaml" 2>/dev/null || echo "")"
if [[ "$MANIFEST_M1_PROBE" == "framework/scripts/probe-m1-holder-decrypt.sh" ]]; then
  test_pass "M1 probe field is framework/scripts/probe-m1-holder-decrypt.sh (not recover-secrets.sh)"
else
  test_fail "M1 probe regressed: got '${MANIFEST_M1_PROBE}' (expected framework/scripts/probe-m1-holder-decrypt.sh)"
fi

# ==========================================================================
# Issue #813 defect 2 — probe-m1-holder-decrypt.sh: real per-holder
# decrypt, fails closed when a holder cannot decrypt.
#
# The pre-#813 M1 probe (recover-secrets.sh) no-oped when secrets.yaml
# existed — so it passed even if delivery to a holder had failed. This
# section unit-tests the replacement script directly.
# ==========================================================================

PROBE_M1_SCRIPT="${REPO_ROOT}/framework/scripts/probe-m1-holder-decrypt.sh"

setup_probe_m1_fixture() {
  local name="$1"
  local canonical_key_valid="$2"    # 1 = key can decrypt, 0 = cannot
  local fixture_dir
  fixture_dir="$(mktemp -d "${TMP_DIR}/probe-m1-${name}.XXXXXX")"
  local repo="${fixture_dir}/repo"
  mkdir -p "${repo}/site/sops"
  printf 'fixture flake\n' > "${repo}/flake.nix"
  # Encrypt a real secrets.yaml with a real age key so the probe's
  # `sops -d` is exercised end-to-end. Using real sops+age is fine here
  # because these are unit tests of the probe script itself, not of the
  # driver's shim environment.
  age-keygen -o "${fixture_dir}/valid.age.key" >/dev/null 2>&1
  age-keygen -o "${fixture_dir}/wrong.age.key" >/dev/null 2>&1
  local pub
  pub="$(grep -F 'public key:' "${fixture_dir}/valid.age.key" | awk '{print $NF}')"
  cat > "${repo}/.sops.yaml" <<EOF
creation_rules:
  - path_regex: site/sops/.*\.yaml$
    age: ${pub}
EOF
  printf '%s\n' 'seed: bootstrap' > "${repo}/site/sops/secrets.yaml"
  # sops walks up from cwd looking for .sops.yaml. Running this test from
  # anywhere inside the operator's own repo would otherwise pick up the
  # operator's .sops.yaml and encrypt against that recipient — not the
  # fixture's. Pass --config explicitly to pin the fixture's rules.
  SOPS_AGE_KEY_FILE="${fixture_dir}/valid.age.key" \
    sops --config "${repo}/.sops.yaml" -e -i "${repo}/site/sops/secrets.yaml"
  cat > "${repo}/site/config.yaml" <<EOF
vms:
  cicd:
    ip: 127.0.0.1
EOF
  if [[ "$canonical_key_valid" == "1" ]]; then
    cp "${fixture_dir}/valid.age.key" "${repo}/operator.age.key"
  else
    cp "${fixture_dir}/wrong.age.key" "${repo}/operator.age.key"
  fi
  printf '%s\n' "$fixture_dir"
}

run_probe_m1() {
  local fixture_dir="$1"
  local holder="$2"
  local delivery="$3"
  local repo="${fixture_dir}/repo"
  set +e
  PROBE_M1_OUTPUT="$(
    env \
      PROBE_M1_REPO_DIR="$repo" \
      DRT009_HOLDER_NAME="$holder" \
      DRT009_HOLDER_DELIVERY="$delivery" \
      bash "$PROBE_M1_SCRIPT" 2>&1
  )"
  PROBE_M1_STATUS=$?
  set -e
}

# Skip these three tests if this host lacks real sops/age (some CI leg
# hypothetically may). Follow the sops-round-trip pattern.
sops_help_probe="$(sops --version 2>&1 || true)"
age_help_probe="$(age-keygen --help 2>&1 || true)"
if [[ -z "$sops_help_probe" || -z "$age_help_probe" ]]; then
  test_start "#813-defect2-probe-workstation-pass" "probe-m1-holder-decrypt (workstation, key present) PASSES"
  test_skip "sops or age missing on this host — probe-m1-holder-decrypt unit tests need both"
  test_start "#813-defect2-probe-workstation-fail" "probe-m1-holder-decrypt (workstation, wrong key) FAILS"
  test_skip "sops or age missing on this host — probe-m1-holder-decrypt unit tests need both"
  test_start "#813-defect2-probe-unknown-holder" "probe-m1-holder-decrypt rejects unknown holder/delivery"
  test_skip "sops or age missing on this host — probe-m1-holder-decrypt unit tests need both"
else
  test_start "#813-defect2-probe-workstation-pass" "probe-m1-holder-decrypt (workstation, correct key at canonical path) PASSES"
  W_OK_FIX="$(setup_probe_m1_fixture workstation-ok 1)"
  run_probe_m1 "$W_OK_FIX" workstation local-file
  if [[ "$PROBE_M1_STATUS" -eq 0 ]]; then
    test_pass "workstation probe with correct canonical key decrypts secrets.yaml (exit 0)"
  else
    test_fail "workstation probe FAILED against a valid canonical key"
    printf '%s\n' "$PROBE_M1_OUTPUT" >&2
  fi

  test_start "#813-defect2-probe-workstation-fail" "probe-m1-holder-decrypt (workstation, key at canonical path DOES NOT match ciphertext) FAILS"
  W_BAD_FIX="$(setup_probe_m1_fixture workstation-bad 0)"
  run_probe_m1 "$W_BAD_FIX" workstation local-file
  # This is the operator's #813 defect-2 fixture requirement: a holder
  # that has NOT received the correct key must FAIL. Pre-#813, the
  # recover-secrets.sh probe would return 0 here (secrets.yaml exists,
  # no-op). Post-#813, the real decrypt fails.
  if [[ "$PROBE_M1_STATUS" -ne 0 ]] &&
     grep -Fq 'workstation key at' <<< "$PROBE_M1_OUTPUT" &&
     grep -Fq 'cannot decrypt' <<< "$PROBE_M1_OUTPUT"; then
    test_pass "workstation probe with a wrong canonical key FAILS closed with a diagnostic error"
  else
    test_fail "#813 defect 2 broke: wrong-key workstation probe did not fail with the expected message"
    printf '%s\n' "$PROBE_M1_OUTPUT" >&2
  fi

  test_start "#813-defect2-probe-unknown-holder" "probe-m1-holder-decrypt rejects an unknown holder/delivery combination"
  UNK_FIX="$(setup_probe_m1_fixture unknown 1)"
  run_probe_m1 "$UNK_FIX" hypothetical-new-holder some-new-delivery
  if [[ "$PROBE_M1_STATUS" -ne 0 ]] &&
     grep -Fq 'unsupported holder/delivery: hypothetical-new-holder:some-new-delivery' <<< "$PROBE_M1_OUTPUT"; then
    test_pass "unknown holder/delivery fails closed with an actionable error"
  else
    test_fail "#813 defect 2 probe did not fail closed on unknown holder"
    printf '%s\n' "$PROBE_M1_OUTPUT" >&2
  fi
fi

# ==========================================================================
# Issue #817 — driver must not consult `tofu plan -detailed-exitcode`.
#
# Pre-#817: after Step 7's retire commit the driver called
#   SOPS_AGE_KEY_FILE=... tofu-wrapper.sh plan -detailed-exitcode >/dev/null
# under `set -e`. The exit contract of `plan -detailed-exitcode` is
# rc 2 on ANY pending change — legitimate dev/prod image drift, placeholder
# tfvars in a fresh clone, or any unrelated cluster state. rc 2 aborted the
# driver every time on this cluster, so G3 attempt 9 (2026-07-31) reported
# FAIL after a completely correct rotation whose commits merged as !553.
# DRT-009 already brackets the driver with a delta-form assertion that
# tolerates pre-existing drift (framework/dr-tests/tests/DRT-009-key-rotation.sh:669
# capture, :673 assert; the #791 replacement of the same absolute check).
# The driver's private copy added no coverage and one failure mode.
#
# Antibody: reproduce the real cluster condition (drifted plan → shim
# returns rc 2 for `plan -detailed-exitcode`) and assert the driver
# completes AND never invokes tofu-wrapper.sh at all. This assertion
# fails on the parent commit two independent ways:
#   1. RUN_STATUS is non-zero (set -e aborts on the rc-2 exit),
#   2. events.log contains a `tofu-wrapper|plan -detailed-exitcode` entry
#      (proving the driver reached out to tofu).
# Both go away when the driver's private plan check is deleted.
# ==========================================================================
I817_FIXTURE="$(make_fixture i817-driver-does-not-consult-tofu)"
FAKE_TOFU_PLAN_RC=2 run_rotate "$I817_FIXTURE"

test_start "#817-driver-does-not-consult-tofu-plan" "driver completes and never invokes tofu-wrapper.sh even when the surrounding plan shows drift"
I817_EVENTS="${I817_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   ! grep -Fq 'tofu-wrapper|' "$I817_EVENTS" &&
   grep -Fq 'updatekeys-newonly|site/sops/secrets.yaml' "$I817_EVENTS"; then
  test_pass "driver completed the retire step without a tofu plan call, even against a drifted cluster"
else
  test_fail "#817 regressed: driver either failed on drifted plan or still invoked tofu-wrapper.sh"
  printf 'RUN_STATUS=%s\n' "$RUN_STATUS" >&2
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$I817_EVENTS" >&2
fi

runner_summary
