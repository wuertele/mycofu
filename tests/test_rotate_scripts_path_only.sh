#!/usr/bin/env bash
# V2.7: path-only static ratchet for rotation scripts.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

rotation_files=()
while IFS= read -r file; do
  rotation_files+=("$file")
done < <(find "${REPO_ROOT}/framework/scripts" -maxdepth 1 -name 'rotate-*.sh' -type f | sort)

# probe-*.sh scripts under framework/scripts participate in the rotation
# surface at attended-window time (M1 per-holder decrypt probe added in
# #813 defect 2). They handle the same key material as rotate-*.sh and
# must obey the same ratchets (V2.7-prove-negative-redirection for
# whole-file `sops -d`, path-only for extracts). Adding here so the
# static ratchets scan them going forward — codex/claude R1 P2 finding.
while IFS= read -r file; do
  rotation_files+=("$file")
done < <(find "${REPO_ROOT}/framework/scripts" -maxdepth 1 -name 'probe-*.sh' -type f | sort)

drt009="${REPO_ROOT}/framework/dr-tests/tests/DRT-009-key-rotation.sh"
if [[ -f "$drt009" ]]; then
  rotation_files+=("$drt009")
fi

# Callers of rotation scripts and other scripts that handle the same tracked
# secrets stay in the sensitive-output scan.
direct_caller_files=()
for rel in \
  framework/scripts/backup-now.sh \
  framework/scripts/check-rotation-manifest.sh \
  framework/scripts/configure-gitlab.sh \
  framework/scripts/register-runner.sh \
  framework/scripts/restore-from-pbs.sh \
  framework/scripts/tofu-wrapper.sh; do
  if [[ -f "${REPO_ROOT}/${rel}" ]]; then
    direct_caller_files+=("${REPO_ROOT}/${rel}")
  fi
done

failures_file="$(mktemp "${TMPDIR:-/tmp}/rotate-path-only.XXXXXX")"
trap 'rm -f "$failures_file"' EXIT

test_start "V2.7-scope" "rotation ratchet is bounded to rotation scripts, their callers, and same-secret helper scripts"
if [[ "${#rotation_files[@]}" -ge 3 && "${#direct_caller_files[@]}" -ge 2 ]]; then
  test_pass "found ${#rotation_files[@]} rotation-surface files and ${#direct_caller_files[@]} same-secret helper files"
else
  test_fail "expected at least the three MR-4 rotate scripts plus same-secret helpers"
fi

test_start "V2.7-no-command-substitution" "no sensitive SOPS extract is assigned through command substitution"
# Command substitution requires $(...) or backticks. Env-var-prefixed calls
# that redirect stdout to a file (e.g. SOPS_AGE_KEY_FILE=... sops -d --extract
# ... > "$OUT_FILE") are the path-only contract this ratchet is asserting,
# not the pattern it is guarding against — a prior version also flagged them
# and false-positived on the issue #802 defect-1 fix. See the case that made
# this concrete: rotate-gitlab-root-password.sh's Step 2 escrow write.
for file in "${rotation_files[@]}"; do
  awk '
    /sops[[:space:]]+-d[[:space:]]+--extract/ &&
    /(sops_age_key|ssh_privkey|_unseal_key|_root_token|gitlab_root_password)/ &&
    (/\$\(/ || /`/) {
      print FILENAME ":" FNR ":" $0
    }
  ' "$file" >> "$failures_file"
done
if [[ ! -s "$failures_file" ]]; then
  test_pass "sensitive extracts are redirected to files or external paths, not shell variables"
else
  test_fail "sensitive SOPS extract command substitution found"
  cat "$failures_file" >&2
fi
: > "$failures_file"

test_start "V2.7-direct-caller-sensitive-output" "rotation-script callers and same-secret helper scripts cannot echo tracked secret values"
for file in "${direct_caller_files[@]}"; do
  awk '
    BEGIN {
      sensitive = "sops_age_key|ssh_privkey|gitlab_root_password|gitlab_runner_registration_token|vault_.*_unseal_key|vault_.*_root_token|_unseal_key|_root_token"
    }
    /sops[[:space:]]+-d[[:space:]]+--extract/ && $0 ~ sensitive {
      if ($0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/) {
        var = $0
        sub(/^[[:space:]]*/, "", var)
        sub(/=.*/, "", var)
        secret_vars[var] = 1
      }
      if ($0 ~ /^[[:space:]]*(echo|printf)[[:space:]]/) {
        print FILENAME ":" FNR ":" $0
      }
    }
    /^[[:space:]]*(echo|printf)[[:space:]]/ {
      for (var in secret_vars) {
        if (index($0, "$" var) || index($0, "${" var "}")) {
          print FILENAME ":" FNR ":" $0
        }
      }
    }
  ' "$file" >> "$failures_file"
done
if [[ ! -s "$failures_file" ]]; then
  test_pass "direct callers do not print tracked SOPS extract values"
else
  test_fail "direct caller can echo a tracked secret value"
  cat "$failures_file" >&2
fi
: > "$failures_file"

test_start "V2.7-path-references" "drivers operate through SOPS_AGE_KEY_FILE or escrow paths, not logged values"
for file in "${rotation_files[@]}"; do
  base="$(basename "$file")"
  case "$base" in
    rotate-sops-recipient.sh)
      grep -q 'SOPS_AGE_KEY_FILE' "$file" || printf '%s: missing SOPS_AGE_KEY_FILE reference\n' "$file" >> "$failures_file"
      grep -q 'ESCROW_' "$file" || printf '%s: missing escrow path reference\n' "$file" >> "$failures_file"
      ;;
    rotate-gitlab-root-password.sh|rotate-vault-credentials.sh)
      grep -q 'ESCROW_' "$file" || printf '%s: missing escrow path reference\n' "$file" >> "$failures_file"
      ;;
  esac
done
if [[ ! -s "$failures_file" ]]; then
  test_pass "rotation scripts expose path contracts for key material"
else
  test_fail "path-only contract missing from one or more drivers"
  cat "$failures_file" >&2
fi
: > "$failures_file"

test_start "V2.7-prove-negative-redirection" "prove-negative sops decrypts redirect stdout to /dev/null"
# The prove-negative doctrine applies to WHOLE-FILE `sops -d` calls: on
# accidental success, the entire cleartext YAML would land on stdout, so
# stdout must be redirected to /dev/null. `sops -d --extract` yields only
# the extracted field and is used to write escrow values to specific files
# — its redirection target is intentionally the escrow path, not /dev/null.
for file in "${rotation_files[@]}"; do
  awk '
    /SOPS_AGE_KEY_FILE=.*sops[[:space:]]+-d/ && !/--extract/ && !/>[[:space:]]*"?\/dev\/null/ {
      print FILENAME ":" FNR ":" $0
    }
  ' "$file" >> "$failures_file"
done
if [[ ! -s "$failures_file" ]]; then
  test_pass "SOPS prove-negative decrypts have stdout redirection"
else
  test_fail "prove-negative SOPS decrypt without stdout redirection found"
  cat "$failures_file" >&2
fi
: > "$failures_file"

runner_summary
