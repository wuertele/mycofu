#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIG="${REPO_ROOT}/tests/hil/bfnet/config.yaml"
HELPER="${REPO_ROOT}/framework/scripts/hil-boot-secret-env.sh"

nix_unavailable() {
  [[ "$1" == *"cannot connect to socket"*"Operation not permitted"* || "$1" == *"unable to open database file"* ]]
}

# s037.0.8 (real ISO build) moved to tests/test_hil_boot_iso_real_build.sh.
# The build pulls a 1.4 GB upstream PVE ISO via fetchurl and runs xorriso
# extract+repack — it does not belong in the validate stage. The build
# stage's hil-boot image job exercises the same derivation transitively.

test_start "s037.0.16" "hil-boot image gets extra filesystem headroom"
if grep -q 'imageAdditionalSpaceFor = role:' "${REPO_ROOT}/flake.nix" && \
   grep -q 'role == "hil-boot" then "8G"' "${REPO_ROOT}/flake.nix" && \
   grep -q 'additionalSpace = imageAdditionalSpaceFor role' "${REPO_ROOT}/flake.nix"; then
  test_pass "hil-boot image uses role-specific make-disk-image slack"
else
  test_fail "hil-boot image does not have explicit additionalSpace headroom"
fi

test_start "s037.0.17" "hil-boot runtime disk leaves room above image slack"
hil_extra_gb="$(sed -n 's/.*role == "hil-boot" then "\([0-9][0-9]*\)G".*/\1/p' "${REPO_ROOT}/flake.nix" | head -1)"
hil_runtime_gb="$(awk '/module "hil_boot"/{flag=1} flag && /vda_size_gb/{print $3; exit}' "${REPO_ROOT}/framework/tofu/root/main.tf")"
if [[ "${hil_extra_gb}" =~ ^[0-9]+$ && "${hil_runtime_gb}" =~ ^[0-9]+$ ]] && \
   (( hil_runtime_gb >= hil_extra_gb + 24 )); then
  test_pass "hil-boot runtime disk (${hil_runtime_gb}G) remains larger than image slack (${hil_extra_gb}G) plus fixed overhead"
else
  test_fail "hil-boot runtime disk must be increased when image slack grows"
fi

test_start "s037.0.18" "hil-boot build checks qcow2 virtual size against runtime disk"
if grep -q 'check-hil-boot-image-size.sh" "$QCOW2_FILE"' "${REPO_ROOT}/framework/scripts/build-image.sh" && \
   [[ -x "${REPO_ROOT}/framework/scripts/check-hil-boot-image-size.sh" ]]; then
  test_pass "hil-boot image build invokes the runtime disk size guard"
else
  test_fail "hil-boot image build must verify qcow2 virtual size"
fi

test_start "s037.0.19" "hil-boot image size guard fails when virtual image reaches runtime disk"
guard_tmp="$(mktemp -d "${TMPDIR:-/tmp}/hil-image-size.XXXXXX")"
cleanup_guard_tmp() {
  rm -rf "$guard_tmp"
}
trap cleanup_guard_tmp EXIT
touch "${guard_tmp}/hil-boot.qcow2"
mkdir -p "${guard_tmp}/bin"
cat > "${guard_tmp}/bin/qemu-img" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "info" && "$2" == "--output=json" ]]; then
  printf '{"virtual-size": %s}\n' "${FAKE_QEMU_IMG_VIRTUAL_SIZE:?}"
  exit 0
fi
exit 2
EOF
chmod +x "${guard_tmp}/bin/qemu-img"
runtime_bytes=$((hil_runtime_gb * 1073741824))
safe_bytes=$(((hil_runtime_gb - 2) * 1073741824))
if PATH="${guard_tmp}/bin:${PATH}" FAKE_QEMU_IMG_VIRTUAL_SIZE="$safe_bytes" \
     "${REPO_ROOT}/framework/scripts/check-hil-boot-image-size.sh" "${guard_tmp}/hil-boot.qcow2" >/dev/null && \
   ! PATH="${guard_tmp}/bin:${PATH}" FAKE_QEMU_IMG_VIRTUAL_SIZE="$runtime_bytes" \
     "${REPO_ROOT}/framework/scripts/check-hil-boot-image-size.sh" "${guard_tmp}/hil-boot.qcow2" >/dev/null 2>&1; then
  test_pass "hil-boot image size guard accepts safe images and rejects images without runtime margin"
else
  test_fail "hil-boot image size guard did not enforce the runtime disk margin"
fi
cleanup_guard_tmp
trap - EXIT

test_start "s037.0.9" "all six per-node ISO package names are exposed"
set +e
names_stderr="$(mktemp "${TMPDIR:-/tmp}/nix-eval-stderr.XXXXXX")"
names_output="$(cd "$REPO_ROOT" && nix eval .#packages.x86_64-linux --apply 'attrs: builtins.attrNames attrs' --json 2>"$names_stderr")"
names_rc=$?
set -e
names_err="$(cat "$names_stderr")"; rm -f "$names_stderr"
if [[ "$names_rc" -ne 0 ]] && nix_unavailable "$names_err"; then
  test_skip "Nix daemon is not reachable from this sandbox"
elif names="$(jq -r '.[]' <<< "$names_output" | grep '^hil-boot-bpve[0-9][0-9]-iso$' | sort)" && \
   [[ "$(wc -l <<< "$names" | tr -d ' ')" == "6" ]]; then
  test_pass "six hil-boot-bpveNN-iso packages exposed"
else
  test_fail "expected six hil-boot-bpveNN-iso packages"
fi

test_start "s037.0.13" "PVE ISO pin is read from tests/hil config"
if grep -q 'pveIsoSha256 = firstValue "iso_sha256"' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
   grep -q 'pveIsoName = firstValue "iso"' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
   ! grep -q 'proxmox-ve_9.1-1.iso' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
   ! grep -q 'bY9a/HjAxmgS1ycs3nyLmL5+tUQBzrBFQA2wXrWubSI=' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix"; then
  test_pass "hil-boot artifacts derive stock ISO URL and hash from HIL config"
else
  test_fail "hil-boot artifacts still hardcode the stock ISO URL or hash"
fi

test_start "s037.0.15" "enabled nodeNames are derived from tests/hil config"
if grep -q 'nodeNames = parseEnabledNodeNames' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
   ! grep -q '"bpve01"' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix"; then
  test_pass "hil-boot artifacts derive nodeNames from regreen_enabled nodes"
else
  test_fail "hil-boot artifacts still hardcode bpve nodeNames"
fi

test_start "s037.0.14" "mutating proxmox.installer.iso_sha256 changes ISO derivation"
set +e
before_stderr="$(mktemp "${TMPDIR:-/tmp}/nix-eval-stderr.XXXXXX")"
before_drv="$(cd "$REPO_ROOT" && nix eval --impure --raw .#packages.x86_64-linux.hil-boot-bpve02-iso.drvPath 2>"$before_stderr")"
before_rc=$?
set -e
before_err="$(cat "$before_stderr")"; rm -f "$before_stderr"
if [[ "$before_rc" -ne 0 ]] && nix_unavailable "$before_err"; then
  test_skip "Nix daemon is not reachable from this sandbox"
elif [[ "$before_rc" -ne 0 ]]; then
  test_fail "initial ISO derivation evaluation failed"
  printf '%s\n' "$before_err" >&2
else
  backup="$(mktemp "${TMPDIR:-/tmp}/hil-iso-config.XXXXXX.yaml")"
  cp "$CONFIG" "$backup"
  restore_config() {
    cp "$backup" "$CONFIG"
    rm -f "$backup"
  }
  trap restore_config EXIT

  yq -i '.proxmox.installer.iso_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$CONFIG"

  set +e
  after_stderr="$(mktemp "${TMPDIR:-/tmp}/nix-eval-stderr.XXXXXX")"
  after_drv="$(cd "$REPO_ROOT" && nix eval --impure --raw .#packages.x86_64-linux.hil-boot-bpve02-iso.drvPath 2>"$after_stderr")"
  after_rc=$?
  set -e
  after_err="$(cat "$after_stderr")"; rm -f "$after_stderr"

  restore_config
  trap - EXIT

  if [[ "$after_rc" -ne 0 ]]; then
    test_fail "mutated ISO derivation evaluation failed"
    printf '%s\n' "$after_err" >&2
  elif [[ "$before_drv" != "$after_drv" ]]; then
    test_pass "ISO derivation changes when config iso_sha256 changes"
  else
    test_fail "ISO derivation did not change after config iso_sha256 mutation"
  fi
fi

runner_summary
