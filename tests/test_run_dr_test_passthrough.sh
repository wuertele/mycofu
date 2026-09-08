#!/usr/bin/env bash
# V3.2: run-dr-test.sh argument passthrough and list-mode regressions.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

RUNNER_SRC="${REPO_ROOT}/framework/dr-tests/run-dr-test.sh"
FIXTURE_ROOT="${TMP_DIR}/fixture"
RUNNER="${FIXTURE_ROOT}/framework/dr-tests/run-dr-test.sh"
TESTS_DIR="${FIXTURE_ROOT}/framework/dr-tests/tests"

mkdir -p "$TESTS_DIR"
cp "$RUNNER_SRC" "$RUNNER"
chmod +x "$RUNNER"

write_test_script() {
  local path="$1" id="$2" name="$3" destructive="$4"
  cat > "$path" <<EOF
#!/usr/bin/env bash
# DRT-ID: ${id}
# DRT-NAME: ${name}
# DRT-TIME: fixture
# DRT-DESTRUCTIVE: ${destructive}
printf '%s argc=%s argv=' '${id}' "\$#"
printf '<%s>' "\$@"
printf '\n'
EOF
  chmod +x "$path"
}

write_test_script "${TESTS_DIR}/SYN-argv.sh" "SYN" "Synthetic Argv" "no"
for n in 1 2 3 4 5 6 7 8; do
  id="$(printf 'DRT-%03d' "$n")"
  write_test_script "${TESTS_DIR}/${id}-fixture.sh" "$id" "Fixture ${id}" "no"
done
write_test_script \
  "${TESTS_DIR}/DRT-009-key-rotation.sh" \
  "DRT-009" \
  "Key Rotation" \
  "depth-dependent (rekey: no | resecret-all: yes)"

test_start "V3.2-passthrough" "runner passes trailing args after the DRT ID"
OUT="$(cd "$FIXTURE_ROOT" && framework/dr-tests/run-dr-test.sh SYN foo bar baz)"
if [[ "$OUT" == 'SYN argc=3 argv=<foo><bar><baz>' ]]; then
  test_pass "trailing argv reached the selected test script unchanged"
else
  test_fail "runner did not pass through trailing argv; got: ${OUT}"
fi

test_start "V3.2-single-arg" "single-arg invocation remains argv-empty for DRT-001..008"
ok=1
for n in 1 2 3 4 5 6 7 8; do
  id="$(printf 'DRT-%03d' "$n")"
  out="$(cd "$FIXTURE_ROOT" && framework/dr-tests/run-dr-test.sh "$id")"
  expected="${id} argc=0 argv=<>"
  if [[ "$out" != "$expected" ]]; then
    ok=0
    printf 'expected %s, got %s\n' "$expected" "$out" >&2
  fi
done
if [[ "$ok" -eq 1 ]]; then
  test_pass "DRT-001..008 single-argument calls still receive no script argv"
else
  test_fail "one or more DRT-001..008 single-argument calls received extra argv"
fi

test_start "V3.2-list-raw-header" "list mode prints raw non-yes destructive header values"
LIST_OUT="$(cd "$FIXTURE_ROOT" && framework/dr-tests/run-dr-test.sh --list)"
if grep -Fq 'depth-dependent (rekey: no | resecret-all: yes)' <<< "$LIST_OUT"; then
  test_pass "raw depth-dependent DRT-DESTRUCTIVE header appears in list output"
else
  test_fail "list output did not preserve raw depth-dependent destructive header"
  printf '%s\n' "$LIST_OUT" >&2
fi

runner_summary
