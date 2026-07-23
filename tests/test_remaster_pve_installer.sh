#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "$SHIM_DIR"
XORRISO_LOG="${TMP_DIR}/xorriso.log"
MODE_CAPTURE="${TMP_DIR}/auto-installer-mode.toml"

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" && "${3:-}" == '["proxmox_api_password"]' ]]; then
  printf 'supersecret-root\n'
  exit 0
fi
echo "unexpected sops invocation: $*" >&2
exit 1
EOF
chmod +x "${SHIM_DIR}/sops"

cat > "${SHIM_DIR}/xorriso" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${XORRISO_LOG}"

if [[ "${1:-}" == "-osirrox" ]]; then
  dest="${@: -1}"
  mkdir -p "${dest}/boot/grub/i386-pc"
  printf 'eltorito\n' > "${dest}/boot/grub/i386-pc/eltorito.img"
  printf 'efi\n' > "${dest}/efi.img"
  exit 0
fi

if [[ "${1:-}" == "-as" && "${2:-}" == "mkisofs" ]]; then
  out=""
  src="${@: -1}"
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then
      out="$2"
      shift 2
      continue
    fi
    shift
  done
  [[ -n "$out" ]] || exit 98
  if [[ -f "${src}/auto-installer-mode.toml" ]]; then
    cp "${src}/auto-installer-mode.toml" "${MODE_CAPTURE:?}"
  fi
  printf 'remastered iso\n' > "$out"
  if [[ "${XORRISO_FAIL_MKISOFS:-0}" == "1" ]]; then
    exit 42
  fi
  exit 0
fi

echo "unexpected xorriso invocation: $*" >&2
exit 99
EOF
chmod +x "${SHIM_DIR}/xorriso"

export PATH="${SHIM_DIR}:${PATH}"
export XORRISO_LOG MODE_CAPTURE

# Hermetic isolation: keep the regreener cache and xorriso scratch space
# out of the operator's repo and off the canonical /nix paths; disable
# auto-GC (no real Nix store present in this test environment).
export MYCOFU_REGREENER_CACHE_DIR="${TMP_DIR}/regreener-cache"
export MYCOFU_REGREENER_WORK_ROOT="${TMP_DIR}/regreener-work"
export MYCOFU_REGREENER_SKIP_GC=1
mkdir -p "$MYCOFU_REGREENER_WORK_ROOT"

make_config() {
  local dir="$1"
  mkdir -p "${dir}/sops"
  printf 'encrypted\n' > "${dir}/sops/secrets.yaml"
  cat > "${dir}/config.yaml" <<'EOF'
domain: example.test
timezone: "UTC"
email:
  to: ops@example.test
management:
  subnet: 192.0.2.0/24
  gateway: 192.0.2.1
proxmox:
  installer:
    iso: proxmox-ve_9.1-1.iso
    iso_sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    expected_version: "pve-manager/9.1"
    filesystem: ext4
    reboot_mode: reboot
nodes:
  - name: node1
    mgmt_ip: 192.0.2.11
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
    install_filesystem: ext4
EOF
}

run_remaster() {
  local output rc
  set +e
  output="$("${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" "$@" 2>&1)"
  rc=$?
  set -e
  REMASTER_OUTPUT="$output"
  return "$rc"
}

test_start "s034.2.1" "config dry-run renders redacted answer and does not call xorriso"
site_dir="${TMP_DIR}/site"
make_config "$site_dir"
: > "$XORRISO_LOG"
if run_remaster --config "${site_dir}/config.yaml" --node node1 --dry-run; then
  if grep -Fq 'root-password = "***REDACTED***"' <<< "$REMASTER_OUTPUT" && \
     ! grep -q 'supersecret-root' <<< "$REMASTER_OUTPUT" && \
     [[ ! -s "$XORRISO_LOG" ]]; then
    test_pass "dry-run rendered redacted TOML without ISO side effects"
  else
    test_fail "dry-run leaked secret or called xorriso"
  fi
else
  test_fail "config dry-run failed"
  printf '%s\n' "$REMASTER_OUTPUT" >&2
fi

test_start "s034.2.2" "--print-output-iso emits content-addressed cache path only"
if run_remaster --config "${site_dir}/config.yaml" --node node1 --print-output-iso; then
  if [[ "$REMASTER_OUTPUT" == "${MYCOFU_REGREENER_CACHE_DIR}/isos/pve-node1-"*.iso ]]; then
    test_pass "--print-output-iso returned a pve-node1 cache path"
  else
    test_fail "unexpected output path: ${REMASTER_OUTPUT}"
  fi
else
  test_fail "--print-output-iso failed"
fi

test_start "s034.2.3" "standalone explicit CLI path builds with xorriso"
fake_iso="${TMP_DIR}/stock.iso"
out_iso="${TMP_DIR}/out.iso"
pw_file="${TMP_DIR}/root-password"
printf 'fake stock iso\n' > "$fake_iso"
printf 'standalone-secret\n' > "$pw_file"
: > "$XORRISO_LOG"
: > "$MODE_CAPTURE"
if run_remaster \
  --input-iso "$fake_iso" \
  --output-iso "$out_iso" \
  --fqdn node1.example.test \
  --cidr 192.0.2.11/24 \
  --gateway 192.0.2.1 \
  --dns 192.0.2.1 \
  --root-password-file "$pw_file" \
  --nic-driver e1000e \
  --disk-pci-path pci-0000:00:1d.0-nvme-1; then
  if [[ -s "$out_iso" ]] && grep -q -- '-as mkisofs' "$XORRISO_LOG"; then
    test_pass "standalone mode created the requested ISO"
  else
    test_fail "standalone mode did not create ISO or did not call mkisofs"
  fi
else
  test_fail "standalone mode failed"
  printf '%s\n' "$REMASTER_OUTPUT" >&2
fi

test_start "s037.19.1" "canonical auto-installer mode TOML is embedded"
expected_mode="${TMP_DIR}/expected-mode.toml"
printf 'mode = "iso"\npartition_label = "proxmox-ais"\n\n[http]\n' > "$expected_mode"
if diff -u "$expected_mode" "$MODE_CAPTURE" >/dev/null; then
  test_pass "mode TOML uses canonical paia schema"
else
  test_fail "mode TOML is not canonical"
  diff -u "$expected_mode" "$MODE_CAPTURE" >&2 || true
fi

test_start "s037.19.2" "remaster helper no longer references deleted regreener-host module"
if ! grep -q 'regreener-host.nix\|executes on cicd' "${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" && \
   grep -q 'MYCOFU_REGREENER_CACHE_DIR' "${REPO_ROOT}/framework/scripts/README.md" && \
   grep -q 'MYCOFU_REGREENER_WORK_ROOT' "${REPO_ROOT}/framework/scripts/README.md"; then
  test_pass "remaster helper points to hil-boot era overrides"
else
  test_fail "remaster helper or README still references deleted regreener-host path"
fi

test_start "s034.2.4" "invalid filesystem fails before xorriso"
: > "$XORRISO_LOG"
if run_remaster \
  --input-iso "$fake_iso" \
  --output-iso "${TMP_DIR}/bad.iso" \
  --fqdn node1.example.test \
  --cidr 192.0.2.11/24 \
  --gateway 192.0.2.1 \
  --dns 192.0.2.1 \
  --root-password standalone-secret \
  --nic-driver e1000e \
  --disk-pci-path pci-0000:00:1d.0-nvme-1 \
  --filesystem btrfs; then
  test_fail "invalid filesystem unexpectedly accepted"
else
  if [[ ! -s "$XORRISO_LOG" ]]; then
    test_pass "invalid filesystem rejected before xorriso"
  else
    test_fail "xorriso was called despite invalid filesystem"
  fi
fi

test_start "s034.2.5" "failed remaster removes partial output"
partial_iso="${TMP_DIR}/partial.iso"
: > "$XORRISO_LOG"
if XORRISO_FAIL_MKISOFS=1 run_remaster \
  --input-iso "$fake_iso" \
  --output-iso "$partial_iso" \
  --fqdn node1.example.test \
  --cidr 192.0.2.11/24 \
  --gateway 192.0.2.1 \
  --dns 192.0.2.1 \
  --root-password standalone-secret \
  --nic-driver e1000e \
  --disk-pci-path pci-0000:00:1d.0-nvme-1; then
  test_fail "failing xorriso unexpectedly succeeded"
else
  if [[ ! -e "$partial_iso" ]]; then
    test_pass "partial output ISO was removed after failure"
  else
    test_fail "partial output ISO still exists"
  fi
fi

# The HTTP-only stock ISO download (no TLS validation; download.proxmox.com
# presents a cert for enterprise.proxmox.com only) leans on verify_input_iso()
# as the sole integrity anchor. This test guards that anchor against silent
# regression.
test_start "s034.2.6" "stock ISO SHA mismatch rejects before xorriso"
mismatch_iso="${TMP_DIR}/mismatch-stock.iso"
mismatch_out="${TMP_DIR}/mismatch-out.iso"
printf 'arbitrary stock ISO contents for sha-mismatch test\n' > "$mismatch_iso"
: > "$XORRISO_LOG"
set +e
mismatch_output="$("${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
  --input-iso "$mismatch_iso" \
  --input-iso-sha256 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
  --output-iso "$mismatch_out" \
  --fqdn node1.example.test \
  --cidr 192.0.2.11/24 \
  --gateway 192.0.2.1 \
  --dns 192.0.2.1 \
  --root-password standalone-secret \
  --nic-driver e1000e \
  --disk-pci-path pci-0000:00:1d.0-nvme-1 2>&1)"
mismatch_rc=$?
set -e
if [[ "$mismatch_rc" -eq 0 ]]; then
  test_fail "SHA mismatch unexpectedly accepted (rc=0)"
elif ! grep -Fq 'stock ISO checksum mismatch' <<< "$mismatch_output"; then
  test_fail "expected 'stock ISO checksum mismatch' in stderr; got: $mismatch_output"
elif [[ -s "$XORRISO_LOG" ]]; then
  test_fail "xorriso was called despite SHA mismatch"
elif [[ -e "$mismatch_out" ]]; then
  test_fail "output ISO was produced despite SHA mismatch"
else
  test_pass "SHA mismatch rejected before xorriso, no output produced"
fi

runner_summary
