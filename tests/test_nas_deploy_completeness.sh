#!/usr/bin/env bash
# Verify NAS placement-watchdog deployment includes every co-located script
# dependency used by the NAS-invoked scripts.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

REBALANCE="${REPO_ROOT}/framework/scripts/rebalance-cluster.sh"
WATCHDOG="${REPO_ROOT}/framework/scripts/placement-watchdog.sh"
CONFIGURE="${REPO_ROOT}/framework/scripts/configure-sentinel-gatus.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

DERIVED_FILE="${TMP_DIR}/derived-deps.txt"
SCP_FILE="${TMP_DIR}/scp-set.txt"

test_start "nas.files" "required scripts are present"
missing=0
for f in "${REBALANCE}" "${WATCHDOG}" "${CONFIGURE}"; do
  if [[ -f "${f}" ]]; then
    test_pass "${f#${REPO_ROOT}/} exists"
  else
    test_fail "${f#${REPO_ROOT}/} exists"
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || runner_summary

test_start "nas.derive" "derive co-located source/exec dependencies"
# Derivation contract:
# - Count shell source forms whose command word is `source` or `.` and whose
#   target token ends in .sh.
# - Count direct sibling script executions only when the command token itself
#   is `${...}/name.sh` or `"${...}/name.sh"`; assignment-only strings,
#   comments, echo/printf text, and remediation prose are intentionally ignored.
if python3 - "${REBALANCE}" "${WATCHDOG}" > "${DERIVED_FILE}" <<'PY'
import os
import re
import sys

source_re = re.compile(r'^\s*(?:source|\.)\s+([^\s;]+)')
exec_re = re.compile(r'^\s*(?:"?\$\{[^}]+\}/([^/"\s;]+\.sh)"?)(?:\s|;|$)')
assign_re = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=.*((?:/framework/scripts/(?:[^/"\s]+/)*|/lib/)[^/"\s]+\.sh)')
var_ref_re = re.compile(r'^\$([A-Za-z_][A-Za-z0-9_]*)$|^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$')
skip_re = re.compile(r'^\s*(?:#|echo\b|printf\b|cat\s+>&2\s+<<|cat\s+<<)')

deps = set()
vars_by_file = {}
for path in sys.argv[1:]:
    vars = {}
    with open(path, encoding='utf-8') as fh:
        lines = list(fh)
    for raw in lines:
        m = assign_re.match(raw.rstrip('\n'))
        if m:
            vars[m.group(1)] = m.group(2)
    vars_by_file[path] = vars

    def resolve_token(token):
        token = token.strip('"\'')
        m = var_ref_re.match(token)
        if not m:
            return token
        return vars.get(m.group(1) or m.group(2), token)

    for raw in lines:
        line = raw.rstrip('\n')
        stripped = line.strip()
        if not stripped or skip_re.match(line):
            continue

        m = source_re.match(line)
        if m:
            token = resolve_token(m.group(1))
            base = os.path.basename(token)
            if base.endswith('.sh'):
                deps.add(base)
            continue

        m = exec_re.match(line)
        if m:
            deps.add(m.group(1))

for dep in sorted(deps):
    print(dep)
PY
then
  test_pass "dependency derivation completed"
else
  test_fail "dependency derivation completed"
fi

if [[ -s "${DERIVED_FILE}" ]]; then
  while IFS= read -r dep; do
    test_pass "derived dependency: ${dep}"
  done < "${DERIVED_FILE}"
else
  test_pass "no additional source/exec dependencies derived"
fi

test_start "nas.scp" "collect placement-watchdog NAS scp set"
if python3 - "${CONFIGURE}" > "${SCP_FILE}" <<'PY'
import os
import re
import sys

scp_re = re.compile(r'\bscp\b')
script_re = re.compile(r'/framework/scripts/((?:[^/"\s]+/)*[^/"\s]+\.sh)')
dest_re = re.compile(r'/volume1/docker/placement-watchdog/')
assign_re = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=.*((?:/framework/scripts/(?:[^/"\s]+/)*|/lib/)[^/"\s]+\.sh)')
var_ref_re = re.compile(r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))')

scripts = set()
with open(sys.argv[1], encoding='utf-8') as fh:
    lines = list(fh)

vars = {}
for raw in lines:
    m = assign_re.match(raw.rstrip('\n'))
    if m:
        vars[m.group(1)] = m.group(2)

for raw in lines:
    line = raw.strip()
    if line.startswith('#'):
        continue
    if scp_re.search(line) and dest_re.search(line):
        scripts.update(os.path.basename(script) for script in script_re.findall(line))
        for m in var_ref_re.finditer(line):
            path = vars.get(m.group(1) or m.group(2))
            if path:
                scripts.add(os.path.basename(path))

for script in sorted(scripts):
    print(script)
PY
then
  test_pass "scp deployment set collected"
else
  test_fail "scp deployment set collected"
fi

if [[ -s "${SCP_FILE}" ]]; then
  while IFS= read -r script; do
    test_pass "NAS scp includes ${script}"
  done < "${SCP_FILE}"
else
  test_fail "NAS scp set is empty"
fi

test_start "nas.self" "NAS deploy copies the two invoked scripts"
for script in rebalance-cluster.sh placement-watchdog.sh; do
  if grep -qxF "${script}" "${SCP_FILE}"; then
    test_pass "${script} copied to NAS placement-watchdog directory"
  else
    test_fail "${script} copied to NAS placement-watchdog directory"
  fi
done
if grep -qxF "cidata-guard.sh" "${SCP_FILE}"; then
  test_pass "cidata-guard.sh copied to NAS placement-watchdog lib directory"
else
  test_fail "cidata-guard.sh copied to NAS placement-watchdog lib directory"
fi

test_start "nas.dependencies" "all derived dependencies are copied to NAS"
missing_deps=0
while IFS= read -r dep; do
  [[ -n "${dep}" ]] || continue
  if grep -qxF "${dep}" "${SCP_FILE}"; then
    test_pass "derived dependency copied: ${dep}"
  else
    test_fail "derived dependency missing from NAS scp set: ${dep}"
    missing_deps=1
  fi
done < "${DERIVED_FILE}"

if [[ "${missing_deps}" -eq 0 ]]; then
  test_pass "all derived dependencies are present in the NAS scp set"
fi

test_start "nas.missing-lib" "rebalance fails closed when cidata guard lib is missing"
FIXTURE_REPO="${TMP_DIR}/missing-lib-repo"
mkdir -p "${FIXTURE_REPO}/framework/scripts"
cp "${REBALANCE}" "${FIXTURE_REPO}/framework/scripts/rebalance-cluster.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/rebalance-cluster.sh"
set +e
MISSING_LIB_OUT="$(
  cd "${FIXTURE_REPO}" && bash framework/scripts/rebalance-cluster.sh 2>&1
)"
MISSING_LIB_RC=$?
set -e
if [[ "${MISSING_LIB_RC}" -ne 0 ]]; then
  test_pass "rebalance exits non-zero when cidata guard lib is absent"
else
  test_fail "rebalance exits non-zero when cidata guard lib is absent"
fi
if grep -qF "cidata guard library not found" <<<"${MISSING_LIB_OUT}" \
   && grep -qF "cidata-guard.sh" <<<"${MISSING_LIB_OUT}" \
   && grep -qF "configure-sentinel-gatus.sh" <<<"${MISSING_LIB_OUT}"; then
  test_pass "missing-lib error names cidata-guard.sh and configure-sentinel-gatus.sh"
else
  test_fail "missing-lib error names cidata-guard.sh and configure-sentinel-gatus.sh"
  echo "    OUT:"; printf '%s\n' "${MISSING_LIB_OUT}" | sed 's/^/      /'
fi

test_start "nas.old-lib-version" "rebalance fails closed when NAS cidata guard lib is older than required"
OLD_LIB_REPO="${TMP_DIR}/old-lib-repo"
mkdir -p "${OLD_LIB_REPO}/framework/scripts/lib"
cp "${REBALANCE}" "${OLD_LIB_REPO}/framework/scripts/rebalance-cluster.sh"
cat > "${OLD_LIB_REPO}/framework/scripts/lib/cidata-guard.sh" <<'OLDLIB'
# shellcheck shell=bash
CIDATA_GUARD_LIB_VERSION="2"
cidata_guard_node_change() { :; }
cidata_ha_service_node() { :; }
cidata_ha_service_state() { :; }
vm_is_ballooned() { :; }
OLDLIB
chmod +x "${OLD_LIB_REPO}/framework/scripts/rebalance-cluster.sh"
set +e
OLD_LIB_OUT="$(
  cd "${OLD_LIB_REPO}" && bash framework/scripts/rebalance-cluster.sh 2>&1
)"
OLD_LIB_RC=$?
set -e
if [[ "${OLD_LIB_RC}" -ne 0 ]]; then
  test_pass "rebalance exits non-zero when cidata guard lib is version 2"
else
  test_fail "rebalance exits non-zero when cidata guard lib is version 2"
fi
if grep -qF "version '2'" <<<"${OLD_LIB_OUT}" \
   && grep -qF "requires >= 3" <<<"${OLD_LIB_OUT}" \
   && grep -qF "configure-sentinel-gatus.sh" <<<"${OLD_LIB_OUT}"; then
  test_pass "old-version error names observed version, required floor, and configure-sentinel-gatus.sh"
else
  test_fail "old-version error names observed version, required floor, and configure-sentinel-gatus.sh"
  echo "    OUT:"; printf '%s\n' "${OLD_LIB_OUT}" | sed 's/^/      /'
fi

runner_summary
