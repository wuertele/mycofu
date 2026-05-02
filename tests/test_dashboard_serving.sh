#!/usr/bin/env bash
# test_dashboard_serving.sh — Verify cluster dashboard serving contracts.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

DASHBOARD_MODULE="${REPO_ROOT}/framework/catalog/cluster-dashboard/module.nix"
INFLUXDB_MODULE="${REPO_ROOT}/framework/catalog/influxdb/module.nix"
INDEX_HTML="${REPO_ROOT}/framework/catalog/cluster-dashboard/static/index.html"
INFLUXDB_HEALTH="${REPO_ROOT}/framework/catalog/influxdb/health.yaml"
DASHBOARD_HEALTH="${REPO_ROOT}/framework/catalog/cluster-dashboard/health.yaml"
APPS_CONFIG="${REPO_ROOT}/site/applications.yaml"
GATUS_CONFIG_SCRIPT="${REPO_ROOT}/framework/scripts/generate-gatus-config.sh"

test_start "1" "dashboard static assets are present"
if [[ -f "${INDEX_HTML}" ]] && \
   [[ -f "${REPO_ROOT}/framework/catalog/cluster-dashboard/static/dashboard.js" ]] && \
   [[ -f "${REPO_ROOT}/framework/catalog/cluster-dashboard/static/dashboard.css" ]] && \
   [[ -f "${REPO_ROOT}/framework/catalog/cluster-dashboard/static/vendor/uPlot.min.js" ]] && \
   [[ -f "${REPO_ROOT}/framework/catalog/cluster-dashboard/static/vendor/uPlot.min.css" ]]; then
  test_pass "HTML, JS, CSS, and vendored uPlot assets exist"
else
  test_fail "dashboard static asset bundle is incomplete"
fi

test_start "2" "nginx serves the dashboard on 443"
if grep -Fq 'port = 443; ssl = true;' "${DASHBOARD_MODULE}" && \
   grep -Fq 'sslCertificate = "/etc/letsencrypt/live/influxdb/fullchain.pem";' "${DASHBOARD_MODULE}" && \
   grep -Fq 'root = dashboardSite;' "${DASHBOARD_MODULE}" && \
   grep -Fq 'try_files $uri $uri/ /index.html;' "${DASHBOARD_MODULE}"; then
  test_pass "dashboard module defines the TLS virtual host and static site root"
else
  test_fail "dashboard module is missing the expected TLS/static nginx wiring"
fi

test_start "3" "dashboard proxy endpoints are configured"
if grep -Fq 'locations."/api/proxmox/"' "${DASHBOARD_MODULE}" && \
   grep -Fq 'return 404;' "${DASHBOARD_MODULE}" && \
   grep -Fq 'locations."= /api/proxmox/cluster/resources"' "${DASHBOARD_MODULE}" && \
   grep -Fq 'proxyPass = "https://cluster_dashboard_proxmox/api2/json/cluster/resources";' "${DASHBOARD_MODULE}" && \
   grep -Fq 'if ($arg_type !~ "^(vm|node)$") {' "${DASHBOARD_MODULE}" && \
   grep -Fq 'locations."/api/influxdb/"' "${DASHBOARD_MODULE}" && \
   grep -Fq 'proxyPass = "https://127.0.0.1:8086/";' "${DASHBOARD_MODULE}" && \
   grep -Fq 'locations."= /api/config"' "${DASHBOARD_MODULE}"; then
  test_pass "Proxmox, InfluxDB, and runtime config proxy locations are present"
else
  test_fail "dashboard proxy locations are incomplete"
fi

test_start "4" "runtime nginx includes are rendered before nginx starts"
if grep -Fq 'include /run/cluster-dashboard/upstreams.conf;' "${DASHBOARD_MODULE}" && \
   grep -Fq 'cluster-dashboard-nginx-runtime' "${DASHBOARD_MODULE}" && \
   grep -Fq 'proxmox-headers.conf' "${DASHBOARD_MODULE}" && \
   grep -Fq 'influx-headers.conf' "${DASHBOARD_MODULE}"; then
  test_pass "runtime upstream/header includes are generated and ordered before nginx"
else
  test_fail "runtime nginx include generation is incomplete"
fi

test_start "5" "influxdb composes the dashboard without displacing :8086"
if grep -Fq '../cluster-dashboard/module.nix' "${INFLUXDB_MODULE}" && \
   grep -Fq 'services.clusterDashboard.enable = true;' "${INFLUXDB_MODULE}" && \
   grep -Fq 'networking.firewall.allowedTCPPorts = [ 8086 ];' "${INFLUXDB_MODULE}"; then
  test_pass "InfluxDB imports the dashboard module and still exposes 8086"
else
  test_fail "InfluxDB/dashboard composition is missing or 8086 exposure regressed"
fi

test_start "6" "health metadata keeps backend and dashboard checks separate"
if [[ "$(yq -r '.port' "${INFLUXDB_HEALTH}")" == "8086" ]] && \
   [[ "$(yq -r '.path' "${INFLUXDB_HEALTH}")" == "/health" ]] && \
   [[ "$(yq -r '.port' "${DASHBOARD_HEALTH}")" == "443" ]] && \
   [[ "$(yq -r '.path' "${DASHBOARD_HEALTH}")" == "/" ]]; then
  test_pass "InfluxDB backend health and dashboard health metadata stay distinct"
else
  test_fail "health metadata does not preserve distinct backend and dashboard checks"
fi

test_start "7" "Gatus config emits both InfluxDB backend and dashboard checks"
INFLUXDB_PROD_IP="$(yq -r '.applications.influxdb.environments.prod.ip' "${APPS_CONFIG}")"
GATUS_CONFIG_OUTPUT="$("${GATUS_CONFIG_SCRIPT}")"
if grep -Fq 'name: influxdb-prod' <<< "${GATUS_CONFIG_OUTPUT}" && \
   grep -Fq "url: \"https://${INFLUXDB_PROD_IP}:8086/health\"" <<< "${GATUS_CONFIG_OUTPUT}" && \
   grep -Fq 'name: influxdb-dashboard-prod' <<< "${GATUS_CONFIG_OUTPUT}" && \
   grep -Fq "url: \"https://${INFLUXDB_PROD_IP}:443/\"" <<< "${GATUS_CONFIG_OUTPUT}"; then
  test_pass "Gatus config monitors both the InfluxDB API and the dashboard landing page"
else
  test_fail "Gatus config is missing either the InfluxDB backend or dashboard check"
fi

test_start "8" "static HTML advertises the dashboard runtime assets"
if grep -Fq 'Cluster Dashboard' "${INDEX_HTML}" && \
   grep -Fq '/vendor/uPlot.min.css' "${INDEX_HTML}" && \
   grep -Fq '/dashboard.css' "${INDEX_HTML}" && \
   grep -Fq '/dashboard.js' "${INDEX_HTML}"; then
  test_pass "index.html references the expected dashboard assets"
else
  test_fail "index.html is missing expected dashboard markers"
fi

test_start "9" "influxdb remains backup-enabled for the PBS restore path"
if [[ "$(yq -r '.applications.influxdb.backup' "${APPS_CONFIG}")" == "true" ]]; then
  test_pass "applications.yaml still marks influxdb as backup-enabled"
else
  test_fail "influxdb backup contract regressed in applications.yaml"
fi

runner_summary
