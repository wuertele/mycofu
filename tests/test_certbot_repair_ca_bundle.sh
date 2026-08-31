#!/usr/bin/env bash
#
# Ratchet for #568: every certbot invocation that talks to the ACME server must
# run with REQUESTS_CA_BUNDLE exported.
#
# certbot's python-requests verifies TLS against the certifi bundle (public
# roots only) unless REQUESTS_CA_BUNDLE points it at the system bundle, which
# extra-ca-bundle.service augments with the dev ACME CA root. The #525
# self-heal (certbot-repair-persisted-state) shipped without that export: its
# account-liveness probe died CERTIFICATE_VERIFY_FAILED against dev's step-ca,
# was classified `unreachable`, and the service failed closed — so it never
# re-registered the dead account it exists to repair. The guard was missing and
# no test noticed, which is why this file is a ratchet and not just a unit test.
#
# The generic check (A568.3) covers every script block in certbot.nix, not just
# the repair block, so a NEW certbot-invoking block added later is guarded too.
# A568.4-A568.8 are mutation tests: they prove the detector actually bites on
# each way the guard could plausibly go missing, and (A568.8) that it does not
# simply flag everything.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CERTBOT_NIX="${REPO_ROOT}/framework/nix/modules/certbot.nix"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# awk program: report script blocks in a certbot.nix that invoke certbot
# against the ACME server without a preceding REQUESTS_CA_BUNDLE export.
#
# A line is an invocation when `certbot` appears in command position — bare
# (`certbot renew`) or via a store path (`${pkgs.certbot}/bin/certbot renew`) —
# followed by a network-facing subcommand. Backslash continuations are joined
# first, so `certbot \` / `register \` is caught. `pkgs.certbot` in a
# makeBinPath list is not an invocation (preceded by `.`), and neither are the
# hyphenated neighbours certbot-renewability.sh / certbot-persisted-state.sh
# (the subcommand must be a separate word). Comments are stripped.
read -r -d '' UNGUARDED_AWK <<'AWK' || true
BEGIN {
  # `certbot <net-subcommand>`, allowing an optional /bin/ store-path prefix.
  # The char before `certbot` must not be alnum/_/./- , which rejects
  # `pkgs.certbot` while accepting `.../bin/certbot`.
  INVOKE = "(^|[^[:alnum:]_.-])certbot[[:space:]]+(certonly|renew|register|show_account)([[:space:]]|$)"
  EXPORT = "^[[:space:]]*export[[:space:]]+REQUESTS_CA_BUNDLE="
  OPEN   = "(writeShellScript(Bin)?[[:space:]]+\"[^\"]+\"[[:space:]]*''|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*''[[:space:]]*$)"
  # A block closes on a line whose first non-space token is '' (optionally
  # followed by ; or other trailing text). Shell lines that merely *contain*
  # '' — the escaped-interpolation form ''${VAR} — are not close markers.
  CLOSE  = "^[[:space:]]*''([^$]|$)"
}

# Remember the enclosing systemd service so `script = ''` blocks get a name.
/^[[:space:]]*systemd\.services\.[A-Za-z0-9_.-]+[[:space:]]*=/ {
  svc = $0
  sub(/^[[:space:]]*systemd\.services\./, "", svc)
  sub(/[[:space:]]*=.*$/, "", svc)
}

!in_block && $0 ~ OPEN {
  in_block = 1
  name = block_name($0, svc)
  first_invoke = 0
  first_export = 0
  pending = ""
  next
}

in_block && $0 ~ CLOSE {
  if (first_invoke > 0) {
    if (first_export == 0) {
      print name " (invokes certbot, no REQUESTS_CA_BUNDLE export)"
    } else if (first_export > first_invoke) {
      print name " (exports REQUESTS_CA_BUNDLE only AFTER its certbot invocation)"
    }
  }
  in_block = 0
  next
}

in_block {
  line = $0
  stripped = line
  sub(/^[[:space:]]*/, "", stripped)
  if (stripped ~ /^#/) { next }

  if (first_export == 0 && line ~ EXPORT) { first_export = NR }

  # Join backslash continuations into one logical command before matching, so
  # a subcommand parked on the next line is still seen.
  if (pending == "") { start = NR }
  logical = pending line
  if (line ~ /\\[[:space:]]*$/) {
    sub(/\\[[:space:]]*$/, " ", logical)
    pending = logical
    next
  }
  pending = ""

  if (first_invoke == 0 && logical ~ INVOKE) { first_invoke = start }
}

function block_name(opener, service,   tmp, lhs) {
  if (opener ~ /writeShellScript(Bin)?[[:space:]]+"/) {
    tmp = opener
    sub(/^.*writeShellScript(Bin)?[[:space:]]+"/, "", tmp)
    sub(/".*$/, "", tmp)
    return tmp
  }
  lhs = opener
  sub(/^[[:space:]]*/, "", lhs)
  sub(/[[:space:]]*=.*$/, "", lhs)
  if (lhs == "script" && service != "") { return service }
  return lhs
}
AWK

# Echoes the names of script blocks in the given certbot.nix that invoke a
# network-facing certbot subcommand unguarded by REQUESTS_CA_BUNDLE.
# Empty output == no violations.
find_unguarded_certbot_blocks() {
  awk "${UNGUARDED_AWK}" "$1"
}

read -r -d '' REPAIR_BLOCK_AWK <<'AWK' || true
/systemd\.services\.certbot-repair-persisted-state = \{/ { in_service = 1 }
in_service && /^[[:space:]]*script = ''/ { in_block = 1; next }
in_block && /^[[:space:]]*'';[[:space:]]*$/ { exit }
in_block { print }
AWK

repair_block="$(awk "${REPAIR_BLOCK_AWK}" "${CERTBOT_NIX}")"

# --- The guard is present, and covers every certbot call in the repair block ---

test_start "A568.1" "certbot-repair-persisted-state exports REQUESTS_CA_BUNDLE from caBundlePath"
if grep -Eq 'export[[:space:]]+REQUESTS_CA_BUNDLE="?\$\{caBundlePath\}"?' <<< "${repair_block}"; then
  test_pass "repair script exports REQUESTS_CA_BUNDLE=\${caBundlePath}"
else
  test_fail "repair script does not export REQUESTS_CA_BUNDLE=\${caBundlePath}"
fi

test_start "A568.2" "the export precedes the repair block's first certbot invocation"
# Covers all three network-facing calls in the block: the show_account liveness
# probe and both register call sites (the dead-account and no-account branches).
repair_calls="$(grep -cE '(^|[^[:alnum:]_.-])certbot[[:space:]]+(certonly|renew|register|show_account)([[:space:]]|$)' \
  <<< "$(grep -v '^[[:space:]]*#' <<< "${repair_block}")" || true)"
export_line="$(awk '/^[[:space:]]*export[[:space:]]+REQUESTS_CA_BUNDLE=/ { print NR; exit }' <<< "${repair_block}")"
first_call_line="$(grep -vn '^[[:space:]]*#' <<< "${repair_block}" \
  | grep -m1 -E '(^|[^[:alnum:]_.-])certbot[[:space:]]+(certonly|renew|register|show_account)([[:space:]]|$)' \
  | cut -d: -f1 || true)"
if [[ -n "${export_line}" && -n "${first_call_line}" && "${export_line}" -lt "${first_call_line}" \
      && "${repair_calls}" -ge 3 ]]; then
  test_pass "export at block line ${export_line} precedes all ${repair_calls} certbot calls (first at ${first_call_line})"
else
  test_fail "export (line ${export_line:-none}) does not precede all ${repair_calls} certbot calls (first at ${first_call_line:-none})"
fi

test_start "A568.3" "every certbot-invoking block in certbot.nix is guarded"
violations="$(find_unguarded_certbot_blocks "${CERTBOT_NIX}")"
if [[ -z "${violations}" ]]; then
  test_pass "no unguarded certbot invocation sites in certbot.nix"
else
  test_fail "unguarded certbot blocks: ${violations//$'\n'/; }"
fi

# --- Mutation tests: prove the detector bites (non-vacuity) ---

# Appends a synthetic script block to a copy of certbot.nix and echoes the copy.
mutate_append() {
  local tag="$1" body="$2" copy="${TMP_DIR}/certbot-${1}.nix"
  cp "${CERTBOT_NIX}" "${copy}"
  printf '%s\n' "${body}" >> "${copy}"
  printf '%s' "${copy}"
}

test_start "A568.4" "detector reports the repair block when its export is deleted"
mutated="${TMP_DIR}/certbot-noexport.nix"
removed_file="${TMP_DIR}/removed"
read -r -d '' DROP_EXPORT_AWK <<'AWK' || true
/systemd\.services\.certbot-repair-persisted-state = \{/ { in_service = 1 }
in_service && /^[[:space:]]*script = ''/ { in_block = 1 }
in_block && /^[[:space:]]*'';[[:space:]]*$/ { in_block = 0; in_service = 0 }
in_block && /^[[:space:]]*export[[:space:]]+REQUESTS_CA_BUNDLE=/ && removed == 0 { removed = 1; next }
{ print }
END { print removed > removed_file }
AWK
awk -v removed_file="${removed_file}" "${DROP_EXPORT_AWK}" "${CERTBOT_NIX}" > "${mutated}"
# removed==1 proves the mutation actually changed something: if the export were
# already absent, this check fails rather than passing vacuously.
if [[ "$(cat "${removed_file}")" == "1" ]] \
   && grep -q 'certbot-repair-persisted-state' <<< "$(find_unguarded_certbot_blocks "${mutated}")"; then
  test_pass "deleting the export turns the ratchet red"
else
  test_fail "deleting the export did NOT turn the ratchet red"
fi

test_start "A568.5" "detector reports a store-path invocation (\${pkgs.certbot}/bin/certbot)"
copy="$(mutate_append storepath '  syntheticStorePath = pkgs.writeShellScript "synthetic-storepath" '"''"'
    set -euo pipefail
    ${pkgs.certbot}/bin/certbot certonly --server "$ACME_SERVER"
  '"''"';')"
if grep -q 'synthetic-storepath' <<< "$(find_unguarded_certbot_blocks "${copy}")"; then
  test_pass "store-path certbot invocation without the export is reported"
else
  test_fail "store-path certbot invocation without the export slipped through"
fi

test_start "A568.6" "detector reports a line-continuation invocation (subcommand on the next line)"
copy="$(mutate_append continuation '  syntheticContinuation = pkgs.writeShellScript "synthetic-continuation" '"''"'
    set -euo pipefail
    certbot \
      register \
      --non-interactive \
      --server "$ACME_SERVER"
  '"''"';')"
if grep -q 'synthetic-continuation' <<< "$(find_unguarded_certbot_blocks "${copy}")"; then
  test_pass "continuation-form certbot invocation without the export is reported"
else
  test_fail "continuation-form certbot invocation without the export slipped through"
fi

test_start "A568.7" "detector reports an export that comes AFTER the invocation"
copy="$(mutate_append ordering '  syntheticLate = pkgs.writeShellScript "synthetic-late-export" '"''"'
    set -euo pipefail
    certbot show_account --server "$ACME_SERVER"
    export REQUESTS_CA_BUNDLE=${caBundlePath}
  '"''"';')"
late="$(find_unguarded_certbot_blocks "${copy}")"
if grep -q 'synthetic-late-export' <<< "${late}" && grep -q 'AFTER' <<< "${late}"; then
  test_pass "an export placed after the invocation is reported as an ordering violation"
else
  test_fail "an export placed after the invocation slipped through"
fi

test_start "A568.8" "negative control: guarded blocks and non-invoking wrappers are NOT reported"
copy="$(mutate_append guarded '  syntheticGuarded = pkgs.writeShellScript "synthetic-guarded" '"''"'
    set -euo pipefail
    export REQUESTS_CA_BUNDLE=${caBundlePath}
    ${pkgs.certbot}/bin/certbot renew --non-interactive
  '"''"';')"
guarded_violations="$(find_unguarded_certbot_blocks "${copy}")"
# The writeShellScriptBin wrappers (persistedStateTool, renewabilityTool) name
# pkgs.certbot in a makeBinPath list and exec a hook script; they make no ACME
# call and must never be flagged — otherwise the detector is just noise.
if [[ -z "${guarded_violations}" ]]; then
  test_pass "a guarded block, the makeBinPath wrappers, and cert-sync are all left unflagged"
else
  test_fail "false positives: ${guarded_violations//$'\n'/; }"
fi

runner_summary
