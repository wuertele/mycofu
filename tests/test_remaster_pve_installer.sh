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

# #317: the stock ISO download must verify SHA256 BEFORE promoting the
# downloaded bytes to the canonical cache name. A corrupt download (good HTTP,
# bad bytes) must fail closed AND leave nothing at the canonical path, so the
# next run re-downloads cleanly instead of re-failing the checksum against a
# poisoned cache forever. These two tests exercise the download-then-promote
# flow (s034.2.6 only covers a local --input-iso, which returns before the
# download path). A curl shim on PATH stands in for the real CDN fetch.
#
# --input-iso points at a non-existent absolute path so resolve_input_iso()
# skips the local-file and cached-file short-circuits and takes the download
# branch, deriving the cache path from the basename.
stock_basename="proxmox-ve_9.1-1.iso"
missing_input="${TMP_DIR}/no-such-dir/${stock_basename}"
canonical_cache="${MYCOFU_REGREENER_CACHE_DIR}/stock/${stock_basename}"
common_iso_args=(
  --fqdn node1.example.test
  --cidr 192.0.2.11/24
  --gateway 192.0.2.1
  --dns 192.0.2.1
  --root-password standalone-secret
  --nic-driver e1000e
  --disk-pci-path pci-0000:00:1d.0-nvme-1
)

install_curl_shim() {
  # $1 = path to a source file the shim copies to curl's -o target.
  local payload="$1"
  cat > "${SHIM_DIR}/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-o" ]]; then out="\$2"; shift 2; continue; fi
  shift
done
[[ -n "\$out" ]] || { echo "curl shim: no -o target" >&2; exit 3; }
cp "${payload}" "\$out"
exit 0
EOF
  chmod +x "${SHIM_DIR}/curl"
}

test_start "s034.2.7" "corrupt stock download is rejected and leaves no poisoned cache file"
corrupt_payload="${TMP_DIR}/corrupt-stock.iso"
corrupt_out="${TMP_DIR}/corrupt-out.iso"
printf 'corrupt bytes that do not match the configured sha256\n' > "$corrupt_payload"
install_curl_shim "$corrupt_payload"
rm -f "$canonical_cache" "${canonical_cache}.partial"
: > "$XORRISO_LOG"
set +e
corrupt_output="$("${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
  --input-iso "$missing_input" \
  --input-iso-sha256 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
  --output-iso "$corrupt_out" \
  "${common_iso_args[@]}" 2>&1)"
corrupt_rc=$?
set -e
rm -f "${SHIM_DIR}/curl"
if [[ "$corrupt_rc" -eq 0 ]]; then
  test_fail "corrupt download unexpectedly accepted (rc=0)"
elif ! grep -Fq 'stock ISO checksum mismatch' <<< "$corrupt_output"; then
  test_fail "expected 'stock ISO checksum mismatch'; got: $corrupt_output"
elif [[ -e "$canonical_cache" ]]; then
  test_fail "corrupt bytes were promoted to the canonical cache name (poisoned cache)"
elif [[ -e "${canonical_cache}.partial" ]]; then
  test_fail ".partial download was left behind after checksum failure"
elif [[ -s "$XORRISO_LOG" ]]; then
  test_fail "xorriso was called despite corrupt download"
elif [[ -e "$corrupt_out" ]]; then
  test_fail "output ISO was produced despite corrupt download"
else
  test_pass "corrupt download rejected before promote; cache self-heals (no poisoned file)"
fi

test_start "s034.2.8" "verified stock download is promoted to the canonical cache name"
good_payload="${TMP_DIR}/good-stock.iso"
good_out="${TMP_DIR}/good-out.iso"
printf 'good stock iso payload for the verify-before-promote happy path\n' > "$good_payload"
# Hash with the same method the script's sha256_file() uses, so the expected
# value is byte-for-byte what the script computes over the shim's payload.
good_sha="$(python3 - "$good_payload" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
install_curl_shim "$good_payload"
rm -f "$canonical_cache" "${canonical_cache}.partial"
: > "$XORRISO_LOG"
set +e
good_output="$("${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
  --input-iso "$missing_input" \
  --input-iso-sha256 "$good_sha" \
  --output-iso "$good_out" \
  "${common_iso_args[@]}" 2>&1)"
good_rc=$?
set -e
rm -f "${SHIM_DIR}/curl"
if [[ "$good_rc" -ne 0 ]]; then
  test_fail "verified download unexpectedly failed (rc=${good_rc}): $good_output"
elif [[ ! -s "$canonical_cache" ]]; then
  test_fail "verified download was not promoted to the canonical cache name"
elif [[ -e "${canonical_cache}.partial" ]]; then
  test_fail ".partial file lingered after successful promote"
elif [[ ! -s "$good_out" ]]; then
  test_fail "output ISO was not produced from the verified download"
else
  test_pass "verified download promoted to canonical cache and remaster proceeded"
fi
rm -f "$canonical_cache" "${canonical_cache}.partial"

# End-to-end self-healing (the core #317 property): a corrupt download followed
# by a corrected one, with NO manual cache cleanup between the two runs. Stage 1
# must fail closed and leave the cache clean; Stage 2 must then re-download and
# promote on its own, proving the operator no longer has to delete a poisoned
# cache file by hand. cmp against the payload proves the canonical file is the
# freshly re-downloaded good bytes, not a lingering poisoned artifact.
test_start "s034.2.9" "corrupt download self-heals: next run re-downloads cleanly without manual cleanup"
heal_out1="${TMP_DIR}/heal-corrupt-out.iso"
heal_out2="${TMP_DIR}/heal-good-out.iso"
heal_payload="${TMP_DIR}/heal-good-stock.iso"
printf 'healthy stock iso payload for the self-heal sequence\n' > "$heal_payload"
heal_sha="$(python3 - "$heal_payload" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
rm -f "$canonical_cache" "${canonical_cache}.partial"
# Stage 1: corrupt bytes under the SAME configured hash -> mismatch -> fail closed.
install_curl_shim "$corrupt_payload"
set +e
"${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
  --input-iso "$missing_input" \
  --input-iso-sha256 "$heal_sha" \
  --output-iso "$heal_out1" \
  "${common_iso_args[@]}" >/dev/null 2>&1
heal_rc1=$?
set -e
rm -f "${SHIM_DIR}/curl"
# Stage 2: corrected bytes, NO cache cleanup performed by the test in between.
install_curl_shim "$heal_payload"
set +e
"${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
  --input-iso "$missing_input" \
  --input-iso-sha256 "$heal_sha" \
  --output-iso "$heal_out2" \
  "${common_iso_args[@]}" >/dev/null 2>&1
heal_rc2=$?
set -e
rm -f "${SHIM_DIR}/curl"
if [[ "$heal_rc1" -eq 0 ]]; then
  test_fail "self-heal stage 1: corrupt download unexpectedly succeeded"
elif [[ "$heal_rc2" -ne 0 ]]; then
  test_fail "self-heal stage 2: clean re-download failed (rc=${heal_rc2}) — cache did not self-heal"
elif [[ ! -s "$canonical_cache" ]]; then
  test_fail "self-heal stage 2: canonical cache was not populated by the re-download"
elif ! cmp -s "$heal_payload" "$canonical_cache"; then
  test_fail "self-heal stage 2: canonical cache does not match the corrected payload (stale poisoned file?)"
elif [[ ! -s "$heal_out2" ]]; then
  test_fail "self-heal stage 2: output ISO not produced from the corrected download"
else
  test_pass "corrupt download self-heals: next run re-downloads and promotes with no manual cleanup"
fi
rm -f "$canonical_cache" "${canonical_cache}.partial"

# #721: with NO configured SHA256 the stock ISO has no integrity anchor at all,
# and the bytes arrive over plain HTTP. "Cannot determine" is not "pass" — the
# script must refuse rather than promote unverified bytes into the cache and on
# into an installer that gets booted on bare metal. Two reachable entries into
# the untrusted-bytes path are covered: a fresh download (7.1) and a cache hit
# from an earlier run (7.2). The curl shim would happily serve bytes in both
# cases, so a regression here is a real promotion of unverified content, not a
# test artifact.
test_start "s034.2.10" "no configured SHA256 refuses the stock download instead of promoting unverified bytes"
nohash_payload="${TMP_DIR}/nohash-stock.iso"
nohash_out="${TMP_DIR}/nohash-out.iso"
printf 'bytes a hostile or broken CDN could have returned\n' > "$nohash_payload"
install_curl_shim "$nohash_payload"
rm -f "$canonical_cache" "${canonical_cache}.partial"
: > "$XORRISO_LOG"
set +e
# No --input-iso-sha256 at all: the standalone-CLI edge the issue describes.
nohash_output="$("${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
  --input-iso "$missing_input" \
  --output-iso "$nohash_out" \
  "${common_iso_args[@]}" 2>&1)"
nohash_rc=$?
set -e
rm -f "${SHIM_DIR}/curl"
if [[ "$nohash_rc" -eq 0 ]]; then
  test_fail "unverified stock download accepted with no configured SHA256 (rc=0)"
elif ! grep -Fq 'without a configured SHA256' <<< "$nohash_output"; then
  test_fail "expected a 'without a configured SHA256' refusal; got: $nohash_output"
elif [[ -e "$canonical_cache" ]]; then
  test_fail "unverified bytes were promoted to the canonical cache name"
elif [[ -e "${canonical_cache}.partial" ]]; then
  test_fail "unverified .partial download was left behind"
elif [[ -s "$XORRISO_LOG" ]]; then
  test_fail "xorriso was called on unverified stock bytes"
elif [[ -e "$nohash_out" ]]; then
  test_fail "an installer ISO was produced from unverified stock bytes"
else
  test_pass "no configured SHA256 fails closed: nothing downloaded, promoted, or built"
fi

# A cache hit serves bytes that a previous run fetched over the same plain HTTP.
# Refusing the fresh fetch but serving the identical unverified bytes from cache
# would leave the defect live, so the guard covers the whole managed-cache path.
test_start "s034.2.11" "no configured SHA256 also refuses a pre-populated stock cache hit"
cachehit_out="${TMP_DIR}/cachehit-out.iso"
mkdir -p "$(dirname "$canonical_cache")"
printf 'unverified bytes left in the cache by an earlier run\n' > "$canonical_cache"
: > "$XORRISO_LOG"
set +e
cachehit_output="$("${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
  --input-iso "$missing_input" \
  --output-iso "$cachehit_out" \
  "${common_iso_args[@]}" 2>&1)"
cachehit_rc=$?
set -e
if [[ "$cachehit_rc" -eq 0 ]]; then
  test_fail "unverified cached stock ISO accepted with no configured SHA256 (rc=0)"
elif ! grep -Fq 'without a configured SHA256' <<< "$cachehit_output"; then
  test_fail "expected a 'without a configured SHA256' refusal; got: $cachehit_output"
elif [[ -s "$XORRISO_LOG" ]]; then
  test_fail "xorriso was called on unverified cached bytes"
elif [[ -e "$cachehit_out" ]]; then
  test_fail "an installer ISO was produced from unverified cached bytes"
else
  test_pass "pre-populated cache with no configured SHA256 fails closed; no ISO built"
fi
rm -f "$canonical_cache" "${canonical_cache}.partial"

# Guard against the fix over-reaching: a locally supplied --input-iso is the
# operator vouching for their own bytes and must still work with no hash. If
# this regresses, the refusal moved above the local short-circuit.
test_start "s034.2.12" "locally supplied --input-iso still works with no configured SHA256"
local_iso="${TMP_DIR}/local-supplied.iso"
local_out="${TMP_DIR}/local-supplied-out.iso"
printf 'operator-supplied local stock iso contents\n' > "$local_iso"
: > "$XORRISO_LOG"
set +e
local_output="$("${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
  --input-iso "$local_iso" \
  --output-iso "$local_out" \
  "${common_iso_args[@]}" 2>&1)"
local_rc=$?
set -e
if [[ "$local_rc" -ne 0 ]]; then
  test_fail "local --input-iso with no SHA256 was refused (rc=${local_rc}): $local_output"
elif [[ ! -s "$local_out" ]]; then
  test_fail "local --input-iso produced no output ISO"
else
  test_pass "local --input-iso path unchanged by the download-path refusal"
fi

# #721 review round 1 (codex P1): in config mode proxmox.installer.iso is the
# CDN artifact's BASENAME, so the `-s "$INPUT_ISO"` local short-circuit
# resolves against the CURRENT WORKING DIRECTORY. Without a required pin, a
# same-named file sitting next to the invocation was remastered in place of
# the real Proxmox installer with no integrity check — a bypass of the whole
# fix, in the mode the regreener actually runs in. This exercises the exact
# repro: cd into a dir containing a decoy named like the configured ISO.
test_start "s034.2.13" "config mode without iso_sha256 refuses instead of remastering a CWD decoy"
nohash_site="${TMP_DIR}/site-nohash"
mkdir -p "${nohash_site}/sops"
printf 'encrypted\n' > "${nohash_site}/sops/secrets.yaml"
sed '/iso_sha256:/d' "${site_dir}/config.yaml" > "${nohash_site}/config.yaml"
if grep -q 'iso_sha256' "${nohash_site}/config.yaml"; then
  test_fail "fixture setup error: iso_sha256 was not removed from the test config"
else
  decoy_dir="${TMP_DIR}/decoy-cwd"
  mkdir -p "$decoy_dir"
  # A decoy named exactly like the configured CDN artifact.
  printf 'decoy bytes that are not the real proxmox installer\n' \
    > "${decoy_dir}/proxmox-ve_9.1-1.iso"
  decoy_out="${TMP_DIR}/decoy-out.iso"
  : > "$XORRISO_LOG"
  set +e
  decoy_output="$(cd "$decoy_dir" && "${REPO_ROOT}/framework/scripts/remaster-pve-installer.sh" \
    --config "${nohash_site}/config.yaml" \
    --node node1 \
    --output-iso "$decoy_out" 2>&1)"
  decoy_rc=$?
  set -e
  if [[ "$decoy_rc" -eq 0 ]]; then
    test_fail "config mode with no iso_sha256 accepted a CWD decoy ISO (rc=0)"
  elif ! grep -Fq 'proxmox.installer.iso_sha256' <<< "$decoy_output"; then
    test_fail "expected a missing-'proxmox.installer.iso_sha256' error; got: $decoy_output"
  elif [[ -s "$XORRISO_LOG" ]]; then
    test_fail "xorriso was called on the unverified CWD decoy"
  elif [[ -e "$decoy_out" ]]; then
    test_fail "an installer ISO was built from the unverified CWD decoy"
  else
    test_pass "config mode requires iso_sha256; CWD decoy never reaches xorriso"
  fi
fi

runner_summary
