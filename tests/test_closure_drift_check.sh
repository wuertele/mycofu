#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

setup_fixture_repo() {
  local repo_dir="$1"

  mkdir -p "${repo_dir}/framework/scripts" "${repo_dir}/site"

  cp "${REPO_ROOT}/framework/scripts/check-control-plane-drift.sh" \
    "${repo_dir}/framework/scripts/check-control-plane-drift.sh"
  chmod +x "${repo_dir}/framework/scripts/check-control-plane-drift.sh"

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
vms:
  gitlab:
    ip: 10.0.0.10
  cicd:
    ip: 10.0.0.20
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

query="$*"

case "${query}" in
  *'nixosConfigurations.gitlab.config.system.build.toplevel'*)
    printf '%s\n' "${STUB_DESIRED_GITLAB:-/nix/store/gitlab-desired}"
    ;;
  *'nixosConfigurations.cicd.config.system.build.toplevel'*)
    printf '%s\n' "${STUB_DESIRED_CICD:-/nix/store/cicd-desired}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${shim_dir}/nix"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=""
for arg in "$@"; do
  if [[ "${arg}" == root@* ]]; then
    target="${arg#root@}"
  fi
done

case "${target}" in
  10.0.0.10)
    printf '%s\n' "${STUB_LIVE_GITLAB:-/nix/store/gitlab-live}"
    ;;
  10.0.0.20)
    printf '%s\n' "${STUB_LIVE_CICD:-/nix/store/cicd-live}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${shim_dir}/ssh"
}

run_fixture() {
  local scenario="$1"
  shift
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local output_file="${TMP_DIR}/${scenario}.out"

  setup_fixture_repo "${repo_dir}"
  setup_shims "${shim_dir}"

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    cd "${repo_dir}"
    framework/scripts/check-control-plane-drift.sh "$@"
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n' "${status}" "${output_file}"
}

artifact_status() {
  printf '%s\n' "$1" | sed -n '1p'
}

artifact_output_file() {
  printf '%s\n' "$1" | sed -n '2p'
}

test_start "5.2" "validate.sh R7.2 calls the rewritten drift checker"
if grep -q 'check-control-plane-drift\.sh' "${REPO_ROOT}/framework/scripts/validate.sh"; then
  test_pass "validate.sh invokes check-control-plane-drift.sh for R7.2"
else
  test_fail "validate.sh invokes check-control-plane-drift.sh for R7.2"
fi

test_start "5.2a" "validate.sh no longer skips R7.2 when the drift check is incomplete"
if ! grep -q 'check_skip "R7.2' "${REPO_ROOT}/framework/scripts/validate.sh"; then
  test_pass "validate.sh does not soft-fail R7.2 via check_skip"
else
  test_fail "validate.sh does not soft-fail R7.2 via check_skip"
fi

test_start "5.2b" "matching live closures pass the drift check"
MATCH_ARTIFACTS="$(
  STUB_DESIRED_GITLAB="/nix/store/gitlab-good" \
  STUB_LIVE_GITLAB="/nix/store/gitlab-good" \
  STUB_DESIRED_CICD="/nix/store/cicd-good" \
  STUB_LIVE_CICD="/nix/store/cicd-good" \
  run_fixture match
)"
MATCH_STATUS="$(artifact_status "${MATCH_ARTIFACTS}")"
MATCH_OUTPUT_FILE="$(artifact_output_file "${MATCH_ARTIFACTS}")"
if [[ "${MATCH_STATUS}" == "0" ]]; then
  test_pass "matching closure check exits 0"
else
  test_fail "matching closure check exits 0"
  cat "${MATCH_OUTPUT_FILE}" >&2
fi
if grep -q 'Live closures match flake outputs\.' "${MATCH_OUTPUT_FILE}"; then
  test_pass "matching closure check reports success"
else
  test_fail "matching closure check reports success"
  cat "${MATCH_OUTPUT_FILE}" >&2
fi

test_start "5.2c" "mismatched live closures fail with a converge-vm remediation"
MISMATCH_ARTIFACTS="$(
  STUB_DESIRED_GITLAB="/nix/store/gitlab-good" \
  STUB_LIVE_GITLAB="/nix/store/gitlab-good" \
  STUB_DESIRED_CICD="/nix/store/cicd-new" \
  STUB_LIVE_CICD="/nix/store/cicd-old" \
  run_fixture mismatch
)"
MISMATCH_STATUS="$(artifact_status "${MISMATCH_ARTIFACTS}")"
MISMATCH_OUTPUT_FILE="$(artifact_output_file "${MISMATCH_ARTIFACTS}")"
if [[ "${MISMATCH_STATUS}" == "1" ]]; then
  test_pass "mismatched closure check exits 1"
else
  test_fail "mismatched closure check exits 1"
  cat "${MISMATCH_OUTPUT_FILE}" >&2
fi
if grep -q 'DRIFT: cicd (10.0.0.20) running /nix/store/cicd-old, want /nix/store/cicd-new' "${MISMATCH_OUTPUT_FILE}" && \
   grep -q 'framework/scripts/converge-vm.sh --closure /nix/store/cicd-new --targets -target=module.cicd' "${MISMATCH_OUTPUT_FILE}"; then
  test_pass "mismatched closure check prints the converge-vm remediation"
else
  test_fail "mismatched closure check prints the converge-vm remediation"
  cat "${MISMATCH_OUTPUT_FILE}" >&2
fi

test_start "5.2d" "--all-nixos is accepted by the argument parser"
ALL_NIXOS_HELP_ARTIFACTS="$(run_fixture all-nixos-help --all-nixos --help)"
ALL_NIXOS_HELP_STATUS="$(artifact_status "${ALL_NIXOS_HELP_ARTIFACTS}")"
ALL_NIXOS_HELP_OUTPUT_FILE="$(artifact_output_file "${ALL_NIXOS_HELP_ARTIFACTS}")"
if [[ "${ALL_NIXOS_HELP_STATUS}" == "0" ]]; then
  test_pass "--all-nixos parser path exits 0 with --help"
else
  test_fail "--all-nixos parser path exits 0 with --help"
  cat "${ALL_NIXOS_HELP_OUTPUT_FILE}" >&2
fi
if grep -q -- '--all-nixos' "${ALL_NIXOS_HELP_OUTPUT_FILE}"; then
  test_pass "help output documents --all-nixos"
else
  test_fail "help output documents --all-nixos"
  cat "${ALL_NIXOS_HELP_OUTPUT_FILE}" >&2
fi

runner_summary
