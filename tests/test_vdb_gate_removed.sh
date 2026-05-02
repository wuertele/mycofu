#!/usr/bin/env bash
# test_vdb_gate_removed.sh - static ratchet for Sprint 031 Path A.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

VDB_WORD="vdb"
DEPLOY_WORD="deploy"
LEGACY_GATE="wait-for-${VDB_WORD}"
LEGACY_READY="${VDB_WORD}-ready.target"
LEGACY_FLAG="${VDB_WORD}-restore-expected"
LEGACY_VAR="${VDB_WORD}_restore_expected"
LEGACY_PATTERNS=(
  "${LEGACY_GATE}"
  "${LEGACY_READY}"
  "/run/secrets/${LEGACY_FLAG}"
  "${LEGACY_VAR}"
  "Upholds="
  "check-first-${DEPLOY_WORD}-marker"
  "maybe_accept_first_${DEPLOY_WORD}_marker"
  "cicd-first-${DEPLOY_WORD}-policy"
)
LEGACY_RULE_NARRATIVE_PATTERNS=(
  "post-apply recovery suite"
  "post-boot restore"
  "runs \`restore-from-pbs\\.sh\` which"
  "[Pp]lanned fix.*(#224|safe-apply|restore)"
  "[Ff]uture sprint will address"
  "[Rr]estore precious state from PBS"
  "creating empty ${VDB_WORD} VMs.*then stopping"
  "creates all framework VMs fresh.*empty ${VDB_WORD}"
  "stop each framework VM with precious state.*restore.*restart"
  "[Ss]top[s]?\\b.{0,50}\\b[Vv][Mm]\\b.{0,50}[Rr]estor.{0,50}\\b[Ss]tart(s|ed)?\\b"
  "[Rr]estore[ds]? (only )?${VDB_WORD}( from PBS)?.{0,50}\\b[Ss]tart(s|ed)?\\b (it|the VM)"
  "[Ff]resh-init.{0,80}\\bLevel [0-9]"
  "Level [0-9].{0,80}[Ff]resh-init"
  "[Ff]resh empty ${VDB_WORD}"
  "[Mm]anually stop.{0,50}[Rr]estor.{0,80}\\b[Ss]tart(s|ed)?\\b"
  "post-creation stop"
  "If no backup exists: skips"
  "The step is always safe to run.*PBS"
  "restored from PBS after"
)

PATTERN="$(IFS='|'; printf '%s' "${LEGACY_PATTERNS[*]}")"

test_start "1" "legacy guest-side vdb gate files are absent"
missing=0
for path in \
  "${REPO_ROOT}/framework/nix/modules/${LEGACY_GATE}.nix" \
  "${REPO_ROOT}/framework/scripts/restore-after-${DEPLOY_WORD}.sh"
do
  if [[ -e "$path" ]]; then
    missing=1
    printf '    unexpected file: %s\n' "$path" >&2
  fi
done
if [[ "$missing" -eq 0 ]]; then
  test_pass "legacy gate and post-boot restore files are absent"
else
  test_fail "legacy gate or post-boot restore file still exists"
fi

test_start "2" "production code contains no legacy guest-side vdb gate references"
set +e
MATCHES="$(
  git -C "${REPO_ROOT}" grep -nE -e "$PATTERN" -- \
    ':!docs/**' \
    ':!**/*.md' \
    ':!tests/**'
)"
GREP_STATUS=$?
set -e

if [[ "$GREP_STATUS" -eq 1 ]]; then
  test_pass "no legacy vdb gate references remain outside docs"
elif [[ "$GREP_STATUS" -eq 0 ]]; then
  test_fail "legacy vdb gate references remain outside docs"
  printf '%s\n' "$MATCHES" >&2
else
  test_fail "git grep failed while checking legacy vdb gate references"
  printf '%s\n' "$MATCHES" >&2
fi

test_start "3" "authoritative docs contain no stale post-boot restore or guest-gate instructions"
RULE_GREP_ARGS=(
  -e "restore-after-${DEPLOY_WORD}"
  -e "${LEGACY_GATE}"
  -e "${LEGACY_READY}"
)
for pattern in "${LEGACY_RULE_NARRATIVE_PATTERNS[@]}"; do
  RULE_GREP_ARGS+=(-e "$pattern")
done

RULE_DOC_TARGETS=(
  "${REPO_ROOT}/.claude/rules"
  "${REPO_ROOT}/architecture.md"
  "${REPO_ROOT}/implementation-plan.md"
  "${REPO_ROOT}/OPERATIONS.md"
  "${REPO_ROOT}/GETTING-STARTED.md"
  "${REPO_ROOT}/README.md"
  "${REPO_ROOT}/CLAUDE.md"
  "${REPO_ROOT}/convergent-deploy.md"
  "${REPO_ROOT}/framework/scripts/README.md"
  "${REPO_ROOT}/framework/docs/CONTRIBUTING.md"
  "${REPO_ROOT}/site/bringup.md"
)
for path in "${REPO_ROOT}"/framework/dr-tests/*.md; do
  [[ -e "$path" ]] && RULE_DOC_TARGETS+=("$path")
done
while IFS= read -r -d '' path; do
  RULE_DOC_TARGETS+=("$path")
done < <(find "${REPO_ROOT}/framework/catalog" -type f -name '*.md' -print0)

set +e
RULE_MATCHES="$(
  grep -rnE --include='*.md' \
    "${RULE_GREP_ARGS[@]}" \
    "${RULE_DOC_TARGETS[@]}"
)"
RULE_GREP_STATUS=$?
set -e

if [[ "$RULE_GREP_STATUS" -eq 1 ]]; then
  test_pass "authoritative docs only describe the preboot restore flow"
elif [[ "$RULE_GREP_STATUS" -eq 0 ]]; then
  test_fail "authoritative docs still contain stale restore/gate instructions"
  printf '%s\n' "$RULE_MATCHES" >&2
else
  test_fail "grep failed while checking authoritative docs"
  printf '%s\n' "$RULE_MATCHES" >&2
fi

test_start "4" "authoritative docs contain no multiline stop/restore/start prescriptions"
MULTILINE_RULE_PATTERNS=(
  '(?is)^\s*\d+\.\s+[^\n]*\bstop\b[^\n]*(?:\n\s*\d+\.\s+[^\n]*){0,5}\n\s*\d+\.\s+[^\n]*\brestore[^\n]*(?:\n\s*\d+\.\s+[^\n]*){0,5}\n\s*\d+\.\s+[^\n]*\bstart\b[^\n]*'
  '(?is)^\s*\d+\.\s+[^\n]*\bdestroy[^\n]*(?:\n\s*\d+\.\s+[^\n]*){0,5}\n\s*\d+\.\s+[^\n]*\brecreate[^\n]*(?:\n\s*\d+\.\s+[^\n]*){0,5}\n\s*\d+\.\s+[^\n]*\brestore[^\n]*\bvdb[^\n]*'
)

# Collect every *.md file under the rule doc targets (mirrors rg --glob '*.md').
MULTILINE_FILES=()
while IFS= read -r -d '' path; do
  MULTILINE_FILES+=("$path")
done < <(
  for target in "${RULE_DOC_TARGETS[@]}"; do
    if [[ -d "$target" ]]; then
      find "$target" -type f -name '*.md' -print0
    elif [[ -f "$target" && "$target" == *.md ]]; then
      printf '%s\0' "$target"
    fi
  done
)

set +e
MULTILINE_RULE_MATCHES="$(
  python3 - "${MULTILINE_RULE_PATTERNS[@]}" -- "${MULTILINE_FILES[@]}" <<'PY'
import re
import sys

argv = sys.argv[1:]
sep = argv.index('--')
patterns = [re.compile(p) for p in argv[:sep]]
files = argv[sep + 1:]

found = False
for path in files:
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    except OSError:
        continue
    for pat in patterns:
        for m in pat.finditer(text):
            line = text.count('\n', 0, m.start()) + 1
            snippet = m.group(0).splitlines()[0] if m.group(0) else ''
            print(f"{path}:{line}:{snippet}")
            found = True

sys.exit(0 if found else 1)
PY
)"
MULTILINE_RULE_STATUS=$?
set -e

if [[ "$MULTILINE_RULE_STATUS" -eq 1 ]]; then
  test_pass "authoritative docs do not prescribe post-boot ordered-list restore"
elif [[ "$MULTILINE_RULE_STATUS" -eq 0 ]]; then
  test_fail "authoritative docs still contain multiline stale restore instructions"
  printf '%s\n' "$MULTILINE_RULE_MATCHES" >&2
else
  test_fail "python3 multiline scan failed while checking authoritative docs"
  printf '%s\n' "$MULTILINE_RULE_MATCHES" >&2
fi

runner_summary
