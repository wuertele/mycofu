#!/usr/bin/env bash
# test_ci_control_plane_roles_alignment.sh — structural guard against
# drift between the control-plane-built-roles list derived from
# framework/images.yaml (via `vm-scope.sh control-plane-built-roles`)
# and its three hardcoded sites in .gitlab-ci.yml (#575).
#
# ## The failure mode this guards
#
# `merge-image-versions.sh` derives the control-plane host list from
# `vm-scope.sh control-plane-built-roles`. Meanwhile the build:image
# job hardcodes the same list in three places:
#
#   1. `parallel:matrix` ROLE list — the fan-out that actually builds
#      each role's image. If a control-plane role is missing here, it
#      never gets built.
#   2. `if [ "$ROLE" = "gitlab" ] || [ "$ROLE" = "cicd" ]` closure-build
#      gate — the branch that also builds the system closure and
#      registers the GC root. If a control-plane role is missing here,
#      its closure is not built and the deploy stage's `nix copy` fails
#      later.
#   3. `artifacts.paths` — `build/closure-<role>`, `build/closure-path-
#      <role>.txt` (build:image) and `build/closure-<role>` again
#      (build:merge). If missing here, the closure and its store-path
#      pointer are not shipped to the deploy stage.
#
# #573 explicitly REUSED the existing gate (site 2) rather than adding a
# fourth copy so it did not worsen the drift — but the underlying
# triplication is a latent hazard for the next control-plane role to
# be added.
#
# This test enforces the invariant: every role emitted by
# `vm-scope.sh control-plane-built-roles` MUST appear in all three
# hardcoded sites. Under the current manifest that means gitlab and
# cicd; if a future MR adds a third control-plane built role to
# `framework/images.yaml` without updating .gitlab-ci.yml, this test
# fails loudly at CI time rather than at deploy time when the missing
# closure would break the deploy stage.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

CI_YAML=".gitlab-ci.yml"

# P2-2 (adversarial review): scope grep checks to the specific job
# blocks, not the whole .gitlab-ci.yml. Otherwise a role missing from
# build:image could still pass Site 1 if it appears in another matrix
# elsewhere (e.g. an upload:image matrix, deploy matrices, or the
# hil-boot standalone job). The extractor emits lines from the target
# job header (e.g. `build:image:`) up to (but excluding) the next
# top-level job declaration — any line starting with a non-space
# character. Runs on stdin so the caller can pipe with `< "$CI_YAML"`.
extract_ci_job() {
  local job="$1"
  awk -v job="$job" '
    # Enter the block on the header line `<job>:`
    $0 ~ "^" job ":$" { inblock = 1; print; next }
    # Leave when we hit ANY new top-level identifier (col-0, non-blank,
    # non-comment). Blank lines and comments inside a job block are
    # preserved.
    inblock && /^[A-Za-z_.]/ { inblock = 0 }
    inblock { print }
  '
}

BUILD_IMAGE_BLOCK="$(mktemp -t cp-align-build-image.XXXXXX)"
BUILD_MERGE_BLOCK="$(mktemp -t cp-align-build-merge.XXXXXX)"
trap 'rm -f "$BUILD_IMAGE_BLOCK" "$BUILD_MERGE_BLOCK"' EXIT
extract_ci_job "build:image" < "$CI_YAML" > "$BUILD_IMAGE_BLOCK"
extract_ci_job "build:merge" < "$CI_YAML" > "$BUILD_MERGE_BLOCK"

# Sanity: both extractions must have found something. If .gitlab-ci.yml
# is restructured so the header line no longer matches, the greps below
# will trivially pass; fail here instead so the operator knows the
# extractor needs updating.
if [[ ! -s "$BUILD_IMAGE_BLOCK" ]]; then
  test_start "0a" "extract build:image block from .gitlab-ci.yml"
  test_fail "extract_ci_job build:image emitted 0 lines — extractor needs updating"
  runner_summary
fi
if [[ ! -s "$BUILD_MERGE_BLOCK" ]]; then
  test_start "0b" "extract build:merge block from .gitlab-ci.yml"
  test_fail "extract_ci_job build:merge emitted 0 lines — extractor needs updating"
  runner_summary
fi

# --- Derive the control-plane-built-roles authoritative list --------------
# Sorting is intentional: the alignment assertions below compare sets, not
# manifest ordering. `vm-scope.sh control-plane-built-roles` emits the list
# in manifest insertion order (see cmd_control_plane_built_roles in
# vm-scope.sh) — we sort here so callers cannot accidentally rely on order.
# bash 3.2 compat: no `mapfile`. Read line by line into a plain array.
CP_ROLES=()
while IFS= read -r line; do
  CP_ROLES+=("$line")
done < <(framework/scripts/vm-scope.sh control-plane-built-roles | sort)

if [[ "${#CP_ROLES[@]}" -eq 0 ]]; then
  test_start "0" "control-plane-built-roles emits at least one role"
  test_fail "vm-scope.sh control-plane-built-roles returned empty — cannot align"
  runner_summary
fi

# --- Site 1: parallel:matrix ROLE list ------------------------------------
# The matrix is the full buildable-roles list; we assert it INCLUDES every
# control-plane role. A missing role here means the fan-out never builds
# that image.
test_start "1" "site 1: parallel:matrix ROLE list contains every control-plane role"
MISSING_MATRIX=""
for role in "${CP_ROLES[@]}"; do
  # `-` prefix identifies a matrix ROLE list entry; anchored with
  # `[[:space:]]*` to tolerate indentation changes.
  if ! grep -Eq "^[[:space:]]*-[[:space:]]+${role}[[:space:]]*$" "$BUILD_IMAGE_BLOCK"; then
    MISSING_MATRIX+=" ${role}"
  fi
done
if [[ -z "$MISSING_MATRIX" ]]; then
  test_pass "matrix contains: ${CP_ROLES[*]}"
else
  test_fail "matrix missing:${MISSING_MATRIX} — .gitlab-ci.yml build:image parallel:matrix needs update"
fi

# --- Site 2: closure-build gate ------------------------------------------
# The gate is an OR-chain: `[ "$ROLE" = "gitlab" ] || [ "$ROLE" = "cicd" ]`
# per current shape. Every control-plane role must appear as an OR clause.
# We match relaxed whitespace to tolerate future reformatting.
test_start "2" "site 2: \$ROLE closure-build gate branches on every control-plane role"
MISSING_GATE=""
for role in "${CP_ROLES[@]}"; do
  # The clause is `[ "$ROLE" = "gitlab" ]` (or cicd). Use fixed-string
  # match since the shell syntax is stable and the role name is the sole
  # variable.
  if ! grep -Fq "[ \"\$ROLE\" = \"${role}\" ]" "$BUILD_IMAGE_BLOCK"; then
    MISSING_GATE+=" ${role}"
  fi
done
if [[ -z "$MISSING_GATE" ]]; then
  test_pass "gate branches on every role: ${CP_ROLES[*]}"
else
  test_fail "gate missing OR-clauses:${MISSING_GATE} — add [ \"\$ROLE\" = \"<role>\" ] || ..."
fi

# --- Site 3: artifacts.paths ---------------------------------------------
# The build:image job artifacts include:
#   - build/closure-<role>
#   - build/closure-path-<role>.txt
# The build:merge job artifacts include only:
#   - build/closure-<role>
# All three must include every control-plane role.
test_start "3" "site 3: artifacts.paths include build/closure-<role> and build/closure-path-<role>.txt for every control-plane role"
MISSING_ARTIFACT=""
for role in "${CP_ROLES[@]}"; do
  # `build/closure-<role>` must appear in the build:image block AND the
  # build:merge block. Checking each independently means a missing role
  # in either block is caught with a specific label.
  IMG_CLOSURE_COUNT=$(grep -cF "build/closure-${role}" "$BUILD_IMAGE_BLOCK" || true)
  MRG_CLOSURE_COUNT=$(grep -cF "build/closure-${role}" "$BUILD_MERGE_BLOCK" || true)
  # `build/closure-path-<role>.txt` must appear at least ONCE (build:image).
  PATH_COUNT=$(grep -cF "build/closure-path-${role}.txt" "$BUILD_IMAGE_BLOCK" || true)
  if [[ "$IMG_CLOSURE_COUNT" -lt 1 ]]; then
    MISSING_ARTIFACT+=" ${role}(build:image-closure=0)"
  fi
  if [[ "$MRG_CLOSURE_COUNT" -lt 1 ]]; then
    MISSING_ARTIFACT+=" ${role}(build:merge-closure=0)"
  fi
  if [[ "$PATH_COUNT" -lt 1 ]]; then
    MISSING_ARTIFACT+=" ${role}(build:image-path=0)"
  fi
done
if [[ -z "$MISSING_ARTIFACT" ]]; then
  test_pass "artifacts include closure + closure-path for every role: ${CP_ROLES[*]}"
else
  test_fail "artifacts missing:${MISSING_ARTIFACT} — add build/closure-<role> and build/closure-path-<role>.txt"
fi

# --- Bonus: no ORPHAN closure-<role> paths in artifacts -------------------
# The inverse of Site 3: if .gitlab-ci.yml carries `build/closure-foo` but
# `foo` is NOT in control-plane-built-roles, we've drifted (a role was
# removed from images.yaml but its artifact path wasn't cleaned up). Not
# a functional break (extra artifact paths are harmless), but a signal of
# incomplete cleanup.
test_start "4" "no orphan closure-<role> paths in .gitlab-ci.yml artifacts"
ORPHANS=""
# Extract every unique <role> mentioned in a `build/closure-<role>` path.
# Filter out `build/closure-paths.json` (a different file, not a role).
# `build/closure-<role>` and `build/closure-path-<role>.txt` both match
# the base pattern; strip the `path-` prefix from the latter so the
# role extraction is uniform, then filter out `paths` (from
# `build/closure-paths.json`, which is a different file, not a role).
# Orphan check: scoped to build:image + build:merge blocks so we do not
# flag references from other unrelated matrices/jobs. If a role appears
# in EITHER extracted block, it is candidate; then we compare against
# CP_ROLES.
CLOSURE_ROLES_IN_YAML=$(
  { grep -oE 'build/closure-[a-zA-Z0-9_-]+' "$BUILD_IMAGE_BLOCK"; \
    grep -oE 'build/closure-[a-zA-Z0-9_-]+' "$BUILD_MERGE_BLOCK"; } \
    | sed -E 's|^build/closure-path-||; s|^build/closure-||' \
    | grep -Ev '^paths$' \
    | sort -u || true
)
for role in $CLOSURE_ROLES_IN_YAML; do
  FOUND=0
  for cp in "${CP_ROLES[@]}"; do
    [[ "$cp" == "$role" ]] && FOUND=1 && break
  done
  [[ "$FOUND" -eq 0 ]] && ORPHANS+=" ${role}"
done
if [[ -z "$ORPHANS" ]]; then
  test_pass "no orphan closure-<role> paths"
else
  test_fail "orphan closure-<role> paths (roles no longer in control-plane-built-roles):${ORPHANS}"
fi

runner_summary
