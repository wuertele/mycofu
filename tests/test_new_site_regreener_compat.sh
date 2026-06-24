#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "${TMP_DIR}/framework/scripts" "${TMP_DIR}/framework/templates"
cp "${REPO_ROOT}/framework/scripts/new-site.sh" \
   "${REPO_ROOT}/framework/scripts/validate-site-config.sh" \
   "${TMP_DIR}/framework/scripts/"
cp "${REPO_ROOT}/framework/templates/config.yaml.example" \
   "${REPO_ROOT}/framework/templates/images.yaml.example" \
   "${REPO_ROOT}/framework/templates/gitlab.yaml.example" \
   "${TMP_DIR}/framework/templates/"
printf '{}\n' > "${TMP_DIR}/flake.nix"

test_start "s034.r2.1" "new-site scaffolds config with regreener disabled by default"
set +e
NEW_SITE_OUTPUT="$(
  cd "$TMP_DIR" && printf 'example.test\n' | framework/scripts/new-site.sh 2>&1
)"
NEW_SITE_RC=$?
set -e

CONFIG="${TMP_DIR}/site/config.yaml"
APPS_CONFIG="${TMP_DIR}/site/applications.yaml"

if [[ "$NEW_SITE_RC" -eq 0 ]] && [[ -f "$CONFIG" ]] && [[ -f "$APPS_CONFIG" ]]; then
  test_pass "new-site generated site config and applications config"
else
  test_fail "new-site failed (rc=${NEW_SITE_RC})"
  printf '%s\n' "$NEW_SITE_OUTPUT" >&2
fi

test_start "s034.r2.2" "generated config validates"
if VALIDATE_SITE_CONFIG_CONFIG="$CONFIG" \
   VALIDATE_SITE_CONFIG_APPS_CONFIG="$APPS_CONFIG" \
   "${TMP_DIR}/framework/scripts/validate-site-config.sh" >/dev/null 2>&1; then
  test_pass "generated config passes validate-site-config.sh"
else
  test_fail "generated config did not validate"
fi

test_start "s034.r2.3" "generated config keeps regreen opt-in disabled"
if [[ "$(yq -r '[.nodes[] | select(.regreen_enabled == true)] | length' "$CONFIG")" == "0" ]] && \
   grep -q 'regreen_enabled: false' "$CONFIG"; then
  test_pass "no node is regreen_enabled by default"
else
  test_fail "new-site generated an enabled regreener node"
fi

test_start "s034.r2.4" "generated config carries AMT guidance comments"
if grep -q 'AMT systems with a single shared NIC' "$CONFIG" && \
   grep -q 'amt_ip equal to mgmt_ip' "$CONFIG" && \
   grep -q 'install_disk_id_path' "$CONFIG"; then
  test_pass "optional AMT and single-shared-NIC comments are present"
else
  test_fail "regreener AMT comments missing from generated config"
fi

runner_summary
