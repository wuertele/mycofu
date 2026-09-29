#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "$SHIM_DIR"

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

keys_csv="${SOPS_STUB_KEYS:-amt_password_bfnet,pdu_password_bfnet,proxmox_api_password}"

has_key() {
  local needle="$1"
  IFS=',' read -r -a keys <<< "$keys_csv"
  for key in "${keys[@]}"; do
    [[ "$key" == "$needle" ]] && return 0
  done
  return 1
}

if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  ref="$3"
  key="$(printf '%s' "$ref" | sed -E 's/^\["([^"]+)"\]$/\1/')"
  if has_key "$key"; then
    printf 'secret-value\n'
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "-d" ]]; then
  IFS=',' read -r -a keys <<< "$keys_csv"
  for key in "${keys[@]}"; do
    printf '%s: secret-value\n' "$key"
  done
  exit 0
fi

echo "unexpected sops invocation: $*" >&2
exit 99
EOF
chmod +x "${SHIM_DIR}/sops"

export PATH="${SHIM_DIR}:${PATH}"

make_site() {
  local name="$1"
  local node_block="$2"
  local extra_top="${3:-}"
  local dir="${TMP_DIR}/${name}"

  mkdir -p "${dir}/sops"
  cat > "${dir}/applications.yaml" <<'EOF'
applications: {}
EOF
  printf 'stub encrypted secrets\n' > "${dir}/sops/secrets.yaml"
  cat > "${dir}/config.yaml" <<EOF
domain: example.test
management:
  subnet: 192.0.2.0/24
  gateway: 192.0.2.1
regreener:
  install_timeout_sec: 1800
  ssh_timeout_sec: 600
replication:
  topology: mesh
  corosync_subnet: 10.10.0.0/24
  mtu: 9000
  health_port: 9100
proxmox:
  storage_pool: local-zfs
  installer:
    iso: proxmox-ve_9.1-1.iso
    iso_sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    expected_version: "pve-manager/9.1"
    filesystem: ext4
    reboot_mode: reboot
nodes:
${node_block}
vms: {}
applications: {}
${extra_top}
EOF
  printf '%s\n' "$dir"
}

run_validate() {
  local dir="$1"
  VALIDATE_SITE_CONFIG_CONFIG="${dir}/config.yaml" \
  VALIDATE_SITE_CONFIG_APPS_CONFIG="${dir}/applications.yaml" \
    "${REPO_ROOT}/framework/scripts/validate-site-config.sh" >/dev/null 2>&1
}

enabled_node='  - name: node1
    mgmt_ip: 192.0.2.11
    ram_gb: 32
    mgmt_iface: nic0
    repl_ip: 10.10.0.1
    regreen_enabled: true
    amt_ip: 192.0.2.11
    amt_user: admin
    amt_password_ref: amt_password_bfnet
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
    install_filesystem: ext4
    repl_peers: {}'

disabled_node='  - name: node1
    mgmt_ip: 192.0.2.11
    ram_gb: 32
    mgmt_iface: nic0
    repl_ip: 10.10.0.1
    repl_peers: {}'

test_start "s034.1.1" "enabled AMT node with shared SOPS ref validates"
dir="$(make_site valid "$enabled_node")"
if run_validate "$dir"; then
  test_pass "valid enabled node accepted"
else
  test_fail "valid enabled node rejected"
fi

test_start "s034.1.2" "two enabled nodes can share or split AMT SOPS refs"
two_nodes="${enabled_node}"$'\n'"  - name: node2
    mgmt_ip: 192.0.2.12
    ram_gb: 32
    mgmt_iface: nic0
    repl_ip: 10.10.0.2
    regreen_enabled: true
    amt_ip: 192.0.2.12
    amt_user: admin
    amt_password_ref: amt_password_node2
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
    install_filesystem: zfs
    repl_peers: {}"
dir="$(make_site two "$two_nodes")"
if SOPS_STUB_KEYS="amt_password_bfnet,amt_password_node2,proxmox_api_password" run_validate "$dir"; then
  test_pass "shared and per-node AMT refs accepted without special sharing logic"
else
  test_fail "multiple AMT refs rejected"
fi

test_start "s034.1.3" "missing amt_ip fails for enabled node"
dir="$(make_site missing_amt_ip "$enabled_node")"
yq -i 'del(.nodes[0].amt_ip)' "${dir}/config.yaml"
if run_validate "$dir"; then
  test_fail "missing amt_ip unexpectedly accepted"
else
  test_pass "missing amt_ip rejected"
fi

test_start "s034.1.4" "malformed amt_ip fails"
dir="$(make_site bad_amt_ip "${enabled_node/amt_ip: 192.0.2.11/amt_ip: 999.0.2.11}")"
if run_validate "$dir"; then
  test_fail "malformed amt_ip unexpectedly accepted"
else
  test_pass "malformed amt_ip rejected"
fi

test_start "s034.1.5" "missing amt_password_ref fails"
dir="$(make_site missing_ref "$enabled_node")"
yq -i 'del(.nodes[0].amt_password_ref)' "${dir}/config.yaml"
if run_validate "$dir"; then
  test_fail "missing amt_password_ref unexpectedly accepted"
else
  test_pass "missing amt_password_ref rejected"
fi

test_start "s034.1.6" "missing SOPS key fails when SOPS decrypts"
dir="$(make_site missing_sops "$enabled_node")"
if SOPS_STUB_KEYS="proxmox_api_password" run_validate "$dir"; then
  test_fail "missing AMT SOPS key unexpectedly accepted"
else
  test_pass "missing AMT SOPS key rejected"
fi

test_start "s034.1.7" "invalid install filesystem fails"
dir="$(make_site bad_fs "${enabled_node/install_filesystem: ext4/install_filesystem: btrfs}")"
if run_validate "$dir"; then
  test_fail "invalid install filesystem unexpectedly accepted"
else
  test_pass "invalid install filesystem rejected"
fi

test_start "s034.1.8" "disabled nodes require no AMT fields"
dir="$(make_site disabled "$disabled_node")"
if run_validate "$dir"; then
  test_pass "disabled node without AMT fields accepted"
else
  test_fail "disabled node without AMT fields rejected"
fi

test_start "s034.1.9" "regreener defaults require positive integers"
dir="$(make_site bad_timeout "$disabled_node")"
yq -i '.regreener.install_timeout_sec = 0 | .regreener.ssh_timeout_sec = "no"' "${dir}/config.yaml"
if run_validate "$dir"; then
  test_fail "invalid regreener timeouts unexpectedly accepted"
else
  test_pass "invalid regreener timeouts rejected"
fi

test_start "s034.1.10" "bfnet HIL fixture validates without local secrets"
printf 'applications: {}\n' > "${TMP_DIR}/empty-apps.yaml"
if VALIDATE_SITE_CONFIG_CONFIG="${REPO_ROOT}/tests/hil/bfnet/config.yaml" \
   VALIDATE_SITE_CONFIG_APPS_CONFIG="${TMP_DIR}/empty-apps.yaml" \
   "${REPO_ROOT}/framework/scripts/validate-site-config.sh" >/dev/null 2>&1; then
  test_pass "tests/hil/bfnet/config.yaml validates"
else
  test_fail "tests/hil/bfnet/config.yaml failed validation"
fi

test_start "s034.1.11" "placeholder bfnet ISO SHA keeps M2 marked not runnable"
placeholder_sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
bfnet_sha="$(yq -r '.proxmox.installer.iso_sha256 // ""' "${REPO_ROOT}/tests/hil/bfnet/config.yaml")"
bfnet_m2_runnable="$(yq -r '.hil.m2_runnable // false' "${REPO_ROOT}/tests/hil/bfnet/config.yaml")"
if [[ "$bfnet_sha" != "$placeholder_sha" || "$bfnet_m2_runnable" == "false" ]]; then
  test_pass "bfnet fixture does not advertise M2 readiness with placeholder ISO SHA"
else
  test_fail "bfnet fixture advertises M2 runnable while ISO SHA is still placeholder"
fi

test_start "s034.1.12" "enabled regreener nodes require install hardware selectors"
dir="$(make_site missing_install_selectors "$enabled_node")"
yq -i 'del(.nodes[0].install_nic_driver) | del(.nodes[0].install_disk_id_path)' "${dir}/config.yaml"
if run_validate "$dir"; then
  test_fail "missing install selectors unexpectedly accepted"
else
  test_pass "missing install selectors rejected"
fi

runner_summary
