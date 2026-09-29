#!/usr/bin/env bash
# test_tofu_wrapper_parallelism.sh — issue #1011 Phase-1 storage-lock margin.
#
# Drive the real tofu-wrapper.sh in a hermetic fixture and record the final tofu
# argv. apply/destroy default to one worker so our own PVE storage allocations
# cannot consume the fixed 10 s storage-lock acquisition budget; read-only and
# unrelated commands remain unbounded, and an explicit tofu flag is the escape
# hatch. This tests behavior, not a source-scan ratchet: calls can be indirect or
# can legitimately use that escape hatch.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
TOFU_ARGV="${TMP_DIR}/tofu.argv"
IMAGE_VERSIONS_FILE="${FIXTURE_REPO}/site/tofu/image-versions.auto.tfvars"

mkdir -p \
  "${FIXTURE_REPO}/framework/scripts" \
  "${FIXTURE_REPO}/framework/tofu/root" \
  "${FIXTURE_REPO}/site/sops" \
  "${FIXTURE_REPO}/site/tofu" \
  "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh" "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

printf 'fixture flake\n' > "${FIXTURE_REPO}/flake.nix"
printf 'dummy-age-key\n' > "${FIXTURE_REPO}/operator.age.key"
printf 'encrypted-placeholder\n' > "${FIXTURE_REPO}/site/sops/secrets.yaml"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nas:
  ip: 10.0.0.10
  postgres_port: 5432
nodes:
  - mgmt_ip: 10.0.0.11
vms: {}
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
# The fixture uses an already-built image manifest, so no modules are needed.
EOF

cat > "${IMAGE_VERSIONS_FILE}" <<'EOF'
image_versions = {
  "dns" = "dns-12345678.img"
}
EOF

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"proxmox_api_user":"user","proxmox_api_password":"pass","tofu_db_password":"dbpass","ssh_pubkey":"ssh-ed25519 AAAA test","pdns_api_key":"pdns"}
JSON
EOF
chmod +x "${SHIM_DIR}/sops"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${STUB_TOFU_ARGV}"
case "${1:-}" in
  state)
    case "${2:-}" in
      list|show|rm) exit 0 ;;
    esac
    ;;
  plan|apply|destroy|init|refresh) exit 0 ;;
esac
echo "unexpected tofu invocation: $*" >&2
exit 98
EOF
chmod +x "${SHIM_DIR}/tofu"

export PATH="${SHIM_DIR}:${PATH}"
export STUB_TOFU_ARGV="${TOFU_ARGV}"

OUTPUT=""
STATUS=0
TOFU_VECTOR=""

run_wrapper() {
  : > "${TOFU_ARGV}"
  set +e
  OUTPUT="$(cd "${FIXTURE_REPO}" && framework/scripts/tofu-wrapper.sh "$@" 2>&1)"
  STATUS=$?
  set -e
  TOFU_VECTOR="$(<"${TOFU_ARGV}")"
}

parallelism_occurrences() {
  grep -Ec -- '^--?parallelism(=|$)' "${TOFU_ARGV}" || true
}

# 1. apply gets the safe default immediately after the other injected arg.
test_start "1" "apply defaults to -parallelism=1"
run_wrapper apply
if [[ "$STATUS" -eq 0 ]] &&
   [[ "$TOFU_VECTOR" == $'apply\n'"-var-file=${IMAGE_VERSIONS_FILE}"$'\n-parallelism=1' ]]; then
  test_pass "apply receives exactly one worker after the image var-file"
else
  test_fail "apply argv mismatch (status=${STATUS}, vector=[${TOFU_VECTOR}], output=[${OUTPUT}])"
fi

# 2. destroy gets the same storage-lock bound.
test_start "2" "destroy defaults to -parallelism=1"
run_wrapper destroy
if [[ "$STATUS" -eq 0 ]] &&
   [[ "$TOFU_VECTOR" == $'destroy\n'"-var-file=${IMAGE_VERSIONS_FILE}"$'\n-parallelism=1' ]]; then
  test_pass "destroy receives exactly one worker after the image var-file"
else
  test_fail "destroy argv mismatch (status=${STATUS}, vector=[${TOFU_VECTOR}], output=[${OUTPUT}])"
fi

# 3. plan remains unbounded; this would fail if injection were unconditional.
test_start "3" "plan receives no parallelism flag"
run_wrapper plan
if [[ "$STATUS" -eq 0 ]] && [[ "${TOFU_VECTOR%%$'\n'*}" == "plan" ]] &&
   ! grep -Fq -- '-parallelism' "${TOFU_ARGV}"; then
  test_pass "plan still executes without a parallelism flag"
else
  test_fail "plan was absent or bounded (status=${STATUS}, vector=[${TOFU_VECTOR}])"
fi

# 4. Single-dash explicit value is the escape hatch.
test_start "4" "apply preserves explicit -parallelism=N"
run_wrapper apply -parallelism=4
if [[ "$STATUS" -eq 0 ]] && grep -Fxq -- '-parallelism=4' "${TOFU_ARGV}" &&
   ! grep -Fxq -- '-parallelism=1' "${TOFU_ARGV}" &&
   [[ "$(parallelism_occurrences)" -eq 1 ]]; then
  test_pass "single-dash override survives exactly once and suppresses the default"
else
  test_fail "single-dash override mishandled (status=${STATUS}, vector=[${TOFU_VECTOR}])"
fi

# 5. Double-dash spelling is also accepted by tofu and suppresses the default.
test_start "5" "apply preserves explicit --parallelism=N"
run_wrapper apply --parallelism=4
if [[ "$STATUS" -eq 0 ]] && grep -Fxq -- '--parallelism=4' "${TOFU_ARGV}" &&
   ! grep -Fxq -- '-parallelism=1' "${TOFU_ARGV}" &&
   [[ "$(parallelism_occurrences)" -eq 1 ]]; then
  test_pass "double-dash override survives exactly once and suppresses the default"
else
  test_fail "double-dash override mishandled (status=${STATUS}, vector=[${TOFU_VECTOR}])"
fi

# 6. Single-dash space form is also explicit; its value remains a separate arg.
test_start "6" "apply preserves explicit -parallelism N"
run_wrapper apply -parallelism 4
if [[ "$STATUS" -eq 0 ]] && grep -Fxq -- '-parallelism' "${TOFU_ARGV}" &&
   ! grep -Fxq -- '-parallelism=1' "${TOFU_ARGV}" &&
   [[ "$(parallelism_occurrences)" -eq 1 ]]; then
  test_pass "single-dash space-form override survives once and suppresses the default"
else
  test_fail "single-dash space-form override mishandled (status=${STATUS}, vector=[${TOFU_VECTOR}])"
fi

# 7. Double-dash space form is also explicit; its value remains a separate arg.
test_start "7" "apply preserves explicit --parallelism N"
run_wrapper apply --parallelism 4
if [[ "$STATUS" -eq 0 ]] && grep -Fxq -- '--parallelism' "${TOFU_ARGV}" &&
   ! grep -Fxq -- '-parallelism=1' "${TOFU_ARGV}" &&
   [[ "$(parallelism_occurrences)" -eq 1 ]]; then
  test_pass "double-dash space-form override survives once and suppresses the default"
else
  test_fail "double-dash space-form override mishandled (status=${STATUS}, vector=[${TOFU_VECTOR}])"
fi

# 8. init remains an ordinary pass-through command.
test_start "8" "init executes without a parallelism flag"
run_wrapper init
if [[ "$STATUS" -eq 0 ]] && [[ "$TOFU_VECTOR" == "init" ]] &&
   ! grep -Fq -- '-parallelism' "${TOFU_ARGV}"; then
  test_pass "init still execs and remains unbounded"
else
  test_fail "init was absent, altered, or bounded (status=${STATUS}, vector=[${TOFU_VECTOR}])"
fi

# 9. Exercise the exact Phase-1 and Phase-2 vectors used by safe-apply.sh.
test_start "9.phase-1" "safe-apply Phase-1 vector is bounded and retains vars"
run_wrapper apply -var=start_vms=false -var=register_ha=false -auto-approve
if [[ "$STATUS" -eq 0 ]] && grep -Fxq -- '-parallelism=1' "${TOFU_ARGV}" &&
   grep -Fxq -- '-var=start_vms=false' "${TOFU_ARGV}" &&
   grep -Fxq -- '-var=register_ha=false' "${TOFU_ARGV}"; then
  test_pass "Phase-1 apply is bounded and both caller vars survive"
else
  test_fail "Phase-1 vector mishandled (status=${STATUS}, vector=[${TOFU_VECTOR}])"
fi

test_start "9.phase-2" "safe-apply Phase-2 vector is bounded and retains vars"
run_wrapper apply -var=start_vms=true -var=register_ha=true -auto-approve
if [[ "$STATUS" -eq 0 ]] && grep -Fxq -- '-parallelism=1' "${TOFU_ARGV}" &&
   grep -Fxq -- '-var=start_vms=true' "${TOFU_ARGV}" &&
   grep -Fxq -- '-var=register_ha=true' "${TOFU_ARGV}"; then
  test_pass "Phase-2 apply is bounded and both caller vars survive"
else
  test_fail "Phase-2 vector mishandled (status=${STATUS}, vector=[${TOFU_VECTOR}])"
fi

runner_summary
