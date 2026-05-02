#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

setup_fixture_repo() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/site/nix/hosts" \
    "${repo_dir}/site/tofu"

  cp "${REPO_ROOT}/framework/scripts/build-all-images.sh" \
    "${repo_dir}/framework/scripts/build-all-images.sh"
  chmod +x "${repo_dir}/framework/scripts/build-all-images.sh"

  cat > "${repo_dir}/framework/scripts/validate-site-config.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${repo_dir}/framework/scripts/validate-site-config.sh"

  cat > "${repo_dir}/framework/scripts/build-image.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

mkdir -p "${REPO_DIR}/site/tofu"
printf 'image_versions = {}\n' > "${REPO_DIR}/site/tofu/image-versions.auto.tfvars"
EOF
  chmod +x "${repo_dir}/framework/scripts/build-image.sh"

  cat > "${repo_dir}/framework/images.yaml" <<'EOF'
roles: {}
EOF

  cat > "${repo_dir}/site/images.yaml" <<'EOF'
roles: {}
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  : > "${repo_dir}/site/nix/hosts/gitlab.nix"
  : > "${repo_dir}/site/nix/hosts/cicd.nix"
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cat <<'OUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
stub 100000000 0 52428800 0% /nix/store
OUT
EOF
  chmod +x "${shim_dir}/df"

  cat > "${shim_dir}/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out_link=""
flake_ref=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-link)
      out_link="$2"
      shift 2
      ;;
    .#*)
      flake_ref="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "${flake_ref}" in
  *'nixosConfigurations.gitlab.config.system.build.toplevel'*)
    store_path="/nix/store/gitlab-test-closure"
    ;;
  *'nixosConfigurations.cicd.config.system.build.toplevel'*)
    store_path="/nix/store/cicd-test-closure"
    ;;
  *)
    exit 1
    ;;
esac

ln -snf "${store_path}" "${out_link}"
printf '%s\n' "${store_path}"
EOF
  chmod +x "${shim_dir}/nix"

  cat > "${shim_dir}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

query=""
file=""

for arg in "$@"; do
  case "${arg}" in
    -r|-e)
      ;;
    *)
      if [[ -z "${query}" ]]; then
        query="${arg}"
      else
        file="${arg}"
      fi
      ;;
  esac
done

if [[ "${query}" == '.roles | keys | .[]' && "${file}" == */framework/images.yaml ]]; then
  printf 'gitlab\ncicd\n'
  exit 0
fi

if [[ "${query}" == '.roles | keys | .[]' && "${file}" == */site/images.yaml ]]; then
  exit 0
fi

if [[ "${query}" == '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' && "${file}" == */site/applications.yaml ]]; then
  exit 0
fi

if [[ "${query}" == '.roles.gitlab' && "${file}" == */framework/images.yaml ]]; then
  exit 0
fi

if [[ "${query}" == '.roles.cicd' && "${file}" == */framework/images.yaml ]]; then
  exit 0
fi

if [[ "${query}" == '.roles.gitlab.category' && "${file}" == */framework/images.yaml ]]; then
  printf 'nix\n'
  exit 0
fi

if [[ "${query}" == '.roles.cicd.category' && "${file}" == */framework/images.yaml ]]; then
  printf 'nix\n'
  exit 0
fi

if [[ "${query}" == '.roles.gitlab.host_config' && "${file}" == */framework/images.yaml ]]; then
  printf 'site/nix/hosts/gitlab.nix\n'
  exit 0
fi

if [[ "${query}" == '.roles.cicd.host_config' && "${file}" == */framework/images.yaml ]]; then
  printf 'site/nix/hosts/cicd.nix\n'
  exit 0
fi

exit 1
EOF
  chmod +x "${shim_dir}/yq"
}

run_fixture() {
  local repo_dir="${TMP_DIR}/fixture-repo"
  local shim_dir="${TMP_DIR}/fixture-shims"
  local output_file="${TMP_DIR}/fixture.out"

  setup_fixture_repo "${repo_dir}"
  setup_shims "${shim_dir}"

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    cd "${repo_dir}"
    framework/scripts/build-all-images.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n' "${status}" "${repo_dir}" "${output_file}"
}

artifact_status() {
  printf '%s\n' "$1" | sed -n '1p'
}

artifact_repo_dir() {
  printf '%s\n' "$1" | sed -n '2p'
}

artifact_output_file() {
  printf '%s\n' "$1" | sed -n '3p'
}

test_start "1.4" "build-all-images.sh writes a valid closure-paths artifact in stub mode"
ARTIFACTS="$(run_fixture)"
STATUS="$(artifact_status "${ARTIFACTS}")"
REPO_DIR="$(artifact_repo_dir "${ARTIFACTS}")"
OUTPUT_FILE="$(artifact_output_file "${ARTIFACTS}")"
JSON_FILE="${REPO_DIR}/build/closure-paths.json"
GITLAB_LINK="${REPO_DIR}/build/closure-gitlab"
CICD_LINK="${REPO_DIR}/build/closure-cicd"

if [[ "${STATUS}" == "0" ]]; then
  test_pass "stubbed build-all-images.sh exits 0"
else
  test_fail "stubbed build-all-images.sh exits 0"
  cat "${OUTPUT_FILE}" >&2
fi

if [[ -f "${JSON_FILE}" ]]; then
  test_pass "closure-paths.json is created"
else
  test_fail "closure-paths.json is created"
fi

if jq -e '
  type == "object"
  and (.gitlab | type == "string" and startswith("/nix/store/"))
  and (.cicd | type == "string" and startswith("/nix/store/"))
' "${JSON_FILE}" >/dev/null 2>&1; then
  test_pass "closure-paths.json is valid JSON with gitlab/cicd nix store paths"
else
  test_fail "closure-paths.json is valid JSON with gitlab/cicd nix store paths"
  cat "${JSON_FILE}" >&2
fi

if [[ -L "${GITLAB_LINK}" ]] && [[ "$(readlink "${GITLAB_LINK}")" == "/nix/store/gitlab-test-closure" ]] && \
   [[ -L "${CICD_LINK}" ]] && [[ "$(readlink "${CICD_LINK}")" == "/nix/store/cicd-test-closure" ]]; then
  test_pass "control-plane closure out-links are created as GC-root symlinks"
else
  test_fail "control-plane closure out-links are created as GC-root symlinks"
fi

runner_summary
