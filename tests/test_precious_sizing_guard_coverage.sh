#!/usr/bin/env bash
# Coverage ratchet: every precious-state (`backup: true`) application in
# site/applications.yaml MUST have a matching plan-time sizing guard
# (`resource "terraform_data" "precious_sizing_<app>"`) in
# framework/tofu/root/main.tf, and that guard MUST reference every sizing
# field the app declares in applications.yaml.
#
# Why (#597, batch E P2 follow-up):
# The precious-state sizing guard (#557, MR !462) closes the G11 (#42 + #280)
# silent-default footgun: an operator who omits a sizing field on an enabled
# `backup: true` app would otherwise get a silent catalog default (a smaller
# disk / less RAM than intended) instead of a loud plan-time failure. But the
# guards in main.tf are hand-enumerated per catalog app
# (`precious_sizing_influxdb`, `_roon`, `_workstation`). If a future
# `enable-app.sh` adds a new catalog app with `backup: true`, nothing forces
# the operator to add a matching guard block — the new precious app would be
# unguarded, silently re-opening the exact failure mode #557 was created to
# prevent. This ratchet fails CI the moment a precious app has no guard, or a
# guard stops covering one of its declared sizing fields.
#
# Companion to #558 (tests/test_root_sizing_defaults_match_catalog.sh):
#   - #558 catches drift between existing coalesce fallbacks and catalog
#     defaults (are the numbers right?).
#   - #597 (this test) catches guard-omission on newly-added precious apps and
#     field-omission within an existing guard (does the guard exist and cover
#     every declared sizing field?).
#
# Field-coverage anchoring: the guard conditions uniformly reference
# `local.app_<app>.<field>`, so this test derives the required references
# from the app's declared sizing fields in applications.yaml — no per-app
# field table is hand-maintained here (that would just relocate the
# hand-enumeration problem #597 removes). This automatically covers the
# `cpus_dev` / `cpus_prod` pair added to the workstation guard by #607/#608
# (MR !509): workstation declares `cpus_dev` / `cpus_prod` in applications.yaml,
# so the ratchet requires the guard to reference them. Re-anchored against
# gitlab/dev tip 7a2cdee (post-!509).
#
# Coverage set is `backup: true` regardless of `enabled`. Preciousness is
# `backup: true` (see .claude/rules/design-taste.md: "Preciousness
# (backup: true) already encodes restore-vs-reinitialize"); a guard should
# exist BEFORE an app is flipped `enabled: true`, so a disabled precious app
# with a missing/incomplete guard fails now rather than the day it is enabled.
# This is strictly stronger than the issue's "enabled AND backup" wording and
# passes on current dev (workstation is disabled but fully guarded).
#
# The "stronger, more work" alternative from #597 (a `for_each` generating the
# guards dynamically from per-app sizing metadata) is intentionally NOT taken;
# it requires a sizing-field schema and is out of scope for a CI ratchet.
#
# No total-count floor (unlike the sibling's EXPECTED_SITES=26): the required
# set is DERIVED from applications.yaml, so it self-adjusts and cannot silently
# under-count the way a main.tf regex-scrape can — a count floor would add no
# safety here. Corollary: the field set the ratchet enforces tracks the YAML
# (the single source of truth, per design-taste principle 2). If an operator
# deliberately drops `workstation.cpus_dev` from applications.yaml, the deploy
# coalesce falls back to the catalog default and the guard legitimately no
# longer needs that precondition — so the ratchet stops requiring it too. It is
# a coverage ratchet ("does every declared field have a guard?"), not a frozen
# inventory of the guard's fields.
#
# Only TOP-LEVEL sizing keys are enumerated. Today's schema keeps sizing at the
# top level (`ram`, or env-suffixed `ram_dev`/`ram_prod`); a future sizing key
# nested under `environments.<env>` would not be seen. Flag for whoever changes
# the sizing schema.
#
# Portability: yq (mikefarah/go-yq, as used throughout framework/scripts) +
# POSIX awk + grep. Must run on macOS (BSD awk/grep) and NixOS (gawk/GNU grep).
# No gawk-only or GNU-grep-only extensions (no `\b`, no 3-arg match()).
#
# Related: #597, #557, #558, #607, #608, #42, #280, MR !462, !509.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_TF="$REPO_DIR/framework/tofu/root/main.tf"
APPS_YAML="$REPO_DIR/site/applications.yaml"

fail() { echo "[test] FAIL: $*" >&2; exit 1; }
info() { echo "[test] $*"; }

[[ -f "$MAIN_TF" ]]    || fail "not found: $MAIN_TF"
[[ -f "$APPS_YAML" ]]  || fail "not found: $APPS_YAML"
command -v yq >/dev/null 2>&1 || fail "yq not found on PATH (required to parse $APPS_YAML)"

# Sizing fields recognised by the precious-state guards. Matches the base
# field and its env-suffixed / cpu-aliased forms:
#   ram, cores, cpus, disk_size, data_disk_size  (+ optional _dev / _prod)
# If a new sizing-field family is ever introduced (e.g. a GPU count), extend
# this pattern in the same commit that adds the guard for it.
SIZING_FIELD_RE='^(ram|cores|cpus|disk_size|data_disk_size)(_(dev|prod))?$'

# Extract the source text of one guard block: from its `resource ...` header
# line through the first column-0 closing brace.
#
# The header is matched by a regex anchored to an UNCOMMENTED
# `resource "terraform_data" "precious_sizing_<app>"` declaration — not a bare
# label substring — so a commented-out header (`# resource ...`), a different
# resource type (`null_resource`), or the label appearing in prose cannot
# satisfy the check (adversarial-review finding, codex/agy). The closing `"`
# in the pattern bounds the app name (so `precious_sizing_influx` cannot match
# `precious_sizing_influxdb`).
#
# Parse assumptions (hold for `terraform fmt` output, which this repo runs):
# the resource-closing brace is the first `}` at column 0, while every inner
# brace (lifecycle, precondition) is indented. A hand-authored non-fmt block
# could defeat this; fmt guarantees it.
extract_guard_block() {
  local app="$1"
  awk -v pat="^[[:space:]]*resource[[:space:]]+\"terraform_data\"[[:space:]]+\"precious_sizing_${app}\"" '
    $0 ~ pat      { inblk=1 }
    inblk         { print }
    inblk && /^\}/ { exit }
  ' "$MAIN_TF"
}

# Every backup:true app in applications.yaml. Read into an array with a
# portable while-read loop (macOS bash 3.2 has no `mapfile`).
precious_apps=()
while IFS= read -r app; do
  [[ -n "$app" ]] && precious_apps+=("$app")
done < <(
  yq -r '.applications | to_entries[] | select(.value.backup == true) | .key' "$APPS_YAML"
)

if [[ "${#precious_apps[@]}" -eq 0 ]]; then
  fail "no backup:true apps found in $APPS_YAML — yq parse likely broken (expected at least influxdb and roon)."
fi

missing_guards=0
missing_fields=0
apps_checked=0

for app in "${precious_apps[@]}"; do
  [[ -z "$app" ]] && continue
  apps_checked=$((apps_checked + 1))

  block="$(extract_guard_block "$app")"
  if [[ -z "$block" ]]; then
    echo "[test] MISSING GUARD: precious app '$app' (backup: true) has no 'resource \"terraform_data\" \"precious_sizing_${app}\"' block in framework/tofu/root/main.tf. Add one modelled on the existing precious_sizing_* guards (a lifecycle precondition per sizing field, failing loudly when the field is unset)." >&2
    missing_guards=$((missing_guards + 1))
    continue
  fi

  # Sizing fields this app declares in applications.yaml.
  sizing_fields=()
  while IFS= read -r field; do
    [[ -n "$field" ]] && sizing_fields+=("$field")
  done < <(
    yq -r ".applications.\"$app\" | keys | .[]" "$APPS_YAML" \
      | grep -E "$SIZING_FIELD_RE" || true
  )

  if [[ "${#sizing_fields[@]}" -eq 0 ]]; then
    fail "precious app '$app' declares no recognised sizing field in $APPS_YAML — a backup:true app with no sizing field is unexpected; either the app is misconfigured or $SIZING_FIELD_RE needs extending."
  fi

  # Restrict field matching to the guard's ACTIVE precondition condition lines,
  # not the whole block text. A `local.app_<app>.<field>` reference sitting in a
  # comment, in the `count` expression, or in an `error_message` string must NOT
  # count as coverage — only a live `condition = ...` line does. Comment lines
  # (`# condition = ...`) are excluded because the anchor requires the line to
  # begin with `condition` after optional whitespace. (Adversarial-review
  # finding, codex/sub-claude: a commented reference otherwise produced a false
  # pass.) Assumes fmt's one-condition-per-line form, which the real guards use.
  cond_lines="$(printf '%s\n' "$block" | grep -E '^[[:space:]]*condition[[:space:]]*=' || true)"

  for field in "${sizing_fields[@]}"; do
    [[ -z "$field" ]] && continue
    # Require an exact `local.app_<app>.<field>` reference on a condition line.
    # Trailing char class prevents `data_disk_size` from matching
    # `data_disk_size_dev` (portable substitute for a word boundary). Here-string
    # (not a pipe) so no SIGPIPE/pipefail interaction with `grep -q`.
    if grep -Eq "local\.app_${app}\.${field}([^A-Za-z0-9_]|\$)" <<<"$cond_lines"; then
      info "OK: $app.$field guarded by precious_sizing_${app}"
    else
      echo "[test] UNGUARDED FIELD: precious app '$app' declares sizing field '$field' in $APPS_YAML but precious_sizing_${app} in framework/tofu/root/main.tf has no precondition referencing 'local.app_${app}.${field}'. Add a lifecycle precondition guarding it (a silent catalog default would change the deployed size on a fresh deploy)." >&2
      missing_fields=$((missing_fields + 1))
    fi
  done
done

if [[ "$missing_guards" -gt 0 || "$missing_fields" -gt 0 ]]; then
  fail "$missing_guards precious app(s) missing a sizing guard and $missing_fields declared sizing field(s) unguarded. Every backup:true app in site/applications.yaml must have a 'terraform_data \"precious_sizing_<app>\"' block in framework/tofu/root/main.tf covering each of its declared sizing fields."
fi

info "PASS: all $apps_checked precious (backup:true) app(s) have a precious_sizing guard covering every declared sizing field."
