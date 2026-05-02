#!/usr/bin/env bash
# test_grafana_dashboard_provisioning.sh — Verify drill-down dashboard provisioning and regressions.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

GRAFANA_HOST="${REPO_ROOT}/site/nix/hosts/grafana.nix"
PROVIDER_FILE="${REPO_ROOT}/site/apps/grafana/dashboards.yaml"
OVERVIEW_FILE="${REPO_ROOT}/site/apps/grafana/dashboards/cluster-overview.json"
VM_DETAIL_FILE="${REPO_ROOT}/site/apps/grafana/dashboards/cluster-vm-detail.json"
NODE_DETAIL_FILE="${REPO_ROOT}/site/apps/grafana/dashboards/cluster-node-detail.json"

test_start "1" "dashboard provider path remains the provisioned dashboards directory"
if [[ "$(yq -r '.providers[0].options.path' "${PROVIDER_FILE}")" == "/var/lib/grafana/dashboards" ]]; then
  test_pass "Grafana dashboard provider still points at /var/lib/grafana/dashboards"
else
  test_fail "Grafana dashboard provider path changed unexpectedly"
fi

test_start "2" "benchmark dashboard provisioning remains attached to the Grafana host"
if grep -Fq '../../../benchmarks/grafana/dashboard.json' "${GRAFANA_HOST}"; then
  test_pass "Grafana host still provisions the benchmark dashboard"
else
  test_fail "Grafana host no longer provisions the benchmark dashboard"
fi

test_start "3" "existing cluster overview dashboard is still present"
if [[ "$(jq -r '.uid' "${OVERVIEW_FILE}")" == "cluster-overview" ]]; then
  test_pass "cluster-overview dashboard UID is unchanged"
else
  test_fail "cluster-overview dashboard UID changed or file is invalid"
fi

test_start "4" "new drill-down dashboards have stable UIDs and URL template variables"
if [[ "$(jq -r '.uid' "${VM_DETAIL_FILE}")" == "cluster-vm-detail" ]] && \
   [[ "$(jq -r '.uid' "${NODE_DETAIL_FILE}")" == "cluster-node-detail" ]] && \
   [[ "$(jq -r '.templating.list[0].name' "${VM_DETAIL_FILE}")" == "vmid" ]] && \
   [[ "$(jq -r '.templating.list[0].name' "${NODE_DETAIL_FILE}")" == "node" ]]; then
  test_pass "drill-down dashboards expose the expected UID and variable contract"
else
  test_fail "drill-down dashboard UID or variable contract is wrong"
fi

test_start "5" "drill-down queries target the cluster metrics bucket explicitly"
if jq -e '.panels[].targets[].query | contains("from(bucket: \"default\")")' "${VM_DETAIL_FILE}" >/dev/null && \
   jq -e '.panels[].targets[].query | contains("from(bucket: \"default\")")' "${NODE_DETAIL_FILE}" >/dev/null; then
  test_pass "drill-down dashboards query the explicit cluster metrics bucket"
else
  test_fail "drill-down dashboards are relying on datasource default bucket selection"
fi

runner_summary
