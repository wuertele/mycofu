#!/usr/bin/env bash
# Drift guard: the numeric fallbacks in root/main.tf's `coalesce(try(x, null),
# N)` sizing sites MUST match the corresponding `default = N` values in the
# receiving catalog module's `variables.tf`.
#
# Why: G11 (#42 + #280, MR !421) inlined catalog defaults at 18 sizing sites
# in framework/tofu/root/main.tf to defend against the null-cascade footgun.
# The numeric literals duplicate the `default = N` declarations in
# framework/catalog/{influxdb,grafana,roon,workstation}/variables.tf. At
# time of G11 they matched, but nothing enforces the invariant: a catalog
# author bumping `roon.vdb_size_gb` from 50 → 60 will silently leave main.tf's
# coalesce fallback at 50, and a deploy that omits `data_disk_size` for roon
# in applications.yaml will silently allocate 50 GB (the caller override wins
# over the catalog default). Silent divergence between "what the catalog
# intends" and "what actually deploys."
#
# This test enumerates the coalesce sites and asserts equality against the
# catalog defaults. It fails with a clear message pointing at both files so
# the author knows which side to update. Companion to the plan-time
# precondition guard in main.tf added by #557.
#
# Portability: uses POSIX awk + grep/sed — must run on macOS (BSD awk) and
# NixOS (gawk) alike. Do not use gawk-only extensions like the 3-arg form
# of match().
#
# Related: #42, #280, #276, #557, MR !421.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_TF="$REPO_DIR/framework/tofu/root/main.tf"
CATALOG_DIR="$REPO_DIR/framework/catalog"

fail() { echo "[test] FAIL: $*" >&2; exit 1; }
info() { echo "[test] $*"; }

[[ -f "$MAIN_TF" ]] || fail "not found: $MAIN_TF"
[[ -d "$CATALOG_DIR" ]] || fail "not found: $CATALOG_DIR"

# Extract catalog default for (app, var). Returns the number, or empty if not found.
# Catalog variables.tf declarations look like:
#   variable "ram_mb" {
#     description = "RAM in MB"
#     type        = number
#     default     = 2048
#   }
catalog_default() {
  local app="$1" var="$2"
  local vars_tf="$CATALOG_DIR/$app/variables.tf"
  [[ -f "$vars_tf" ]] || return 1
  awk -v var="$var" '
    $0 ~ "^variable \"" var "\" \\{" { in_block=1; next }
    in_block && /^\}/ { in_block=0; next }
    in_block && /^[[:space:]]+default[[:space:]]*=[[:space:]]/ {
      sub(/^[[:space:]]+default[[:space:]]*=[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$vars_tf"
}

# Extract coalesce sites from main.tf. Each output line: "app<TAB>var<TAB>value<TAB>linenum"
#
# Matches lines of the form:
#   <spaces><var><spaces>=<spaces>coalesce(try(local.app_<app>.<field>, null), ... <NUMBER>)
#
# The trailing NUMBER (before the closing paren) is the catalog-default
# fallback. The <field> reference inside the first try() picks up the app
# name. Handles chained coalesce (multiple try() args before the trailing
# number).
#
# Only picks up sites where the fallback is a bare numeric literal — HCL
# supports other fallback shapes (strings, references) but the sizing sites
# only use numbers, and other fallback shapes are not part of this drift
# invariant.
extract_sites() {
  # Two-step extraction (portable to BSD awk):
  # 1. grep -nE to keep line numbers and filter to coalesce+local.app_ lines
  # 2. awk to slice out (var, app, value)
  grep -nE '^[[:space:]]+[a-z_][a-z_0-9]*[[:space:]]*=[[:space:]]*coalesce\(.*local\.app_[a-z_][a-z_0-9]*\..*,[[:space:]]*[0-9]+\)[[:space:]]*$' "$MAIN_TF" \
    | awk -F: '{
        line=$0
        # line format is "LINENUM:TEXT"
        colon=index(line, ":")
        linenum=substr(line, 1, colon-1)
        text=substr(line, colon+1)
        # Extract var (LHS): strip leading whitespace then take the first token
        varpart=text
        sub(/^[[:space:]]+/, "", varpart)
        var=varpart
        sub(/[[:space:]].*$/, "", var)
        # Extract app: everything between "local.app_" and the next "."
        # First occurrence wins (the FIRST try() references the app).
        apppart=text
        sub(/^.*local\.app_/, "", apppart)
        app=apppart
        sub(/\..*$/, "", app)
        # Extract trailing number: last integer before the final ")"
        valpart=text
        sub(/\)[[:space:]]*$/, "", valpart)
        # Strip everything up to the last comma+optional-space
        sub(/^.*, /, "", valpart)
        # If still contains "try(" or letters, something is off; skip
        if (valpart !~ /^[0-9]+$/) { next }
        print app "\t" var "\t" valpart "\t" linenum
      }'
}

# Main: walk each site and compare.
mismatches=0
sites=0

while IFS=$'\t' read -r app var value linenum; do
  [[ -z "${app:-}" ]] && continue
  sites=$((sites + 1))
  cat_default=$(catalog_default "$app" "$var" || true)
  if [[ -z "$cat_default" ]]; then
    fail "no catalog default for ($app, $var) — checked $CATALOG_DIR/$app/variables.tf; main.tf:$linenum sets coalesce fallback = $value but no matching variable declaration was found"
  fi
  if [[ "$value" != "$cat_default" ]]; then
    echo "[test] MISMATCH: app=$app var=$var main.tf:$linenum fallback=$value catalog=$CATALOG_DIR/$app/variables.tf default=$cat_default" >&2
    mismatches=$((mismatches + 1))
  else
    info "OK: $app.$var main.tf:$linenum = catalog = $value"
  fi
done < <(extract_sites)

if [[ "$sites" -eq 0 ]]; then
  fail "no coalesce sites matched the extraction pattern — regex is likely broken; expected at least 20 sites across influxdb/grafana/roon/workstation"
fi

# Ratchet: assert we found EXACTLY the current sizing sites.
# Currently expected sites (verified 2026-07-15 against dev tip 4cd84c5,
# after G11 MR !421 landed):
#   influxdb dev/prod: 3 sizing vars each (ram_mb, vda_size_gb, vdb_size_gb) → 6
#   grafana  dev/prod: 3 sizing vars each (ram_mb, vda_size_gb, vdb_size_gb) → 6
#   roon     dev/prod: 3 sizing vars each (ram_mb, vda_size_gb, vdb_size_gb) → 6
#   workstation dev/prod: 4 sizing vars each (ram_mb, cores, vda_size_gb, vdb_size_gb) → 8
#   TOTAL: 26 sites
# Floor is set at the exact site count (not a lower bound) so a future
# reformat that silently drops a site — e.g. `terraform fmt` wrapping a
# long chained coalesce across multiple lines — will fail the ratchet
# before it can silently pass. If a future catalog addition raises the
# total, bump this floor in the same commit as the coalesce site.
EXPECTED_SITES=26
if [[ "$sites" -ne "$EXPECTED_SITES" ]]; then
  fail "extracted $sites sizing sites — expected exactly $EXPECTED_SITES. Either (a) the extraction regex has broken (e.g., 'terraform fmt' wrapped a chained coalesce across multiple lines and the single-line grep now misses it), or (b) a coalesce site was legitimately added/removed and this ratchet needs to be bumped in the same commit. See tests/test_root_sizing_defaults_match_catalog.sh for the site inventory."
fi

if [[ "$mismatches" -gt 0 ]]; then
  fail "$mismatches drift(s) between framework/tofu/root/main.tf coalesce fallbacks and framework/catalog/*/variables.tf defaults. The catalog module's \`variable { default = N }\` is the source of truth; update framework/tofu/root/main.tf to match unless the intent is to raise the catalog default (in which case update both)."
fi

info "PASS: all $sites coalesce fallbacks in framework/tofu/root/main.tf match their catalog module defaults."
