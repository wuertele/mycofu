#!/usr/bin/env bash
# test_replication_policy_single_authority.sh — Sprint 047 V5.1 static ratchet.
#
# The sprint's policy is derived by exactly ONE authority
# (framework/scripts/list-replicated-vmids.sh) and consumed by exactly four
# consumers via the helper or its artifact. Any drift — a new script that
# parses `replicate:` directly, a consumer that forgets to route through the
# helper, a stray converge-cluster.sh call, a change to the safe-apply.sh
# three-step chain from #620 — would recreate the exact failure class this
# sprint exists to close (pipeline-1633 / #617).
#
# V5.1 subchecks:
#   (a) No file outside the allowlist parses `replicate:` from YAML.
#   (b) All four consumers reference the helper (`list-replicated-vmids.sh`)
#       or the artifact (`/etc/repl-policy.vmids`).
#   (c) This sprint introduces no new `converge-cluster.sh` call
#       (#529 doctrine).
#   (d) `safe-apply.sh`'s run_post_success calls post-deploy.sh →
#       configure-backups.sh → configure-replication.sh in that order,
#       all unconditional (#617/#620/#621 ratchet).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
source "${TEST_DIR}/lib/runner.sh"

# ---------------------------------------------------------------------------
# V5.1.a — allowlist: no non-authority parses `replicate:` from YAML.
# ---------------------------------------------------------------------------
test_start "V5.1.a" "no file outside the allowlist parses replicate: from YAML"

# Allowlist (paths RELATIVE to $REPO_DIR):
#  - framework/scripts/list-replicated-vmids.sh  (the sole authority)
#  - framework/scripts/validate-site-config.sh   (guard-only; validates key
#                                                 shape, never enumerates the
#                                                 policy set)
#  - framework/tofu/root/main.tf                 (#691: HCL re-derives the
#                                                 same rule so `tofu plan`
#                                                 does not need to shell out
#                                                 at plan time. Equivalence
#                                                 is ratcheted by
#                                                 tests/test_replication_policy_hcl_wiring.sh
#                                                 — the sanctioned V5.1
#                                                 equivalence proof.)
#  - Sprint 047 test files (V1.1, V2.2, V5.1, V5.2, V6.2 fixtures)
#  - Everything under tests/  and docs/
#  - The example template + the site config itself
readonly ALLOWLIST_TOKENS=(
  "framework/scripts/list-replicated-vmids.sh"
  "framework/scripts/validate-site-config.sh"
  "framework/tofu/root/main.tf"
  "tests/"
  "docs/"
  "site/config.yaml"
  "site/applications.yaml"
  "framework/templates/config.yaml.example"
  # DR tests and their registry are documentation of failure scenarios,
  # not policy parsers. Comment references to `replicate:` here document
  # the sprint's opt-in mechanism (e.g., DRT-006 references dns_prod's
  # `replicate: true` opt-in in a header comment). Same allowlist class
  # as tests/ and docs/.
  "framework/dr-tests/"
)

is_allowlisted() {
  local path="$1"
  local prefix
  for prefix in "${ALLOWLIST_TOKENS[@]}"; do
    if [[ "$path" == "$prefix"* || "$path" == "./${prefix}"* ]]; then
      return 0
    fi
  done
  return 1
}

VIOLATIONS_FILE=$(mktemp /tmp/v51a.XXXXXX)
trap 'rm -f "$VIOLATIONS_FILE"' EXIT

# grep for `.replicate` (attribute-access style, e.g. `vm.replicate`,
# `.replicate == true`) or `replicate:` (YAML key). Exclude the allowlist.
(
  cd "$REPO_DIR"
  # Only search source directories; skip binary/build artefacts.
  grep -rE '\.replicate|replicate:' \
    --include='*.sh' \
    --include='*.py' \
    --include='*.nix' \
    --include='*.tf' \
    --include='*.hcl' \
    --include='*.yaml' \
    --include='*.yml' \
    --include='*.md' \
    -l framework/ site/ .gitlab-ci.yml 2>/dev/null || true
) | while IFS= read -r path; do
  is_allowlisted "$path" && continue
  # Whitelisted classes:
  # - the helper itself (already allowlisted by prefix)
  # - the guard (already allowlisted)
  # - comments / docs (already allowlisted under docs/)
  # An .md file NOT under docs/ is a suspicious inline doc — surface.
  echo "$path"
done > "$VIOLATIONS_FILE"

if [[ ! -s "$VIOLATIONS_FILE" ]]; then
  test_pass "no non-authority files parse replicate: from YAML"
else
  test_fail "V5.1.a: policy-parser leak — the following files parse replicate: from YAML but are not on the allowlist"
  cat "$VIOLATIONS_FILE" >&2
fi

# ---------------------------------------------------------------------------
# V5.1.b — all runtime consumers reference the helper or the artifact.
#
# #691 (interim HA-retry damage limiter) added a FIFTH consumer:
# framework/tofu/root/main.tf re-derives the same policy rule in HCL so
# `tofu plan` does not need to shell out. That consumer is checked by
# tests/test_replication_policy_hcl_wiring.sh (structural + equivalence
# ratchet against the helper), not here — this test remains focused on
# the four shell-runtime consumers.
# ---------------------------------------------------------------------------
test_start "V5.1.b" "four shell-runtime consumers reference the helper or /etc/repl-policy.vmids"

consumer_ok() {
  local script_path="$1" label="$2"
  if grep -qE 'list-replicated-vmids\.sh|/etc/repl-policy\.vmids' "$REPO_DIR/$script_path"; then
    return 0
  fi
  echo "  ✗ $label ($script_path) does not reference helper or artifact" >&2
  return 1
}

failures=0
consumer_ok "framework/scripts/configure-replication.sh" "configure-replication create/prune" || failures=$((failures + 1))
consumer_ok "framework/scripts/configure-replication.sh" "configure-replication initial-sync wait (inherits)" || true
consumer_ok "framework/scripts/repl-health.sh"          "repl-health.sh" || failures=$((failures + 1))
consumer_ok "framework/scripts/validate.sh"             "validate.sh conformance + equivalence" || failures=$((failures + 1))

# configure-replication.sh's initial-sync wait is inside the same file as
# the create/prune loop — a separate consumer_ok call would be redundant.
# The three physical files above ARE the four logical consumers (create/prune
# and initial-sync-wait live in configure-replication.sh together).

if [[ $failures -eq 0 ]]; then
  test_pass "all four shell-runtime consumers reference the helper or the artifact"
else
  test_fail "V5.1.b: $failures consumer(s) do not route through the single authority"
fi

# ---------------------------------------------------------------------------
# V5.1.c — this sprint introduces no new converge-cluster.sh call.
# ---------------------------------------------------------------------------
test_start "V5.1.c" "no new converge-cluster.sh call site introduced by this sprint"

# Sprint 047 touches these framework scripts. None of them should call
# converge-cluster.sh (#529 env-scoping doctrine).
SPRINT_TOUCHED_SCRIPTS=(
  "framework/scripts/list-replicated-vmids.sh"
  "framework/scripts/validate-site-config.sh"
  "framework/scripts/configure-replication.sh"
  "framework/scripts/repl-health.sh"
  "framework/scripts/validate.sh"
  "framework/scripts/safe-apply.sh"
)

conv_failures=0
for script in "${SPRINT_TOUCHED_SCRIPTS[@]}"; do
  # A "call" is a real invocation, not a comment. Strip comments before
  # searching. Also allow the SCRIPT_DIR-invoked pattern that the framework
  # uses; a bare `converge-cluster.sh` string in a comment/error message is
  # not a call.
  invocations=$(grep -nE 'converge-cluster\.sh' "$REPO_DIR/$script" \
                | grep -v '^[[:space:]]*#' \
                | grep -vE '^\s*[0-9]+:\s*#' \
                | grep -vE '^\s*[0-9]+:\s*[^#]*#[^"]*converge-cluster\.sh' \
                | grep -vE '"[^"]*converge-cluster\.sh[^"]*"[^)]*$' \
                || true)
  if [[ -n "$invocations" ]]; then
    echo "  ✗ $script contains converge-cluster.sh call:" >&2
    echo "$invocations" >&2
    conv_failures=$((conv_failures + 1))
  fi
done

if [[ $conv_failures -eq 0 ]]; then
  test_pass "no sprint-touched script calls converge-cluster.sh"
else
  test_fail "V5.1.c: $conv_failures sprint-touched script(s) call converge-cluster.sh"
fi

# ---------------------------------------------------------------------------
# V5.1.d — safe-apply.sh's run_post_success three-step chain intact.
#   Order: post-deploy.sh → configure-backups.sh → configure-replication.sh
#   All unconditional (no `if` gating the invocation itself).
# ---------------------------------------------------------------------------
test_start "V5.1.d" "safe-apply.sh three-step chain (post-deploy → configure-backups → configure-replication)"

SAFE_APPLY="$REPO_DIR/framework/scripts/safe-apply.sh"

# Extract the run_post_success function body.
CHAIN_BODY=$(awk '/^run_post_success\(\)/,/^}/' "$SAFE_APPLY")

# Order check: post-deploy.sh must appear before configure-backups.sh, which
# must appear before configure-replication.sh (as function invocations, not
# just comments).
post_line=$(echo "$CHAIN_BODY"  | grep -nE '\$\{SCRIPT_DIR\}/post-deploy\.sh|/post-deploy\.sh' | head -1 | cut -d: -f1)
backups_line=$(echo "$CHAIN_BODY" | grep -nE 'run_configure_backups|configure-backups\.sh' | head -1 | cut -d: -f1)
repl_line=$(echo "$CHAIN_BODY"  | grep -nE '/configure-replication\.sh' | head -1 | cut -d: -f1)

order_ok=1
if [[ -z "$post_line" || -z "$backups_line" || -z "$repl_line" ]]; then
  order_ok=0
  echo "  ✗ Missing one of the three chain calls: post_line='$post_line' backups='$backups_line' repl='$repl_line'" >&2
elif [[ "$post_line" -gt "$backups_line" || "$backups_line" -gt "$repl_line" ]]; then
  order_ok=0
  echo "  ✗ Chain order violated: post=$post_line backups=$backups_line repl=$repl_line (must be increasing)" >&2
fi

# Unconditional check: each call is invoked directly, then its exit code is
# captured and inspected for reporting only. The chain is unconditional if
# each of the three "invocation" lines is NOT preceded by an `if` that
# guards WHETHER the invocation runs. The `if [[ $rc -ne 0 ]]` blocks that
# follow the invocations are reporting-only (they echo ERROR and continue),
# so they're allowed. We assert the presence of the "continue" language
# specifically — the ratchet is that #617/#620 discipline is preserved.
if ! echo "$CHAIN_BODY" | grep -qE 'Continuing to configure-backups\.sh and configure-replication\.sh|Backup-job reconciliation must not be gated'; then
  echo "  ✗ Missing #617/#620 continuation language after post-deploy.sh failure" >&2
  order_ok=0
fi

# Assert the three script tokens are all present as invocations. Use -E for
# alternation.
for token in "post-deploy\.sh" "run_configure_backups|configure-backups\.sh" "configure-replication\.sh"; do
  if ! echo "$CHAIN_BODY" | grep -Eq "$token"; then
    echo "  ✗ Missing chain call token: $token" >&2
    order_ok=0
  fi
done

if [[ $order_ok -eq 1 ]]; then
  test_pass "run_post_success invokes post-deploy → configure-backups → configure-replication in order, all unconditional"
else
  test_fail "V5.1.d: three-step chain violated"
fi

# ---------------------------------------------------------------------------
# V5.1.e — cadence shorthand parser and 24h anchor table live only in helper.
# ---------------------------------------------------------------------------
test_start "V5.1.e" "cadence parser and 24h anchor table stay only in list-replicated-vmids.sh"
HELPER="$REPO_DIR/framework/scripts/list-replicated-vmids.sh"
CONFIG_REPL="$REPO_DIR/framework/scripts/configure-replication.sh"
REPL_HEALTH="$REPO_DIR/framework/scripts/repl-health.sh"
VALIDATE="$REPO_DIR/framework/scripts/validate.sh"
if grep -q 'CADENCE_PATTERN' "$HELPER" \
   && grep -q 'ANCHOR_24H' "$HELPER" \
   && ! grep -qE 'CADENCE_PATTERN|ANCHOR_24H' "$CONFIG_REPL" "$REPL_HEALTH" "$VALIDATE"; then
  test_pass "cadence parser tokens and anchor table remain helper-only"
else
  test_fail "V5.1.e: cadence parser or anchor table leaked outside helper"
fi

# ---------------------------------------------------------------------------
# V5.2.a — helper TSV has the 9-column cadence consumer shape.
# ---------------------------------------------------------------------------
test_start "V5.2.a" "helper TSV exposes the 9-column cadence consumer shape"
CONFIG_REPL="$REPO_DIR/framework/scripts/configure-replication.sh"
REPL_HEALTH="$REPO_DIR/framework/scripts/repl-health.sh"
VALIDATE="$REPO_DIR/framework/scripts/validate.sh"
HELPER="$REPO_DIR/framework/scripts/list-replicated-vmids.sh"
helper_tsv="$(
  LIST_REPLICATED_VMIDS_CONFIG="$REPO_DIR/tests/fixtures/replication-policy/config.yaml" \
  LIST_REPLICATED_VMIDS_APPS_CONFIG="$REPO_DIR/tests/fixtures/replication-policy/applications.yaml" \
  "$HELPER" --format tsv --mode replicated all 2>/dev/null
)"
cadence_map="$(printf '%s\n' "$helper_tsv" | awk -F'\t' 'BEGIN{OFS=":"} NF>=8 {print $1, $8}' | sort -n | paste -sd, -)"
# MR-4 T4.1 defaults: 12 rows at 60s (all backup:true + all shared + all
# prod + dns2-prod explicit "1m") and 2 rows at 86400s (dev derivable:
# dns1-dev 301, grafana-dev 502). The fixture VMIDs 160/301/502 are in
# the ANCHOR_24H table; other 24h VMIDs would fail closed.
expected_cadence_map="150:60,160:60,301:86400,303:60,401:60,402:60,403:60,404:60,501:60,502:86400,503:60,601:60,602:60,603:60"
if [[ -n "$helper_tsv" ]] \
   && printf '%s\n' "$helper_tsv" | awk -F'\t' 'NF != 9 {bad=1} END {exit bad}' \
   && [[ "$cadence_map" == "$expected_cadence_map" ]]; then
  test_pass "replicated TSV rows have 9 columns and derive the expected sorted CADENCE_MAP"
else
  test_fail "V5.2.a: helper TSV shape or CADENCE_MAP derivation drifted"
  printf 'helper_tsv:\n%s\ncadence_map=%s\nexpected=%s\n' "$helper_tsv" "$cadence_map" "$expected_cadence_map" >&2
fi

# ---------------------------------------------------------------------------
# V5.2.b — cadence consumers use helper/artifact projections, not YAML parsing.
# ---------------------------------------------------------------------------
test_start "V5.2.b" "cadence consumers stay routed through helper TSV or node artifact"
if grep -q 'helper_schedule_for' "$CONFIG_REPL" \
   && grep -q 'helper_seed_class_for' "$CONFIG_REPL" \
   && grep -q 'pvesr_schedule' "$CONFIG_REPL" \
   && grep -q 'seed_wait_class' "$CONFIG_REPL" \
   && grep -q 'CADENCE_MAP' "$REPL_HEALTH" \
   && grep -q 'replication_policy_cadence_map_from_tsv' "$VALIDATE" \
   && ! grep -q 'SCHEDULE_MAP' "$CONFIG_REPL" "$REPL_HEALTH" "$VALIDATE"; then
  test_pass "cadence consumers are helper/artifact based and no SCHEDULE_MAP consumer exists"
else
  test_fail "V5.2.b: cadence consumer routing drifted"
fi

# ---------------------------------------------------------------------------
# V5.3 — Interlock 1 self-check: configure ACTUALLY CONSUMES helper TSV
# columns (not just token-present but functionally applied).
#
# The helper's tsv column order is:
#   $1 vmid, $2 label, $3 env, $4 replicated, $5 source, $6 cadence,
#   $7 pvesr_schedule, $8 cadence_seconds, $9 seed_wait_class
#
# configure-replication.sh's helper accessor functions:
#   helper_schedule_for      -> awk on column 7  (pvesr_schedule)
#   helper_seed_class_for    -> awk on column 9  (seed_wait_class)
#
# This test asserts (a) the accessor functions exist; (b) they use the
# correct column indices; (c) the resulting VM_SCHEDULE and
# SEED_WAIT_CLASS values are consumed downstream (pvesh --schedule
# uses the schedule; the async partition uses the wait class).
# Comment-only presence of the tokens does not satisfy the ratchet.
# ---------------------------------------------------------------------------
test_start "V5.3" "configure-replication consumes pvesr_schedule and seed_wait_class from helper TSV"
_v53_fail=""
grep -Eq 'helper_schedule_for\(\).*awk.*print \$7' "$CONFIG_REPL" \
  || _v53_fail+="helper_schedule_for does not awk column 7; "
grep -Eq 'helper_seed_class_for\(\).*awk.*print \$9' "$CONFIG_REPL" \
  || _v53_fail+="helper_seed_class_for does not awk column 9; "
grep -Fq '"$(helper_schedule_for "$VMID")"' "$CONFIG_REPL" \
  || _v53_fail+="helper_schedule_for not called with VMID; "
grep -Fq 'shell_quote "$VM_SCHEDULE"' "$CONFIG_REPL" \
  || _v53_fail+="VM_SCHEDULE not passed to pvesh --schedule via shell_quote; "
grep -Fq 'SEED_WAIT_CLASS=' "$CONFIG_REPL" \
  || _v53_fail+="SEED_WAIT_CLASS assignment absent; "
grep -Fq 'SEED_WAIT_CLASS" == "async"' "$CONFIG_REPL" \
  || _v53_fail+="SEED_WAIT_CLASS not gated on \"async\" in create loop; "
if [[ -z "$_v53_fail" ]]; then
  test_pass "configure-replication.sh consumes pvesr_schedule (col 7) into pvesh --schedule AND seed_wait_class (col 9) into the async partition"
else
  test_fail "V5.3: ${_v53_fail%%; }"
fi

runner_summary
