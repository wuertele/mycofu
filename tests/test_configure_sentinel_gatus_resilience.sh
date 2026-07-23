#!/usr/bin/env bash
#
# test_configure_sentinel_gatus_resilience.sh — verify configure-sentinel-gatus.sh
# is resilient to NAS dockerd hangs.
#
# Origin: DRT-001 on 2026-04-25 hung 30+ minutes inside `docker stop
# gatus-sentinel` against a NAS dockerd that had leaked container state
# after 55 days uptime. The script had no SSH timeout, no docker-stop
# timeout, and used `2>/dev/null || true` to mask failures — so it could
# not detect or recover from the hang. See
# docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md.
#
# This test is a static ratchet plus an integration probe of the
# docker-replace logic with a PATH-shimmed ssh that simulates each of
# the scenarios from the report's dimension B (T1-T5).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT_PATH="${REPO_ROOT}/framework/scripts/configure-sentinel-gatus.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# Static ratchets — prevent future MRs from regressing the resilience
# patterns. Each ratchet has a comment explaining what it protects.
# ---------------------------------------------------------------------------

test_start "1" "SSH_OPTS constant is defined and includes ConnectTimeout"
# SSH_OPTS may be a single-line `(opt1 opt2 ...)` or a multi-line array;
# match both by extracting the parenthesized body via awk.
ssh_opts_body=$(awk '/^SSH_OPTS=\(/{flag=1} flag{print} /^\)/{if(flag){flag=0}}' "${SCRIPT_PATH}")
if grep -qE 'ConnectTimeout=' <<< "${ssh_opts_body}"; then
  test_pass "SSH_OPTS includes ConnectTimeout"
else
  test_fail "SSH_OPTS missing ConnectTimeout"
fi

test_start "2" "SSH_OPTS includes ServerAliveInterval and ServerAliveCountMax"
if grep -qE 'ServerAliveInterval=' <<< "${ssh_opts_body}" && \
   grep -qE 'ServerAliveCountMax=' <<< "${ssh_opts_body}"; then
  test_pass "SSH_OPTS includes server-alive bounds"
else
  test_fail "SSH_OPTS missing ServerAliveInterval or ServerAliveCountMax"
fi

test_start "3" "every ssh/scp call to the NAS uses \${SSH_OPTS}"
# Strip comments and heredoc/echo content (they may contain example commands
# for operators, not actual invocations). Look only at lines that begin with
# whitespace + ssh/scp + something-that-needs-options.
NAS_CALLS_WITHOUT_OPTS=$(
  sed 's/#.*//' "${SCRIPT_PATH}" \
    | grep -nE '(^|[[:space:]])(ssh|scp)[[:space:]]+[^$]*"\$\{NAS' \
    | grep -v '\${SSH_OPTS}' \
    || true
)
if [[ -z "${NAS_CALLS_WITHOUT_OPTS}" ]]; then
  test_pass "every NAS ssh/scp invocation references SSH_OPTS"
else
  test_fail "found NAS ssh/scp invocation(s) without \${SSH_OPTS}"
  printf '    bare invocation:\n%s\n' "${NAS_CALLS_WITHOUT_OPTS}" >&2
fi

test_start "4" "docker stop is bounded by remote 'timeout' command"
# The fix uses NAS-side `timeout DOCKER_STOP_TIMEOUT docker stop ...` so
# the remote command can't hang forever.
if grep -qE 'timeout[[:space:]]+\$\{?DOCKER_STOP_TIMEOUT\}?[[:space:]]+\$\{?NAS_DOCKER\}?[[:space:]]+stop' "${SCRIPT_PATH}"; then
  test_pass "docker stop is wrapped by 'timeout \${DOCKER_STOP_TIMEOUT}'"
else
  test_fail "docker stop is not bounded by 'timeout \${DOCKER_STOP_TIMEOUT}'"
fi

test_start "5" "escalation path: docker kill -s SIGKILL after stop fails"
# The fix escalates to SIGKILL via docker kill if docker stop fails or
# times out. This must use the same timeout bound.
if grep -qE '\$\{?NAS_DOCKER\}?[[:space:]]+kill -s SIGKILL gatus-sentinel' "${SCRIPT_PATH}" && \
   grep -qE 'timeout[[:space:]]+\$\{?DOCKER_KILL_TIMEOUT\}?[[:space:]]+\$\{?NAS_DOCKER\}?[[:space:]]+kill' "${SCRIPT_PATH}"; then
  test_pass "docker kill -s SIGKILL escalation is bounded and present"
else
  test_fail "docker kill -s SIGKILL escalation is missing or unbounded"
fi

test_start "6" "no '|| true' masking on docker stop/kill/rm/run mutation lines"
# Goal 10 propagation pattern from Sprint 029. The bug-bearing original
# used '2>/dev/null || true' on docker stop — that masking is what made
# the hang invisible to the script. Mutation operations must propagate
# their exit codes so the script (and the convergence step) can react.
MASKED=$(
  sed 's/#.*//' "${SCRIPT_PATH}" \
    | grep -nE '\$\{?NAS_DOCKER\}?[[:space:]]+(stop|kill|inspect|rm|run)[[:space:]]' \
    | grep -E '\|\|[[:space:]]+(true|:)' \
    || true
)
if [[ -z "${MASKED}" ]]; then
  test_pass "docker stop/kill/inspect/rm/run lines do not have '|| true' or '|| :' masking"
else
  test_fail "found '|| true' masking on docker mutation line(s)"
  printf '    masked:\n%s\n' "${MASKED}" >&2
fi

test_start "6.1" "every docker container-lifecycle call is bounded by 'timeout'"
# Sprint 029 MR !200 review found that bounding only stop/kill leaves
# rm/run/inspect exposed to the same daemon-leak hang class. Every
# container-lifecycle call should be wrapped in NAS-side `timeout`.
UNBOUNDED=$(
  sed 's/#.*//' "${SCRIPT_PATH}" \
    | grep -nE '\$\{?NAS_DOCKER\}?[[:space:]]+(stop|kill|inspect|rm|run)[[:space:]]' \
    | grep -vE 'timeout[[:space:]]+\$\{?DOCKER_[A-Z_]+_TIMEOUT\}?[[:space:]]+\$\{?NAS_DOCKER\}?' \
    || true
)
if [[ -z "${UNBOUNDED}" ]]; then
  test_pass "every docker stop/kill/inspect/rm/run is bounded by 'timeout \${DOCKER_*_TIMEOUT}'"
else
  test_fail "found unbounded docker container-lifecycle call(s)"
  printf '    unbounded:\n%s\n' "${UNBOUNDED}" >&2
fi

test_start "6.2" "SSH_OPTS is a bash array, not a flat string"
# Sister Sprint 029 script cert-storage-backfill.sh uses array form;
# this script should match. Array form prevents word-splitting bugs
# when an option contains a space.
BARE_USES=$(grep -nE '\$\{SSH_OPTS\}[^[]' "${SCRIPT_PATH}" || true)
if grep -qE '^SSH_OPTS=\(' "${SCRIPT_PATH}" && [[ -z "${BARE_USES}" ]]; then
  test_pass "SSH_OPTS=(...) array form, used as \"\${SSH_OPTS[@]}\" everywhere"
else
  test_fail "SSH_OPTS not array, or used as flat \${SSH_OPTS} somewhere"
  printf '    bare uses:\n%s\n' "${BARE_USES}" >&2
fi

test_start "6.3" "NAS prereq check verifies 'timeout' is available"
# The script's resilience depends on NAS-side `timeout`. If the NAS
# lacks it, the script should fail loud with a clear error rather
# than silently fall back to unbounded calls.
if grep -qE 'command -v timeout' "${SCRIPT_PATH}"; then
  test_pass "script verifies NAS has 'timeout' before issuing bounded calls"
else
  test_fail "script does not verify NAS has 'timeout'"
fi

test_start "7" "post-stop verification poll exists before docker run"
# Even after stop+kill return success, dockerd's view can lag. The fix
# polls 'docker inspect' until the container reports not-running before
# proceeding to docker rm/run. Without this, docker run can race and
# fail with "name already in use" against a daemon that still holds the
# old container's state.
if grep -qE '\$\{?NAS_DOCKER\}?[[:space:]]+inspect.*\.State\.Running' "${SCRIPT_PATH}" && \
   grep -qE 'DOCKER_VERIFY_TIMEOUT' "${SCRIPT_PATH}"; then
  test_pass "post-stop verification poll is present"
else
  test_fail "post-stop verification poll is missing"
fi

test_start "8" "operator-actionable error message references synopkg restart"
# When stop AND kill both fail, the script must tell the operator
# exactly what to do (per the no-manual-fixes principle: automation
# output is operator instruction).
if grep -qF 'synopkg restart ContainerManager' "${SCRIPT_PATH}"; then
  test_pass "error path references the synopkg restart recovery"
else
  test_fail "error path does not reference synopkg restart"
fi

test_start "9" "error path references the diagnostic report"
# Operators encountering this failure should be pointed at the report
# so they can verify they're seeing the same wedge mode.
if grep -qF 'docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md' "${SCRIPT_PATH}"; then
  test_pass "error path references the diagnostic report"
else
  test_fail "error path does not reference docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md"
fi

# ---------------------------------------------------------------------------
# Behavioral test — narrowly verify the docker-replace logic with a
# PATH-shimmed ssh. Tests just the docker stop/kill/inspect/rm/run lines
# by extracting them into a callable harness (the rest of the script
# touches yq/jq/scp and would require a much larger fixture).
# ---------------------------------------------------------------------------

# Extract just the SSH_OPTS, timeout constants, and the docker-replace
# block (between "Step 1: detect" and "Step 4: start the new container"
# end) into a stub script. This avoids fighting the rest of the file's
# config-generation logic.
HARNESS="${TMP_DIR}/docker-replace-harness.sh"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${SHIM_DIR}"

cat > "${HARNESS}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
NAS_USER=root
NAS_IP=127.0.0.1
# Stub SSH_MUX_DIR so SSH_OPTS' ControlPath=${SSH_MUX_DIR}/... resolves
# under set -u. The harness uses a PATH-shimmed ssh that ignores SSH
# options entirely, so the path's content doesn't matter — only that
# the variable is defined.
SSH_MUX_DIR="${TMP_DIR:-/tmp}/harness-ssh-mux"
mkdir -p "${SSH_MUX_DIR}"
# nas_docker() (added in G9 issues #30 + #61) probes the NAS for the
# docker binary path and populates NAS_DOCKER. That resolver has its
# own dedicated test file (test_nas_docker_resolver.sh); this harness
# just stubs NAS_DOCKER so the docker-replace block can run against
# the PATH-shimmed ssh. The value doesn't matter — the shim inspects
# the docker verb (stop/kill/inspect/rm/run), not the binary path.
NAS_DOCKER=/usr/local/bin/docker
EOF

# Pull from the real script:
#   - SSH_OPTS array + DOCKER_*_TIMEOUT constants
#   - The NAS prereq check (verifies `timeout` exists on NAS)
#   - The inspect_container_state helper function
#   - The "Step 1" through "Step 4" docker-replace logic (ends at the
#     gatus image sha256 reference — last line of the docker run)
awk '
  /^SSH_OPTS=\(/                        { in_const=1 }
  /^DOCKER_VERIFY_TIMEOUT=/             { in_const=1; print; in_const=0; next }
  in_const                              { print; next }

  /^# NAS prereq check/                 { in_prereq=1 }
  in_prereq                             { print }
  in_prereq && /^fi$/                   { in_prereq=0; print ""; next }

  # LAST_INSPECT_STDERR_FILE + last_inspect_stderr helpers (#614).
  # Captured as its own block so the awk `^}$` terminator does not
  # stop after the helper function and skip inspect_container_state.
  #
  # Extraction contract for future maintainers: this block matches
  # from the comment `# LAST_INSPECT_STDERR_FILE side channel:` to
  # the FIRST `^}$` after it. That covers exactly the variable
  # declaration + last_inspect_stderr() body. If you add a SECOND
  # helper function inside the same block, extend this stanza with
  # an in_helper_* variable — otherwise the second function is
  # silently omitted from the harness and its callers fail with
  # `<name>: command not found` at test-run time.
  /^# LAST_INSPECT_STDERR_FILE side channel:/ { in_helper_a=1 }
  in_helper_a                           { print }
  in_helper_a && /^}$/                  { in_helper_a=0; print ""; next }

  /^# inspect_container_state:/         { in_helper=1 }
  in_helper                             { print }
  in_helper && /^}$/                    { in_helper=0; print ""; next }

  /^# Step 1: detect/                   { in_block=1 }
  in_block                              { print }
  in_block && /twinproduction\/gatus@sha256/ { exit }
' "${SCRIPT_PATH}" >> "${HARNESS}"

chmod +x "${HARNESS}"

run_harness() {
  PATH="${SHIM_DIR}:${PATH}" \
    SHIM_LOG="${TMP_DIR}/shim.log" \
    bash "${HARNESS}" 2>&1
}

write_ssh_shim() {
  cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
# ssh shim: parses the remote command and behaves per env vars.
#   SHIM_PREREQ_BEHAVIOR     = "ok" (default) | "missing" | "ssh-fail"
#   SHIM_INSPECT_RESULT      = "true" | "false" | "missing" | "ssh-fail"
#                            | "probe-timeout" | "unexpected"
#                            | "probe-error-1-daemon-down"
#                            | "probe-error-1-perm-denied"
#                            | "probe-error-125" | "probe-error-126"
#                            | "probe-error-127"
#                            | "missing-no-such-object"
#                            | "missing-no-such-container"
#   SHIM_INSPECT_AFTER_STOP  = if set, what inspect returns after stop runs
#                              (same value set as SHIM_INSPECT_RESULT)
#   SHIM_STOP_BEHAVIOR       = "ok" | "fail" | "hang" (124)
#   SHIM_KILL_BEHAVIOR       = "ok" | "fail"
#   SHIM_RM_BEHAVIOR         = "ok" | "fail"
#   SHIM_RUN_BEHAVIOR        = "ok" | "fail"
# Logs every invocation to SHIM_LOG.

# Skip ssh options to find the remote command (it's the last arg).
remote=""
for arg in "$@"; do
  remote="$arg"
done

echo "$(date +%H:%M:%S) ssh: ${remote}" >> "${SHIM_LOG:-/dev/null}"

emit_state() {
  case "$1" in
    true|false)        echo "$1"; exit 0 ;;
    # "missing" defaults to docker's modern "No such object" phrasing
    # so the #614 stderr-matching classifier maps it to missing rather
    # than probe-error:1. The two explicit "missing-*" variants exercise
    # each phrase individually.
    missing|missing-no-such-object)
                       echo "Error: No such object: gatus-sentinel" >&2
                       exit 1 ;;
    missing-no-such-container)
                       echo "Error response from daemon: No such container: gatus-sentinel" >&2
                       exit 1 ;;
    "ssh-fail")        exit 255 ;;
    "probe-timeout")   exit 124 ;;
    # Issue #614: rc=1 sub-cases distinct from "No such container".
    # These must route to probe-error:1 rather than being silently
    # collapsed into "missing" and racing docker rm/run against
    # unknown daemon state.
    "probe-error-1-daemon-down")
                       echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
                       exit 1 ;;
    "probe-error-1-perm-denied")
                       echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2
                       exit 1 ;;
    "probe-error-1-template-error")
                       # docker CLI template-error rc=1 (invalid --format string,
                       # future template-syntax regression). fork1 P2-3.
                       # Inside a double-quoted string a literal apostrophe
                       # needs no escape; keep it that way to stay parseable
                       # in a `<<'EOF'` heredoc where no expansion happens.
                       echo "template: :1:16: executing at <.State.NoSuch>: cannot evaluate field NoSuch in type *types.ContainerState" >&2
                       exit 1 ;;
    # Unclassified probe-error codes per issue #588. rc=125 (timeout
    # itself errored), rc=126 (command not executable), rc=127
    # (command not found) all indicate the NAS-side probe could not
    # be invoked normally and must fail loud instead of collapsing
    # into "missing".
    "probe-error-125") exit 125 ;;
    "probe-error-126") exit 126 ;;
    "probe-error-127") exit 127 ;;
    unexpected)        echo "Restarting"; exit 0 ;;
    *)                 echo "shim: unknown state '$1'" >&2; exit 99 ;;
  esac
}

case "$remote" in
  "command -v timeout"*)
    case "${SHIM_PREREQ_BEHAVIOR:-ok}" in
      ok)        exit 0 ;;
      missing)   exit 1 ;;
      "ssh-fail")exit 255 ;;
    esac
    ;;
  *"docker inspect"*"State.Running"*)
    if [[ -n "${SHIM_INSPECT_AFTER_STOP:-}" && -f "${TMP_DIR:-/tmp}/.stop-ran" ]]; then
      emit_state "${SHIM_INSPECT_AFTER_STOP}"
    else
      emit_state "${SHIM_INSPECT_RESULT:-missing}"
    fi
    ;;
  *"docker stop"*)
    touch "${TMP_DIR:-/tmp}/.stop-ran"
    case "${SHIM_STOP_BEHAVIOR:-ok}" in
      ok)   exit 0 ;;
      fail) exit 1 ;;
      hang) exit 124 ;;  # what `timeout` returns on overrun
    esac
    ;;
  *"docker kill"*)
    case "${SHIM_KILL_BEHAVIOR:-ok}" in
      ok)   exit 0 ;;
      fail) exit 124 ;;
    esac
    ;;
  *"docker rm"*)
    case "${SHIM_RM_BEHAVIOR:-ok}" in
      ok)   exit 0 ;;
      fail) echo "rm failed" >&2; exit 1 ;;
    esac
    ;;
  *"docker run"*)
    case "${SHIM_RUN_BEHAVIOR:-ok}" in
      ok)   echo "abc123"; exit 0 ;;
      fail) echo "ERROR: name already in use" >&2; exit 1 ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${SHIM_DIR}/ssh"
}

write_ssh_shim
export TMP_DIR

test_start "10" "T1: container missing — script proceeds to docker run cleanly"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=missing \
  SHIM_RUN_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=0$' <<< "${output}" && \
   ! grep -q 'docker stop' "${TMP_DIR}/shim.log" && \
   grep -q 'docker run' "${TMP_DIR}/shim.log"; then
  test_pass "T1: missing container path skips stop/kill, runs new container"
else
  test_fail "T1: missing container path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "11" "T2: container running, docker stop OK — proceeds normally"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=true \
  SHIM_INSPECT_AFTER_STOP=false \
  SHIM_STOP_BEHAVIOR=ok \
  SHIM_RUN_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=0$' <<< "${output}" && \
   grep -q 'docker stop' "${TMP_DIR}/shim.log" && \
   ! grep -q 'docker kill' "${TMP_DIR}/shim.log" && \
   grep -q 'docker run' "${TMP_DIR}/shim.log"; then
  test_pass "T2: graceful stop path takes stop+rm+run, no kill"
else
  test_fail "T2: graceful stop path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "12" "T3: docker stop hangs — escalates to docker kill, continues"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=true \
  SHIM_INSPECT_AFTER_STOP=false \
  SHIM_STOP_BEHAVIOR=hang \
  SHIM_KILL_BEHAVIOR=ok \
  SHIM_RUN_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=0$' <<< "${output}" && \
   grep -q 'docker stop' "${TMP_DIR}/shim.log" && \
   grep -q 'docker kill' "${TMP_DIR}/shim.log" && \
   grep -q 'docker run' "${TMP_DIR}/shim.log" && \
   grep -qF 'escalating to SIGKILL' <<< "${output}"; then
  test_pass "T3: hang escalation path stop+kill+rm+run with operator log"
else
  test_fail "T3: hang escalation path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "13" "T4: docker stop AND docker kill both fail — script exits non-zero with operator instruction"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=true \
  SHIM_STOP_BEHAVIOR=hang \
  SHIM_KILL_BEHAVIOR=fail \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'synopkg restart ContainerManager' <<< "${output}" && \
   grep -qF 'docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md' <<< "${output}" && \
   ! grep -q 'docker run' "${TMP_DIR}/shim.log"; then
  test_pass "T4: unrecoverable path exits 1, points at synopkg + report, never reaches docker run"
else
  test_fail "T4: unrecoverable path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "14" "T5: container existed and stop succeeded but post-verify still says Running — refuses docker run"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=true \
  SHIM_INSPECT_AFTER_STOP=true \
  SHIM_STOP_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'still reports Running' <<< "${output}" && \
   ! grep -q 'docker run' "${TMP_DIR}/shim.log"; then
  test_pass "T5: stuck-running container blocks docker run, fails loud"
else
  test_fail "T5: stuck-running container path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

# ---------------------------------------------------------------------------
# Goal 10 cases — added per MR !200 adversarial review (claude/codex/gemini
# consensus). The script must distinguish SSH-transport failure from
# docker-side failure, fail loud on unexpected inspect output, and refuse
# to operate when its NAS-side `timeout` dependency is missing.
# ---------------------------------------------------------------------------

test_start "15" "T15: NAS missing 'timeout' — script exits 1 with prereq error"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_PREREQ_BEHAVIOR=missing \
  SHIM_INSPECT_RESULT=missing \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF "does not have 'timeout' available" <<< "${output}" && \
   ! grep -q 'docker' "${TMP_DIR}/shim.log"; then
  test_pass "T15: missing 'timeout' on NAS exits 1 before any docker call"
else
  test_fail "T15: missing-timeout prereq path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "16" "T16: SSH transport fails on initial inspect — script exits 1, no docker mutation"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=ssh-fail \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'SSH to NAS' <<< "${output}" && \
   grep -qF 'failed during initial container inspect' <<< "${output}" && \
   ! grep -qE 'docker (stop|kill|rm|run)' "${TMP_DIR}/shim.log"; then
  test_pass "T16: initial-inspect SSH fail exits 1 with no docker mutation"
else
  test_fail "T16: SSH-fail-on-initial-inspect path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "17" "T17: SSH transport fails during verification poll — exits 1, no docker rm"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=true \
  SHIM_INSPECT_AFTER_STOP=ssh-fail \
  SHIM_STOP_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'failed during post-stop verification poll' <<< "${output}" && \
   ! grep -q 'docker rm' "${TMP_DIR}/shim.log" && \
   ! grep -q 'docker run' "${TMP_DIR}/shim.log"; then
  test_pass "T17: poll-time SSH fail exits 1 before docker rm/run"
else
  test_fail "T17: SSH-fail-during-poll path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "18" "T18: docker inspect returns unexpected value — exits 1, no docker mutation"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=unexpected \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'returned an unexpected value' <<< "${output}" && \
   ! grep -qE 'docker (stop|kill|rm|run)' "${TMP_DIR}/shim.log"; then
  test_pass "T18: unexpected inspect output exits 1 with no docker mutation"
else
  test_fail "T18: unexpected-inspect-output path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

# ---------------------------------------------------------------------------
# Issue #559 — probe-timeout must be distinguished from "missing".
#
# Before this fix, inspect_container_state() collapsed every non-255
# non-zero SSH exit code (including rc=124 from the NAS-side `timeout`
# firing) into the "missing" sentinel. The post-stop verification poll
# then treated "missing" as terminal-good and proceeded to docker rm/run
# against unknown daemon state — the same DRT-001 wedge class Sprint 029
# was supposed to close, just narrower (silent race instead of a loud
# 30-minute hang).
# ---------------------------------------------------------------------------

test_start "19" "T19: docker inspect probe times out (rc=124) during post-stop verification poll — exits 1, no docker rm/run (issue #559)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=true \
  SHIM_INSPECT_AFTER_STOP=probe-timeout \
  SHIM_STOP_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'timed out (rc=124)' <<< "${output}" && \
   grep -qF 'post-stop verification poll' <<< "${output}" && \
   ! grep -q 'docker rm' "${TMP_DIR}/shim.log" && \
   ! grep -q 'docker run' "${TMP_DIR}/shim.log"; then
  test_pass "T19: rc=124 during post-stop poll fails loud before docker rm/run"
else
  test_fail "T19: probe-timeout during post-stop poll mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "20" "T20: docker inspect probe times out (rc=124) during initial inspect — exits 1, no docker mutation (issue #559)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=probe-timeout \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'timed out (rc=124)' <<< "${output}" && \
   grep -qF 'initial container detection' <<< "${output}" && \
   ! grep -qE 'docker (stop|kill|rm|run)' "${TMP_DIR}/shim.log"; then
  test_pass "T20: rc=124 during initial inspect fails loud before any docker mutation"
else
  test_fail "T20: probe-timeout during initial inspect mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

# ---------------------------------------------------------------------------
# Issue #588 — probe-error must be distinguished from "missing" for any
# non-{0,1,124,255} exit code.
#
# The #559 fix distinguished rc=124 (probe-timeout) from "missing", but
# the catch-all `*)` branch still collapsed every other non-{0,124,255}
# code into "missing". That includes:
#   rc=125  `timeout` itself errored
#   rc=126  command found but not executable
#   rc=127  command not found (${NAS_DOCKER} stale after package upgrade)
#   rc=137/143  alternate `timeout` impls signalling overrun as SIGKILL/SIGTERM
# Any of these silently falling through to "missing" would race
# docker rm/run against unknown daemon state — the same DRT-001 wedge
# class #559 closed for rc=124, just narrower.
# ---------------------------------------------------------------------------

test_start "21" "T21: docker inspect returns rc=127 during initial detection (probe-error) — exits 1 with rc captured, no docker mutation (issue #588)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=probe-error-127 \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'unclassified non-zero exit code (rc=127)' <<< "${output}" && \
   grep -qF 'initial container detection' <<< "${output}" && \
   ! grep -qE 'docker (stop|kill|rm|run|create|start|network|volume|exec|update|restart)' "${TMP_DIR}/shim.log"; then
  test_pass "T21: rc=127 during initial inspect fails loud with rc captured before any docker mutation"
else
  test_fail "T21: probe-error rc=127 during initial inspect mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "22" "T22: docker inspect returns rc=125 during post-stop verification poll (probe-error) — exits 1 with rc captured, no docker rm/run (issue #588)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=true \
  SHIM_INSPECT_AFTER_STOP=probe-error-125 \
  SHIM_STOP_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'unclassified non-zero exit code (rc=125)' <<< "${output}" && \
   grep -qF 'post-stop verification poll' <<< "${output}" && \
   ! grep -qE 'docker (rm|run|create|start|network|volume|exec|update|restart)' "${TMP_DIR}/shim.log"; then
  test_pass "T22: rc=125 during post-stop poll fails loud with rc captured before docker rm/run"
else
  test_fail "T22: probe-error rc=125 during post-stop poll mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

# ---------------------------------------------------------------------------
# Issue #614 — rc=1 sub-case classification via captured docker stderr.
#
# Before this fix, inspect_container_state() collapsed every rc=1 into
# "missing", matching docker's documented "no such container" case. But
# docker CLI also emits rc=1 for daemon connection failures, template
# errors, and socket permission errors — the discarded remote stderr
# was the only signal distinguishing them from a genuinely-missing
# container. A broken daemon returning rc=1 (rather than rc=124/125/126/127)
# would silently race docker rm/run against unknown daemon state — the
# same DRT-001 wedge class in a narrower form.
#
# The fix captures the remote stderr, text-matches "No such object" /
# "No such container" to identify the missing case, and routes every
# other rc=1 to "probe-error:1" (composing with the existing #588
# probe-error:<rc> sentinel family).
# ---------------------------------------------------------------------------

test_start "23" "T23: rc=1 with 'No such object' stderr — missing (docker >=1.13 phrasing) (issue #614)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=missing-no-such-object \
  SHIM_RUN_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=0$' <<< "${output}" && \
   ! grep -q 'docker stop' "${TMP_DIR}/shim.log" && \
   ! grep -q 'docker kill' "${TMP_DIR}/shim.log" && \
   ! grep -q 'docker rm' "${TMP_DIR}/shim.log" && \
   grep -q 'docker run' "${TMP_DIR}/shim.log" && \
   ! grep -qF 'probe-error' <<< "${output}"; then
  test_pass "T23: 'No such object' rc=1 stderr maps to missing; only docker run runs, no stop/kill/rm"
else
  test_fail "T23: 'No such object' rc=1 stderr path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "24" "T24: rc=1 with 'No such container' stderr — missing (older docker phrasing) (issue #614)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=missing-no-such-container \
  SHIM_RUN_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=0$' <<< "${output}" && \
   ! grep -q 'docker stop' "${TMP_DIR}/shim.log" && \
   ! grep -q 'docker kill' "${TMP_DIR}/shim.log" && \
   ! grep -q 'docker rm' "${TMP_DIR}/shim.log" && \
   grep -q 'docker run' "${TMP_DIR}/shim.log" && \
   ! grep -qF 'probe-error' <<< "${output}"; then
  test_pass "T24: 'No such container' rc=1 stderr maps to missing; only docker run runs, no stop/kill/rm"
else
  test_fail "T24: 'No such container' rc=1 stderr path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "25" "T25: rc=1 with daemon-down stderr during initial detection — probe-error:1, no docker mutation, stderr surfaced (issue #614)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=probe-error-1-daemon-down \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'unclassified non-zero exit code (rc=1)' <<< "${output}" && \
   grep -qF 'initial container detection' <<< "${output}" && \
   grep -qF 'unix:///var/run/docker.sock' <<< "${output}" && \
   grep -qF 'BEGIN REMOTE STDERR' <<< "${output}" && \
   ! grep -qE 'docker (stop|kill|rm|run|create|start|network|volume|exec|update|restart)' "${TMP_DIR}/shim.log"; then
  # Note: match 'unix:///var/run/docker.sock' (shim-unique) rather than
  # 'Cannot connect to the Docker daemon' — the latter phrase appears
  # verbatim inside the error template's "Common causes" list (#614
  # docs section), so a match there would false-pass even if
  # LAST_INSPECT_STDERR_FILE capture failed. The socket path is only
  # in the shim's stderr, so this assertion is truly gated on capture.
  test_pass "T25: daemon-down rc=1 fails loud with rc + captured stderr (shim-unique phrase), no docker mutation"
else
  test_fail "T25: daemon-down rc=1 path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "26" "T26: rc=1 with permission-denied stderr during post-stop poll — probe-error:1, no docker rm/run, stderr surfaced (issue #614)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=true \
  SHIM_INSPECT_AFTER_STOP=probe-error-1-perm-denied \
  SHIM_STOP_BEHAVIOR=ok \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'unclassified non-zero exit code (rc=1)' <<< "${output}" && \
   grep -qF 'post-stop verification poll' <<< "${output}" && \
   grep -qF 'permission denied' <<< "${output}" && \
   grep -qF 'BEGIN REMOTE STDERR' <<< "${output}" && \
   ! grep -qE 'docker (rm|run|create|start|network|volume|exec|update|restart)' "${TMP_DIR}/shim.log"; then
  test_pass "T26: perm-denied rc=1 during post-stop poll fails loud with rc + stderr, no docker rm/run"
else
  test_fail "T26: perm-denied rc=1 during post-stop poll mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "27" "T27: rc=1 with empty stderr — probe-error:1 (defensive: absence of match is not a match) (issue #614)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
# This shim path deliberately writes no stderr and exits 1. Under the
# pre-#614 classifier this would collapse into "missing" (silent
# false-good). Under the #614 classifier it must route to probe-error:1
# because the "No such object"/"No such container" phrase is absent.
cat > "${SHIM_DIR}/ssh-empty-stderr-r1" <<'EMPTYSHIMEOF'
#!/usr/bin/env bash
remote=""
for arg in "$@"; do remote="$arg"; done
echo "$(date +%H:%M:%S) ssh: ${remote}" >> "${SHIM_LOG:-/dev/null}"
case "$remote" in
  "command -v timeout"*)               exit 0 ;;
  *"docker inspect"*"State.Running"*)  exit 1 ;;   # empty stderr, rc=1
  *)                                   exit 0 ;;
esac
EMPTYSHIMEOF
chmod +x "${SHIM_DIR}/ssh-empty-stderr-r1"
# Swap the shim ssh for this call.
mv "${SHIM_DIR}/ssh" "${SHIM_DIR}/ssh.bak"
mv "${SHIM_DIR}/ssh-empty-stderr-r1" "${SHIM_DIR}/ssh"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
# Restore the standard shim so any tests added after this one still work.
mv "${SHIM_DIR}/ssh" "${SHIM_DIR}/ssh-empty-stderr-r1"
mv "${SHIM_DIR}/ssh.bak" "${SHIM_DIR}/ssh"
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'unclassified non-zero exit code (rc=1)' <<< "${output}" && \
   ! grep -qE 'docker (stop|kill|rm|run|create|start|network|volume|exec|update|restart)' "${TMP_DIR}/shim.log"; then
  test_pass "T27: empty-stderr rc=1 routes to probe-error:1 (not silent 'missing' collapse)"
else
  test_fail "T27: empty-stderr rc=1 path mishandled — likely regression of pre-#614 collapse"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

test_start "28" "T28: rc=1 with docker template-error stderr — probe-error:1, no docker mutation (fork1 P2-3, issue #614)"
rm -f "${TMP_DIR}/.stop-ran"
> "${TMP_DIR}/shim.log"
output=$(\
  PATH="${SHIM_DIR}:${PATH}" \
  TMP_DIR="${TMP_DIR}" \
  SHIM_LOG="${TMP_DIR}/shim.log" \
  SHIM_INSPECT_RESULT=probe-error-1-template-error \
  bash "${HARNESS}" 2>&1; echo "EXIT=$?")
if grep -qE 'EXIT=1$' <<< "${output}" && \
   grep -qF 'unclassified non-zero exit code (rc=1)' <<< "${output}" && \
   grep -qF 'template:' <<< "${output}" && \
   grep -qF 'BEGIN REMOTE STDERR' <<< "${output}" && \
   ! grep -qE 'docker (stop|kill|rm|run|create|start|network|volume|exec|update|restart)' "${TMP_DIR}/shim.log"; then
  test_pass "T28: docker template-error rc=1 routes to probe-error:1 with stderr surfaced, no docker mutation"
else
  test_fail "T28: docker template-error rc=1 path mishandled"
  printf '    output:\n%s\n' "${output}" >&2
  printf '    shim.log:\n'; cat "${TMP_DIR}/shim.log" >&2
fi

# CRITICAL: this call is what gates the test's exit code on _FAIL_COUNT.
# Without it, every test_fail above is decorative and the GitLab job
# reports green regardless of failures (P1 finding from MR !200 review).
runner_summary
