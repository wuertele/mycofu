#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIG="${REPO_ROOT}/tests/hil/bfnet/config.yaml"
HIL_BOOT_IP="$(yq -r '.vms.hil_boot.ip' "${REPO_ROOT}/site/config.yaml")"

build_dnsmasq_conf() {
  (cd "$REPO_ROOT" && nix build .#packages.x86_64-linux.hil-boot-dnsmasq-conf --no-link --print-out-paths 2>&1)
}

test_start "s037.2.5" "generated dnsmasq config has six static bpve hosts"
set +e
build_output="$(build_dnsmasq_conf)"
build_rc=$?
set -e
if [[ "$build_rc" -ne 0 && ( "$build_output" == *"cannot connect to socket"*"Operation not permitted"* || "$build_output" == *"unable to open database file"* ) ]]; then
  test_skip "Nix daemon is not reachable from this sandbox"
  DNSMASQ_CONF=""
elif [[ "$build_rc" -eq 0 ]]; then
  DNSMASQ_CONF="$(tail -1 <<< "$build_output")"
  host_count="$(grep -c '^dhcp-host=' "$DNSMASQ_CONF")"
  expected_count="$(yq -r '[.nodes[] | select(.regreen_enabled == true)] | length' "$CONFIG")"
  if [[ "$host_count" == "$expected_count" && "$host_count" == "6" ]]; then
    test_pass "generated dnsmasq config has exactly six dhcp-host entries"
  else
    test_fail "generated dnsmasq config has ${host_count} dhcp-host entries; expected 6"
  fi
else
  test_fail "could not build hil-boot-dnsmasq-conf"
  DNSMASQ_CONF=""
fi

test_start "s037.2.6" "dnsmasq config is static PXE-only"
if [[ -n "${DNSMASQ_CONF:-}" ]]; then
  if grep -q '^port=0$' "$DNSMASQ_CONF" && \
     grep -q '^bind-dynamic$' "$DNSMASQ_CONF" && \
     ! grep -q '^interface=' "$DNSMASQ_CONF" && \
     grep -q '^dhcp-userclass=set:ipxe-client,iPXE$' "$DNSMASQ_CONF" && \
     grep -q 'ipxe.efi' "$DNSMASQ_CONF" && \
     grep -q "http://${HIL_BOOT_IP}/nodes/.*/boot.ipxe" "$DNSMASQ_CONF" && \
     ! grep -Eq '^dhcp-range=[^t].*,.*,.*' "$DNSMASQ_CONF"; then
    test_pass "dnsmasq config has no DNS, bind-dynamic, iPXE user-class, IP-literal boot, and no broad dynamic range"
  else
    test_fail "dnsmasq config is missing required PXE constraints"
  fi
else
  if grep -q 'port=0' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
     grep -q 'bind-dynamic' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
     ! grep -q 'interface=eth0\|bind-interfaces' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
     grep -q 'dhcp-userclass=set:ipxe-client,iPXE' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
     grep -q 'tag:bios-pxe,tag:!ipxe-client,ipxe.efi' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
     grep -q 'tag:ipxe-client,http://%s/nodes' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix"; then
    test_pass "static dnsmasq generator contains required PXE constraints"
  else
    test_fail "static dnsmasq generator missing required PXE constraints"
  fi
fi

test_start "s037.2.7" "dnsmasq generator uses all configured MACs"
missing=0
if [[ -n "${DNSMASQ_CONF:-}" ]]; then
  while IFS=$'\t' read -r node mac; do
    [[ -n "$node" ]] || continue
    grep -Fq "dhcp-host=${mac}," "$DNSMASQ_CONF" || missing=$((missing + 1))
  done < <(yq -r '.nodes[] | select(.regreen_enabled == true) | [.name, .mac] | @tsv' "$CONFIG")
else
  grep -q 'select(.name == strenv(NODE)) | .mac' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" || missing=1
fi

if [[ "$missing" -eq 0 ]]; then
  test_pass "all enabled node MACs are represented by generated/static dnsmasq config"
else
  test_fail "${missing} enabled node MAC(s) missing from dnsmasq config"
fi

runner_summary
