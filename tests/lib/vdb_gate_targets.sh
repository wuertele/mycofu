#!/usr/bin/env bash
# vdb_gate_targets.sh - Shared target-collection for the vdb-gate substring
# scan (see tests/test_vdb_gate_removed.sh checks 3 and 4).
#
# Extracting the target list into one place lets tests exercise the exclusion
# rules against fixtures (tests/test_vdb_gate_registry_exclusion.sh) and keeps
# the guard's structural intent — "authoritative/prescriptive docs only" — in
# a single place.
#
# Contract:
#   vdb_gate_collect_rule_doc_targets <repo_root>
# prints each target path NUL-terminated on stdout. Callers populate their
# own array via `while IFS= read -r -d '' path; do arr+=("$path"); done`.
# NUL-delimited output is portable across bash 3.2 (macOS) and 4+.
#
# Files that document *runs* rather than *mechanism* (see EXCLUSIONS below)
# are omitted so that a truthful forensic record such as "no post-boot restore
# occurred" does not trip the substring scan (issue #526).

# Basenames of files under framework/dr-tests/ that are forensic append-only
# logs of test runs rather than prescriptive documentation of mechanism. These
# describe what *did* happen (including "the forbidden thing did not happen"),
# not what the system is designed to do. The vdb-gate substring scan cannot
# distinguish negated forensic mentions from prescriptive ones, so these files
# are excluded from the scan. Full guard strength is retained on every other
# authoritative surface (rules, architecture, scripts, OPERATIONS, catalog).
_VDB_GATE_DR_TESTS_FORENSIC_BASENAMES=(
  "DR-REGISTRY.md"
)

vdb_gate_collect_rule_doc_targets() {
  local repo_root="$1"

  local defaults=(
    "${repo_root}/.claude/rules"
    "${repo_root}/architecture.md"
    "${repo_root}/implementation-plan.md"
    "${repo_root}/OPERATIONS.md"
    "${repo_root}/GETTING-STARTED.md"
    "${repo_root}/README.md"
    "${repo_root}/CLAUDE.md"
    "${repo_root}/convergent-deploy.md"
    "${repo_root}/framework/scripts/README.md"
    "${repo_root}/framework/docs/CONTRIBUTING.md"
    "${repo_root}/site/bringup.md"
  )
  printf '%s\0' "${defaults[@]}"

  local path base excluded skip
  for path in "${repo_root}"/framework/dr-tests/*.md; do
    [[ -e "$path" ]] || continue
    base="$(basename "$path")"
    excluded=0
    for skip in "${_VDB_GATE_DR_TESTS_FORENSIC_BASENAMES[@]}"; do
      if [[ "$base" == "$skip" ]]; then
        excluded=1
        break
      fi
    done
    [[ "$excluded" -eq 1 ]] && continue
    printf '%s\0' "$path"
  done

  find "${repo_root}/framework/catalog" -type f -name '*.md' -print0 2>/dev/null || true
}
