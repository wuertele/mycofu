#!/usr/bin/env bash
#
# test_cert_restore_fullchain.sh — verify cert-restore.service writes
# fullchain.pem as the byte-exact concatenation of cert.pem + chain.pem,
# so certbot's fullchain == cert + chain check passes.
#
# The write path lives in framework/nix/modules/certbot.nix
# (`certRestoreScript`). This test extracts the four PEM-write lines
# and the two chmod lines from that module, executes them against
# hermetic fixture inputs, and asserts the byte invariants.
#
# Regression class: without this fixture, a future "cleanup" that
# reverts fullchain to `printf '%s' "$fullchain" > fullchain1.pem`
# would silently restore the field-comparison bug: certbot's
# `verify_fullchain` would fail with "fullchain does not match
# cert + chain", causing lineage skip and blocked renewal.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

CERTBOT_NIX="${REPO_ROOT}/framework/nix/modules/certbot.nix"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# Static ratchet: the module still writes fullchain.pem via cat, not
# from the Vault-stored $fullchain variable.
# ---------------------------------------------------------------------------

test_start "1" "certbot.nix writes fullchain.pem via cat cert1.pem chain1.pem"
if awk '
  /printf .*"\$cert" > "\$archive_dir\/cert1.pem"/ { seen_cert=1; next }
  seen_cert && /printf .*"\$chain" > "\$archive_dir\/chain1.pem"/ { seen_chain=1; next }
  seen_chain && /cat "\$archive_dir\/cert1.pem" "\$archive_dir\/chain1.pem"/ { seen_cat=1 }
  END { exit seen_cat ? 0 : 1 }
' "${CERTBOT_NIX}"; then
  test_pass "cat-reconstruction block present in the expected order"
else
  test_fail "cat-reconstruction block missing or reordered — fullchain may revert to Vault-stored value"
  exit 1
fi

test_start "2" "certbot.nix does NOT write fullchain from the Vault \$fullchain variable"
if grep -qE 'printf .*"\$fullchain".*>.*fullchain1\.pem' "${CERTBOT_NIX}"; then
  test_fail "fullchain1.pem is being written from \$fullchain — this reintroduces the field-comparison bug"
  exit 1
else
  test_pass "no direct \$fullchain write to fullchain1.pem"
fi

# ---------------------------------------------------------------------------
# Behavioral: simulate the module's write block against fixture inputs
# and assert byte-exact fullchain == cert + chain.
# ---------------------------------------------------------------------------

# Extract the write block from certbot.nix. We re-emit it into a temp
# script so any future edit that breaks the byte invariant fails the
# test.
extract_write_block() {
  # Match from the leading comment through the last chmod (privkey1.pem
  # mode). The block is bounded by grep anchors we control.
  awk '
    /# Write each PEM with a trailing newline/ { in_block=1 }
    in_block { print }
    in_block && /chmod 600 "\$archive_dir\/privkey1.pem"/ { exit }
  ' "${CERTBOT_NIX}"
}

WRITE_BLOCK="$(extract_write_block)"

test_start "3" "extracted write block is non-empty and contains all four PEM lines"
if [[ -n "${WRITE_BLOCK}" ]] \
   && grep -q 'cert1\.pem' <<< "${WRITE_BLOCK}" \
   && grep -q 'chain1\.pem' <<< "${WRITE_BLOCK}" \
   && grep -q 'fullchain1\.pem' <<< "${WRITE_BLOCK}" \
   && grep -q 'privkey1\.pem' <<< "${WRITE_BLOCK}"; then
  test_pass "extraction found all four PEM writes"
else
  test_fail "extraction failed — write-block markers may have drifted"
  exit 1
fi

run_write_block() {
  local cert="$1" chain="$2" privkey="$3"
  local archive_dir="${TMP_DIR}/case-$$-$(date +%N)"
  mkdir -p "${archive_dir}"

  # Feed the block into a subshell with the same shell variables the
  # module's certRestoreScript sets. archive_dir is a bash var here.
  bash <<EOF
set -uo pipefail
cert=$(printf '%q' "${cert}")
chain=$(printf '%q' "${chain}")
privkey=$(printf '%q' "${privkey}")
archive_dir=${archive_dir}
${WRITE_BLOCK}
EOF

  echo "${archive_dir}"
}

# Byte-exact comparator: cmp the two file paths.
assert_files_equal() {
  local a="$1" b="$2" label="$3"
  if cmp -s "${a}" "${b}"; then
    test_pass "${label}: byte-equal ($(wc -c < "${a}") bytes)"
  else
    test_fail "${label}: mismatch — $(wc -c < "${a}") vs $(wc -c < "${b}") bytes"
  fi
}

# Case A: Vault-stored blobs have NO trailing newline (canonical case
# after jq -r + $()).
test_start "4a" "canonical case: fullchain1.pem == cert1.pem + chain1.pem byte-exactly"
cert_blob=$'-----BEGIN CERTIFICATE-----\nLEAFAAA\n-----END CERTIFICATE-----'
chain_blob=$'-----BEGIN CERTIFICATE-----\nINTA\n-----END CERTIFICATE-----'
privkey_blob=$'-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----'

archive="$(run_write_block "${cert_blob}" "${chain_blob}" "${privkey_blob}")"
cat "${archive}/cert1.pem" "${archive}/chain1.pem" > "${TMP_DIR}/cat-canonical"
assert_files_equal "${archive}/fullchain1.pem" "${TMP_DIR}/cat-canonical" "canonical"

# Case B: cert1.pem and chain1.pem end with exactly one trailing \n.
test_start "4b" "canonical case: cert1.pem and chain1.pem end with one trailing LF"
last_cert_byte="$(tail -c 1 "${archive}/cert1.pem" | xxd -p)"
last_chain_byte="$(tail -c 1 "${archive}/chain1.pem" | xxd -p)"
if [[ "${last_cert_byte}" == "0a" && "${last_chain_byte}" == "0a" ]]; then
  test_pass "both PEM component files end with LF"
else
  test_fail "trailing byte: cert=0x${last_cert_byte}, chain=0x${last_chain_byte} (expected 0x0a)"
fi

# Case C: PEM chain with multiple intermediates (chain.pem containing
# two CERTIFICATE blocks). The fullchain must byte-equal cert + chain
# regardless of how many certs are in the chain.
test_start "5" "multi-cert chain: fullchain == cert + chain"
cert_blob=$'-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----'
chain_blob=$'-----BEGIN CERTIFICATE-----\nINT1\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nINT2\n-----END CERTIFICATE-----'
privkey_blob=$'-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----'

archive="$(run_write_block "${cert_blob}" "${chain_blob}" "${privkey_blob}")"
cat "${archive}/cert1.pem" "${archive}/chain1.pem" > "${TMP_DIR}/cat-multi"
assert_files_equal "${archive}/fullchain1.pem" "${TMP_DIR}/cat-multi" "multi-cert chain"

# Case D: Vault-stored blob already has a trailing newline (defensive
# case — should still produce a byte-equal fullchain).
test_start "6" "blob already has trailing newline: fullchain still == cert + chain"
cert_blob=$'-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n'
chain_blob=$'-----BEGIN CERTIFICATE-----\nINT\n-----END CERTIFICATE-----\n'
privkey_blob=$'-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----\n'

archive="$(run_write_block "${cert_blob}" "${chain_blob}" "${privkey_blob}")"
cat "${archive}/cert1.pem" "${archive}/chain1.pem" > "${TMP_DIR}/cat-newlined"
assert_files_equal "${archive}/fullchain1.pem" "${TMP_DIR}/cat-newlined" "already-newlined blob"

# Case E: PEM content contains characters that could be shell
# metacharacters ($, backtick, quote). Since printf '%s\n' is used
# with a quoted expansion, these must be preserved as data, not
# interpreted or executed.
test_start "7" "shell metachars in PEM content are preserved verbatim"
cert_blob=$'-----BEGIN CERTIFICATE-----\nAAA$(rm -rf /)`BBB`CCC\n-----END CERTIFICATE-----'
chain_blob=$'-----BEGIN CERTIFICATE-----\nDDD\n-----END CERTIFICATE-----'
privkey_blob=$'-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----'

archive="$(run_write_block "${cert_blob}" "${chain_blob}" "${privkey_blob}")"
printf '%s\n' "${cert_blob}" > "${TMP_DIR}/expected-cert-metachar"
assert_files_equal "${archive}/cert1.pem" "${TMP_DIR}/expected-cert-metachar" "shell metachars preserved"

# Case F: fullchain must ALSO equal cert + chain in the metachar case.
test_start "8" "shell-metachar case: fullchain == cert + chain"
cat "${archive}/cert1.pem" "${archive}/chain1.pem" > "${TMP_DIR}/cat-metachar"
assert_files_equal "${archive}/fullchain1.pem" "${TMP_DIR}/cat-metachar" "metachar fullchain"
