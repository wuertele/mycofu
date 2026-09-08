#!/usr/bin/env bash
# V2.2b: .gitlab-ci.yml must not reference removed cicd CIDATA secret paths.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REMOVED_REFS=(
  'TF_VAR_sops_age_key'
  'TF_VAR_ssh_privkey'
  '/run/secrets/sops/age-key'
  '/run/secrets/gitlab-runner/ssh-privkey'
)

assert_no_removed_refs() {
  local file="$1"
  local found=0
  local ref

  for ref in "${REMOVED_REFS[@]}"; do
    if grep -Fq "$ref" "$file"; then
      printf '%s\n' "$ref"
      found=1
    fi
  done

  [[ "$found" -eq 0 ]]
}

test_start "V2.2b-real-tree" ".gitlab-ci.yml has no removed TF_VARs or CIDATA paths"
set +e
REAL_HITS="$(assert_no_removed_refs "$CI_FILE")"
REAL_STATUS=$?
set -e
if [[ "$REAL_STATUS" -eq 0 ]]; then
  test_pass ".gitlab-ci.yml is clean of removed runner secret references"
else
  test_fail ".gitlab-ci.yml still contains removed runner secret references: ${REAL_HITS}"
fi

test_start "V2.2b-negative-fixture" "ratchet fails when removed references are present"
FIXTURE_CI="${TMP_DIR}/gitlab-ci-with-removed-refs.yml"
cat > "$FIXTURE_CI" <<'EOF'
variables:
  TF_VAR_sops_age_key: SENTINEL-REMOVED
  TF_VAR_ssh_privkey: SENTINEL-REMOVED
  SOPS_AGE_KEY_FILE: /run/secrets/sops/age-key
before_script:
  - test -f /run/secrets/gitlab-runner/ssh-privkey
EOF

set +e
FIXTURE_HITS="$(assert_no_removed_refs "$FIXTURE_CI")"
FIXTURE_STATUS=$?
set -e
if [[ "$FIXTURE_STATUS" -ne 0 ]] &&
   grep -Fq 'TF_VAR_sops_age_key' <<< "$FIXTURE_HITS" &&
   grep -Fq 'TF_VAR_ssh_privkey' <<< "$FIXTURE_HITS" &&
   grep -Fq '/run/secrets/sops/age-key' <<< "$FIXTURE_HITS" &&
   grep -Fq '/run/secrets/gitlab-runner/ssh-privkey' <<< "$FIXTURE_HITS"; then
  test_pass "negative fixture fails and reports every removed reference"
else
  test_fail "negative fixture did not fail as expected"
  printf 'status=%s\nhits=%s\n' "$FIXTURE_STATUS" "$FIXTURE_HITS" >&2
fi

runner_summary
