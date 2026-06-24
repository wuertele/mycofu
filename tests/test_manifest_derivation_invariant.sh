#!/usr/bin/env bash
# test_manifest_derivation_invariant.sh — manifest comes from default plan.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
EVENT_LOG="${TMP_DIR}/events.log"
MANIFEST_CAPTURE="${TMP_DIR}/manifest-capture.json"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/framework/tofu/root" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"

for script in check-approle-creds.sh check-control-plane-drift.sh; do
  cat > "${FIXTURE_REPO}/framework/scripts/${script}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/${script}"
done

cat > "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper %s\n' "$*" >> "${EVENT_LOG}"
case "${1:-}" in
  plan)
    for arg in "$@"; do
      [[ "$arg" == -out=* ]] && : > "${arg#-out=}"
    done
    ;;
  apply|state)
    ;;
esac
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

cat > "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${EVENT_LOG}"
manifest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) manifest="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$manifest" "${MANIFEST_CAPTURE}"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

for script in configure-replication.sh post-deploy.sh; do
  cat > "${FIXTURE_REPO}/framework/scripts/${script}" <<EOF
#!/usr/bin/env bash
printf '${script} %s\n' "\$*" >> "${EVENT_LOG}"
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/${script}"
done

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s' "${STUB_PLAN_JSON}"
  exit 0
fi
exit 2
EOF
chmod +x "${SHIM_DIR}/tofu"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[]'
exit 0
EOF
chmod +x "${SHIM_DIR}/ssh"

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-o=json" ]]; then
  cat <<'JSON'
{"nodes":[{"name":"pve01","mgmt_ip":"127.0.0.1"}],"vms":{"vault_dev":{"vmid":303,"backup":true}}}
JSON
  exit 0
fi
echo "127.0.0.1"
EOF
chmod +x "${SHIM_DIR}/yq"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
vms:
  vault_dev:
    vmid: 303
    backup: true
EOF

export PATH="${SHIM_DIR}:${PATH}"
export EVENT_LOG MANIFEST_CAPTURE
export STUB_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"started":false},"after":{"started":true}}}]}'

set +e
OUT="$(cd "${FIXTURE_REPO}" && framework/scripts/safe-apply.sh dev 2>&1)"
RC=$?
set -e

test_start "16.1" "safe-apply fixture exits successfully"
if [[ "$RC" -eq 0 ]]; then
  test_pass "safe-apply exited 0"
else
  test_fail "safe-apply failed"
  printf '%s\n' "$OUT" >&2
fi

test_start "16.2" "manifest includes started-false-resume from default plan"
if jq -e '.entries | length == 1 and .[0].label == "vault_dev" and .[0].vmid == 303 and .[0].reason == "started-false-resume"' "$MANIFEST_CAPTURE" >/dev/null; then
  test_pass "default-plan manifest includes the stopped VM resume"
else
  test_fail "manifest did not include started-false-resume"
  cat "$MANIFEST_CAPTURE" >&2
fi

test_start "16.3" "membership plan is run without Phase 1 start/HA vars"
PLAN_LINE="$(grep '^tofu-wrapper plan ' "$EVENT_LOG" | head -1 || true)"
if [[ "$PLAN_LINE" != *"start_vms=false"* && "$PLAN_LINE" != *"register_ha=false"* ]]; then
  test_pass "manifest membership plan uses defaults"
else
  test_fail "plan line contains Phase 1 vars: $PLAN_LINE"
fi

test_start "16.4" "Phase 1 apply still uses stopped/no-HA vars"
if grep -Fq 'tofu-wrapper apply -target=module.vault_dev -var=start_vms=false -var=register_ha=false -auto-approve' "$EVENT_LOG"; then
  test_pass "apply that follows uses stopped/no-HA vars"
else
  test_fail "Phase 1 apply vars missing"
  cat "$EVENT_LOG" >&2
fi

runner_summary
