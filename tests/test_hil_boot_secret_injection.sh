#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIG="${REPO_ROOT}/tests/hil/bfnet/config.yaml"
HELPER="${REPO_ROOT}/framework/scripts/hil-boot-secret-env.sh"

test_start "s037.0.4" "missing SOPS_AGE_KEY_FILE fails before secret output"
set +e
missing_output="$(env -u SOPS_AGE_KEY_FILE "$HELPER" "$CONFIG" proxmox_api_password 2>&1)"
missing_rc=$?
set -e
if [[ "$missing_rc" -eq 2 && "$missing_output" == *"SOPS_AGE_KEY_FILE is required"* ]]; then
  test_pass "helper fails fast without SOPS_AGE_KEY_FILE"
else
  test_fail "helper did not fail clearly without SOPS_AGE_KEY_FILE"
fi

test_start "s037.0.5" "fixture key decrypts for derivation input"
if [[ -n "${SOPS_AGE_KEY_FILE:-}" && -r "${SOPS_AGE_KEY_FILE:-}" ]]; then
  if secret="$("$HELPER" "$CONFIG" proxmox_api_password)" && [[ -n "$secret" ]]; then
    test_pass "helper decrypted proxmox_api_password"
  else
    test_fail "helper could not decrypt proxmox_api_password"
  fi
else
  test_skip "SOPS_AGE_KEY_FILE is not set in this environment"
fi

test_start "s037.0.6" "hil-boot ISO derivation requires explicit secret input"
set +e
eval_output="$(cd "$REPO_ROOT" && env -u MYCOFU_HIL_BOOT_ROOT_PASSWORD nix build .#packages.x86_64-linux.hil-boot-bpve02-iso --no-link 2>&1)"
eval_rc=$?
set -e
if [[ "$eval_rc" -ne 0 && ( "$eval_output" == *"cannot connect to socket"*"Operation not permitted"* || "$eval_output" == *"unable to open database file"* ) ]]; then
  test_skip "Nix daemon is not reachable from this sandbox"
elif [[ "$eval_rc" -ne 0 && "$eval_output" == *"MYCOFU_HIL_BOOT_ROOT_PASSWORD"* ]]; then
  test_pass "missing derivation secret is rejected"
else
  test_fail "hil-boot ISO derivation did not reject missing MYCOFU_HIL_BOOT_ROOT_PASSWORD"
fi

test_start "s037.0.7" "plaintext fixture password is not committed"
if git -C "$REPO_ROOT" grep -n 'BfnetLab2026!' -- . ':!docs/**' ':!tests/test_hil_boot_secret_injection.sh' >/tmp/hil-secret-grep.$$ 2>/dev/null; then
  test_fail "plaintext HIL password is committed outside docs"
  sed 's/^/    /' /tmp/hil-secret-grep.$$
else
  test_pass "plaintext HIL password absent from committed non-doc files"
fi
rm -f /tmp/hil-secret-grep.$$

test_start "s037.0.16" "helper surfaces sops decryption stderr"
tmp_dir="$(mktemp -d)"
mkdir -p "$tmp_dir/sops" "$tmp_dir/shims"
printf 'encrypted\n' > "$tmp_dir/sops/secrets.yaml"
printf 'age-secret-key-1fixture\n' > "$tmp_dir/key.txt"
cat > "$tmp_dir/config.yaml" <<EOF
domain: example.test
EOF
cat > "$tmp_dir/shims/sops" <<'EOF'
#!/usr/bin/env bash
printf 'recipient mismatch fixture\n' >&2
exit 1
EOF
chmod +x "$tmp_dir/shims/sops"
set +e
decrypt_output="$(PATH="$tmp_dir/shims:$PATH" SOPS_AGE_KEY_FILE="$tmp_dir/key.txt" "$HELPER" "$tmp_dir/config.yaml" proxmox_api_password 2>&1)"
decrypt_rc=$?
set -e
rm -rf "$tmp_dir"
if [[ "$decrypt_rc" -eq 2 && "$decrypt_output" == *"recipient mismatch fixture"* ]]; then
  test_pass "sops stderr is preserved on decrypt failure"
else
  test_fail "sops decrypt failure did not surface stderr"
  printf '%s\n' "$decrypt_output" >&2
fi

runner_summary
