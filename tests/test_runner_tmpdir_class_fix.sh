#!/usr/bin/env bash
# test_runner_tmpdir_class_fix.sh — G4 teeth for #537.
#
# Two invariants:
#
# 1. gitlab-runner.nix sets TMPDIR=/nix/tmp at the systemd service
#    `environment` level so every child job inherits it, AND declares a
#    systemd-tmpfiles age-sweep for the mktemp-shaped corpses on the
#    new location. Together these make the class fix structural:
#    relocation + active cleanup.
#
# 2. .gitlab-ci.yml has NO per-job `TMPDIR:` override. Once #537 lands,
#    every job's scratch resolves to /nix/tmp via the runner env; any
#    per-job override is the exact per-instance-patch pattern the
#    issue rules out.
#
# Failure of either invariant reintroduces one of the two failure
# modes: (a) removing the global TMPDIR revives the 256 MiB overlay
# ENOSPC class bug; (b) re-adding per-job TMPDIR revives the per-
# instance-patch treadmill (#510-shaped); (c) removing the sweep rule
# revives the "relocation trap" — unbounded growth of /nix/tmp.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
MODULE="${REPO_ROOT}/framework/nix/modules/gitlab-runner.nix"
CI="${REPO_ROOT}/.gitlab-ci.yml"

source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "1" "gitlab-runner.nix exists and is readable"
if [[ -r "${MODULE}" ]]; then
  test_pass "found ${MODULE#${REPO_ROOT}/}"
else
  test_fail "missing ${MODULE}"
  runner_summary
fi

test_start "2" "gitlab-runner service environment sets TMPDIR via scratchDir let-binding"
# Two invariants in one:
#   (a) the runner service environment binds TMPDIR at all, and
#   (b) it binds via the `scratchDir` let-binding (or the literal /nix/tmp).
# Deriving from `scratchDir` is the G1 finding-C1 fix (single source of
# truth for scratch path across build-dir, tmpfiles, service env,
# system-wide env). The literal alternative is also accepted so a future
# refactor that drops the let-binding but keeps the value doesn't fail
# for cosmetics.
service_env="$(awk '
  /systemd\.services\.gitlab-runner = \{/,/^  \};/ {
    if (/environment = \{/) inenv=1
    if (inenv) print
    if (inenv && /^    \};/) inenv=0
  }
' "${MODULE}")"
if grep -qE '^\s*TMPDIR\s*=\s*(scratchDir|"/nix/tmp")\s*;' <<<"${service_env}"; then
  test_pass "systemd.services.gitlab-runner.environment.TMPDIR = scratchDir (or literal /nix/tmp)"
else
  test_fail "gitlab-runner service environment must set TMPDIR = scratchDir (class-level fix for #537 job scratch ENOSPC)"
fi

test_start "3" "system-wide environment.variables.TMPDIR bound via scratchDir let-binding"
if grep -qE '^\s*environment\.variables\.TMPDIR\s*=\s*(scratchDir|"/nix/tmp")\s*;' "${MODULE}"; then
  test_pass "environment.variables.TMPDIR = scratchDir (defense-in-depth for interactive shells)"
else
  test_fail "expected system-wide environment.variables.TMPDIR = scratchDir in ${MODULE#${REPO_ROOT}/}"
fi

test_start "4" "systemd.tmpfiles rule sweeps mktemp-shaped corpses on scratchDir with exact 6h age"
# The rule form `e <scratchDir>/tmp.* - - - 6h` sweeps bare `mktemp` /
# `mktemp -d` corpses on the persistent store. The 6h age is a policy
# choice (Reviewer B P3): a future edit to "1h" would drop legitimate
# in-flight scratch; "7d" would revive the "relocation trap" the issue
# names. Enforce the exact value so both drifts trip the ratchet.
# Accept either the derived form (`${scratchDir}/tmp.*`) or the literal
# (`/nix/tmp/tmp.*`) for symmetry with assertions 2/3.
if grep -qE '"e (\$\{scratchDir\}|/nix/tmp)/tmp\.\* - - - (\$\{scratchSweepAge\}|6h)"' "${MODULE}"; then
  test_pass "found exact-6h sweep rule for scratchDir/tmp.*"
else
  test_fail "expected systemd.tmpfiles rule of shape \"e \${scratchDir}/tmp.* - - - \${scratchSweepAge}\" (or literal /nix/tmp/tmp.* / 6h) (active cleanup for relocated scratch)"
fi

test_start "4b" "scratchDir let-binding and sweep-rule scratchDir are the same value"
# Reviewer C finding 2: if a future refactor sets scratchDir to /var/foo
# in the let-binding but leaves the sweep rule at /nix/tmp, the rule
# silently misses every corpse. Assertion 2/3/4 read either the derived
# or literal form; this alignment check pins them together — extract the
# scratchDir literal from the let-binding and confirm the sweep-rule
# path resolves to the same value under the derivation.
scratch_dir_literal="$(sed -n 's/^[[:space:]]*scratchDir[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${MODULE}" | head -1)"
if [[ -z "${scratch_dir_literal}" ]]; then
  test_warn "no scratchDir let-binding literal found — skipping alignment check (module may use inline literals)"
else
  # The sweep rule must reference either `${scratchDir}/tmp.*` (derived)
  # or the exact literal path (which by construction equals scratchDir's value).
  if grep -qE "\"e (\\\$\\{scratchDir\\}|${scratch_dir_literal})/tmp\.\* - - - " "${MODULE}"; then
    test_pass "sweep-rule path aligns with scratchDir = \"${scratch_dir_literal}\""
  else
    test_fail "scratchDir = \"${scratch_dir_literal}\" but the sweep rule targets a different path"
  fi
fi

test_start "5" ".gitlab-ci.yml contains no per-job TMPDIR override"
# Any per-job or global variables: block that sets TMPDIR revives the
# #510-style per-instance patching pattern this class fix supersedes.
offenders="$(grep -nE '^[[:space:]]+TMPDIR:' "${CI}" || true)"
if [[ -z "${offenders}" ]]; then
  test_pass "no TMPDIR override present in .gitlab-ci.yml"
else
  test_fail "per-job TMPDIR override(s) reintroduced (#510 anti-pattern):"
  while IFS= read -r line; do
    echo "      ${line}"
  done <<<"${offenders}"
fi

test_start "6" ".gitlab-ci.yml prior stale prefix-specific tmpfiles rule is gone"
# The publish-filter-test.* rule was the #534-adjacent per-prefix sweep;
# the class fix retires it. Its continued presence in gitlab-runner.nix
# would indicate a merge conflict resolved the wrong way.
if grep -qE '"e /tmp/publish-filter-test\.\*' "${MODULE}"; then
  test_fail "prefix-specific /tmp/publish-filter-test.* rule still present; should be removed (superseded by /nix/tmp/tmp.* sweep)"
else
  test_pass "prefix-specific rule removed (superseded)"
fi

runner_summary
