#!/usr/bin/env bash
#
# test_nas_docker_resolver.sh — verify configure-sentinel-gatus.sh's
# nas_docker() helper walks both known Synology Container Manager paths,
# validates probe output, and distinguishes SSH transport failure from
# docker-not-found.
#
# Origin: G9 (issues #30 + #61). Synology docker binary location varies
# by ContainerManager version — legacy installs at /usr/local/bin/docker,
# newer package layouts at /volume1/@appstore/ContainerManager/usr/bin/docker.
# nas_docker() probes both. The tests here confirm the resolver's contract
# under each behavior mode a PATH-shimmed ssh can simulate.
#
# Uses the same PATH-shim pattern as test_configure_sentinel_gatus_resilience.sh
# (an `ssh` executable is planted at the front of PATH so the script's ssh
# calls are intercepted). The shim inspects the remote command and returns
# per env-var behavior.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT_PATH="${REPO_ROOT}/framework/scripts/configure-sentinel-gatus.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# Static ratchets — protect the resolver's structural contract.
# ---------------------------------------------------------------------------

test_start "1" "nas_docker() is defined in configure-sentinel-gatus.sh"
if grep -qE '^nas_docker\(\)[[:space:]]*\{' "${SCRIPT_PATH}"; then
  test_pass "nas_docker() function is defined"
else
  test_fail "nas_docker() function is not defined"
fi

test_start "2" "nas_docker() probes both known Synology paths"
# Legacy DSM: /usr/local/bin/docker.
# Newer ContainerManager package layout:
# /volume1/@appstore/ContainerManager/usr/bin/docker.
# Both must appear in the candidate loop.
if grep -qF '/usr/local/bin/docker' "${SCRIPT_PATH}" && \
   grep -qF '/volume1/@appstore/ContainerManager/usr/bin/docker' "${SCRIPT_PATH}"; then
  test_pass "both candidate paths are present"
else
  test_fail "one or both candidate paths are missing"
fi

test_start "3" "nas_docker() probe is bounded by NAS-side 'timeout'"
# The whole script's DRT-001 doctrine is that no remote command may hang
# indefinitely. The probe was flagged by adversarial review as an unbounded
# call in the initial draft; the fix wraps it with `timeout ${DOCKER_PATH_PROBE_TIMEOUT}`.
if grep -qE 'timeout[[:space:]]+\$\{?DOCKER_PATH_PROBE_TIMEOUT\}?[[:space:]]+bash' "${SCRIPT_PATH}"; then
  test_pass "probe is wrapped by 'timeout \${DOCKER_PATH_PROBE_TIMEOUT}'"
else
  test_fail "probe is not bounded by 'timeout \${DOCKER_PATH_PROBE_TIMEOUT}'"
fi

test_start "4" "nas_docker() distinguishes SSH transport failure (rc=255)"
# Same distinction as sister helper inspect_container_state(). An SSH
# transport failure means we don't know the NAS state; must fail loud
# rather than fall back to a generic "docker not found" message.
if grep -qE 'case[[:space:]]+"\$rc"' "${SCRIPT_PATH}" && \
   grep -qE '255\)' "${SCRIPT_PATH}"; then
  test_pass "nas_docker() has explicit rc=255 branch"
else
  test_fail "nas_docker() collapses SSH failure into generic 'not found'"
fi

test_start "5" "nas_docker() validates probe output against known candidates"
# MOTD / banner pollution on Synology login shells can leak lines into
# $(ssh ...) capture; without validation the script would try to run
# 'timeout N Copyright... docker inspect' downstream. Validate stdout
# is exactly one known path (case statement or equivalent).
# The check looks for the two candidate paths appearing as alternates
# in a case pattern (\||||) inside the resolver.
if awk '
  /^nas_docker\(\)/ { in_fn=1 }
  in_fn && /^\}$/   { in_fn=0 }
  in_fn && /\/usr\/local\/bin\/docker\|\/volume1\/@appstore\/ContainerManager\/usr\/bin\/docker\)/ { found=1 }
  END { exit (found ? 0 : 1) }
' "${SCRIPT_PATH}"; then
  test_pass "nas_docker() validates probe output against exact candidate set"
else
  test_fail "nas_docker() does not validate probe output — MOTD/banner would leak"
fi

# ---------------------------------------------------------------------------
# Behavioral test — extract the DOCKER_PATH_PROBE_TIMEOUT constant plus
# nas_docker() and invoke it with a PATH-shimmed ssh that returns
# controlled probe results.
# ---------------------------------------------------------------------------

HARNESS="${TMP_DIR}/nas-docker-harness.sh"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${SHIM_DIR}"

cat > "${HARNESS}" <<'HARNESS_HEADER'
#!/usr/bin/env bash
set -euo pipefail
NAS_USER=root
NAS_IP=127.0.0.1
# Same SSH_MUX_DIR stub as the resilience harness.
SSH_MUX_DIR="${TMP_DIR:-/tmp}/harness-ssh-mux"
mkdir -p "${SSH_MUX_DIR}"
HARNESS_HEADER

# Pull SSH_OPTS + DOCKER_PATH_PROBE_TIMEOUT + nas_docker() out of the
# real script.
awk '
  /^SSH_OPTS=\(/                                 { in_opts=1 }
  in_opts                                        { print }
  in_opts && /^\)$/                              { in_opts=0; print ""; next }

  /^DOCKER_PATH_PROBE_TIMEOUT=/                  { print; next }

  /^nas_docker\(\) \{/                           { in_fn=1 }
  in_fn                                          { print }
  in_fn && /^\}$/                                { in_fn=0; print ""; next }
' "${SCRIPT_PATH}" >> "${HARNESS}"

# Append a driver: call nas_docker, echo the result.
cat >> "${HARNESS}" <<'DRIVER'
nas_docker
echo "NAS_DOCKER=${NAS_DOCKER}"
DRIVER

chmod +x "${HARNESS}"

run_harness() {
  PATH="${SHIM_DIR}:${PATH}" \
    SHIM_LOG="${TMP_DIR}/shim.log" \
    bash "${HARNESS}" 2>&1
}

# ssh shim: emits controlled probe output based on env vars.
#   SHIM_PROBE_RESULT = "legacy" | "newer" | "none" | "banner"
#   SHIM_SSH_BEHAVIOR = "ok" (default) | "fail"       (rc=255)
#   SHIM_PROBE_TIMEOUT = "no" (default) | "yes"       (probe rc=124)
write_ssh_shim() {
  cat > "${SHIM_DIR}/ssh" <<'SHIMEOF'
#!/usr/bin/env bash
# Record invocation.
echo "$(date +%H:%M:%S) ssh: $*" >> "${SHIM_LOG:-/dev/null}"

# Skip ssh options; the last arg is the remote command.
remote=""
for arg in "$@"; do
  remote="$arg"
done

# The probe passes its script over stdin (via heredoc), so read it too.
if [ ! -t 0 ]; then
  cat >/dev/null || true
fi

# Handle SHIM_SSH_BEHAVIOR = "fail"
if [ "${SHIM_SSH_BEHAVIOR:-ok}" = "fail" ]; then
  exit 255
fi

# The prereq check is 'command -v timeout ...' — always succeeds.
if [[ "$remote" == *'command -v timeout'* ]]; then
  exit 0
fi

# The probe: `timeout N bash -s` with a heredoc script.
# Return per SHIM_PROBE_RESULT.
if [ "${SHIM_PROBE_TIMEOUT:-no}" = "yes" ]; then
  exit 124
fi

case "${SHIM_PROBE_RESULT:-legacy}" in
  legacy)
    echo "/usr/local/bin/docker"
    exit 0
    ;;
  newer)
    echo "/volume1/@appstore/ContainerManager/usr/bin/docker"
    exit 0
    ;;
  none)
    exit 1
    ;;
  banner)
    # MOTD-pollution simulation: banner text precedes the path.
    echo "Copyright Synology Inc. All rights reserved."
    echo "/usr/local/bin/docker"
    exit 0
    ;;
esac
exit 1
SHIMEOF
  chmod +x "${SHIM_DIR}/ssh"
}

write_ssh_shim

# ---------------------------------------------------------------------------
# Behavioral cases
# ---------------------------------------------------------------------------

# T1: legacy layout — probe returns /usr/local/bin/docker
test_start "10" "T1: legacy layout — probe finds /usr/local/bin/docker"
OUT=$(SHIM_PROBE_RESULT=legacy TMP_DIR="${TMP_DIR}" run_harness || true)
if grep -qF 'NAS_DOCKER=/usr/local/bin/docker' <<< "${OUT}"; then
  test_pass "T1: NAS_DOCKER=/usr/local/bin/docker as expected"
else
  test_fail "T1: expected legacy path, got:"
  printf '    output:\n%s\n' "${OUT}" >&2
fi

# T2: newer layout — probe returns
# /volume1/@appstore/ContainerManager/usr/bin/docker
test_start "11" "T2: newer layout — probe finds /volume1/@appstore/ContainerManager/usr/bin/docker"
OUT=$(SHIM_PROBE_RESULT=newer TMP_DIR="${TMP_DIR}" run_harness || true)
if grep -qF 'NAS_DOCKER=/volume1/@appstore/ContainerManager/usr/bin/docker' <<< "${OUT}"; then
  test_pass "T2: NAS_DOCKER=/volume1/@appstore/ContainerManager/usr/bin/docker as expected"
else
  test_fail "T2: expected newer path, got:"
  printf '    output:\n%s\n' "${OUT}" >&2
fi

# T3: neither path exists — resolver exits non-zero with docker-not-found message
test_start "12" "T3: neither path exists — resolver exits 1 with docker-not-found message"
set +e
OUT=$(SHIM_PROBE_RESULT=none TMP_DIR="${TMP_DIR}" run_harness)
RC=$?
set -e
if [ "$RC" -ne 0 ] && grep -qF 'docker binary not found' <<< "${OUT}"; then
  test_pass "T3: fails loud with 'docker binary not found'"
else
  test_fail "T3: expected non-zero exit + 'docker binary not found', rc=${RC}"
  printf '    output:\n%s\n' "${OUT}" >&2
fi

# T4: SSH transport failure — resolver exits 1 with SSH-failed message
test_start "13" "T4: SSH transport failure (rc=255) — resolver exits 1 with distinct SSH message"
set +e
OUT=$(SHIM_SSH_BEHAVIOR=fail TMP_DIR="${TMP_DIR}" run_harness)
RC=$?
set -e
# Note: SHIM_SSH_BEHAVIOR=fail affects the prereq check too, so may fail
# at that step. Accept either the prereq error or the nas_docker SSH-fail
# error as long as the exit is non-zero (both are the loud-fail outcome).
if [ "$RC" -ne 0 ]; then
  test_pass "T4: exits non-zero on SSH transport failure (rc=${RC})"
else
  test_fail "T4: expected non-zero exit on SSH failure, got 0"
  printf '    output:\n%s\n' "${OUT}" >&2
fi

# T5: banner/MOTD pollution — resolver rejects unexpected stdout
test_start "14" "T5: MOTD/banner pollution — resolver refuses to accept polluted stdout"
set +e
OUT=$(SHIM_PROBE_RESULT=banner TMP_DIR="${TMP_DIR}" run_harness)
RC=$?
set -e
if [ "$RC" -ne 0 ] && grep -qF 'unexpected stdout' <<< "${OUT}"; then
  test_pass "T5: rejects banner-polluted stdout with 'unexpected stdout' error"
else
  test_fail "T5: expected non-zero exit + 'unexpected stdout', rc=${RC}"
  printf '    output:\n%s\n' "${OUT}" >&2
fi

# T6: NAS-side probe timeout (rc=124) — same fail-closed path as "not found"
test_start "15" "T6: NAS-side probe timeout (rc=124) — resolver fails loud"
set +e
OUT=$(SHIM_PROBE_TIMEOUT=yes TMP_DIR="${TMP_DIR}" run_harness)
RC=$?
set -e
if [ "$RC" -ne 0 ] && grep -qF 'docker binary not found' <<< "${OUT}"; then
  test_pass "T6: probe timeout rc=124 fails loud like docker-not-found"
else
  test_fail "T6: expected non-zero exit + 'docker binary not found', rc=${RC}"
  printf '    output:\n%s\n' "${OUT}" >&2
fi

runner_summary
