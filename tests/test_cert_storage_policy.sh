#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "1" "dev dry-run includes testapp cert-storage policy attachment"
DEV_OUTPUT="$(
  cd "${REPO_ROOT}" &&
  framework/scripts/configure-vault.sh dev --dry-run
)"
if grep -Fq 'testapp_dev: default-policy,testapp_dev-cert-storage-policy' <<< "${DEV_OUTPUT}" && \
   grep -Fq 'path "mycofu/data/certs/testapp.dev.wuertele.com"' <<< "${DEV_OUTPUT}" && \
   grep -Fq 'path "mycofu/metadata/certs/testapp.dev.wuertele.com"' <<< "${DEV_OUTPUT}"; then
  test_pass "testapp_dev gets a dedicated Vault cert-storage policy in dry-run output"
else
  test_fail "testapp_dev cert-storage policy is missing from dry-run output"
fi

test_start "2" "manifest-backed grafana roles inherit cert-storage policy in dry-run"
if grep -Fq 'grafana_dev: default-policy,grafana_dev-cert-storage-policy' <<< "${DEV_OUTPUT}" && \
   grep -Fq 'path "mycofu/data/certs/grafana.dev.wuertele.com"' <<< "${DEV_OUTPUT}"; then
  test_pass "grafana_dev manifest wiring includes the cert-storage policy"
else
  test_fail "grafana_dev cert-storage policy is missing from dry-run output"
fi

test_start "3" "prod dry-run covers shared certbot hosts"
PROD_OUTPUT="$(
  cd "${REPO_ROOT}" &&
  framework/scripts/configure-vault.sh prod --dry-run
)"
if grep -Fq 'gitlab: default-policy,gitlab-tailscale-policy,gitlab-cert-storage-policy' <<< "${PROD_OUTPUT}" && \
   grep -Fq 'path "mycofu/data/certs/gitlab.prod.wuertele.com"' <<< "${PROD_OUTPUT}" && \
   grep -Fq 'path "mycofu/metadata/certs/gitlab.prod.wuertele.com"' <<< "${PROD_OUTPUT}"; then
  test_pass "gitlab gets a shared-role cert-storage policy in prod"
else
  test_fail "gitlab cert-storage policy is missing from prod dry-run output"
fi

test_start "4" "non-certbot AppRoles do not get cert-storage policies"
if grep -Fq 'cicd: default-policy,github-publish-policy' <<< "${PROD_OUTPUT}" && \
   ! grep -Fq 'cicd-cert-storage-policy' <<< "${PROD_OUTPUT}"; then
  test_pass "cicd remains outside the cert-storage policy set"
else
  test_fail "cicd should not receive a cert-storage policy"
fi

runner_summary
