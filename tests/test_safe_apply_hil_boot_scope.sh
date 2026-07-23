#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SAFE_APPLY="${REPO_ROOT}/framework/scripts/safe-apply.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "$SHIM_DIR"

PLAN_JSON="${TMP_DIR}/plan.json"
WRAPPER_LOG="${TMP_DIR}/tofu-wrapper.log"

cat > "$PLAN_JSON" <<'JSON'
{
  "format_version": "1.2",
  "resource_changes": [
    {
      "address": "module.hil_boot.proxmox_virtual_environment_vm.vm",
      "change": { "actions": ["update"] }
    },
    {
      "address": "module.dns1_dev.proxmox_virtual_environment_vm.vm",
      "change": { "actions": ["update"] }
    },
    {
      "address": "module.gatus.proxmox_virtual_environment_vm.vm",
      "change": { "actions": ["update"] }
    },
    {
      "address": "module.gitlab.proxmox_virtual_environment_vm.vm",
      "change": { "actions": ["update"] }
    }
  ]
}
JSON

cat > "${TMP_DIR}/tofu-wrapper-shim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${WRAPPER_LOG:?}"
if [[ "${1:-}" == "plan" ]]; then
  out=""
  for arg in "$@"; do
    case "$arg" in
      -out=*) out="${arg#-out=}" ;;
    esac
  done
  [[ -n "$out" ]] || exit 98
  printf 'stub plan\n' > "$out"
  exit 0
fi
exit 99
EOF
chmod +x "${TMP_DIR}/tofu-wrapper-shim"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -chdir=* && "${2:-}" == "show" && "${3:-}" == "-json" ]]; then
  cat "${FIXTURE_PLAN_JSON:?}"
  exit 0
fi
exit 99
EOF
chmod +x "${SHIM_DIR}/tofu"

cat > "${TMP_DIR}/true-shim" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP_DIR}/true-shim"

run_safe_apply() {
  local env="$1"
  local output rc
  : > "$WRAPPER_LOG"
  set +e
  output="$(
    cd "$REPO_ROOT" && \
    PATH="${SHIM_DIR}:${PATH}" \
    FIXTURE_PLAN_JSON="$PLAN_JSON" \
    WRAPPER_LOG="$WRAPPER_LOG" \
    MYCOFU_TOFU_WRAPPER="${TMP_DIR}/tofu-wrapper-shim" \
    MYCOFU_APPROLE_CHECK="${TMP_DIR}/true-shim" \
    MYCOFU_DRIFT_CHECK="${TMP_DIR}/true-shim" \
      "$SAFE_APPLY" "$env" --dry-run 2>&1
  )"
  rc=$?
  set -e
  SAFE_APPLY_OUTPUT="$output"
  SAFE_APPLY_RC="$rc"
}

test_start "s037.3.4" "safe-apply dev dry-run includes hil_boot"
run_safe_apply dev
if [[ "$SAFE_APPLY_RC" -eq 0 ]] && \
   grep -Fq 'Targets: -target=module.dns1_dev -target=module.hil_boot' <<< "$SAFE_APPLY_OUTPUT" && \
   ! grep -Fq -- '-target=module.gatus' <<< "$SAFE_APPLY_OUTPUT"; then
  test_pass "dev dry-run targets module.hil_boot and dev modules only"
else
  test_fail "dev dry-run target categorization was wrong"
  printf '%s\n' "$SAFE_APPLY_OUTPUT" >&2
fi

test_start "s037.3.5" "safe-apply prod dry-run excludes hil_boot"
run_safe_apply prod
if [[ "$SAFE_APPLY_RC" -eq 0 ]] && \
   grep -Fq 'Targets: -target=module.gatus' <<< "$SAFE_APPLY_OUTPUT" && \
   ! grep -Fq -- '-target=module.hil_boot' <<< "$SAFE_APPLY_OUTPUT"; then
  test_pass "prod dry-run targets prod shared modules and excludes hil_boot"
else
  test_fail "prod dry-run target categorization was wrong"
  printf '%s\n' "$SAFE_APPLY_OUTPUT" >&2
fi

test_start "s037.3.6" "control-plane modules remain excluded from plan"
run_safe_apply dev
if grep -Fq -- '-exclude=module.gitlab' "$WRAPPER_LOG" && \
   grep -Fq -- '-exclude=module.cicd' "$WRAPPER_LOG" && \
   grep -Fq -- '-exclude=module.pbs' "$WRAPPER_LOG" && \
   ! grep -Fq -- '-exclude=module.hil_boot' "$WRAPPER_LOG"; then
  test_pass "safe-apply excludes control-plane modules but not hil_boot"
else
  test_fail "safe-apply control-plane exclude list changed unexpectedly"
  cat "$WRAPPER_LOG" >&2
fi

runner_summary
