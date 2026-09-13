#!/usr/bin/env bash
# test_rotation_manifest_schema.sh — guard against ceremony-only manifest fields.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rotation-manifest-schema.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_ROOT="${REPO_ROOT}/tests/fixtures/rotation-manifest/base"
BAD_SCHEMA="${REPO_ROOT}/tests/fixtures/rotation-manifest/bad-schema.yaml"
CHECKER="${REPO_ROOT}/framework/scripts/check-rotation-manifest.sh"

stage_fixture_git() {
  local repo="$1"
  (
    cd "${repo}"
    git init -q
    git -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false add -A
    git -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false commit -q -m "fixture: initial"
  ) >/dev/null
}

repo="${TMP_DIR}/repo"
cp -R "${FIXTURE_ROOT}" "${repo}"
chmod +x "${repo}/framework/scripts/ensure-app-secrets.sh"
cp "${BAD_SCHEMA}" "${repo}/site/rotation-manifest.yaml"
stage_fixture_git "${repo}"

test_start "V1.3" "manifest parser rejects fields outside the machine-consumed allowlist"
set +e
output="$(
  ROTATION_MANIFEST_REPO_DIR="${repo}" \
    "${CHECKER}" 2>&1
)"
status=$?
set -e

if [[ "${status}" -ne 0 && "${output}" == *"unsupported field 'ratified_by'"* ]]; then
  test_pass "ratified_by-style ceremony metadata is rejected"
else
  test_fail "disallowed manifest field was not rejected"
  printf '%s\n' "${output}" >&2
fi

test_start "V1.3-holders-positive" "holders field is accepted for the M1 sops_age_key row"
repo="${TMP_DIR}/holders-ok"
cp -R "${FIXTURE_ROOT}" "${repo}"
chmod +x "${repo}/framework/scripts/ensure-app-secrets.sh"
cat >> "${repo}/fixture-sops/site-secrets.yaml" <<'EOF'
sops_age_key: ENC[AES256_GCM,data:SENTINEL_SOPS_AGE_KEY]
EOF
cat >> "${repo}/site/rotation-manifest.yaml" <<'EOF'
- match: sops_age_key
  class: M1
  driver: framework/scripts/rotate-sops-recipient.sh
  probe: tests/test_rotate_sops_recipient.sh
  holders:
    - name: workstation
      delivery: local-file
    - name: cicd
      delivery: register-runner
EOF
stage_fixture_git "${repo}"
set +e
output="$(
  ROTATION_MANIFEST_REPO_DIR="${repo}" \
    "${CHECKER}" 2>&1
)"
status=$?
set -e
if [[ "${status}" -eq 0 && "${output}" == *"rotation manifest OK"* ]]; then
  test_pass "M1 sops_age_key holders are accepted as machine-consumed delivery metadata"
else
  test_fail "valid sops_age_key holders field was rejected"
  printf '%s\n' "${output}" >&2
fi

test_start "V1.3-holders-negative" "holders field is rejected outside the M1 sops_age_key row"
repo="${TMP_DIR}/holders-bad-row"
cp -R "${FIXTURE_ROOT}" "${repo}"
chmod +x "${repo}/framework/scripts/ensure-app-secrets.sh"
yq -i '.[0].holders = [{"name":"workstation","delivery":"local-file"}]' "${repo}/site/rotation-manifest.yaml"
stage_fixture_git "${repo}"
set +e
output="$(
  ROTATION_MANIFEST_REPO_DIR="${repo}" \
    "${CHECKER}" 2>&1
)"
status=$?
set -e
if [[ "${status}" -ne 0 && "${output}" == *"holders are only supported on the M1 sops_age_key row"* ]]; then
  test_pass "holders on unrelated manifest rows fail closed"
else
  test_fail "holders field outside sops_age_key was not rejected"
  printf '%s\n' "${output}" >&2
fi

runner_summary
