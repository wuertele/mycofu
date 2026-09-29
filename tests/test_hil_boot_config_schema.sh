#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATOR="${REPO_ROOT}/framework/scripts/validate-site-config.sh"

test_start "s037.3.7" "site config accepts vms.hil_boot"
if "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_pass "site/config.yaml validates with vms.hil_boot"
else
  test_fail "site/config.yaml failed validation with vms.hil_boot"
  sed 's/^/    /' /tmp/hil-config-schema.$$
fi
rm -f /tmp/hil-config-schema.$$

test_start "s037.5.1" "bfnet HIL config accepts PDU schema and outlets"
if VALIDATE_SITE_CONFIG_CONFIG="${REPO_ROOT}/tests/hil/bfnet/config.yaml" "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_pass "tests/hil/bfnet/config.yaml validates with pdu and pdu_outlet data"
else
  test_fail "bfnet HIL config failed PDU validation"
  sed 's/^/    /' /tmp/hil-config-schema.$$
fi
rm -f /tmp/hil-config-schema.$$

test_start "s037.3.8" "hil_boot backup true is rejected"
tmp="$(mktemp "${TMPDIR:-/tmp}/hil-site-config.XXXXXX.yaml")"
cp "${REPO_ROOT}/site/config.yaml" "$tmp"
yq -i '.vms.hil_boot.backup = true' "$tmp"
if VALIDATE_SITE_CONFIG_CONFIG="$tmp" "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_fail "backup:true hil_boot config unexpectedly passed"
else
  test_pass "backup:true hil_boot config rejected"
fi
rm -f "$tmp" /tmp/hil-config-schema.$$

test_start "s037.3.9" "hil_boot malformed MAC is rejected"
tmp="$(mktemp "${TMPDIR:-/tmp}/hil-site-config.XXXXXX.yaml")"
cp "${REPO_ROOT}/site/config.yaml" "$tmp"
yq -i '.vms.hil_boot.mac = "not-a-mac"' "$tmp"
if VALIDATE_SITE_CONFIG_CONFIG="$tmp" "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_fail "malformed hil_boot MAC unexpectedly passed"
else
  test_pass "malformed hil_boot MAC rejected"
fi
rm -f "$tmp" /tmp/hil-config-schema.$$

test_start "s039.1" "hil_boot taxonomy drift is rejected"
tmp_manifest="$(mktemp "${TMPDIR:-/tmp}/hil-site-images.XXXXXX.yaml")"
cp "${REPO_ROOT}/site/images.yaml" "$tmp_manifest"
yq -i '.roles."hil-boot".control_plane = true' "$tmp_manifest"
if VM_SCOPE_SITE_MANIFEST="$tmp_manifest" "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_fail "control_plane:true hil_boot taxonomy unexpectedly passed"
else
  if grep -q 'hil-boot as scope=shared control_plane=false' /tmp/hil-config-schema.$$; then
    test_pass "control_plane:true hil_boot taxonomy rejected"
  else
    test_fail "hil_boot taxonomy failed for the wrong reason"
    sed 's/^/    /' /tmp/hil-config-schema.$$
  fi
fi
rm -f "$tmp_manifest" /tmp/hil-config-schema.$$

test_start "s037.5.2" "missing PDU outlet is rejected for enabled HIL nodes"
tmp="$(mktemp "${TMPDIR:-/tmp}/hil-pdu-config.XXXXXX.yaml")"
cp "${REPO_ROOT}/tests/hil/bfnet/config.yaml" "$tmp"
yq -i 'del(.nodes[1].pdu_outlet)' "$tmp"
if VALIDATE_SITE_CONFIG_CONFIG="$tmp" "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_fail "missing pdu_outlet unexpectedly passed"
else
  test_pass "missing pdu_outlet rejected"
fi
rm -f "$tmp" /tmp/hil-config-schema.$$

test_start "s037.5.3" "duplicate PDU outlet is rejected"
tmp="$(mktemp "${TMPDIR:-/tmp}/hil-pdu-config.XXXXXX.yaml")"
cp "${REPO_ROOT}/tests/hil/bfnet/config.yaml" "$tmp"
yq -i '.nodes[2].pdu_outlet = .nodes[1].pdu_outlet' "$tmp"
if VALIDATE_SITE_CONFIG_CONFIG="$tmp" "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_fail "duplicate pdu_outlet unexpectedly passed"
else
  test_pass "duplicate pdu_outlet rejected"
fi
rm -f "$tmp" /tmp/hil-config-schema.$$

test_start "s037.5.4" "missing PDU password ref is rejected"
tmp="$(mktemp "${TMPDIR:-/tmp}/hil-pdu-config.XXXXXX.yaml")"
cp "${REPO_ROOT}/tests/hil/bfnet/config.yaml" "$tmp"
yq -i 'del(.pdu.password_ref)' "$tmp"
if VALIDATE_SITE_CONFIG_CONFIG="$tmp" "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_fail "missing pdu.password_ref unexpectedly passed"
else
  test_pass "missing pdu.password_ref rejected"
fi
rm -f "$tmp" /tmp/hil-config-schema.$$

test_start "s037.5.5" "malformed PVE ISO hash is rejected"
tmp="$(mktemp "${TMPDIR:-/tmp}/hil-pve-config.XXXXXX.yaml")"
cp "${REPO_ROOT}/tests/hil/bfnet/config.yaml" "$tmp"
yq -i '.proxmox.installer.iso_sha256 = "not-a-sha"' "$tmp"
if VALIDATE_SITE_CONFIG_CONFIG="$tmp" "$VALIDATOR" >/tmp/hil-config-schema.$$ 2>&1; then
  test_fail "malformed PVE ISO hash unexpectedly passed"
else
  test_pass "malformed PVE ISO hash rejected"
fi
rm -f "$tmp" /tmp/hil-config-schema.$$

runner_summary
