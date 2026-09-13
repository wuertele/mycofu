#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PATTERNS="${TMP_DIR}/patterns.txt"
MATCHES="${TMP_DIR}/matches.txt"
UNEXPECTED="${TMP_DIR}/unexpected.txt"

cat > "$PATTERNS" <<'EOF'
recognized_envless=
prod_only=
DEV_EXTRAS=
PROD_EXTRAS=
CONTROL_PLANE_MODULES="module.gitlab module.cicd module.pbs"
selected_hosts=(gitlab cicd)
CONTROL_PLANE_HOSTS=(gitlab cicd)
control_plane_hosts=(gitlab cicd)
printf '%s\n' gitlab cicd
gitlab\|cicd\|pbs)
gitlab\|cicd\|pbs\|hil_boot
gitlab, cicd, pbs
for vm_key in dns1_prod dns2_prod gatus gitlab testapp_prod vault_prod
for VM_KEY in gitlab gatus
for VM_KEY in $(yq -r ".vms | to_entries[] | select(.key | test(\"_${ENV}$\")) | .key" "$CONFIG"
for APP_KEY in $(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG"
converge_vm_target_selected "module.dns_dev" || converge_vm_target_selected "module.dns_prod"
converge_vm_target_selected "module.vault_dev" || converge_vm_target_selected "module.vault_prod"
converge_vm_target_selected "module.gitlab"
converge_vm_target_selected "module.gitlab" || converge_vm_target_selected "module.cicd"
vm_keys_output="$(yq -r '.vms | keys | .[]' "$CONFIG" | sort)"
yq -r ".applications.${app_key}.environments // {} | keys | .[]" "$APPS_CONFIG"
FRAMEWORK_ROLES=$(yq -r '.roles | keys | .[]' "$FRAMEWORK_MANIFEST"
SITE_ROLES=$(yq -r '.roles | keys | .[]' "$SITE_MANIFEST"
APP_ROLES=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG"
< <(yq -r '.roles | keys | .[]' "$FRAMEWORK_MANIFEST"
< <(yq -r '.roles | keys | .[]' "$SITE_MANIFEST"
< <(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key'
EOF

: > "$MATCHES"
# Portable: use grep -r (rg/ripgrep is not in the cicd NixOS runner's PATH).
grep -r -n -F -f "$PATTERNS" "${REPO_ROOT}/framework/scripts" > "$MATCHES" || true

: > "$UNEXPECTED"
while IFS= read -r match; do
  [[ -n "$match" ]] || continue

  case "$match" in
    # The helper owns compatibility diagnostics and human-readable reasons.
    "${REPO_ROOT}/framework/scripts/vm-scope.sh:"*) continue ;;
    # Cosmetic usage hint; not a classifier or deployment allowlist.
    "${REPO_ROOT}/framework/scripts/git-deploy-context.sh:"*"Use real module names from framework/tofu/root"*) continue ;;
    # GE1: cert-storage/ACME budget inventory, not scope taxonomy.
    "${REPO_ROOT}/framework/scripts/certbot-cluster.sh:"*"for vm_key in dns1_prod dns2_prod gatus gitlab testapp_prod vault_prod"*) continue ;;
    # GE1: cert cleanup/wrong-domain cert inventory for certbot-bearing VMs.
    # NOTE: these entries are pinned to the exact line of a pre-existing,
    # already-sanctioned certbot loop (not scope taxonomy). The pin is by
    # line number, so any edit that shifts converge_step_certs must re-pin
    # them here in the same commit (design-taste #9, self-consistency). The
    # #709/#710/#711 converge-robustness change added lines to
    # converge_step_closure above these loops; re-pinned 537/541/549/564/572/581
    # -> 614/618/626/641/649/658 to match, content unchanged. The #756 fix
    # (root-disk-label preflight in converge_repair_root_disk_labels) added
    # ~168 lines above converge_step_certs; re-pinned 614/618/626/641/649/658
    # -> 782/786/794/809/817/826. The #777 fix (probe rewrite:
    # MAJ:MIN + /dev/block/, error taxonomy split, stage/root_dev in die,
    # local probe_stage) added ~36 lines to converge_repair_root_disk_labels;
    # re-pinned 782/786/794/809/817/826 -> 818/822/830/845/853/862. The #779
    # fix (raw_root_source/raw_root_majmin capture + awk trim inside
    # probe_cmd) added 2 lines to converge_repair_root_disk_labels; re-pinned
    # 818/822/830/845/853/862 -> 820/824/832/847/855/864.
    "${REPO_ROOT}/framework/scripts/converge-lib.sh:820:"*"for VM_KEY in \$(yq -r \".vms | to_entries[] | select(.key | test(\\\"_\${ENV}\$\\\")) | .key\" \"\$CONFIG\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-lib.sh:824:"*"for APP_KEY in \$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' \"\$APPS_CONFIG\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-lib.sh:832:"*"for VM_KEY in gitlab gatus"*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-lib.sh:847:"*"for VM_KEY in \$(yq -r \".vms | to_entries[] | select(.key | test(\\\"_\${ENV}\$\\\")) | .key\" \"\$CONFIG\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-lib.sh:855:"*"for APP_KEY in \$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' \"\$APPS_CONFIG\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-lib.sh:864:"*"for VM_KEY in gitlab gatus"*) continue ;;
    # GE1: converge-vm step routing, not VM scope taxonomy.
    "${REPO_ROOT}/framework/scripts/converge-vm.sh:194:"*"converge_vm_target_selected \"module.dns_dev\" || converge_vm_target_selected \"module.dns_prod\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-vm.sh:201:"*"converge_vm_target_selected \"module.vault_dev\" || converge_vm_target_selected \"module.vault_prod\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-vm.sh:205:"*"converge_vm_target_selected \"module.gitlab\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-vm.sh:209:"*"converge_vm_target_selected \"module.gitlab\" || converge_vm_target_selected \"module.cicd\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-vm.sh:213:"*"converge_vm_target_selected \"module.gitlab\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-vm.sh:236:"*"vm_keys_output=\"\$(yq -r '.vms | keys | .[]' \"\$CONFIG\" | sort)\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-vm.sh:256:"*"yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' \"\$APPS_CONFIG\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/converge-vm.sh:262:"*"yq -r \".applications.\${app_key}.environments // {} | keys | .[]\" \"\$APPS_CONFIG\""*) continue ;;
    # GE1: build manifest role enumeration; scope/control-plane taxonomy is not reinterpreted here.
    "${REPO_ROOT}/framework/scripts/build-all-images.sh:51:"*"FRAMEWORK_ROLES=\$(yq -r '.roles | keys | .[]' \"\$FRAMEWORK_MANIFEST\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/build-all-images.sh:56:"*"SITE_ROLES=\$(yq -r '.roles | keys | .[]' \"\$SITE_MANIFEST\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/build-all-images.sh:73:"*"APP_ROLES=\$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' \"\$APPS_CONFIG\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/merge-image-versions.sh:58:"*"< <(yq -r '.roles | keys | .[]' \"\$FRAMEWORK_MANIFEST\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/merge-image-versions.sh:62:"*"< <(yq -r '.roles | keys | .[]' \"\$SITE_MANIFEST\""*) continue ;;
    "${REPO_ROOT}/framework/scripts/merge-image-versions.sh:66:"*"< <(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key'"*) continue ;;
  esac

  printf '%s\n' "$match" >> "$UNEXPECTED"
done < "$MATCHES"

test_start "S39.1" "migrated classifier allowlists are absent outside approved files"
if [[ ! -s "$UNEXPECTED" ]]; then
  test_pass "no residual migrated role allowlists found"
else
  test_fail "unexpected residual migrated role allowlists found"
  sed 's/^/    /' "$UNEXPECTED" >&2
fi

test_start "S39.2" "cosmetic git-deploy-context usage hint remains explicitly allowlisted"
if grep -Fq 'framework/scripts/git-deploy-context.sh:' "$MATCHES" &&
   grep -Fq 'Use real module names from framework/tofu/root' "$MATCHES"; then
  test_pass "git-deploy-context cosmetic usage hint is covered by the allowlist"
else
  test_fail "expected cosmetic git-deploy-context usage hint was not found"
fi

test_start "S39.3" "numbered env-label class resolution stays consistent across copied resolvers"
missing_numbered_resolver=()
for script in \
  "${REPO_ROOT}/framework/scripts/vm-topology-lib.sh" \
  "${REPO_ROOT}/framework/scripts/vm-scope.sh" \
  "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" \
  "${REPO_ROOT}/framework/scripts/safe-apply.sh"
do
  if ! grep -Fq 'numbered_base = re.sub(r"[0-9]+$", "", match.group(1))' "$script"; then
    missing_numbered_resolver+=("$script")
  fi
done
if [[ "${#missing_numbered_resolver[@]}" -eq 0 ]]; then
  test_pass "all copied class resolvers include numbered env-label handling"
else
  test_fail "missing numbered env-label handling in copied resolver(s)"
  printf '    %s\n' "${missing_numbered_resolver[@]}" >&2
fi

runner_summary
