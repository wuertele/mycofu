#!/usr/bin/env bash
# test_vdb_park_validation.sh — Sprint 044 validate/config/static guards.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"
VALIDATE_SITE="${REPO_ROOT}/framework/scripts/validate-site-config.sh"
CONFIG="${REPO_ROOT}/site/config.yaml"
APPS_CONFIG="${REPO_ROOT}/site/applications.yaml"

run_site_validation() {
  local config="$1"
  set +e
  OUT="$(VALIDATE_SITE_CONFIG_CONFIG="$config" VALIDATE_SITE_CONFIG_APPS_CONFIG="$APPS_CONFIG" "$VALIDATE_SITE" 2>&1)"
  RC=$?
  set -e
}

test_start "A9.a" "validate.sh has parked-vdb WARN and scan-fail FAIL contracts"
park_body="$(awk '/^parked_vdb_zvols_check\(\)/{in_fn=1} in_fn{print} in_fn && /^}/{exit}' "$VALIDATE")"
if grep -Fq 'failed to scan parked vdb zvols' <<< "$park_body" &&
   ! grep -Fq 'vdb_park_bridge_enabled_any' <<< "$park_body" &&
   grep -Fq 'return 1' <<< "$park_body" &&
   grep -Fq 'return 3' <<< "$park_body" &&
   grep -Fq 'parked-vdb.sh inspect' <<< "$park_body" &&
   grep -Fq 'parked-vdb.sh release' <<< "$park_body" &&
   grep -Fq 'check_warn "no parked vdb zvols cluster-wide" parked_vdb_zvols_check' "$VALIDATE"; then
  test_pass "parked-vdb validate check has PASS/WARN/FAIL shape"
else
  test_fail "parked-vdb validate contract missing"
  printf '%s\n' "$park_body" >&2
fi

test_start "A9.b" "validate.sh qemu-server ratchet is bridge-gated and WARNs on drift"
version_body="$(awk '/^qemu_server_version_ratchet_check\(\)/{in_fn=1} in_fn{print} in_fn && /^}/{exit}' "$VALIDATE")"
if grep -Fq 'if ! vdb_park_bridge_enabled_any; then' <<< "$version_body" &&
   grep -Fq 'return 0' <<< "$version_body" &&
   grep -Fq 'vdb_park_version_allowed "$version"' <<< "$version_body" &&
   grep -Fq '${VDB_PARK_VERIFIED_QEMU_SERVER}' <<< "$version_body" &&
   grep -Fq 'return 3' <<< "$version_body" &&
   grep -Fq 'node_name' <<< "$version_body" &&
   grep -Fq 'version' <<< "$version_body" &&
   grep -Fq -- '-o LogLevel=ERROR' <<< "$version_body"; then
  test_pass "qemu-server version ratchet is gated and warning-based"
else
  test_fail "qemu-server version ratchet contract missing"
  printf '%s\n' "$version_body" >&2
fi

test_start "A9.c" "ratchet ssh capture rejects known-hosts stderr pollution (#506)"
STUB_DIR="${TMP_DIR}/A9c"
mkdir -p "$STUB_DIR"
cat > "${STUB_DIR}/ssh" <<'STUB'
#!/usr/bin/env bash
# Mimic real ssh(1): the "Warning: Permanently added ..." line is emitted
# to stderr at INFO level. Suppress it when LogLevel is set to ERROR or
# stricter. This is the class of bug from #506 — a capture with 2>&1 that
# does not filter this line will contaminate the collected value.
suppress=0
for arg in "$@"; do
  case "$arg" in
    LogLevel=ERROR|LogLevel=QUIET|LogLevel=FATAL) suppress=1 ;;
  esac
done
if [[ "$suppress" -eq 0 ]]; then
  echo "Warning: Permanently added 'stub-host' (ED25519) to the list of known hosts." >&2
fi
printf '9.0.30'
STUB
chmod +x "${STUB_DIR}/ssh"

# Positive path: with LogLevel=ERROR the shim stays silent on stderr, so the
# 2>&1 capture used by qemu_server_version_ratchet_check yields a clean value.
set +e
version=$(PATH="${STUB_DIR}:$PATH" ssh -n \
  -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  root@stub 'dpkg-query -W' 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 && "$version" == "9.0.30" ]]; then
  test_pass "LogLevel=ERROR capture yields clean version string"
else
  test_fail "capture polluted or failed under LogLevel=ERROR: rc=${rc} version='${version}'"
fi

# Negative path: without LogLevel=ERROR the shim writes the known-hosts warning
# to stderr, 2>&1 captures it, and vdb_park_version_allowed would report drift.
# This asserts the shim faithfully reproduces the #506 pollution — otherwise the
# positive path above would be a no-op that stayed green even if the fix regressed.
set +e
polluted=$(PATH="${STUB_DIR}:$PATH" ssh -n \
  -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@stub 'dpkg-query -W' 2>&1)
set -e
if [[ "$polluted" == *"Warning: Permanently added"* && "$polluted" == *"9.0.30" ]]; then
  test_pass "shim reproduces #506 pollution when LogLevel is not filtered"
else
  test_fail "shim did not reproduce pollution: '${polluted}'"
fi

test_start "A11.a" "current dev-enabled config passes site validation"
run_site_validation "$CONFIG"
if [[ "$RC" -eq 0 ]]; then
  test_pass "current site/config.yaml accepts dev vdb_park_bridge"
else
  test_fail "current config should pass dev-only bridge validation"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "A11.b" "non-dev vdb_park_bridge values are rejected"
for env_name in prod shared management; do
  cfg="${TMP_DIR}/config-${env_name}.yaml"
  cp "$CONFIG" "$cfg"
  ENV_NAME="$env_name" yq -i '.environments[strenv(ENV_NAME)].vdb_park_bridge = true' "$cfg"
  run_site_validation "$cfg"
  if [[ "$RC" -ne 0 ]] &&
     grep -Fq "environments.${env_name}.vdb_park_bridge" <<< "$OUT" &&
     grep -Fq "promotion to non-dev requires the documented promotion process" <<< "$OUT"; then
    test_pass "rejects environments.${env_name}.vdb_park_bridge"
  else
    test_fail "did not reject environments.${env_name}.vdb_park_bridge"
    printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
  fi
done

test_start "A11.c" "absent vdb_park_bridge key remains accepted"
cfg="${TMP_DIR}/config-absent.yaml"
yq 'del(.environments.dev.vdb_park_bridge)' "$CONFIG" > "$cfg"
run_site_validation "$cfg"
if [[ "$RC" -eq 0 ]]; then
  test_pass "absent bridge key is accepted"
else
  test_fail "absent bridge key should pass"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "A12" "vdb bridge scripts contain no guest-delivery machinery markers"
set +e
# grep -E, not rg: the CI runner has no ripgrep (pipeline 1282 failure)
MARKERS="$(grep -n -i -E 'cidata|write_files|cloud-init|/etc/systemd|systemctl|vault[-_a-z0-9]*marker|restore[-_]marker|/run/secrets' \
  "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" \
  "${REPO_ROOT}/framework/scripts/parked-vdb.sh" 2>&1)"
MARKER_RC=$?
set -e
if [[ "$MARKER_RC" -eq 1 && -z "$MARKERS" ]]; then
  test_pass "no guest delivery markers found in vdb bridge scripts"
else
  test_fail "guest delivery marker grep found matches"
  printf '%s\n' "$MARKERS" >&2
fi

runner_summary
