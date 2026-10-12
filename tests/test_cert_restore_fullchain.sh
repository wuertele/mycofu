#!/usr/bin/env bash
#
# test_cert_restore_fullchain.sh — verify cert-restore.service writes
# fullchain.pem as the byte-exact concatenation of cert.pem + chain.pem,
# so certbot's fullchain == cert + chain check passes.
#
# The write path lives in framework/nix/modules/certbot.nix
# (`certRestoreScript`). This test extracts the four PEM-write lines
# and the two chmod lines from that module, executes them against
# hermetic fixture inputs, and asserts the byte invariants. It also runs
# the complete restore script through delayed Vault readiness to the
# persisted lineage and initial-issuance decision (#1035).
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

# #1035: run the COMPLETE restore script, including main and its final exit,
# under a simulated clock. Keep production loops and the 300s budget intact.
# Substitutions: Nix's makeBinPath becomes the fixture's existing PATH; the
# auth/cleanup/cert-sync references become inert fixture paths (only written
# into renewal.conf); Nix's escaped Bash interpolations become literal ${...}.
extract_restore_script() {
  awk -v nix_end="  '';" '
    /certRestoreScript = pkgs.writeShellScript/ { in_script=1; next }
    in_script && $0 == nix_end { exit }
    in_script { print }
  ' "${CERTBOT_NIX}" | sed \
    -e '/export PATH=${lib.makeBinPath \[/,/]}:\$PATH/c\
    export PATH="$FIXTURE_PATH"\
' \
    -e 's|${authHook}|/fixture/auth-hook|g' \
    -e 's|${cleanupHook}|/fixture/cleanup-hook|g' \
    -e 's|${certSyncTool}|/fixture/cert-sync|g' \
    -e "s/''[$]/$/g"
}
extract_restore_script > "${TMP_DIR}/cert-restore.sh"
bash -n "${TMP_DIR}/cert-restore.sh"

# Extract the real issuance condition's final path assignment and predicate;
# FQDN is supplied by the same fixture secret used by the complete restore.
awk '
  /ExecCondition = pkgs.writeShellScript "certbot-check-needed"/ { in_condition=1 }
  in_condition && /CERT="/ { print }
  in_condition && /\[ ! -s "\$CERT" \]/ { print; exit }
' "${CERTBOT_NIX}" | sed "s/''[$]/$/g" > "${TMP_DIR}/initial-condition.sh"
test -s "${TMP_DIR}/initial-condition.sh"

# The script uses GNU date -d on NixOS. On macOS use installed GNU date;
# neither clock parsing nor expiry validation is mocked.
DATE_BIN="$(command -v gdate || command -v date)"
FIXTURE_PATH="$PATH"
FQDN="restore.fixture.invalid"
ACME_SERVER="https://acme.fixture.invalid/directory"
not_after="$($DATE_BIN -u -d '+90 days' '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' 'fixture leaf' > "${TMP_DIR}/expected-cert"
printf '%s\n' 'fixture chain' > "${TMP_DIR}/expected-chain"
printf '%s\n' 'fixture private key' > "${TMP_DIR}/expected-privkey"
cat "${TMP_DIR}/expected-cert" "${TMP_DIR}/expected-chain" > "${TMP_DIR}/expected-fullchain"
jq -n --arg not_after "$not_after" \
  '{data:{data:{cert:"fixture leaf", chain:"fixture chain",
    fullchain:"fixture leaf\nfixture chain", privkey:"fixture private key",
    not_after:$not_after}}}' > "${TMP_DIR}/lineage.json"

run_restore_case() {
  local case_name="$1" token_at="$2" lookup_mode="$3"
  CASE_DIR="${TMP_DIR}/${case_name}"
  mkdir -p "${CASE_DIR}/run/vault-agent" "${CASE_DIR}/run/secrets/certbot"
  printf '%s\n' "$FQDN" > "${CASE_DIR}/run/secrets/certbot/fqdn"
  printf '%s\n' "$ACME_SERVER" > "${CASE_DIR}/run/secrets/certbot/acme-server-url"
  printf '0\n' > "${CASE_DIR}/calls"
  if [[ "$case_name" == whitespace ]]; then
    printf ' \t\n' > "${CASE_DIR}/run/vault-agent/token"
  elif [[ "$token_at" -eq 0 ]]; then
    printf 'fixture-token\n' > "${CASE_DIR}/run/vault-agent/token"
  fi

  # Redirect all absolute runtime inputs/outputs under this case's temp dir:
  # token, certbot secrets, fallback search-domain/resolv.conf, and the entire
  # letsencrypt tree (including paths embedded in renewal.conf and symlinks).
  sed -e "s|/run/vault-agent/token|${CASE_DIR}/run/vault-agent/token|g" \
      -e "s|/run/secrets/|${CASE_DIR}/run/secrets/|g" \
      -e "s|/etc/resolv.conf|${CASE_DIR}/resolv.conf|g" \
      -e "s|/etc/letsencrypt|${CASE_DIR}/letsencrypt|g" \
      "${TMP_DIR}/cert-restore.sh" > "${CASE_DIR}/restore.sh"
  sed "s|/etc/letsencrypt|${CASE_DIR}/letsencrypt|g" \
      "${TMP_DIR}/initial-condition.sh" > "${CASE_DIR}/initial-condition.sh"

  local restore_status=0
  (
    # Match production's lack of errexit; source executes its unchanged main.
    set +e
    trap 'printf "%s\n" "$((SECONDS - clock_started))" > "${CASE_DIR}/elapsed"' EXIT
    SECONDS=0
    clock_started=$SECONDS
    date() { "$DATE_BIN" "$@"; }
    sleep() {
      SECONDS=$((SECONDS + $1))
      if [[ "$token_at" -ge 0 && "$((SECONDS - clock_started))" -ge "$token_at" ]]; then
        printf 'fixture-token\n' > "${CASE_DIR}/run/vault-agent/token"
      fi
    }
    curl() {
      # Command substitution runs curl in a subshell: keep counts on disk.
      local count format="" header=""
      count=$(< "${CASE_DIR}/calls")
      count=$((count + 1))
      printf '%s\n' "$count" > "${CASE_DIR}/calls"
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          -w) format="$2"; shift ;;
          -H) header="$2"; shift ;;
        esac
        shift
      done
      if [[ "$format" != '\n%{http_code}' || "$header" != 'X-Vault-Token: fixture-token' ]]; then
        echo 'invalid curl write-out contract or token' > "${CASE_DIR}/shim-error"
        return 2
      fi
      case "$lookup_mode:$count" in
        sequence:1|unavailable:*) return 7 ;;
        sequence:2) printf '%s\n503' '{"errors":["sealed"]}' ;;
        sequence:3) printf '%s\n429' '{"errors":["rate limited"]}' ;;
        missing:*) printf '%s\n404' '{"errors":["not found"]}' ;;
        denied:*) printf '%s\n403' '{"errors":["permission denied"]}' ;;
        *) printf '%s\n200' "$(cat "${TMP_DIR}/lineage.json")" ;;
      esac
    }
    source "${CASE_DIR}/restore.sh"
  ) > "${CASE_DIR}/log" 2>&1 || restore_status=$?

  if [[ "$restore_status" -ne 0 || -e "${CASE_DIR}/shim-error" ]] ||
     grep -q 'restore encountered an error' "${CASE_DIR}/log"; then
    cat "${CASE_DIR}/log"
    test_fail "$case_name: restore exited $restore_status or shim/main failed"
    exit 1
  fi
  test_pass "$case_name: return 0; elapsed=$(< "${CASE_DIR}/elapsed")s; lookups=$(< "${CASE_DIR}/calls")"
}

assert_restored() {
  local part live="${CASE_DIR}/letsencrypt/live/${FQDN}"
  for part in cert chain privkey fullchain; do
    assert_files_equal "$live/$part.pem" "${TMP_DIR}/expected-$part" "restored $part"
    if [[ -L "$live/$part.pem" && "$(readlink "$live/$part.pem")" == "../../archive/$FQDN/${part}1.pem" ]]; then
      test_pass "$part: live symlink targets restored archive"
    else
      test_fail "$part: missing or incorrect symlink"
    fi
  done
  local conf="${CASE_DIR}/letsencrypt/renewal/${FQDN}.conf"
  if grep -Fxq "server = $ACME_SERVER" "$conf" &&
     grep -Fxq "fullchain = $live/fullchain.pem" "$conf" &&
     grep -Fxq 'manual_auth_hook = /fixture/auth-hook' "$conf" &&
     grep -Fxq 'manual_cleanup_hook = /fixture/cleanup-hook' "$conf" &&
     grep -Fxq 'renew_hook = /fixture/cert-sync/bin/cert-sync' "$conf"; then
    test_pass 'renewal conf contains restored paths, server and resolved hooks'
  else
    test_fail 'renewal conf missing or incorrect'
  fi
  local condition_status=0
  FQDN="$FQDN" bash "${CASE_DIR}/initial-condition.sh" || condition_status=$?
  if [[ "$condition_status" -eq 1 ]] &&
     grep -Fq "restored certificate from Vault for $FQDN" "${CASE_DIR}/log"; then
    test_pass 'restore completes and actual certbot-initial predicate skips issuance'
  else
    test_fail "restore/issuance outcome incorrect (condition=$condition_status)"
  fi
}

assert_fallthrough() {
  if [[ ! -e "${CASE_DIR}/letsencrypt" ]] &&
     FQDN="$FQDN" bash "${CASE_DIR}/initial-condition.sh"; then
    test_pass 'no lineage written; actual certbot-initial predicate permits issuance'
  else
    test_fail 'fall-through unexpectedly wrote a lineage or skipped issuance'
  fi
}

assert_case_log() {
  local pattern="$1"
  if grep -Eq "$pattern" "${CASE_DIR}/log"; then
    test_pass "log matches: $pattern"
  else
    cat "${CASE_DIR}/log"
    test_fail "missing log: $pattern"
  fi
}

test_start '9a' 'token at +71s; transport failure, JSON 503, JSON 429, then fresh lineage'
run_restore_case late-token 71 sequence
assert_restored
[[ "$(< "${CASE_DIR}/calls")" -eq 4 ]] || test_fail 'expected exactly four lookup attempts'
assert_case_log 'Vault token available after 7[1-5]s'

test_start '9b' 'token never arrives; bounded return-zero fall-through'
run_restore_case no-token -1 success
assert_fallthrough
elapsed=$(< "${CASE_DIR}/elapsed")
[[ "$elapsed" -ge 300 && "$elapsed" -le 305 && "$(< "${CASE_DIR}/calls")" -eq 0 ]] ||
  test_fail "token timeout elapsed=$elapsed or unexpected lookup"
assert_case_log 'WARNING: Vault token unavailable after 30[0-5]s; falling through to certbot'

test_start '9c' 'token at +290s; unavailable lookup shares the original 300s deadline'
run_restore_case late-unavailable 290 unavailable
assert_fallthrough
elapsed=$(< "${CASE_DIR}/elapsed")
calls=$(< "${CASE_DIR}/calls")
[[ "$elapsed" -ge 300 && "$elapsed" -le 305 && "$calls" -gt 0 && "$calls" -le 10 ]] ||
  test_fail "lookup did not share budget: elapsed=$elapsed calls=$calls"
assert_case_log 'WARNING: Vault lookup unavailable .* after 30[0-5]s; falling through to certbot'

for response in missing denied; do
  test_start "9-$response" 'first JSON 404/403 is definitive; no retries'
  run_restore_case "$response" 0 "$response"
  assert_fallthrough
  [[ "$(< "${CASE_DIR}/calls")" -eq 1 && "$(< "${CASE_DIR}/elapsed")" -lt 5 ]] ||
    test_fail "$response: retried or waited instead of definitive fall-through"
  status=404
  [[ "$response" != denied ]] || status=403
  # The denied case also covers R2-2(g)/R2-8: HTTP 403 is journal-visible.
  assert_case_log "no restorable Vault cert found .* \(HTTP $status\); falling through to certbot"
done

test_start '9f' 'whitespace-only token waits for a real token, then restores'
run_restore_case whitespace 71 success
assert_restored
[[ "$(< "${CASE_DIR}/calls")" -eq 1 ]] || test_fail 'whitespace token caused extra lookup'
assert_case_log 'Vault token available after 7[1-5]s'

runner_summary
