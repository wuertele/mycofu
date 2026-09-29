#!/usr/bin/env bash
# V3.1: DRT-009 static and fixture-routed behavioral shape tests.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

DRT_SCRIPT="${REPO_ROOT}/framework/dr-tests/tests/DRT-009-key-rotation.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

RUN_OUTPUT=""
RUN_STDOUT=""
RUN_STDERR=""
RUN_STATUS=0
SENTINEL_ONE="SENTINEL_DRT009_SECRET_VALUE_ONE"
SENTINEL_TWO="SENTINEL_DRT009_SECRET_VALUE_TWO"

first_line_number() {
  local pattern="$1" file="$2"
  grep -Fn "$pattern" "$file" | head -1 | cut -d: -f1 || true
}

first_exact_line_number() {
  local pattern="$1" file="$2"
  awk -v pattern="$pattern" '$0 == pattern {print NR; exit}' "$file"
}

# file_mode: portable octal-mode probe. GNU-first so a GNU-only environment
# (the NixOS CI runner) cannot leak the misinterpreted-format text of a
# failed BSD-style call into the caller's captured value.
#
# The naive `stat -f '%Lp' P || stat -c '%a' P` idiom is unsafe on GNU
# coreutils: `-f` there means "filesystem status", so `%Lp` is parsed as
# another file operand. GNU stat prints filesystem-info text to stdout AND
# exits non-zero, so a `2>/dev/null || ...` fallback appends the true mode
# after the noise. Captured by a command substitution the caller sees a
# multi-line garbled string that never equals a bare mode. The two-branch
# `if mode="$(...)"; then` form below anchors the captured value to exactly
# one successful call — the other branch never contributes to stdout.
# Reference: .claude/rules/platform.md (BSD on workstation, GNU on NixOS).
file_mode() {
  local path="$1" mode
  if mode="$(stat -c '%a' "$path" 2>/dev/null)" && [[ -n "$mode" ]]; then
    printf '%s\n' "$mode"
  elif mode="$(stat -f '%Lp' "$path" 2>/dev/null)" && [[ -n "$mode" ]]; then
    printf '%s\n' "$mode"
  else
    printf '%s\n' ERR
  fi
}

write_executable() {
  local path="$1"
  shift
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' "$@"
  } > "$path"
  chmod +x "$path"
}

make_fixture() {
  local name="$1"
  local with_m2="${2:-yes}"
  local fixture="${TMP_DIR}/${name}"
  local bin="${fixture}/bin"
  local evidence="${fixture}/evidence"
  mkdir -p "$bin" "$evidence" "${fixture}/escrow" "${fixture}/repo/framework/dr-tests/tests" "${fixture}/repo/framework/dr-tests/lib"

  # Fixture-controlled tofu plan JSON. The mock tofu-wrapper (below) reads
  # plan-state.json to build `resource_changes` for `tofu show -json`. Default
  # is empty — a clean cluster with zero drift. Drift fixtures overwrite this
  # file before running the DRT to simulate pre-existing dev/prod image
  # drift. The M1 driver mock's rekey-alters-cidata mode APPENDS to this
  # file, changing the plan digest between the pre-M1 capture and the
  # post-M1 assertion so the delta-zero check fails.
  printf '%s\n' '[]' > "${fixture}/plan-state.json"

  cat > "${fixture}/manifest.yaml" <<EOF
- match: sops_age_key
  class: M1
  driver: ${bin}/m1-driver
  probe: ${bin}/m1-probe
  holders:
    - name: workstation
      delivery: local-file
    - name: cicd
      delivery: register-runner
EOF
  if [[ "$with_m2" == "yes" ]]; then
    cat >> "${fixture}/manifest.yaml" <<EOF
- match: ssh_privkey
  class: M2
  driver: "procedure: OPERATIONS.md#framework-deploy-keypair-m2"
  probe: ${bin}/m2-probe
EOF
  fi
  cat >> "${fixture}/manifest.yaml" <<EOF
- match: stateless_token
  class: M3
  driver: ${bin}/m3-driver
  probe: ${bin}/m3-probe
- match: vault_dev_root_token
  class: M4
  driver: ${bin}/m4-vault-driver
  probe: ${bin}/m4-probe
- match: gitlab_root_password
  class: M4
  driver: ${bin}/m4-gitlab-driver
  probe: ${bin}/m4-probe
- match: github_deploy_key
  class: M5-automated
  driver: ${bin}/m5-driver
  probe: ${bin}/m5-probe
EOF

  cat > "${fixture}/config.yaml" <<EOF
proxmox:
  storage_pool: vmstore
replication:
  health_port: 18080
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
EOF
  printf '%s\n' 'quiescent' > "${fixture}/curl-mode"

  # The fixture git mock intentionally makes common.sh's
  # `git rev-parse --short HEAD` return `fixture` in both run_real_drt and the
  # attended repo copy. These shape tests do not validate commit identity, and
  # the mock keeps every fixture hermetic without per-fixture git repository
  # setup.
  write_executable "${bin}/git" \
    'if [[ "$*" == "rev-parse --short HEAD" ]]; then printf "fixture\n"; exit 0; fi' \
    'printf "unexpected git invocation: %s\n" "$*" >&2' \
    'exit 1'
  write_executable "${bin}/curl" \
    "FIXTURE='${fixture}'" \
    'url=""' \
    'for arg in "$@"; do case "$arg" in http://*) url="$arg" ;; esac; done' \
    'ip="${url#http://}"' \
    'ip="${ip%%:*}"' \
    'safe_ip="$(printf "%s" "$ip" | tr -c "A-Za-z0-9._-" "_")"' \
    'count_file="$FIXTURE/curl-count-${safe_ip}"' \
    'count="$(cat "$count_file" 2>/dev/null || printf 0)"' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$count_file"' \
    'mode="$(cat "$FIXTURE/curl-mode" 2>/dev/null || printf quiescent)"' \
    'case "$mode" in' \
    '  unreachable) printf "repl-health|%s|%s|curl-fail\n" "$ip" "$count" >> "$EVENT_LOG"; exit 7 ;;' \
    '  unparseable) printf "repl-health|%s|%s|unparseable\n" "$ip" "$count" >> "$EVENT_LOG"; printf "{not-json\n"; exit 0 ;;' \
    '  stale) stale=true ;;' \
    '  stale-then-ok) threshold="$(cat "$FIXTURE/curl-stale-samples" 2>/dev/null || printf 1)"; if [[ "$count" -le "$threshold" ]]; then stale=true; else stale=false; fi ;;' \
    '  *) stale=false ;;' \
    'esac' \
    'printf "repl-health|%s|%s|stale=%s\n" "$ip" "$count" "$stale" >> "$EVENT_LOG"' \
    'printf "{\"replication_stale\": %s, \"zfs_pools\": {\"vmstore\": \"healthy\", \"rpool\": \"healthy\"}}\n" "$stale"'
  write_executable "${bin}/ssh" \
    'printf "ssh|%s\n" "$*" >> "$EVENT_LOG"' \
    'case "$*" in' \
    '  *"pvesr status"*) printf "mock pvesr status\n" ;;' \
    '  *"zpool status -x"*) printf "all pools are healthy\n" ;;' \
    '  *) printf "unexpected ssh command: %s\n" "$*" >&2; exit 1 ;;' \
    'esac'
  write_executable "${bin}/check-manifest" \
    'printf "check-manifest\n" >> "$EVENT_LOG"'
  write_executable "${bin}/backup-now" \
    'pin_out=""' \
    'while [[ $# -gt 0 ]]; do case "$1" in --pin-out) pin_out="$2"; shift 2 ;; *) shift ;; esac; done' \
    '[[ -n "$pin_out" ]] || { echo "missing --pin-out" >&2; exit 1; }' \
    'mkdir -p "$(dirname "$pin_out")"' \
    'printf "backup-now|%s\n" "$pin_out" >> "$EVENT_LOG"' \
    'printf "{\"pins\":{\"150\":\"pbs-nas:backup/vm/150/2026-07-26T12:00:00Z\",\"303\":{\"volid\":\"pbs-nas:backup/vm/303/2026-07-26T12:00:00Z\"}}}\n" > "$pin_out"'
  # Emit distinctive stdout AND stderr text — used by the #820 success-path
  # fixture below to prove validate-unscoped.log persists BOTH streams on a
  # PASS run (post-hoc diagnosis of a transient-class #820 needs the log
  # regardless of exit code). The event-log write keeps the pre-existing
  # V3.1-depth-rekey / V3.1-only-routing invocation tracking working.
  write_executable "${bin}/validate" \
    'printf "validate\n" >> "$EVENT_LOG"' \
    'printf "validate-mock-stdout-ok\n"' \
    'printf "validate-mock-stderr-ok\n" >&2'
  # Mock tofu-wrapper. Supports the two commands the DRT calls via
  # capture_plan_digest:
  #   plan -no-color -refresh=false -out=<file>
  #                               — write a stub plan file, return 0
  #   show -json <file>           — emit a "Decrypting secrets..."
  #                                 preamble (mirroring the real
  #                                 tofu-wrapper.sh:157 stdout emission)
  #                                 followed by plan JSON whose
  #                                 resource_changes array is read
  #                                 verbatim from the fixture's
  #                                 plan-state.json
  # The preamble line exercises the sed-strip in capture_plan_digest —
  # without it, the fixture would only cover the mock and would miss the
  # real-production failure documented in #791's adversarial review
  # (codex round 1).
  #
  # Any change to plan-state.json between two show-json calls flips the
  # digest, which is how the CIDATA-altering-rekey fixture (below)
  # proves the delta-zero assertion still fails when the rekey genuinely
  # mutates a plan-visible input. plan-state.json defaults to []; drift
  # fixtures populate it before invoking the DRT.
  write_executable "${bin}/tofu-wrapper" \
    "PLAN_STATE='${fixture}/plan-state.json'" \
    'printf "tofu-wrapper|%s\n" "$*" >> "$EVENT_LOG"' \
    'case "${1:-}" in' \
    '  plan)' \
    '    for arg in "$@"; do' \
    '      case "$arg" in' \
    '        -out=*) printf "PLAN\n" > "${arg#-out=}" ;;' \
    '      esac' \
    '    done' \
    '    exit 0' \
    '    ;;' \
    '  show)' \
    '    if [[ "${2:-}" == "-json" ]]; then' \
    '      printf "Decrypting secrets...\n"' \
    '      rc="$(cat "$PLAN_STATE" 2>/dev/null || printf "[]")"' \
    '      printf "{\"format_version\":\"1.2\",\"resource_changes\":%s}\n" "$rc"' \
    '      exit 0' \
    '    fi' \
    '    exit 1' \
    '    ;;' \
    '  *) exit 1 ;;' \
    'esac'
  # See comment on m1-driver above: DRT-009 now persists probe output, so a
  # mock that emits sentinels on stdout/stderr would leak them into
  # evidence/m1-holder-probe-*.log. Emit only harmless status text on the
  # standard streams; write sentinels to the off-limits side-channel file
  # so V3.1-sentinel-leak still exercises "DRT never surfaces arbitrary
  # driver-written file paths" (the mock writes are the substitute for
  # a hypothetical rogue driver emitting secrets on stdout/stderr).
  #
  # FIXTURE_M1_PROBE_FAIL_ON_HOLDER — when set to a holder name, the probe
  # exits 1 with a known error message for that holder only. Used by the
  # #813 defect-2 fixture to prove a holder that hasn't received the key
  # FAILS the probe (the pre-#813 recover-secrets.sh probe was a no-op and
  # falsely passed in that case).
  write_executable "${bin}/m1-probe" \
    "MOCK_OFF_LIMITS='${fixture}/off-limits'" \
    'printf "m1-probe|%s|%s\n" "${DRT009_HOLDER_NAME:-}" "${DRT009_HOLDER_DELIVERY:-}" >> "$EVENT_LOG"' \
    'mkdir -p "$MOCK_OFF_LIMITS"' \
    'printf "%s\n" "$DRT009_SENTINEL_ONE" > "$MOCK_OFF_LIMITS/m1-probe-secret-${DRT009_HOLDER_NAME:-none}"' \
    'printf "%s\n" "$DRT009_SENTINEL_TWO" >> "$MOCK_OFF_LIMITS/m1-probe-secret-${DRT009_HOLDER_NAME:-none}"' \
    'printf "m1-probe: holder=%s delivery=%s decrypt OK (mock)\n" "${DRT009_HOLDER_NAME:-none}" "${DRT009_HOLDER_DELIVERY:-none}"' \
    'if [[ "${FIXTURE_M1_PROBE_FAIL_ON_HOLDER:-}" == "${DRT009_HOLDER_NAME:-}" ]]; then' \
    '  printf "m1-probe: holder %s cannot decrypt secrets.yaml with delivered key (FIXTURE_M1_PROBE_FAIL_ON_HOLDER)\n" "${DRT009_HOLDER_NAME}" >&2' \
    '  exit 1' \
    'fi'
  write_executable "${bin}/m2-probe" \
    'printf "m2-probe\n" >> "$EVENT_LOG"'
  write_executable "${bin}/m3-probe" \
    'printf "m3-probe\n" >> "$EVENT_LOG"'
  write_executable "${bin}/m4-probe" \
    'printf "m4-probe\n" >> "$EVENT_LOG"'
  write_executable "${bin}/m5-probe" \
    'printf "m5-probe\n" >> "$EVENT_LOG"'
  write_executable "${bin}/pipeline-green" \
    'printf "pipeline-green\n" >> "$EVENT_LOG"'

  # M1 driver mock. A no-op rekey (default) never touches plan-state.json,
  # so before/after digests match and assert_m1_plan_delta_zero passes.
  # When FIXTURE_M1_MUTATES_PLAN_STATE=1, the mock appends a resource_change
  # to plan-state.json, simulating a rekey that alters a plan-visible input
  # (a CIDATA-derived resource attribute). The after-digest then differs
  # from the pre-digest and the delta-zero assertion must fail.
  #
  # #800 change: the mock previously emitted DRT009_SENTINEL_ONE/_TWO on
  # stdout/stderr to prove DRT-009 discarded driver output. DRT-009 now
  # CAPTURES and persists driver output (issue #800 fix), so an emit-on-
  # stdout mock would leak sentinels into evidence/driver-M1-N.log. Real
  # rotation drivers do not emit key material on stdout/stderr (V2.7
  # asserts this for `sops -d`; V2.3-sentinel-leak asserts it for
  # rotate-sops-recipient end-to-end). The mock reflects that reality:
  # emit only harmless status text on stdout/stderr, and write the
  # sentinels to an off-limits side-channel file so V3.1-sentinel-leak
  # still exercises "DRT never reads or surfaces arbitrary file paths a
  # driver wrote to". If a driver ever started emitting secrets on
  # stdout/stderr, V2.3-sentinel-leak catches it at the driver boundary.
  #
  # FIXTURE_M1_DRIVER_FAIL_MESSAGE (added for #800 fixture): when set,
  # the mock prints that message to stderr and exits 1 — the tail-on-
  # failure and per-driver log-persistence assertions read the message
  # back through those surfaces.
  write_executable "${bin}/m1-driver" \
    "PLAN_STATE='${fixture}/plan-state.json'" \
    "MOCK_OFF_LIMITS='${fixture}/off-limits'" \
    'printf "m1-driver|%s\n" "$*" >> "$EVENT_LOG"' \
    'mkdir -p "$MOCK_OFF_LIMITS"' \
    'printf "%s\n" "$DRT009_SENTINEL_ONE" > "$MOCK_OFF_LIMITS/m1-driver-secret"' \
    'printf "%s\n" "$DRT009_SENTINEL_TWO" >> "$MOCK_OFF_LIMITS/m1-driver-secret"' \
    'printf "m1-driver: no-op rekey complete (mock)\n"' \
    'printf "m1-driver: rewrote 2 SOPS envelopes (mock)\n" >&2' \
    'mkdir -p "$ROTATE_EVIDENCE_DIR"' \
    'printf "exit=1\nstderr=synthetic-old-key-denied\n" > "$ROTATE_EVIDENCE_DIR/prove-negative.txt"' \
    'if [[ "${FIXTURE_M1_MUTATES_PLAN_STATE:-0}" == "1" ]]; then' \
    '  jq -c '"'"'. + [{"address":"module.dns_prod.cidata_snippet","change":{"actions":["update"],"before":{"content":"old"},"after":{"content":"new"}}}]'"'"' "$PLAN_STATE" > "${PLAN_STATE}.new" && mv "${PLAN_STATE}.new" "$PLAN_STATE"' \
    'fi' \
    'if [[ -n "${FIXTURE_M1_DRIVER_FAIL_MESSAGE:-}" ]]; then' \
    '  printf "%s\n" "$FIXTURE_M1_DRIVER_FAIL_MESSAGE" >&2' \
    '  exit 1' \
    'fi'
  write_executable "${bin}/m3-driver" \
    'printf "m3-driver|%s\n" "$*" >> "$EVENT_LOG"'
  write_executable "${bin}/m4-vault-driver" \
    'printf "m4-vault-driver|%s\n" "$*" >> "$EVENT_LOG"' \
    'mkdir -p "$ROTATE_EVIDENCE_DIR"' \
    'printf "http_status=403\nstderr=synthetic-old-token-denied\n" > "$ROTATE_EVIDENCE_DIR/rotate-vault-dev-prove-negative.txt"'
  write_executable "${bin}/m4-gitlab-driver" \
    'printf "m4-gitlab-driver|%s\n" "$*" >> "$EVENT_LOG"' \
    'mkdir -p "$ROTATE_EVIDENCE_DIR"' \
    'printf "http_status=401\nstderr=synthetic-old-password-denied\n" > "$ROTATE_EVIDENCE_DIR/rotate-gitlab-prove-negative.txt"'
  write_executable "${bin}/m5-driver" \
    'printf "m5-driver|%s\n" "$*" >> "$EVENT_LOG"'

  : > "${fixture}/events.log"
  printf '%s\n' "$fixture"
}

run_real_drt() {
  local fixture="$1"
  shift
  RUN_STDOUT="${fixture}/stdout.txt"
  RUN_STDERR="${fixture}/stderr.txt"
  : > "${fixture}/events.log"
  set +e
  env \
    PATH="${fixture}/bin:${PATH}" \
    EVENT_LOG="${fixture}/events.log" \
    DRT009_SENTINEL_ONE="$SENTINEL_ONE" \
    DRT009_SENTINEL_TWO="$SENTINEL_TWO" \
    DRT009_MANIFEST_FILE="${fixture}/manifest.yaml" \
    DRT009_CONFIG_FILE="${fixture}/config.yaml" \
    DRT009_CHECK_MANIFEST_CMD="${fixture}/bin/check-manifest" \
    DRT009_BACKUP_NOW_CMD="${fixture}/bin/backup-now" \
    DRT009_VALIDATE_CMD="${fixture}/bin/validate" \
    DRT009_TOFU_WRAPPER_CMD="${fixture}/bin/tofu-wrapper" \
    DRT009_PIPELINE_GREEN_CMD="${fixture}/bin/pipeline-green" \
    DRT009_EVIDENCE_DIR="${fixture}/evidence" \
    DRT009_ESCROW_BASE="${fixture}/escrow" \
    DRT009_REPL_QUIESCE_POLL_SECONDS="${DRT009_REPL_QUIESCE_POLL_SECONDS:-30}" \
    DRT009_REPL_QUIESCE_TIMEOUT_SECONDS="${DRT009_REPL_QUIESCE_TIMEOUT_SECONDS:-1800}" \
    DRT009_UTC_STAMP="20260726T130000Z" \
    bash "$DRT_SCRIPT" "$@" >"$RUN_STDOUT" 2>"$RUN_STDERR"
  RUN_STATUS=$?
  set -e
  RUN_OUTPUT="$(cat "$RUN_STDOUT" "$RUN_STDERR")"
}

make_attended_repo() {
  local fixture="$1"
  local repo="${fixture}/repo"
  cp "$DRT_SCRIPT" "${repo}/framework/dr-tests/tests/DRT-009-key-rotation.sh"
  chmod +x "${repo}/framework/dr-tests/tests/DRT-009-key-rotation.sh"
  cat > "${repo}/framework/dr-tests/lib/common.sh" <<'EOF'
DRT_FAILURES=0
DRT_FAILURE_LIST=()
DRT_WARNINGS=0
DRT_WARNING_LIST=()
DRT_BLOCKED_LIST=()
DRT_BLOCKED_EXIT=77
DRT_FINISHED=0
DRT_COMMIT=fixture
DRT_START=2026-07-26T13:00:00Z
DRT_START_EPOCH=0
drt_init() { printf 'drt-init\n' >> "$EVENT_LOG"; }
drt_check() { local desc="$1"; shift; printf 'drt-check|%s\n' "$desc" >> "$EVENT_LOG"; "$@"; }
drt_step() { printf 'drt-step|%s\n' "$1" >> "$EVENT_LOG"; }
drt_assert() {
  local desc="$1" rc
  shift
  printf 'drt-assert|%s\n' "$desc" >> "$EVENT_LOG"
  set +e
  "$@"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    printf '[PASS] %s\n' "$desc"
  else
    printf '[FAIL] %s\n' "$desc"
    DRT_FAILURES=$((DRT_FAILURES + 1))
    DRT_FAILURE_LIST+=("$desc")
  fi
}
drt_expect() { local desc="$1"; shift; printf 'drt-expect|%s\n' "$desc" >> "$EVENT_LOG"; if [[ $# -gt 0 ]]; then "$@"; fi; }
drt_curl() { curl --max-time 10 "$@"; }
drt_elapsed() { printf '0m 0s\n'; }
drt_finish() { printf 'drt-finish\n' >> "$EVENT_LOG"; [[ "$DRT_FAILURES" -eq 0 ]] || exit 1; exit 0; }
EOF
  printf '%s\n' "$repo"
}

run_attended_fixture() {
  local fixture="$1"
  shift
  local repo
  repo="$(make_attended_repo "$fixture")"
  RUN_STDOUT="${fixture}/attended-stdout.txt"
  RUN_STDERR="${fixture}/attended-stderr.txt"
  : > "${fixture}/events.log"
  set +e
  env \
    PATH="${fixture}/bin:${PATH}" \
    EVENT_LOG="${fixture}/events.log" \
    DRT009_SENTINEL_ONE="$SENTINEL_ONE" \
    DRT009_SENTINEL_TWO="$SENTINEL_TWO" \
    DRT009_MANIFEST_FILE="${fixture}/manifest.yaml" \
    DRT009_CONFIG_FILE="${fixture}/config.yaml" \
    DRT009_CHECK_MANIFEST_CMD="${fixture}/bin/check-manifest" \
    DRT009_BACKUP_NOW_CMD="${fixture}/bin/backup-now" \
    DRT009_VALIDATE_CMD="${fixture}/bin/validate" \
    DRT009_TOFU_WRAPPER_CMD="${fixture}/bin/tofu-wrapper" \
    DRT009_PIPELINE_GREEN_CMD="${fixture}/bin/pipeline-green" \
    DRT009_EVIDENCE_DIR="${fixture}/evidence" \
    DRT009_ESCROW_BASE="${fixture}/escrow" \
    DRT009_REPL_QUIESCE_POLL_SECONDS="${DRT009_REPL_QUIESCE_POLL_SECONDS:-30}" \
    DRT009_REPL_QUIESCE_TIMEOUT_SECONDS="${DRT009_REPL_QUIESCE_TIMEOUT_SECONDS:-1800}" \
    DRT009_UTC_STAMP="20260726T130000Z" \
    bash -c 'cd "$1" && framework/dr-tests/tests/DRT-009-key-rotation.sh "${@:2}"' bash "$repo" "$@" >"$RUN_STDOUT" 2>"$RUN_STDERR"
  RUN_STATUS=$?
  set -e
  RUN_OUTPUT="$(cat "$RUN_STDOUT" "$RUN_STDERR")"
}

test_start "V3.1-usage" "--depth is required and unknown depths fail closed"
USAGE_FIXTURE="$(make_fixture usage no)"
run_real_drt "$USAGE_FIXTURE"
missing_status="$RUN_STATUS"
missing_output="$RUN_OUTPUT"
run_real_drt "$USAGE_FIXTURE" --depth bogus
if [[ "$missing_status" -eq 1 ]] &&
   grep -Fq 'Usage:' <<< "$missing_output" &&
   [[ "$RUN_STATUS" -eq 1 ]] &&
   grep -Fq 'Usage:' <<< "$RUN_OUTPUT"; then
  test_pass "missing and unknown --depth return usage with exit 1"
else
  test_fail "--depth usage failure shape changed"
fi

test_start "V3.1-only-depth" "--only is valid only at resecret-all"
run_real_drt "$USAGE_FIXTURE" --depth rekey --only vault_dev_root_token
if [[ "$RUN_STATUS" -eq 1 ]] &&
   grep -Fq 'targeting valid only at --depth resecret-all' <<< "$RUN_OUTPUT"; then
  test_pass "--only at rekey fails with the exact message"
else
  test_fail "--only at rekey did not fail with the required message"
fi

test_start "V3.1-only-unknown" "unknown --only row lists valid manifest match names"
run_real_drt "$USAGE_FIXTURE" --depth resecret-all --only not_a_row
if [[ "$RUN_STATUS" -eq 1 ]] &&
   grep -Fq 'unknown --only row: not_a_row' <<< "$RUN_OUTPUT" &&
   grep -Fq 'vault_dev_root_token' <<< "$RUN_OUTPUT" &&
   grep -Fq 'gitlab_root_password' <<< "$RUN_OUTPUT"; then
  test_pass "unknown --only row fails closed and prints valid M4 match values"
else
  test_fail "unknown --only row did not include valid-name usage"
fi

test_start "V3.1-static" "DRT-009 static ratchets match A7/Q-F/V3.1"
FIRST_DRT_CHECK="$(grep -n '^[[:space:]]*drt_check ' "$DRT_SCRIPT" | head -1)"
PROVE_LINE="$(first_line_number 'prove-negative evidence exists before drt_finish' "$DRT_SCRIPT")"
FINISH_LINE="$(grep -n '^[[:space:]]*drt_finish$' "$DRT_SCRIPT" | tail -1 | cut -d: -f1 || true)"
# Plan-delta ordering ratchet (#791): the pre-M1 plan digest MUST be
# captured before the M1 driver runs, and the delta-zero assertion MUST
# reference the pre-M1 baseline (not an unscoped -detailed-exitcode
# convergence claim, which fails on pre-existing dev/prod image drift).
PRE_M1_CAPTURE_LINE="$(first_line_number 'pre-M1 tofu plan digest captured' "$DRT_SCRIPT")"
M1_DRIVER_LINE="$(first_line_number 'M1 driver completed by path' "$DRT_SCRIPT")"
M1_DELTA_LINE="$(first_line_number 'M1 tofu plan delta zero vs pre-M1 baseline' "$DRT_SCRIPT")"
if grep -Fq 'rotation manifest inventory' <<< "$FIRST_DRT_CHECK" &&
   grep -Fq 'fresh backup pin' "$DRT_SCRIPT" &&
   [[ -n "$PRE_M1_CAPTURE_LINE" && -n "$M1_DRIVER_LINE" && -n "$M1_DELTA_LINE" ]] &&
   [[ "$PRE_M1_CAPTURE_LINE" -lt "$M1_DRIVER_LINE" ]] &&
   [[ "$M1_DRIVER_LINE" -lt "$M1_DELTA_LINE" ]] &&
   ! (grep -vE '^[[:space:]]*#' "$DRT_SCRIPT" | grep -Fq -- '-detailed-exitcode') &&
   grep -Fq 'M4 attended gate accepted' "$DRT_SCRIPT" &&
   grep -Fq 'drt_expect "M4 attended gate accepted' "$DRT_SCRIPT" &&
   [[ -n "$PROVE_LINE" && -n "$FINISH_LINE" && "$PROVE_LINE" -lt "$FINISH_LINE" ]] &&
   grep -Fq 'depth=' "$DRT_SCRIPT" &&
   grep -Fq 'only_scope=' "$DRT_SCRIPT" &&
   grep -Fq 'evidence_sink=' "$DRT_SCRIPT" &&
   grep -Fq 'pre_pbs_pin_volids=' "$DRT_SCRIPT" &&
   grep -Fq 'post_pbs_pin_volids=' "$DRT_SCRIPT"; then
  test_pass "inventory first, pin check, pre-M1 digest captured before driver, delta-zero after driver, no -detailed-exitcode, M4 drt_expect, prove-negative ordering, and registry fields are present"
else
  test_fail "DRT-009 static shape is missing a required token/order"
fi

test_start "V3.1-qf-static" "--only is not sourced from Phase A evidence or manifest annotations"
if ! grep -Eq 'docs/reports|680-exposure-investigation|Phase A' "$DRT_SCRIPT" &&
   ! grep -Eq 'yq .*only|[.]only|only:' "$DRT_SCRIPT"; then
  test_pass "no Phase A report read-path or manifest only-field read exists"
else
  test_fail "DRT-009 appears to read --only routing from a prohibited source"
fi

# ---------------------------------------------------------------------
# #839 fixtures — DRT-009 waits for replication quiescence before the
# unchanged single validate.sh assertion. Production defaults are 30s poll
# / 30m cap; slow paths override them here so the shape test stays local
# and short.
# ---------------------------------------------------------------------
test_start \
  "#839-quiescence-immediate" \
  "first repl-health sample is quiescent and the DRT continues through validate + finish"
QUIESCE_IMMEDIATE_FIXTURE="$(make_fixture quiesce-immediate yes)"
run_real_drt "$QUIESCE_IMMEDIATE_FIXTURE" --depth rekey
EVENTS="${QUIESCE_IMMEDIATE_FIXTURE}/events.log"
SUMMARY="${QUIESCE_IMMEDIATE_FIXTURE}/evidence/drt009-summary.txt"
QUIESCE_LINE="$(first_line_number 'repl-health|' "$EVENTS")"
VALIDATE_LINE="$(first_exact_line_number 'validate' "$EVENTS")"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq "[PASS] replication quiescent before validate.sh" "$RUN_STDOUT" &&
   grep -Fxq "replication_quiescence_start_non_quiescent_rows=none" "$SUMMARY" &&
   grep -Fxq "replication_quiescence_start_probe_errors=none" "$SUMMARY" &&
   grep -Eq '^replication_quiescence_waited_seconds=[0-9]+$' "$SUMMARY" &&
   grep -Fxq "result=PASS" "$SUMMARY" &&
   [[ -n "$QUIESCE_LINE" && -n "$VALIDATE_LINE" ]] &&
   [[ "$QUIESCE_LINE" -lt "$VALIDATE_LINE" ]]; then
  test_pass "immediate quiescence persists telemetry, runs validate after the gate, and reaches finish"
else
  test_fail "#839 immediate-quiescent path did not pass through validate and finish in order"
  cat "$EVENTS" >&2
  cat "$SUMMARY" >&2 2>/dev/null || true
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "#839-quiescence-becomes-ready" "stale first sample waits, then quiescent sample allows validate"
BECOMES_READY_FIXTURE="$(make_fixture quiesce-becomes-ready yes)"
printf '%s\n' 'stale-then-ok' > "${BECOMES_READY_FIXTURE}/curl-mode"
printf '%s\n' '1' > "${BECOMES_READY_FIXTURE}/curl-stale-samples"
DRT009_REPL_QUIESCE_POLL_SECONDS=1 DRT009_REPL_QUIESCE_TIMEOUT_SECONDS=5 \
  run_real_drt "$BECOMES_READY_FIXTURE" --depth rekey
EVENTS="${BECOMES_READY_FIXTURE}/events.log"
SUMMARY="${BECOMES_READY_FIXTURE}/evidence/drt009-summary.txt"
STALE_LINE="$(first_line_number 'stale=true' "$EVENTS")"
READY_LINE="$(first_line_number 'stale=false' "$EVENTS")"
VALIDATE_LINE="$(first_exact_line_number 'validate' "$EVENTS")"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq "[PASS] replication quiescent before validate.sh" "$RUN_STDOUT" &&
   grep -Fq "replication_quiescence_start_non_quiescent_rows=pve01(" "$SUMMARY" &&
   grep -Fq "pve02(stale=true pool=healthy rpool=healthy)" "$SUMMARY" &&
   grep -Fxq "replication_quiescence_start_probe_errors=none" "$SUMMARY" &&
   grep -Eq '^replication_quiescence_waited_seconds=[1-9][0-9]*$' "$SUMMARY" &&
   [[ -n "$STALE_LINE" && -n "$READY_LINE" && -n "$VALIDATE_LINE" ]] &&
   [[ "$STALE_LINE" -lt "$READY_LINE" && "$READY_LINE" -lt "$VALIDATE_LINE" ]]; then
  test_pass "stale sample persists start telemetry, waits, then validate runs after the quiescent sample"
else
  test_fail "#839 becomes-quiescent path did not wait then continue through validate"
  cat "$EVENTS" >&2
  cat "$SUMMARY" >&2 2>/dev/null || true
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start \
  "#839-quiescence-cap-fail" \
  "never-quiescent repl-health exhausts the cap, writes evidence, and blocks validate"
NEVER_READY_FIXTURE="$(make_fixture quiesce-never-ready yes)"
printf '%s\n' 'stale' > "${NEVER_READY_FIXTURE}/curl-mode"
DRT009_REPL_QUIESCE_POLL_SECONDS=1 DRT009_REPL_QUIESCE_TIMEOUT_SECONDS=2 \
  run_real_drt "$NEVER_READY_FIXTURE" --depth rekey
EVENTS="${NEVER_READY_FIXTURE}/events.log"
PROVE_NEGATIVE="${NEVER_READY_FIXTURE}/evidence/drt009-prove-negative-summary.txt"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq "[FAIL] replication quiescent before validate.sh" "$RUN_STDOUT" &&
   grep -Fq "replication quiescence cap exhausted" <<< "$RUN_OUTPUT" &&
   ! grep -Fxq 'validate' "$EVENTS" &&
   [[ -s "${NEVER_READY_FIXTURE}/evidence/repl-health-pve01.json" ]] &&
   [[ -s "${NEVER_READY_FIXTURE}/evidence/pvesr-status-pve01.txt" ]] &&
   [[ -s "${NEVER_READY_FIXTURE}/evidence/zpool-status-pve01.txt" ]] &&
   [[ -s "$PROVE_NEGATIVE" ]] &&
   grep -Fq "M1: exit=0" "$PROVE_NEGATIVE"; then
  test_pass "cap exhaustion fails closed, captures evidence, blocks validate, and aggregates prove-negative"
else
  test_fail "#839 cap-failure path did not fail closed with evidence before validate"
  cat "$EVENTS" >&2
  find "${NEVER_READY_FIXTURE}/evidence" -maxdepth 1 -type f -print >&2 || true
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start \
  "#839-quiescence-unreachable-fail" \
  "unreachable repl-health fails closed instead of being treated as quiescent"
UNREACHABLE_FIXTURE="$(make_fixture quiesce-unreachable yes)"
printf '%s\n' 'unreachable' > "${UNREACHABLE_FIXTURE}/curl-mode"
DRT009_REPL_QUIESCE_POLL_SECONDS=1 DRT009_REPL_QUIESCE_TIMEOUT_SECONDS=2 \
  run_real_drt "$UNREACHABLE_FIXTURE" --depth rekey
EVENTS="${UNREACHABLE_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq "[FAIL] replication quiescent before validate.sh" "$RUN_STDOUT" &&
   grep -Fq "curl failed" <<< "$RUN_OUTPUT" &&
   grep -Fq "last probe errors:" <<< "$RUN_OUTPUT" &&
   [[ "$(grep -Fc 'curl-fail' "$EVENTS")" -ge 4 ]] &&
   ! grep -Fxq 'validate' "$EVENTS" &&
   [[ -s "${UNREACHABLE_FIXTURE}/evidence/pvesr-status-pve01.txt" ]] &&
   [[ -s "${UNREACHABLE_FIXTURE}/evidence/zpool-status-pve01.txt" ]]; then
  test_pass "unreachable node retries until the cap, captures failure evidence, and blocks validate"
else
  test_fail "#839 unreachable-node path did not fail closed before validate"
  cat "$EVENTS" >&2
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start \
  "#839-quiescence-unparseable-fail" \
  "unparseable repl-health retries to the cap, writes evidence, and blocks validate"
UNPARSEABLE_FIXTURE="$(make_fixture quiesce-unparseable yes)"
printf '%s\n' 'unparseable' > "${UNPARSEABLE_FIXTURE}/curl-mode"
DRT009_REPL_QUIESCE_POLL_SECONDS=1 DRT009_REPL_QUIESCE_TIMEOUT_SECONDS=2 \
  run_real_drt "$UNPARSEABLE_FIXTURE" --depth rekey
EVENTS="${UNPARSEABLE_FIXTURE}/events.log"
SUMMARY="${UNPARSEABLE_FIXTURE}/evidence/drt009-summary.txt"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq "[FAIL] replication quiescent before validate.sh" "$RUN_STDOUT" &&
   grep -Fq "unparseable repl-health" "$SUMMARY" &&
   grep -Fq "last probe errors:" <<< "$RUN_OUTPUT" &&
   [[ "$(grep -Fc 'unparseable' "$EVENTS")" -ge 4 ]] &&
   ! grep -Fxq 'validate' "$EVENTS" &&
   grep -Fq "{not-json" "${UNPARSEABLE_FIXTURE}/evidence/repl-health-pve01.json" &&
   [[ -s "${UNPARSEABLE_FIXTURE}/evidence/pvesr-status-pve01.txt" ]] &&
   [[ -s "${UNPARSEABLE_FIXTURE}/evidence/zpool-status-pve01.txt" ]]; then
  test_pass "unparseable repl-health retries until the cap, records evidence, and blocks validate"
else
  test_fail "#839 unparseable repl-health path did not fail closed before validate"
  cat "$EVENTS" >&2
  cat "$SUMMARY" >&2 2>/dev/null || true
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "V3.1-depth-rekey" "rekey depth invokes M1 only and validates holders"
REKEY_FIXTURE="$(make_fixture rekey yes)"
run_real_drt "$REKEY_FIXTURE" --depth rekey
EVENTS="${REKEY_FIXTURE}/events.log"
# The DRT captures a pre-M1 plan digest, runs the M1 driver, then captures
# the post-M1 digest. Each capture calls tofu-wrapper twice
# (plan -no-color -refresh=false -out=<file> then show -json <file>) —
# the fixture mock records both calls.
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq 'm1-driver|--i-mean-it' "$EVENTS" &&
   grep -Fq 'tofu-wrapper|plan -no-color -refresh=false -out=' "$EVENTS" &&
   grep -Fq 'tofu-wrapper|show -json' "$EVENTS" &&
   grep -Fq 'm1-probe|workstation|local-file' "$EVENTS" &&
   grep -Fq 'm1-probe|cicd|register-runner' "$EVENTS" &&
   ! grep -Fq 'm3-driver' "$EVENTS" &&
   ! grep -Fq 'm4-vault-driver' "$EVENTS" &&
   ! grep -Fq 'm4-gitlab-driver' "$EVENTS" &&
   ! grep -Fq 'm5-driver' "$EVENTS"; then
  test_pass "rekey routes M1 only and exercises holder probes"
else
  test_fail "rekey depth routing was not M1-only"
  cat "$EVENTS" >&2
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "V3.1-only-routing" "--only narrows only the M4 dispatch"
ONLY_FIXTURE="$(make_fixture only yes)"
run_attended_fixture "$ONLY_FIXTURE" --depth resecret-all --only vault_dev_root_token
EVENTS="${ONLY_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq 'm1-driver|--i-mean-it' "$EVENTS" &&
   grep -Fq 'm3-driver|' "$EVENTS" &&
   grep -Fq 'm4-vault-driver|--i-mean-it' "$EVENTS" &&
   ! grep -Fq 'm4-gitlab-driver' "$EVENTS" &&
   grep -Fq 'm5-driver|' "$EVENTS"; then
  test_pass "--only selected one M4 row while M1/M3/M5 still ran"
else
  test_fail "--only did not narrow M4 dispatch correctly"
  cat "$EVENTS" >&2
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "V3.1-headless-m4" "headless resecret-all blocks at M4 before mutation"
HEADLESS_FIXTURE="$(make_fixture headless no)"
run_real_drt "$HEADLESS_FIXTURE" --depth resecret-all --only vault_dev_root_token
EVENTS="${HEADLESS_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -eq 77 ]] &&
   grep -Fq 'BLOCKED(attended-required)' "$RUN_STDOUT" &&
   grep -Fq 'M4 attended gate accepted' "$RUN_STDOUT" &&
   ! grep -Fq 'm4-vault-driver' "$EVENTS" &&
   ! grep -Fq 'm4-gitlab-driver' "$EVENTS"; then
  test_pass "headless run emits BLOCKED and no M4 driver mutates"
else
  test_fail "headless M4 interlock failed"
  cat "$EVENTS" >&2
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

# ---------------------------------------------------------------------
# #791 fixtures — the delta-zero assertion is drift-tolerant AND still
# fails-closed when the rekey mutates a plan-visible input.
#
# The 2026-07-28 G3 Act 1 run failed because an unscoped
# `tofu plan -detailed-exitcode` returned exit 2 against a live cluster
# with pre-existing dev/prod image drift (14/2/11 measured). The
# property being asserted — that an M1 SOPS envelope rekey re-wraps
# ciphertext only and must not alter any plan-visible input — is real
# and worth protecting. The fix isolates the ROTATION'S delta rather
# than asserting absolute convergence: capture a plan digest before the
# M1 driver runs, then assert the post-driver digest is identical.
#
# Two fixtures are required:
#   1. drift + no-op rekey → PASS: pre-existing drift shows in both
#      pre and post digests (they cancel out); the M1 driver made no
#      plan-visible change.
#   2. drift + CIDATA-altering rekey → FAIL: the M1 driver mutated
#      plan-state.json, so the post digest differs; the delta-zero
#      assertion still fails-closed on a real regression.
# ---------------------------------------------------------------------

# Represents the 2026-07-28 observation: 14 to add, 2 to change, 11 to
# destroy — a shape that has nothing to do with SOPS envelope rekeying,
# but that an unscoped -detailed-exitcode reads as "changes present".
# Uses the real `tofu show -json` resource_changes shape (address plus
# nested change.{actions,before,after}) so the digest helper's
# canonicalization is exercised end-to-end, not just the address field.
DRIFT_JSON='[
  {"address":"module.gitlab.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"image":"gitlab-abc12345.img"},"after":{"image":"gitlab-def67890.img"}}},
  {"address":"module.vault_prod.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"image":"vault-old.img"},"after":{"image":"vault-new.img"}}},
  {"address":"module.pbs.proxmox_virtual_environment_vm.vm","change":{"actions":["replace"],"before":{"tags":["old"]},"after":{"tags":["new"]}}}
]'

test_start "#791-drift-pass" "no-op rekey with pre-existing drift → M1 delta-zero passes"
DRIFT_PASS_FIXTURE="$(make_fixture drift-pass yes)"
printf '%s\n' "$DRIFT_JSON" > "${DRIFT_PASS_FIXTURE}/plan-state.json"
run_real_drt "$DRIFT_PASS_FIXTURE" --depth rekey
DRIFT_PASS_EVENTS="${DRIFT_PASS_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq '[PASS] pre-M1 tofu plan digest captured' "$RUN_STDOUT" &&
   grep -Fq '[PASS] M1 tofu plan delta zero vs pre-M1 baseline' "$RUN_STDOUT" &&
   ! grep -Fq '[FAIL]' "$RUN_STDOUT" &&
   [[ -s "${DRIFT_PASS_FIXTURE}/evidence/pre-m1-plan-digest.txt" ]] &&
   [[ -s "${DRIFT_PASS_FIXTURE}/evidence/post-m1-plan-digest.txt" ]] &&
   [[ "$(cat "${DRIFT_PASS_FIXTURE}/evidence/pre-m1-plan-digest.txt")" == \
      "$(cat "${DRIFT_PASS_FIXTURE}/evidence/post-m1-plan-digest.txt")" ]]; then
  test_pass "drift-tolerant: pre-existing plan changes present but the M1 delta-zero assertion passes on a no-op rekey"
else
  test_fail "#791 drift-tolerance regressed: no-op rekey with pre-existing drift did not PASS"
  cat "$DRIFT_PASS_EVENTS" >&2
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "#791-cidata-fail" "rekey that mutates a plan input → M1 delta-zero fails closed"
CIDATA_FAIL_FIXTURE="$(make_fixture cidata-fail yes)"
printf '%s\n' "$DRIFT_JSON" > "${CIDATA_FAIL_FIXTURE}/plan-state.json"
# FIXTURE_M1_MUTATES_PLAN_STATE=1 tells the M1 driver mock to append a
# resource_change to plan-state.json, simulating a rekey that alters a
# CIDATA-derived input. This must still FAIL the delta-zero assertion —
# the property being protected is "an M1 rekey changes nothing plan sees".
FIXTURE_M1_MUTATES_PLAN_STATE=1 \
  run_real_drt "$CIDATA_FAIL_FIXTURE" --depth rekey
CIDATA_FAIL_EVENTS="${CIDATA_FAIL_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq '[PASS] pre-M1 tofu plan digest captured' "$RUN_STDOUT" &&
   grep -Fq '[FAIL] M1 tofu plan delta zero vs pre-M1 baseline' "$RUN_STDOUT" &&
   [[ -s "${CIDATA_FAIL_FIXTURE}/evidence/pre-m1-plan-digest.txt" ]] &&
   [[ -s "${CIDATA_FAIL_FIXTURE}/evidence/post-m1-plan-digest.txt" ]] &&
   [[ "$(cat "${CIDATA_FAIL_FIXTURE}/evidence/pre-m1-plan-digest.txt")" != \
      "$(cat "${CIDATA_FAIL_FIXTURE}/evidence/post-m1-plan-digest.txt")" ]]; then
  test_pass "fail-closed: a rekey that alters a plan-visible input is detected even with pre-existing drift"
else
  test_fail "#791 fail-closed property broke: a CIDATA-altering rekey did not FAIL the delta-zero assertion"
  cat "$CIDATA_FAIL_EVENTS" >&2
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "#791-baseline-guard" "pre-M1 capture failure blocks the M1 driver from running"
BASELINE_GUARD_FIXTURE="$(make_fixture baseline-guard yes)"
# Overwrite tofu-wrapper mock to fail on `plan` — this causes
# capture_plan_digest to return non-zero, so the pre-M1 digest file is
# never written. The guard on the M1 driver assertion must observe the
# missing digest and skip the driver invocation entirely. Verified end-
# to-end (R-G-4): the driver mock's event log must NOT contain
# `m1-driver|` after the run.
cat > "${BASELINE_GUARD_FIXTURE}/bin/tofu-wrapper" <<'GUARD_MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf "tofu-wrapper|%s\n" "$*" >> "$EVENT_LOG"
exit 1
GUARD_MOCK
chmod +x "${BASELINE_GUARD_FIXTURE}/bin/tofu-wrapper"
run_real_drt "$BASELINE_GUARD_FIXTURE" --depth rekey
BASELINE_GUARD_EVENTS="${BASELINE_GUARD_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq '[FAIL] pre-M1 tofu plan digest captured' "$RUN_STDOUT" &&
   grep -Fq '[FAIL] M1 driver completed by path' "$RUN_STDOUT" &&
   ! grep -Fq 'm1-driver|' "$BASELINE_GUARD_EVENTS" &&
   [[ ! -s "${BASELINE_GUARD_FIXTURE}/evidence/pre-m1-plan-digest.txt" ]]; then
  test_pass "baseline capture failure fails both assertions and blocks the M1 mutation"
else
  test_fail "#791 baseline-guard broke: driver ran without a baseline, or the fail-closed chain misfired"
  cat "$BASELINE_GUARD_EVENTS" >&2
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "#791-stale-digest-cleared" "startup removes stale pre/post-M1 digest files so a failed current capture cannot inherit a prior run's digest"
STALE_FIXTURE="$(make_fixture stale-digest yes)"
mkdir -p "${STALE_FIXTURE}/evidence"
# Simulate leftover digest files from a prior successful run in the
# same evidence dir (e.g., DRT009_EVIDENCE_DIR reused across runs).
# The value is arbitrary — the guard only cares that the file is
# non-empty; if startup fails to truncate, this value survives and
# the M1 driver runs against a stale baseline.
printf '%s\n' 'deadbeef00000000000000000000000000000000000000000000000000000000' > "${STALE_FIXTURE}/evidence/pre-m1-plan-digest.txt"
printf '%s\n' 'deadbeef00000000000000000000000000000000000000000000000000000000' > "${STALE_FIXTURE}/evidence/post-m1-plan-digest.txt"
# Same tofu-wrapper mock as #791-baseline-guard: fail on plan.
cat > "${STALE_FIXTURE}/bin/tofu-wrapper" <<'STALE_MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf "tofu-wrapper|%s\n" "$*" >> "$EVENT_LOG"
exit 1
STALE_MOCK
chmod +x "${STALE_FIXTURE}/bin/tofu-wrapper"
run_real_drt "$STALE_FIXTURE" --depth rekey
STALE_EVENTS="${STALE_FIXTURE}/events.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq '[FAIL] pre-M1 tofu plan digest captured' "$RUN_STDOUT" &&
   grep -Fq '[FAIL] M1 driver completed by path' "$RUN_STDOUT" &&
   ! grep -Fq 'm1-driver|' "$STALE_EVENTS" &&
   [[ ! -s "${STALE_FIXTURE}/evidence/pre-m1-plan-digest.txt" ]] &&
   [[ ! -s "${STALE_FIXTURE}/evidence/post-m1-plan-digest.txt" ]]; then
  test_pass "stale digest files from prior run are truncated at startup; failed current capture leaves them empty and the guard blocks the M1 driver"
else
  test_fail "#791 stale-digest-cleared broke: stale digest survived startup, or the guard misfired"
  cat "$STALE_EVENTS" >&2
  ls -la "${STALE_FIXTURE}/evidence/" >&2 || true
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "V3.1-sentinel-leak" "DRT-009 output and evidence sink do not leak sentinel values"
# Post-#800: mocks write sentinels to $fixture/off-limits/, NOT to
# stdout/stderr, because DRT-009 now captures driver/probe output. The
# assertion still stands: DRT's own surfaces (stdout, stderr, and the
# evidence sink where driver/probe logs land) must not contain sentinel
# material. The mock's off-limits writes prove DRT never accidentally
# copies arbitrary driver-written paths into evidence — which it
# shouldn't. If a rotation driver ever emitted secrets on stdout/stderr
# it would leak here; V2.3-sentinel-leak
# (tests/test_rotate_sops_recipient.sh) is the driver-side ratchet that
# catches that at the source.
SENTINEL_FIXTURE="$REKEY_FIXTURE"
if ! grep -R -F "$SENTINEL_ONE" "${SENTINEL_FIXTURE}/stdout.txt" "${SENTINEL_FIXTURE}/stderr.txt" "${SENTINEL_FIXTURE}/evidence" >/dev/null 2>&1 &&
   ! grep -R -F "$SENTINEL_TWO" "${SENTINEL_FIXTURE}/stdout.txt" "${SENTINEL_FIXTURE}/stderr.txt" "${SENTINEL_FIXTURE}/evidence" >/dev/null 2>&1; then
  test_pass "sentinels present in mock side-channel are absent from DRT stdout/stderr and evidence sink"
else
  test_fail "sentinel value leaked through DRT-009 output surface"
  grep -R -n -F "$SENTINEL_ONE" "${SENTINEL_FIXTURE}" >&2 || true
  grep -R -n -F "$SENTINEL_TWO" "${SENTINEL_FIXTURE}" >&2 || true
fi

# ---------------------------------------------------------------------
# #800 fixtures — DRT-009 surfaces AND persists driver output on failure.
#
# Pre-#800 behavior: run_driver_path_only piped stdout+stderr to
# /dev/null. A driver failing with a precise error message (e.g. the
# `git tree must be clean` refusal observed in G3 attempt 8,
# rotate-sops-recipient.sh:517) produced ONLY the DRT-level `[FAIL] M1
# driver completed by path ... exit 1` line — no context. Operator had
# to open the driver source to know what its own error said.
#
# Post-#800 contract: the DRT captures stdout+stderr per driver
# invocation to evidence/driver-<class>-<N>.log AND prints tail-9 with
# the seven-space indent used by drt_assert (common.sh:137) so the
# diagnostic is inline with the failure verdict AND persisted for
# post-hoc review. (Tail is 9 not 10 because drt_assert re-tails our
# stdout to 10 lines; a 10-line tail plus the "See persistent log:"
# pointer would exceed the budget and drop one log line.)
#
# Fixture proves both surfaces: RUN_STDOUT contains the driver's error
# message inline, AND evidence/driver-M1-1.log contains the same. R-G-4
# end-to-end check: the mock's error message is a distinct token that
# would NOT have appeared under the pre-#800 discard, so this fixture
# fails against the pre-fix code.
# ---------------------------------------------------------------------
test_start "#800-driver-failure-surfaced" "M1 driver failure prints error tail inline AND persists to evidence/driver-M1-1.log"
DRIVER_FAIL_FIXTURE="$(make_fixture driver-fail yes)"
DRIVER_FAIL_MSG="DRT800_FIXTURE_KNOWN_DRIVER_FAILURE_marker_for_capture_test"
FIXTURE_M1_DRIVER_FAIL_MESSAGE="$DRIVER_FAIL_MSG" \
  run_real_drt "$DRIVER_FAIL_FIXTURE" --depth rekey
DRIVER_FAIL_LOG="${DRIVER_FAIL_FIXTURE}/evidence/driver-M1-1.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq "[FAIL] M1 driver completed by path" "$RUN_STDOUT" &&
   grep -Fq "$DRIVER_FAIL_MSG" "$RUN_STDOUT" &&
   [[ -s "$DRIVER_FAIL_LOG" ]] &&
   grep -Fq "$DRIVER_FAIL_MSG" "$DRIVER_FAIL_LOG" &&
   grep -Fq "See persistent log: " "$RUN_STDOUT" &&
   grep -Fq "driver-M1-1.log" "$RUN_STDOUT"; then
  test_pass "driver failure surfaced its own error tail to DRT stdout AND persisted the full log to evidence"
else
  test_fail "#800 driver-failure surfacing broke: error tail or persistent log missing"
  cat "$RUN_STDOUT" >&2 || true
  cat "$DRIVER_FAIL_LOG" >&2 2>/dev/null || true
fi

test_start "#800-driver-success-persisted" "M1 driver success also persists its output to evidence/driver-M1-1.log"
# Post-hoc diagnosis needs the log even on successful runs (a caller
# investigating a downstream failure may want to see what the driver
# actually did). The REKEY_FIXTURE above already ran the M1 driver
# successfully — assert the log is present and contains the mock's
# expected status text.
DRIVER_OK_LOG="${REKEY_FIXTURE}/evidence/driver-M1-1.log"
if [[ -s "$DRIVER_OK_LOG" ]] &&
   grep -Fq "m1-driver: no-op rekey complete (mock)" "$DRIVER_OK_LOG" &&
   grep -Fq "m1-driver: rewrote 2 SOPS envelopes (mock)" "$DRIVER_OK_LOG"; then
  test_pass "driver-M1-1.log persists both stdout and stderr from a successful driver run"
else
  test_fail "#800 driver-success persistence broke: expected log missing or empty"
  ls -la "${REKEY_FIXTURE}/evidence/" >&2 || true
  cat "$DRIVER_OK_LOG" >&2 2>/dev/null || true
fi

# ---------------------------------------------------------------------
# #813 defect-2 fixture — a holder that has NOT received the key must
# FAIL the M1 holder probe.
#
# Pre-#813 probe was recover-secrets.sh (rotation-manifest.yaml pre-r1),
# which no-ops when secrets.yaml exists. It PASSED in all 8 DRT-009
# attempts, including runs where nothing was delivered. The operator's
# fixture requirement: "a holder that has NOT received the key, asserting
# the probe FAILS."
#
# This fixture uses the mock probe with FIXTURE_M1_PROBE_FAIL_ON_HOLDER
# to simulate a holder whose delivered key doesn't work. The pre-#813
# recover-secrets.sh probe would have passed regardless. Post-#813,
# `probe-m1-holder-decrypt.sh` (or here, the mock exercising the same
# per-holder contract) fails closed. The probe log is captured and its
# failure message is surfaced inline via the #800 capture path.
# ---------------------------------------------------------------------
test_start "#813-defect2-probe-fails-on-missing-holder" "M1 holder probe FAILS closed when a specific holder cannot decrypt"
PROBE_FAIL_FIXTURE="$(make_fixture probe-fail-cicd yes)"
FIXTURE_M1_PROBE_FAIL_ON_HOLDER="cicd" \
  run_real_drt "$PROBE_FAIL_FIXTURE" --depth rekey
CICD_PROBE_LOG=""
for candidate in "${PROBE_FAIL_FIXTURE}/evidence/"m1-holder-probe-*-cicd.log; do
  [[ -e "$candidate" ]] || continue
  CICD_PROBE_LOG="$candidate"
done
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq "[FAIL] M1 per-holder decrypt probes from manifest holders" "$RUN_STDOUT" &&
   grep -Fq "holder cicd cannot decrypt" "$RUN_STDOUT" &&
   [[ -n "$CICD_PROBE_LOG" && -s "$CICD_PROBE_LOG" ]] &&
   grep -Fq "holder cicd cannot decrypt" "$CICD_PROBE_LOG"; then
  test_pass "one-holder probe failure fails the DRT assertion, surfaces the error inline, and persists it per-holder"
else
  test_fail "#813 defect-2 probe-fail-on-missing-holder broke: failure not surfaced or not persisted"
  cat "$RUN_STDOUT" >&2 || true
  ls -la "${PROBE_FAIL_FIXTURE}/evidence/" >&2 || true
  [[ -n "$CICD_PROBE_LOG" ]] && cat "$CICD_PROBE_LOG" >&2
fi

# Meta-check: prove this fixture would have PASSED against the pre-#813
# recover-secrets.sh probe. The manifest field alone is what dispatches
# — a passing probe here (mock configured NOT to fail) MUST still be
# recognized as PASS, so the fixture above genuinely varies on the
# probe's decision, not on unrelated conditions.
test_start "#813-defect2-probe-passes-when-key-works" "M1 holder probe PASSES when every holder can decrypt"
PROBE_OK_FIXTURE="$(make_fixture probe-ok yes)"
run_real_drt "$PROBE_OK_FIXTURE" --depth rekey
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq "[PASS] M1 per-holder decrypt probes from manifest holders" "$RUN_STDOUT" &&
   [[ -s "${PROBE_OK_FIXTURE}/evidence/m1-holder-probe-1-workstation.log" ]] &&
   [[ -s "${PROBE_OK_FIXTURE}/evidence/m1-holder-probe-2-cicd.log" ]]; then
  test_pass "healthy-holder path passes AND persists per-holder logs — fixture's failure signal in the previous test is genuinely from the probe"
else
  test_fail "#813 defect-2 healthy-holder path did not pass or did not persist per-holder logs"
  cat "$RUN_STDOUT" >&2 || true
  ls -la "${PROBE_OK_FIXTURE}/evidence/" >&2 || true
fi

# ---------------------------------------------------------------------
# #820 fixtures — DRT-009 captures AND persists validate.sh output on the
# unscoped-validate step, the way #800 already did for the driver path.
#
# Pre-#820 behavior (framework/dr-tests/tests/DRT-009-key-rotation.sh:311-313
# on the parent commit): run_validate_unscoped delegated to
# run_command_string_suppressed, which piped stdout+stderr to /dev/null. A
# failing validate.sh produced only the DRT-level
# `[FAIL] validate.sh unscoped passes ... Got: exit 1` line — no context in
# stdout and no log in the evidence sink. G3 Act 1 run 20260731T231437Z hit
# this exact hole: every rotation assertion PASSED and validate.sh alone
# went red with its identity unrecoverable (see issue #820).
#
# Post-#820 contract: run_validate_unscoped delegates to
# run_and_capture_command_string_to_evidence (already present at :288 as the
# #800 companion helper for command-string probes), which writes
# stdout+stderr to a 0600 log in the evidence sink and, on non-zero exit,
# prints tail-9 and the persistent log path to stdout so drt_assert's
# tail-10 re-tail (framework/dr-tests/lib/common.sh:137) still carries them.
#
# R-G-4 (`.claude/rules/process-discipline.md`) end-to-end check: BOTH
# tests below exercise the full assertion path (mock -> run_validate_unscoped
# -> drt_assert -> RUN_STDOUT + evidence log), not just "the helper writes a
# file". The failure test's distinctive markers appear in stdout only if the
# tail is being printed; the success test proves the log is persisted even
# when the DRT verdict is PASS (post-hoc diagnosis of the transient class
# described in the #820 report requires the log regardless of exit code).
# ---------------------------------------------------------------------
test_start "#820-validate-failure-surfaced" "validate.sh failure prints stdout+stderr tail inline AND persists to evidence/validate-unscoped.log"
VALIDATE_FAIL_FIXTURE="$(make_fixture validate-fail yes)"
VALIDATE_STDOUT_MARKER="DRT820_FIXTURE_VALIDATE_STDOUT_MARKER"
VALIDATE_STDERR_MARKER="DRT820_FIXTURE_VALIDATE_STDERR_MARKER"
# Overwrite the fixture's validate mock so it emits (in this order — the
# ordering is load-bearing and must not be re-arranged): first a stderr
# marker, then nine numbered stdout LINE_NN markers, then exit 1. bash
# builtin printf writes synchronously to the merged fd (2>&1 in the
# caller), so the combined log is deterministic: 10 lines, stderr on
# line 1, LINE_01..LINE_09 on lines 2-10. tail -9 in the helper drops
# the stderr line and keeps LINE_01..LINE_09; the assertion on BOTH
# LINE_01 and LINE_09 in RUN_STDOUT proves the full tail-9 + pointer
# budget survived drt_assert's outer tail -10 (common.sh:137). A
# regression that shrinks the wrapper's tail (e.g. tail -3) or the
# drt_assert re-tail (e.g. tail -4) drops LINE_01 and the fixture
# goes red — where the earlier two-marker fixture would not.
# The stderr marker is asserted in the persistent log only (proving the
# combined-stream capture works): tail-9 correctly drops it as the
# oldest line, so it does NOT survive into RUN_STDOUT.
cat > "${VALIDATE_FAIL_FIXTURE}/bin/validate" <<VALIDATE_FAIL_MOCK
#!/usr/bin/env bash
set -euo pipefail
printf "validate\n" >> "\$EVENT_LOG"
# Emit the stderr marker FIRST so that tail-9 (over a 10-line combined
# log) drops IT rather than the LINE_01 marker. bash's builtin printf
# writes synchronously to the same merged fd (2>&1 in the caller), so
# the ordering below is deterministic in the persistent log:
#   line  1: STDERR_MARKER
#   lines 2-10: 9 numbered stdout LINE_NN lines
# tail -9 then keeps lines 2-10 (the 9 numbered lines) — stressing the
# full tail-9 budget while surfacing both boundary markers (LINE_01 and
# LINE_09) into RUN_STDOUT.
printf "%s\n" "${VALIDATE_STDERR_MARKER}" >&2
printf "%s_LINE_01\n" "${VALIDATE_STDOUT_MARKER}"
printf "%s_LINE_02\n" "${VALIDATE_STDOUT_MARKER}"
printf "%s_LINE_03\n" "${VALIDATE_STDOUT_MARKER}"
printf "%s_LINE_04\n" "${VALIDATE_STDOUT_MARKER}"
printf "%s_LINE_05\n" "${VALIDATE_STDOUT_MARKER}"
printf "%s_LINE_06\n" "${VALIDATE_STDOUT_MARKER}"
printf "%s_LINE_07\n" "${VALIDATE_STDOUT_MARKER}"
printf "%s_LINE_08\n" "${VALIDATE_STDOUT_MARKER}"
printf "%s_LINE_09\n" "${VALIDATE_STDOUT_MARKER}"
exit 1
VALIDATE_FAIL_MOCK
chmod +x "${VALIDATE_FAIL_FIXTURE}/bin/validate"
run_real_drt "$VALIDATE_FAIL_FIXTURE" --depth rekey
VALIDATE_FAIL_LOG="${VALIDATE_FAIL_FIXTURE}/evidence/validate-unscoped.log"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq "[FAIL] validate.sh unscoped passes" "$RUN_STDOUT" &&
   grep -Fq "${VALIDATE_STDOUT_MARKER}_LINE_01" "$RUN_STDOUT" &&
   grep -Fq "${VALIDATE_STDOUT_MARKER}_LINE_09" "$RUN_STDOUT" &&
   [[ -s "$VALIDATE_FAIL_LOG" ]] &&
   grep -Fq "${VALIDATE_STDOUT_MARKER}_LINE_01" "$VALIDATE_FAIL_LOG" &&
   grep -Fq "${VALIDATE_STDOUT_MARKER}_LINE_09" "$VALIDATE_FAIL_LOG" &&
   grep -Fq "$VALIDATE_STDERR_MARKER" "$VALIDATE_FAIL_LOG" &&
   grep -Fq "See persistent log: " "$RUN_STDOUT" &&
   grep -Fq "validate-unscoped.log" "$RUN_STDOUT"; then
  test_pass "validate.sh failure surfaced tail-9 stdout (LINE_01+LINE_09) inline AND persisted combined stdout+stderr to evidence"
else
  test_fail "#820 validate-failure surfacing broke: tail-9 boundary markers, combined-log capture, or persistent-log pointer missing"
  cat "$RUN_STDOUT" >&2 || true
  cat "$VALIDATE_FAIL_LOG" >&2 2>/dev/null || true
fi

test_start "#820-validate-success-persisted" "validate.sh success also persists BOTH stdout and stderr to evidence/validate-unscoped.log"
# Post-hoc diagnosis of a transient in the #820 class (green run followed by
# operator investigation) requires the log even when the run passed. The
# REKEY_FIXTURE above already ran validate.sh successfully; assert the log
# is present and contains BOTH stdout and stderr from the mock. Checking
# only "file non-empty" would pass on a stdout-only capture that dropped
# stderr — the property the #820 fix relies on is combined-stream capture.
VALIDATE_OK_LOG="${REKEY_FIXTURE}/evidence/validate-unscoped.log"
if [[ -s "$VALIDATE_OK_LOG" ]] &&
   grep -Fq "validate-mock-stdout-ok" "$VALIDATE_OK_LOG" &&
   grep -Fq "validate-mock-stderr-ok" "$VALIDATE_OK_LOG"; then
  test_pass "validate-unscoped.log persists validate.sh stdout AND stderr on a successful run"
else
  test_fail "#820 validate-success persistence broke: expected combined log missing or incomplete"
  ls -la "${REKEY_FIXTURE}/evidence/" >&2 || true
  cat "$VALIDATE_OK_LOG" >&2 2>/dev/null || true
fi

test_start "#820-final-chmod-escalates" "capture helper reports failure if the child command unlinks the persistent log (final chmod broken)"
# codex R2 rev2 P2-1: previous rev suppressed the post-child chmod exit
# with `... 2>/dev/null || true`, so a child that unlinks the log path
# could break the 0600 persistent-log contract silently while the helper
# still reported success. rev3 escalates the final chmod failure over a
# successful child rc. This fixture uses a validate mock that DELETES
# validate-unscoped.log immediately after writing to it and then exits
# 0, then asserts the DRT run went red on the escalation.
FINAL_CHMOD_FIXTURE="$(make_fixture final-chmod-escalate no)"
cat > "${FINAL_CHMOD_FIXTURE}/bin/validate" <<'FINAL_CHMOD_MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf "validate\n" >> "$EVENT_LOG"
# Emit something to stdout so the helper's initial chmod succeeded.
printf "final-chmod-escalation-fixture-was-here\n"
# Now delete the persistent log path so the helper's post-child
# chmod hits ENOENT.
LOG_PATH="${DRT009_EVIDENCE_DIR}/validate-unscoped.log"
rm -f "$LOG_PATH"
exit 0
FINAL_CHMOD_MOCK
chmod +x "${FINAL_CHMOD_FIXTURE}/bin/validate"
run_real_drt "$FINAL_CHMOD_FIXTURE" --depth rekey
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq "[FAIL] validate.sh unscoped passes" "$RUN_STDOUT" &&
   grep -Fq "persistent-log 0600 contract broken" "$RUN_STDOUT"; then
  test_pass "child that unlinks the log path causes helper to escalate the final-chmod failure over the child's zero rc"
else
  test_fail "#820 R2 rev3 P2-1: final chmod failure was not escalated (RUN_STATUS=${RUN_STATUS})"
  cat "$RUN_STDOUT" >&2 || true
fi

test_start "#820-log-mode-0600-on-reuse" "capture helper chmods the log to 0600 even when an operator reuses DRT009_EVIDENCE_DIR with a pre-existing 0644 file"
# codex R2 P2-1: `( umask 077 && : > "$log_path" )` only gives 0600 to
# newly-created files; a shell truncation does not chmod an existing
# file. Pre-create the log at 0644 in the evidence dir, then run the DRT
# and assert the helper's explicit chmod flipped the mode to 0600. Uses
# the REKEY_FIXTURE evidence dir but pre-seeds a distinctive log path
# under DRT009_EVIDENCE_DIR so the reuse case is deterministic.
LOG_MODE_FIXTURE="$(make_fixture log-mode-reuse no)"
LOG_MODE_EVIDENCE="${LOG_MODE_FIXTURE}/evidence"
mkdir -p "$LOG_MODE_EVIDENCE"
# Pre-seed the exact log path validate-unscoped.log at 0644 so a
# truncation-only helper would leave the mode at 0644.
: > "${LOG_MODE_EVIDENCE}/validate-unscoped.log"
chmod 644 "${LOG_MODE_EVIDENCE}/validate-unscoped.log"
run_real_drt "$LOG_MODE_FIXTURE" --depth rekey
LOG_MODE_ACTUAL="$(file_mode "${LOG_MODE_EVIDENCE}/validate-unscoped.log")"
if [[ "$RUN_STATUS" -eq 0 ]] && [[ "$LOG_MODE_ACTUAL" == "600" ]]; then
  test_pass "capture helper forced 0600 on a pre-existing 0644 log (mode=${LOG_MODE_ACTUAL})"
else
  # Print mode on its own line so a multi-line probe defect (should be
  # impossible after the file_mode helper) cannot masquerade as a mode
  # value glued to the RUN_STATUS token.
  test_fail "#820 R2 P2-1: capture helper did not chmod pre-existing log to 0600 (RUN_STATUS=${RUN_STATUS}) mode=[${LOG_MODE_ACTUAL}]"
  cat "$RUN_STDOUT" >&2 || true
fi

runner_summary
