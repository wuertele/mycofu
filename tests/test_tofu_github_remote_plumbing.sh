#!/usr/bin/env bash
# test_tofu_github_remote_plumbing.sh — Verify GitHub remote URL plumbing to cicd.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "1" "tofu-wrapper.sh reads github.remote_url"
if grep -Fq "GITHUB_REMOTE_URL=\$(yq -r '.github.remote_url // \"\"' \"\$CONFIG_FILE\")" "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh"; then
  test_pass "tofu-wrapper reads github.remote_url from config.yaml"
else
  test_fail "tofu-wrapper does not read github.remote_url"
fi

test_start "2" "tofu-wrapper.sh exports TF_VAR_github_remote_url"
if grep -Fq 'export TF_VAR_github_remote_url="${GITHUB_REMOTE_URL}"' "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh"; then
  test_pass "TF_VAR_github_remote_url export exists"
else
  test_fail "TF_VAR_github_remote_url export missing"
fi

test_start "3" "root module trims and threads var.github_remote_url"
if grep -Fq 'github_remote_url = trimspace(' "${REPO_ROOT}/framework/tofu/root/main.tf" && \
   grep -Fq 'var.github_remote_url != "" ? var.github_remote_url : try(local.config.github.remote_url, "")' "${REPO_ROOT}/framework/tofu/root/main.tf" && \
   grep -Fq 'github_remote_url   = local.github_remote_url' "${REPO_ROOT}/framework/tofu/root/main.tf"; then
  test_pass "root module derives and passes github_remote_url"
else
  test_fail "root module github_remote_url threading is missing"
fi

test_start "4" "cicd module materializes /run/secrets/github/remote-url"
if grep -Fq 'path        = "/run/secrets/github/remote-url"' "${REPO_ROOT}/framework/tofu/modules/cicd/main.tf" && \
   grep -Fq 'content     = var.github_remote_url' "${REPO_ROOT}/framework/tofu/modules/cicd/main.tf"; then
  test_pass "cicd module writes runner remote-url secret"
else
  test_fail "cicd module remote-url materialization missing"
fi

test_start "5" "framework does not hardcode wuertele/mycofu"
if ! rg -n 'wuertele/mycofu' "${REPO_ROOT}/framework" >/dev/null 2>&1; then
  test_pass "framework code does not hardcode the site GitHub owner/repo"
else
  test_fail "framework code hardcodes wuertele/mycofu"
fi

test_start "6" "site/config.yaml.production is deleted"
if [[ ! -e "${REPO_ROOT}/site/config.yaml.production" ]]; then
  test_pass "orphan production config file is absent"
else
  test_fail "site/config.yaml.production still exists"
fi

test_start "7" "active deploy paths do not reference config.yaml.production"
if ! rg -n 'config\.yaml\.production' "${REPO_ROOT}/framework" "${REPO_ROOT}/site" "${REPO_ROOT}/.gitlab-ci.yml" \
  -g '*.sh' -g '*.nix' -g '*.tf' -g '*.py' -g '*.yaml' -g '*.yml' >/dev/null 2>&1; then
  test_pass "active deploy paths do not reference config.yaml.production"
else
  test_fail "active deploy paths still reference config.yaml.production"
fi

runner_summary

