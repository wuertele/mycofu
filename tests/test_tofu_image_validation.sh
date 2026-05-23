#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
TOFU_LOG="${TMP_DIR}/tofu.log"
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
module "dns" {
  source = "../modules/example"
  image = var.image_versions["dns"]
}

module "acme_dev" {
  source = "../modules/example"
  image = var.image_versions["acme-dev"]
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

printf '%s\n' "$*" >> "${STUB_TOFU_LOG}"

case "${1:-}" in
  state)
    case "${2:-}" in
      list|show|rm)
        exit 0
        ;;
    esac
    ;;
  plan|apply|destroy|init|refresh)
    exit 0
    ;;
esac

echo "unexpected tofu invocation: $*" >&2
exit 98
EOF
chmod +x "${SHIM_DIR}/tofu"

export PATH="${SHIM_DIR}:${PATH}"
export STUB_TOFU_LOG="${TOFU_LOG}"

OUTPUT=""
STATUS=0

write_image_versions() {
  local content="$1"
  printf '%s\n' "${content}" > "${IMAGE_VERSIONS_FILE}"
}

run_wrapper() {
  : > "${TOFU_LOG}"
  local output=""
  set +e
  output="$(
    cd "${FIXTURE_REPO}" &&
    framework/scripts/tofu-wrapper.sh "$@" 2>&1
  )"
  STATUS=$?
  set -e
  OUTPUT="${output}"
}

assert_exit() {
  local expected="$1"
  local label="$2"

  if [[ "${STATUS}" -eq "${expected}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected exit %s, got %s\n' "${expected}" "${STATUS}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq -- "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing output: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_not_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq -- "${needle}" <<< "${OUTPUT}"; then
    test_fail "${label}"
    printf '    unexpected output: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  else
    test_pass "${label}"
  fi
}

assert_tofu_log_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq -- "${needle}" "${TOFU_LOG}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing tofu log entry: %s\n' "${needle}" >&2
    printf '    tofu log:\n%s\n' "$(cat "${TOFU_LOG}" 2>/dev/null)" >&2
  fi
}

assert_tofu_log_not_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq -- "${needle}" "${TOFU_LOG}"; then
    test_fail "${label}"
    printf '    unexpected tofu log entry: %s\n' "${needle}" >&2
    printf '    tofu log:\n%s\n' "$(cat "${TOFU_LOG}" 2>/dev/null)" >&2
  else
    test_pass "${label}"
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq -- "${needle}" "${file}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing file content: %s\n' "${needle}" >&2
    printf '    file: %s\n' "${file}" >&2
    printf '    contents:\n%s\n' "$(cat "${file}" 2>/dev/null)" >&2
  fi
}

test_start "17.1" "valid image-versions file allows apply"
write_image_versions 'image_versions = {
  "dns" = "dns-4ypjgkci.img"
}'
run_wrapper apply
assert_exit 0 "apply succeeds with a valid image filename"
assert_output_not_contains "Invalid image values detected" "valid apply emits no image validation warning"
assert_tofu_log_contains "apply -var-file=" "valid apply reaches tofu apply"

test_start "17.2" "placeholder values block apply"
write_image_versions 'image_versions = {
  "dns" = "PLACEHOLDER_dns"
}'
run_wrapper apply
assert_exit 1 "apply fails closed on placeholder values"
assert_output_contains "ERROR: Invalid image values detected in image-versions.auto.tfvars:" "placeholder apply prints a blocking error"
assert_output_contains "dns: PLACEHOLDER_dns" "placeholder apply lists the failing role and value"
assert_tofu_log_not_contains "apply -var-file=" "blocked apply never invokes tofu apply"

test_start "17.3" "empty-string values block apply"
write_image_versions 'image_versions = {
  "dns" = ""
}'
run_wrapper apply
assert_exit 1 "apply fails closed on empty image values"
assert_output_contains "dns: " "empty-string apply names the invalid role"
assert_tofu_log_not_contains "apply -var-file=" "empty-string apply does not reach tofu apply"

test_start "17.4" "mixed valid and invalid values list every invalid role"
write_image_versions 'image_versions = {
  "dns" = "dns-4ypjgkci.img"
  "vault" = ""
  "grafana" = "grafana-badvalue.iso"
  "testapp" = "PLACEHOLDER_testapp"
}'
run_wrapper apply
assert_exit 1 "mixed image values still block apply"
assert_output_contains "vault: " "mixed apply reports the empty-string role"
assert_output_contains "grafana: grafana-badvalue.iso" "mixed apply reports the bad extension"
assert_output_contains "testapp: PLACEHOLDER_testapp" "mixed apply reports the placeholder role"

test_start "17.5" "plan warns but proceeds on placeholder values"
write_image_versions 'image_versions = {
  "dns" = "PLACEHOLDER_dns"
}'
run_wrapper plan
assert_exit 0 "plan succeeds with placeholder values"
assert_output_contains "WARNING: Invalid image values detected in image-versions.auto.tfvars; tofu plan will continue, but tofu apply will be blocked:" "plan prints the warning-only message"
assert_tofu_log_contains "plan -var-file=" "plan still reaches tofu"

test_start "17.6" "allow-placeholder-images bypasses the guard"
write_image_versions 'image_versions = {
  "dns" = "PLACEHOLDER_dns"
}'
run_wrapper apply --allow-placeholder-images
assert_exit 0 "allow-placeholder-images lets apply proceed"
assert_output_contains "proceeding due to --allow-placeholder-images" "escape hatch warning is printed"
assert_tofu_log_contains "apply -var-file=" "escape hatch still invokes tofu apply"
assert_tofu_log_not_contains "--allow-placeholder-images" "escape hatch flag is stripped before tofu exec"

test_start "17.7" "missing image-versions file generates sentinels and blocks apply"
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper apply
assert_exit 1 "apply fails closed when the image versions file is missing"
assert_output_contains "generating placeholder sentinels; tofu apply will be blocked" "missing file warning mentions sentinel generation and apply block"
assert_output_contains "dns: PLACEHOLDER_dns" "generated placeholder file is validated and reported"
assert_output_contains "acme-dev: PLACEHOLDER_acme-dev" "generated placeholders include hyphenated roles"
assert_file_contains "${IMAGE_VERSIONS_FILE}" '"dns" = "PLACEHOLDER_dns"' "generated placeholder file uses sentinel values"
assert_file_contains "${IMAGE_VERSIONS_FILE}" '"acme-dev" = "PLACEHOLDER_acme-dev"' "generated placeholder file preserves hyphenated role names"

test_start "17.8" "wrong file extension blocks apply"
write_image_versions 'image_versions = {
  "dns" = "dns-4ypjgkci.iso"
}'
run_wrapper apply
assert_exit 1 "apply fails closed on .iso image values"
assert_output_contains "dns: dns-4ypjgkci.iso" "bad extension is reported explicitly"

test_start "17.9" "nix base32 hashes are accepted"
write_image_versions 'image_versions = {
  "dns" = "dns-4ypjgkci.img"
}'
run_wrapper apply
assert_exit 0 "apply accepts nix base32 image hashes"
assert_output_not_contains "Invalid image values detected" "base32 image values pass validation cleanly"

test_start "17.10" "dev-mode image filenames are accepted"
write_image_versions 'image_versions = {
  "dns" = "dns-a3f82c1d-dev.img"
}'
run_wrapper apply
assert_exit 0 "apply accepts dev-mode image filenames"
assert_output_not_contains "Invalid image values detected" "dev-mode filenames pass validation cleanly"

test_start "17.11" "hyphenated role names are accepted"
write_image_versions 'image_versions = {
  "acme-dev" = "acme-dev-s65mxam5.img"
}'
run_wrapper apply
assert_exit 0 "apply accepts valid hyphenated role image filenames"
assert_output_not_contains "Invalid image values detected" "hyphenated role filenames pass validation cleanly"

test_start "17.12" "inline comments are rejected by the fail-closed parser"
write_image_versions 'image_versions = {
  "dns" = "dns-4ypjgkci.img" # inline comment
}'
run_wrapper apply
assert_exit 1 "apply fails closed on inline-comment image entries"
assert_output_contains "ERROR: Unparseable image_versions entries detected in image-versions.auto.tfvars:" "inline-comment apply prints an unparseable-entry error"
assert_output_contains "\"dns\" = \"dns-4ypjgkci.img\" # inline comment" "inline-comment apply lists the skipped line"
assert_tofu_log_not_contains "apply -var-file=" "inline-comment apply never invokes tofu apply"

test_start "17.13" "single-line image_versions maps are rejected by the fail-closed parser"
write_image_versions 'image_versions = { "dns" = "dns-4ypjgkci.img" }'
run_wrapper apply
assert_exit 1 "apply fails closed on single-line image_versions maps"
assert_output_contains "ERROR: Unparseable image_versions entries detected in image-versions.auto.tfvars:" "single-line map apply prints an unparseable-entry error"
assert_output_contains "image_versions = { \"dns\" = \"dns-4ypjgkci.img\" }" "single-line map apply lists the skipped line"
assert_tofu_log_not_contains "apply -var-file=" "single-line map apply never invokes tofu apply"

runner_summary
