#!/usr/bin/env bash
# test_check_plan_images_present.sh — refuse missing plan images before deploy.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
CONFIG="${TMP_DIR}/config.yaml"
PLAN="${TMP_DIR}/plan.json"
REPLACE_PLAN="${TMP_DIR}/replace-plan.json"
SCRIPT="${REPO_ROOT}/framework/scripts/check-plan-images-present.sh"

mkdir -p "$SHIM_DIR"
cat > "$CONFIG" <<'EOF'
proxmox:
  image_storage_path: /images
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
  - name: pve02
    mgmt_ip: 127.0.0.2
EOF

cat > "$PLAN" <<'EOF'
{
  "resource_changes": [
    {
      "address": "module.vault_dev.proxmox_virtual_environment_vm.vm",
      "change": {
        "actions": ["create"],
        "after": {
          "disk": [
            {"file_id": "local:iso/vault-aa000001.img"}
          ]
        }
      }
    }
  ]
}
EOF

cat > "$REPLACE_PLAN" <<'EOF'
{
  "resource_changes": [
    {
      "address": "module.vault_dev.proxmox_virtual_environment_vm.vm",
      "change": {
        "actions": ["create", "delete"],
        "before": {
          "disk": [
            {"file_id": "local:iso/vault-old00001.img"}
          ]
        },
        "after": {
          "disk": [
            {"file_id": "local:iso/vault-new00001.img"}
          ]
        }
      }
    }
  ]
}
EOF

# Fixtures for #492 regression cases: the same phantom-image name is used
# across no-op / in-place update / resume plans. If the preflight walks
# the resource despite the action filter, ssh will be invoked for
# vault-phantom0.img and the shim will report it missing on both nodes,
# turning the test red. If the fix works, ssh is never called for the
# phantom image and each plan passes with rc=0. See #492.
NO_OP_PLAN="${TMP_DIR}/no-op-plan.json"
UPDATE_PLAN="${TMP_DIR}/update-plan.json"
RESUME_PLAN="${TMP_DIR}/resume-plan.json"

cat > "$NO_OP_PLAN" <<'EOF'
{
  "resource_changes": [
    {
      "address": "module.gitlab.proxmox_virtual_environment_vm.vm",
      "change": {
        "actions": ["no-op"],
        "before": {
          "disk": [
            {"file_id": "local:iso/vault-phantom0.img"}
          ]
        },
        "after": {
          "disk": [
            {"file_id": "local:iso/vault-phantom0.img"}
          ]
        }
      }
    }
  ]
}
EOF

cat > "$UPDATE_PLAN" <<'EOF'
{
  "resource_changes": [
    {
      "address": "module.gitlab.proxmox_virtual_environment_vm.vm",
      "change": {
        "actions": ["update"],
        "before": {
          "disk": [
            {"file_id": "local:iso/vault-phantom0.img"}
          ],
          "tags": ["old"]
        },
        "after": {
          "disk": [
            {"file_id": "local:iso/vault-phantom0.img"}
          ],
          "tags": ["new"]
        }
      }
    }
  ]
}
EOF

cat > "$RESUME_PLAN" <<'EOF'
{
  "resource_changes": [
    {
      "address": "module.vault_dev.proxmox_virtual_environment_vm.vm",
      "change": {
        "actions": ["update"],
        "before": {
          "disk": [
            {"file_id": "local:iso/vault-phantom0.img"}
          ],
          "started": false
        },
        "after": {
          "disk": [
            {"file_id": "local:iso/vault-phantom0.img"}
          ],
          "started": true
        }
      }
    }
  ]
}
EOF

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  ".proxmox.image_storage_path // \"/var/lib/vz/template/iso\"")
    echo "/images"
    ;;
  ".nodes[] | [.name, .mgmt_ip] | @tsv")
    printf 'pve01\t127.0.0.1\npve02\t127.0.0.2\n'
    ;;
  *)
    echo "unexpected yq query: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/yq"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=""
cmd=""
for arg in "$@"; do
  case "$arg" in
    root@*) target="$arg" ;;
    test\ -s*) cmd="$arg" ;;
  esac
done
case "${target}:${cmd}" in
  root@127.0.0.1:"test -s /images/vault-aa000001.img")
    exit 0
    ;;
  root@127.0.0.2:"test -s /images/vault-aa000001.img")
    if [[ "${SECOND_NODE_PRESENT:-0}" == "1" ]]; then
      exit 0
    fi
    exit 1
    ;;
  root@127.0.0.1:"test -s /images/vault-new00001.img" | \
  root@127.0.0.2:"test -s /images/vault-new00001.img")
    exit 0
    ;;
  root@127.0.0.1:"test -s /images/vault-old00001.img" | \
  root@127.0.0.2:"test -s /images/vault-old00001.img")
    exit 1
    ;;
  root@127.0.0.1:"test -s /images/vault-phantom0.img" | \
  root@127.0.0.2:"test -s /images/vault-phantom0.img")
    # Absent from both nodes. #492 tests assert this image is NEVER
    # queried under no-op / in-place update / resume plans. If a query
    # slips through, the exit-1 here turns FAILURES>0 and the test
    # asserts rc=0 will fail, catching the regression.
    exit 1
    ;;
  *)
    echo "unexpected ssh command: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"

test_start "CPI.1" "missing image returns non-zero and names node/image"
set +e
OUT="$(bash "$SCRIPT" --plan-json "$PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "image vault-aa000001.img missing on node pve02 (127.0.0.2); did not deploy" <<< "$OUT"; then
  test_pass "missing image fails closed with expected diagnostic"
else
  test_fail "missing image check did not fail as expected"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.2" "all images present returns zero"
export SECOND_NODE_PRESENT=1
set +e
OUT="$(bash "$SCRIPT" --plan-json "$PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "image vault-aa000001.img present on node pve01" <<< "$OUT" &&
   grep -Fq "image vault-aa000001.img present on node pve02" <<< "$OUT"; then
  test_pass "all-present plan passes"
else
  test_fail "all-present plan did not pass"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.3" "replacement plans ignore missing before image and require after image only"
set +e
OUT="$(bash "$SCRIPT" --plan-json "$REPLACE_PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "image vault-new00001.img present on node pve01" <<< "$OUT" &&
   grep -Fq "image vault-new00001.img present on node pve02" <<< "$OUT" &&
   ! grep -Fq "vault-old00001.img" <<< "$OUT"; then
  test_pass "missing before image does not block replacement plan"
else
  test_fail "replacement plan checked the before image or missed the after image"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.5" "no-op with absent after image passes (image never queried) — #492"
# When a resource has no changes planned, its after.disk.file_id may
# still be a historical value carried in tofu state (e.g. control-plane
# VMs with ignore_changes on the disk block). The preflight must not
# treat that as a required image on the node. If this test breaks, the
# preflight is walking after for actions it shouldn't — the fix's
# action filter is not being applied.
unset SECOND_NODE_PRESENT
set +e
OUT="$(bash "$SCRIPT" --plan-json "$NO_OP_PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]] &&
   ! grep -Fq "vault-phantom0.img" <<< "$OUT"; then
  test_pass "no-op plan passed and did not query the phantom image"
else
  test_fail "no-op plan blocked deploy (or queried the absent image)"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.6" "in-place update with absent after image passes — locks out skip-no-op regression (#492)"
# ignore_changes on disk means an in-place update to a tag / memory /
# HA attribute yields actions == ["update"], NOT ["no-op"], and
# after.disk.file_id is still the ignored historical value. A
# skip-no-op fix would let this recur; the create+replace positive
# filter closes the class. This test is the explicit regression guard.
set +e
OUT="$(bash "$SCRIPT" --plan-json "$UPDATE_PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]] &&
   ! grep -Fq "vault-phantom0.img" <<< "$OUT"; then
  test_pass "in-place update plan passed and did not query the phantom image"
else
  test_fail "in-place update plan blocked deploy (or queried the absent image)"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.7" "started false->true resume with absent image passes — image already consumed at Phase 1 create (#492)"
# In the Sprint 031/041 phased flow, the started-false-resume is a Phase 2
# apply that flips started=false → true on a VM that was already created
# stopped in Phase 1. The image was consumed at Phase 1 create; Phase 2
# neither re-imports nor requires it. Validating an image for a resume
# would re-introduce the #492 false-positive class. Copy the create and
# replace arms only — NOT the started-false-resume arm.
set +e
OUT="$(bash "$SCRIPT" --plan-json "$RESUME_PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]] &&
   ! grep -Fq "vault-phantom0.img" <<< "$OUT"; then
  test_pass "resume plan passed and did not query the phantom image"
else
  test_fail "resume plan blocked deploy (or queried the absent image)"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.8" "replacement action in ['delete','create'] order also walks after image"
# OpenTofu emits ['delete','create'] instead of ['create','delete'] when
# create_before_destroy=false. The membership-based check catches both,
# but pin that behavior with an explicit fixture so a future refactor to
# actions == ['create','delete'] would fail this test.
REPLACE_REVERSE_PLAN="${TMP_DIR}/replace-reverse-plan.json"
cat > "$REPLACE_REVERSE_PLAN" <<'EOF'
{
  "resource_changes": [
    {
      "address": "module.vault_dev.proxmox_virtual_environment_vm.vm",
      "change": {
        "actions": ["delete", "create"],
        "before": {
          "disk": [
            {"file_id": "local:iso/vault-old00001.img"}
          ]
        },
        "after": {
          "disk": [
            {"file_id": "local:iso/vault-new00001.img"}
          ]
        }
      }
    }
  ]
}
EOF
set +e
OUT="$(bash "$SCRIPT" --plan-json "$REPLACE_REVERSE_PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "image vault-new00001.img present on node pve01" <<< "$OUT" &&
   grep -Fq "image vault-new00001.img present on node pve02" <<< "$OUT" &&
   ! grep -Fq "vault-old00001.img" <<< "$OUT"; then
  test_pass "reversed-order replacement plan checks the after image"
else
  test_fail "reversed-order replacement plan did not walk the after image"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.9" "malformed plan (missing actions) fails closed with diagnostic — #492 P2 codex"
# A pre-destructive-apply safety guard must not silently pass unknown
# plan shapes. If change.actions is absent or malformed, the preflight
# should refuse the deploy with a named diagnostic rather than treat
# it like a non-image-consuming skip.
MISSING_ACTIONS_PLAN="${TMP_DIR}/missing-actions-plan.json"
cat > "$MISSING_ACTIONS_PLAN" <<'EOF'
{
  "resource_changes": [
    {
      "address": "module.vault_dev.proxmox_virtual_environment_vm.vm",
      "change": {
        "after": {
          "disk": [
            {"file_id": "local:iso/vault-aa000001.img"}
          ]
        }
      }
    }
  ]
}
EOF
set +e
OUT="$(bash "$SCRIPT" --plan-json "$MISSING_ACTIONS_PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "malformed change.actions" <<< "$OUT" &&
   grep -Fq "module.vault_dev" <<< "$OUT"; then
  test_pass "missing actions fails closed and names the offending address"
else
  test_fail "missing actions did not fail closed with named diagnostic"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.10" "null actions also fails closed — #492 P2 codex"
NULL_ACTIONS_PLAN="${TMP_DIR}/null-actions-plan.json"
cat > "$NULL_ACTIONS_PLAN" <<'EOF'
{
  "resource_changes": [
    {
      "address": "module.vault_dev.proxmox_virtual_environment_vm.vm",
      "change": {
        "actions": null,
        "after": {
          "disk": [
            {"file_id": "local:iso/vault-aa000001.img"}
          ]
        }
      }
    }
  ]
}
EOF
set +e
OUT="$(bash "$SCRIPT" --plan-json "$NULL_ACTIONS_PLAN" --config "$CONFIG" 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "malformed change.actions" <<< "$OUT"; then
  test_pass "null actions fails closed"
else
  test_fail "null actions did not fail closed"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "CPI.4" "safe-apply/rebuild precondition appears before destructive markers"
SAFE_CHECK_LINE="$(grep -n 'check-plan-images-present.sh.*--plan-json' "${REPO_ROOT}/framework/scripts/safe-apply.sh" | head -1 | cut -d: -f1 || true)"
SAFE_APPLY_LINE="$(grep -n 'First apply: create/update stopped VMs' "${REPO_ROOT}/framework/scripts/safe-apply.sh" | head -1 | cut -d: -f1 || true)"
REBUILD_CHECK_LINE="$(grep -n 'check_plan_images_present "atomic-' "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" | head -1 | cut -d: -f1 || true)"
REBUILD_DESTROY_LINE="$(grep -n 'qm destroy ${VMID} --purge' "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" | head -1 | cut -d: -f1 || true)"
if [[ -n "$SAFE_CHECK_LINE" && -n "$SAFE_APPLY_LINE" && "$SAFE_CHECK_LINE" -lt "$SAFE_APPLY_LINE" &&
      -n "$REBUILD_CHECK_LINE" && -n "$REBUILD_DESTROY_LINE" && "$REBUILD_CHECK_LINE" -lt "$REBUILD_DESTROY_LINE" ]]; then
  test_pass "precondition ordering is before safe-apply apply and rebuild atomic destroy"
else
  test_fail "precondition ordering changed"
  printf 'safe_check=%s safe_apply=%s rebuild_check=%s rebuild_destroy=%s\n' \
    "$SAFE_CHECK_LINE" "$SAFE_APPLY_LINE" "$REBUILD_CHECK_LINE" "$REBUILD_DESTROY_LINE" >&2
fi

runner_summary
