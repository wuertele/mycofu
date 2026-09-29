#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT_MAIN="${REPO_ROOT}/framework/tofu/root/main.tf"
CICD_MAIN="${REPO_ROOT}/framework/tofu/modules/cicd/main.tf"
CICD_VARS="${REPO_ROOT}/framework/tofu/modules/cicd/variables.tf"
FIELD_DIR="${REPO_ROOT}/framework/tofu/modules/proxmox-vm-field-updatable"
FIELD_VM="${FIELD_DIR}/vm.tf"
FIELD_VARS_LINK="${FIELD_DIR}/variables.tf"
FIELD_MEMORY_VARS="${FIELD_DIR}/variables-memory.tf"
BASE_VM="${REPO_ROOT}/framework/tofu/modules/proxmox-vm/vm.tf"
PRECIOUS_VM="${REPO_ROOT}/framework/tofu/modules/proxmox-vm-precious/vm.tf"
GITLAB_MAIN="${REPO_ROOT}/framework/tofu/modules/gitlab/main.tf"
WORKSTATION_MAIN="${REPO_ROOT}/framework/catalog/workstation/main.tf"
LOCK_FILE="${REPO_ROOT}/framework/tofu/root/.terraform.lock.hcl"

# Extract an HCL block by its header. Anchored at the start of the line and ignoring
# comments: an unanchored substring match would also fire on a COMMENT mentioning
# `module "gitlab"`, silently extracting the wrong text and making the assertions that
# consume it vacuous.
extract_block() {
  local file="$1"
  local header="$2"
  awk -v header="$header" '
    !in_block && $0 ~ /^[[:space:]]*#/ { next }
    !in_block && index($0, header) == 1 { in_block = 1 }
    in_block {
      print
      opens += gsub(/\{/, "{")
      closes += gsub(/\}/, "}")
      if (opens > 0 && opens == closes) {
        exit
      }
    }
  ' "$file"
}

grep_uncommented() {
  local pattern="$1"
  local file="$2"
  sed '/^[[:space:]]*#/d' "$file" | grep -q "$pattern"
}

provider_version_from_lock() {
  awk '
    /provider "registry\.opentofu\.org\/bpg\/proxmox"/ { in_provider = 1 }
    in_provider && /^[[:space:]]*version[[:space:]]*=/ {
      gsub(/"/, "", $3)
      print $3
      exit
    }
  ' "$LOCK_FILE"
}

write_fixture_main() {
  local fixture_dir="$1"
  local provider_version="$2"

  cat > "${fixture_dir}/main.tf" <<EOF
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "${provider_version}"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://127.0.0.1:8006/"
  api_token = "root@pam!test=00000000-0000-0000-0000-000000000000"
  insecure  = true
  ssh {
    agent    = false
    username = "root"
  }
}

locals {
  all_node_names = ["pve-a", "pve-b", "pve-c"]
  ssh_pubkey     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA sprint046"
  gateway        = "192.0.2.1"
  image_file_id  = "local:iso/test-12345678.img"
  tags           = ["sprint046", "golden"]
}

module "gitlab_like" {
  source         = "./modules/proxmox-vm-field-updatable"
  vm_id          = 150
  vm_name        = "gitlab-like"
  hostname       = "gitlab"
  instance_id    = "gitlab-like"
  target_node    = "pve-a"
  image_file_id  = local.image_file_id
  mac_address    = "02:00:00:00:00:50"
  ssh_pubkey     = local.ssh_pubkey
  ip_address     = "192.0.2.50"
  gateway        = local.gateway
  all_node_names = local.all_node_names
  tags           = local.tags
  ram_mb         = 6144
}

module "workstation_like" {
  source         = "./modules/proxmox-vm-field-updatable"
  vm_id          = 151
  vm_name        = "workstation-like"
  hostname       = "workstation"
  instance_id    = "workstation-like"
  target_node    = "pve-b"
  image_file_id  = local.image_file_id
  mac_address    = "02:00:00:00:00:51"
  ssh_pubkey     = local.ssh_pubkey
  ip_address     = "192.0.2.51"
  gateway        = local.gateway
  all_node_names = local.all_node_names
  tags           = local.tags
  ram_mb         = 4096
}

module "cicd_like" {
  source          = "./modules/proxmox-vm-field-updatable"
  vm_id           = 160
  vm_name         = "cicd-like"
  hostname        = "cicd"
  instance_id     = "cicd-like"
  target_node     = "pve-a"
  image_file_id   = local.image_file_id
  mac_address     = "02:00:00:00:00:60"
  ssh_pubkey      = local.ssh_pubkey
  ip_address      = "192.0.2.60"
  gateway         = local.gateway
  all_node_names  = local.all_node_names
  tags            = local.tags
  ram_mb          = 40960
  ram_floating_mb = 12288
}

module "gitlab_old_control" {
  source         = "./modules/proxmox-vm"
  vm_id          = 250
  vm_name        = "gitlab-old-control"
  hostname       = "gitlab-old"
  instance_id    = "gitlab-old-control"
  target_node    = "pve-a"
  image_file_id  = local.image_file_id
  mac_address    = "02:00:00:00:01:50"
  ssh_pubkey     = local.ssh_pubkey
  ip_address     = "192.0.2.150"
  gateway        = local.gateway
  all_node_names = local.all_node_names
  tags           = local.tags
  ram_mb         = 6144
}

module "workstation_old_control" {
  source         = "./modules/proxmox-vm"
  vm_id          = 251
  vm_name        = "workstation-old-control"
  hostname       = "workstation-old"
  instance_id    = "workstation-old-control"
  target_node    = "pve-b"
  image_file_id  = local.image_file_id
  mac_address    = "02:00:00:00:01:51"
  ssh_pubkey     = local.ssh_pubkey
  ip_address     = "192.0.2.151"
  gateway        = local.gateway
  all_node_names = local.all_node_names
  tags           = local.tags
  ram_mb         = 4096
}
EOF
}

prepare_fixture() {
  local fixture_dir="$1"
  local provider_version="$2"

  mkdir -p "$fixture_dir"
  cp -R "${REPO_ROOT}/framework/tofu/modules" "${fixture_dir}/modules"
  cp "$LOCK_FILE" "${fixture_dir}/.terraform.lock.hcl"
  write_fixture_main "$fixture_dir" "$provider_version"
}

# Render a fixture to p.tfplan.json WITHOUT the golden assertions. Used for the
# pre-seam control, which deliberately renders no `floating` at all and so cannot
# satisfy the golden fixture's cicd expectations.
run_plan() {
  local fixture_dir="$1"
  local output_file="${fixture_dir}/assert.out"

  set +e
  (
    set -euo pipefail
    cd "$fixture_dir"
    if ! tofu init -backend=false -input=false -no-color >tofu-init.out 2>&1; then
      echo "tofu init failed"
      cat tofu-init.out
      exit 1
    fi
    if ! tofu plan -out=p.tfplan -refresh=false -input=false -no-color >tofu-plan.out 2>&1; then
      echo "tofu plan failed"
      cat tofu-plan.out
      exit 1
    fi
    if ! tofu show -json p.tfplan >p.tfplan.json 2>tofu-show.err; then
      echo "tofu show -json failed"
      cat tofu-show.err
      exit 1
    fi
  ) >"$output_file" 2>&1
  local status=$?
  set -e
  return $status
}

run_plan_and_assert() {
  local fixture_dir="$1"
  local output_file="${fixture_dir}/assert.out"

  set +e
  (
    set -euo pipefail
    cd "$fixture_dir"
    if ! tofu init -backend=false -input=false -no-color >tofu-init.out 2>&1; then
      echo "tofu init failed"
      cat tofu-init.out
      exit 1
    fi
    if ! tofu plan -out=p.tfplan -refresh=false -input=false -no-color >tofu-plan.out 2>&1; then
      echo "tofu plan failed"
      cat tofu-plan.out
      exit 1
    fi
    if ! tofu show -json p.tfplan >p.tfplan.json 2>tofu-show.err; then
      echo "tofu show -json failed"
      cat tofu-show.err
      exit 1
    fi
    python3 - p.tfplan.json <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    plan = json.load(fh)


def child_modules(module):
    for child in module.get("child_modules", []) or []:
        yield child
        yield from child_modules(child)


def memory_for(module):
    for resource in module.get("resources", []) or []:
        if resource.get("type") != "proxmox_virtual_environment_vm":
            continue
        values = resource.get("values") or {}
        memory = values.get("memory")
        if isinstance(memory, list) and len(memory) == 1 and isinstance(memory[0], dict):
            return memory[0]
        if isinstance(memory, dict):
            return memory
        raise SystemExit(f"malformed memory value for {module.get('address')}: {memory!r}")
    raise SystemExit(f"VM resource not found in {module.get('address')}")


wanted = {
    "module.gitlab_like",
    "module.workstation_like",
    "module.cicd_like",
    "module.gitlab_old_control",
    "module.workstation_old_control",
}

modules = {}
for module in child_modules(plan.get("planned_values", {}).get("root_module", {})):
    address = module.get("address")
    if address in wanted:
        modules[address] = memory_for(module)

missing = sorted(wanted - modules.keys())
if missing:
    raise SystemExit(f"missing module memory values: {', '.join(missing)}")


def require(condition, message):
    if not condition:
        raise SystemExit(message)


require(
    modules["module.cicd_like"].get("dedicated") == 40960,
    f"cicd_like dedicated mismatch: {modules['module.cicd_like']!r}",
)
require(
    modules["module.cicd_like"].get("floating") == 12288,
    f"cicd_like floating mismatch: {modules['module.cicd_like']!r}",
)
require(
    modules["module.gitlab_like"] == modules["module.gitlab_old_control"],
    "gitlab_like null memory rendering differs from dedicated-only control: "
    f"{modules['module.gitlab_like']!r} != {modules['module.gitlab_old_control']!r}",
)
require(
    modules["module.workstation_like"] == modules["module.workstation_old_control"],
    "workstation_like null memory rendering differs from dedicated-only control: "
    f"{modules['module.workstation_like']!r} != {modules['module.workstation_old_control']!r}",
)


def floating_repr(memory):
    return repr(memory["floating"]) if "floating" in memory else "<absent>"


print("golden memory values:")
for label in ["cicd_like", "gitlab_like", "workstation_like"]:
    memory = modules[f"module.{label}"]
    print(f"  {label}: dedicated={memory.get('dedicated')} floating={floating_repr(memory)}")
PY
  ) >"$output_file" 2>&1
  local status=$?
  set -e
  return "$status"
}

test_start "cicd-balloon.1" "root module threads cicd ceiling and floor memory keys"
root_cicd_block="$(extract_block "$ROOT_MAIN" 'module "cicd"')"
if grep -q 'target_node[[:space:]]*=[[:space:]]*local\.config\.vms\.cicd\.node' <<< "$root_cicd_block" && \
   grep -q 'ram_mb[[:space:]]*=[[:space:]]*local\.config\.cicd\.runner_ram_mb' <<< "$root_cicd_block" && \
   grep -q 'ram_floating_mb[[:space:]]*=[[:space:]]*try(local\.config\.cicd\.runner_ram_floor_mb, null)' <<< "$root_cicd_block" && \
   [[ "$(grep -c '^[[:space:]]*ram_floating_mb[[:space:]]*=' "$ROOT_MAIN")" -eq 1 ]]; then
  test_pass "root module passes ram_floating_mb only to module \"cicd\""
else
  test_fail "root module must pass runner_ram_mb/floor_mb only to module \"cicd\" and use config.yaml for target_node"
fi

test_start "cicd-balloon.2" "cicd wrapper declares and passes ram_floating_mb"
cicd_inner_block="$(extract_block "$CICD_MAIN" 'module "cicd"')"
if grep -q 'variable "ram_floating_mb"' "$CICD_VARS" && \
   grep -q 'nullable[[:space:]]*=[[:space:]]*true' "$CICD_VARS" && \
   grep -q 'default[[:space:]]*=[[:space:]]*null' "$CICD_VARS" && \
   grep -q 'source[[:space:]]*=[[:space:]]*"../proxmox-vm-field-updatable"' <<< "$cicd_inner_block" && \
   grep -q 'ram_floating_mb[[:space:]]*=[[:space:]]*var\.ram_floating_mb' <<< "$cicd_inner_block"; then
  test_pass "cicd wrapper threads ram_floating_mb to field-updatable"
else
  test_fail "cicd wrapper must declare and pass ram_floating_mb"
fi

test_start "cicd-balloon.3" "field-updatable memory variable is module-local and symlink invariant holds"
if [[ -L "$FIELD_VARS_LINK" ]] && \
   [[ "$(readlink "$FIELD_VARS_LINK")" == "../proxmox-vm/variables.tf" ]] && \
   [[ -f "$FIELD_MEMORY_VARS" ]] && \
   grep -q 'variable "ram_floating_mb"' "$FIELD_MEMORY_VARS" && \
   ! grep -q 'variable "ram_floating_mb"' "$FIELD_VARS_LINK"; then
  test_pass "ram_floating_mb lives in variables-memory.tf while variables.tf stays a shared symlink"
else
  test_fail "field-updatable variables.tf symlink or variables-memory.tf placement is wrong"
fi

test_start "cicd-balloon.4" "field-updatable memory is null-gated with dynamic blocks"
field_memory_dynamic_count="$(grep -c 'dynamic "memory"' "$FIELD_VM")"
if [[ "$field_memory_dynamic_count" -eq 2 ]] && \
   grep -q 'for_each[[:space:]]*=[[:space:]]*var\.ram_floating_mb == null ? \[var\.ram_mb\] : \[\]' "$FIELD_VM" && \
   grep -q 'for_each[[:space:]]*=[[:space:]]*var\.ram_floating_mb == null ? \[\] : \[{' "$FIELD_VM" && \
   grep -q 'floating[[:space:]]*=[[:space:]]*var\.ram_floating_mb' "$FIELD_VM" && \
   ! grep_uncommented 'coalesce(var\.ram_floating_mb, var\.ram_mb)' "$FIELD_VM"; then
  test_pass "field-updatable emits dedicated-only when null and dedicated+floating when non-null"
else
  test_fail "field-updatable memory must use null-gated dynamic blocks, not coalesced floating"
fi

test_start "cicd-balloon.5" "non-ballooned gitlab and workstation consumers do not pass ram_floating_mb"
root_gitlab_block="$(extract_block "$ROOT_MAIN" 'module "gitlab"')"
root_workstation_dev_block="$(extract_block "$ROOT_MAIN" 'module "workstation_dev"')"
root_workstation_prod_block="$(extract_block "$ROOT_MAIN" 'module "workstation_prod"')"
gitlab_inner_block="$(extract_block "$GITLAB_MAIN" 'module "gitlab"')"
workstation_inner_block="$(extract_block "$WORKSTATION_MAIN" 'module "workstation"')"
if ! grep -q 'ram_floating_mb' <<< "$root_gitlab_block" && \
   ! grep -q 'ram_floating_mb' <<< "$root_workstation_dev_block" && \
   ! grep -q 'ram_floating_mb' <<< "$root_workstation_prod_block" && \
   ! grep -q 'ram_floating_mb' <<< "$gitlab_inner_block" && \
   ! grep -q 'ram_floating_mb' <<< "$workstation_inner_block"; then
  test_pass "gitlab and workstation keep the field-updatable null default"
else
  test_fail "gitlab/workstation consumers must not pass ram_floating_mb"
fi

test_start "cicd-balloon.6" "base and precious VM modules have no floating memory line"
if ! grep_uncommented 'floating[[:space:]]*=' "$BASE_VM" && \
   ! grep_uncommented 'floating[[:space:]]*=' "$PRECIOUS_VM"; then
  test_pass "proxmox-vm and proxmox-vm-precious memory blocks remain dedicated-only"
else
  test_fail "proxmox-vm and proxmox-vm-precious must not contain a floating memory line"
fi

test_start "cicd-balloon.7" "vendored provider and tofu are available for non-vacuous plan rendering"
PROVIDER_READY=0
if ! command -v tofu >/dev/null 2>&1; then
  test_fail "tofu is not on PATH; golden memory rendering cannot run"
elif ! command -v nix >/dev/null 2>&1; then
  test_fail "nix is not on PATH; cannot build bpg-proxmox-provider mirror"
else
  set +e
  provider_build_output="$(nix build --no-link --print-out-paths "${REPO_ROOT}#bpg-proxmox-provider" 2>&1)"
  provider_build_status=$?
  set -e
  if [[ "$provider_build_status" -ne 0 ]]; then
    test_fail "nix build bpg-proxmox-provider failed: $(tr '\n' ' ' <<< "$provider_build_output")"
  else
    PROVIDER_OUT="$(tail -1 <<< "$provider_build_output")"
    if [[ -z "$PROVIDER_OUT" ]]; then
      test_fail "nix build bpg-proxmox-provider produced empty output path"
    elif [[ ! -f "${PROVIDER_OUT}/etc/terraformrc" ]]; then
      test_fail "provider derivation missing etc/terraformrc: ${PROVIDER_OUT}"
    else
      export TF_CLI_CONFIG_FILE="${PROVIDER_OUT}/etc/terraformrc"
      unset TF_PLUGIN_CACHE_DIR
      PROVIDER_READY=1
      test_pass "using bpg/proxmox provider mirror at ${PROVIDER_OUT}"
    fi
  fi
fi

if [[ "$PROVIDER_READY" -ne 1 ]]; then
  runner_summary
fi

test_start "cicd-balloon.8" "golden show-json memory rendering for null and non-null floating"
provider_version="$(provider_version_from_lock)"
if [[ -z "$provider_version" ]]; then
  test_fail "could not read bpg/proxmox provider version from ${LOCK_FILE}"
  runner_summary
else
  golden_dir="${TMP_DIR}/memory-golden"
  prepare_fixture "$golden_dir" "$provider_version"
  if run_plan_and_assert "$golden_dir"; then
    cat "${golden_dir}/assert.out"
    test_pass "golden show-json proves cicd floating and null dedicated-only no-op"
  else
    test_fail "golden plan/render/assert failed: $(tr '\n' ' ' < "${golden_dir}/assert.out")"
  fi
fi

test_start "cicd-balloon.9" "mutation self-check proves golden fixture is non-vacuous"
mutant_dir="${TMP_DIR}/memory-mutant"
prepare_fixture "$mutant_dir" "$provider_version"
mutant_vm="${mutant_dir}/modules/proxmox-vm-field-updatable/vm.tf"
python3 - "$mutant_vm" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '''dynamic "memory" {
    for_each = var.ram_floating_mb == null ? [var.ram_mb] : []
    content {
      dedicated = memory.value
    }
  }'''
new = '''dynamic "memory" {
    for_each = var.ram_floating_mb == null ? [{
      dedicated = var.ram_mb
      floating  = coalesce(var.ram_floating_mb, var.ram_mb)
    }] : []
    content {
      dedicated = memory.value.dedicated
      floating  = memory.value.floating
    }
  }'''
if old not in text:
    raise SystemExit("target memory block not found for mutation")
path.write_text(text.replace(old, new), encoding="utf-8")
PY

if ! grep -q 'coalesce(var\.ram_floating_mb, var\.ram_mb)' "$mutant_vm"; then
  test_fail "mutation did not patch field-updatable vm.tf"
elif run_plan_and_assert "$mutant_dir"; then
  test_fail "golden fixture is vacuous: mutant rendered floating for null consumers but assertions passed"
else
  mutant_output="$(cat "${mutant_dir}/assert.out")"
  if grep -Fq "gitlab_like null memory rendering differs from dedicated-only control" <<< "$mutant_output"; then
    grep -F "gitlab_like null memory rendering differs from dedicated-only control" <<< "$mutant_output" \
      | sed 's/^/mutation self-check fired: /'
    test_pass "mutant is rejected by the same plan/render/assert path"
  else
    test_fail "mutant failed for an unexpected reason: $(tr '\n' ' ' <<< "$mutant_output")"
  fi
fi

# cicd-balloon.8 proves the memory KEY is unchanged for the null consumers. That is the
# specific regression !430 shipped, but it is a narrower claim than R-1 needs: R-1 is
# "the seam changes NOTHING about how gitlab renders". So compare the FULL rendered
# resource — every attribute — between the current seam (null path) and a reconstruction
# of the PRE-SEAM module (the literal static `memory { dedicated = var.ram_mb }` block
# this MR replaced). Reconstructing the old block in-test, rather than diffing against
# git HEAD, keeps the control valid after this MR is committed — a HEAD-based control
# would compare the new module against itself the moment it lands.
#
# Limit, stated honestly: this proves THIS seam is a no-op. It does not watch the real
# root module against real cluster state, so a FUTURE unrelated edit to the shared module
# could still diff gitlab without failing here. That check (plan the real root, assert
# zero changes and zero replaces on module.gitlab) is the blast-radius gate in MR-5.
test_start "cicd-balloon.10" "null path renders the pre-seam resource attribute-for-attribute"
preseam_dir="${TMP_DIR}/memory-preseam"
prepare_fixture "$preseam_dir" "$provider_version"
preseam_vm="${preseam_dir}/modules/proxmox-vm-field-updatable/vm.tf"
python3 - "$preseam_vm" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Collapse the two null-gated dynamic blocks back into the exact static block that
# stood here before this MR (see `git show gitlab/dev:.../vm.tf`).
pattern = re.compile(
    r'  dynamic "memory" \{\n'
    r'    for_each = var\.ram_floating_mb == null \? \[var\.ram_mb\] : \[\]\n.*?'
    r'  dynamic "memory" \{\n'
    r'    for_each = var\.ram_floating_mb == null \? \[\] : \[\{\n.*?\n  \}\n',
    re.DOTALL,
)
replacement = "  memory {\n    dedicated = var.ram_mb\n  }\n"
new_text, n = pattern.subn(replacement, text, count=1)
if n != 1:
    raise SystemExit("could not reconstruct the pre-seam static memory block")
path.write_text(new_text, encoding="utf-8")
PY

cat > "${TMP_DIR}/compare_preseam.py" <<'PY'
import json
import sys

TARGETS = {
    # address -> must the seam change it?
    "module.gitlab_like": False,
    "module.workstation_like": False,
    "module.cicd_like": True,
}


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        plan = json.load(fh)

    def walk(module):
        for child in module.get("child_modules", []) or []:
            yield child
            yield from walk(child)

    out = {}
    for module in walk(plan.get("planned_values", {}).get("root_module", {})):
        address = module.get("address")
        if address not in TARGETS:
            continue
        for resource in module.get("resources", []) or []:
            if resource.get("type") == "proxmox_virtual_environment_vm":
                out[address] = resource.get("values") or {}
                break
        else:
            raise SystemExit(f"no VM resource rendered in {address}")
    missing = sorted(set(TARGETS) - set(out))
    if missing:
        raise SystemExit(f"missing modules in plan {path}: {', '.join(missing)}")
    return out


current = load(sys.argv[1])
preseam = load(sys.argv[2])

for address, must_change in TARGETS.items():
    changed = current[address] != preseam[address]
    if must_change and not changed:
        raise SystemExit(
            f"{address} rendered IDENTICALLY to the pre-seam module — the fixture is not "
            f"exercising the seam at all, so the no-op proof below is worthless"
        )
    if not must_change and changed:
        diffs = sorted(
            k for k in set(current[address]) | set(preseam[address])
            if current[address].get(k) != preseam[address].get(k)
        )
        raise SystemExit(
            f"{address} is a NULL consumer (gitlab is PRECIOUS) but the seam changed it: "
            f"attributes {diffs} differ. current={ {k: current[address].get(k) for k in diffs} } "
            f"pre-seam={ {k: preseam[address].get(k) for k in diffs} }"
        )

print("pre-seam full-resource comparison:")
for address, must_change in TARGETS.items():
    verdict = "CHANGED (expected)" if must_change else "identical in every attribute"
    print(f"  {address}: {verdict}")
PY

if ! grep -Fq 'memory {
    dedicated = var.ram_mb
  }' "$preseam_vm"; then
  test_fail "pre-seam reconstruction did not produce the static dedicated-only memory block"
elif grep -q 'dynamic "memory"' "$preseam_vm"; then
  test_fail "pre-seam reconstruction left a dynamic memory block behind"
elif ! run_plan "$preseam_dir"; then
  test_fail "pre-seam control fixture failed to plan: $(tr '\n' ' ' < "${preseam_dir}/assert.out")"
else
  set +e
  compare_output="$(python3 "${TMP_DIR}/compare_preseam.py" "${golden_dir}/p.tfplan.json" "${preseam_dir}/p.tfplan.json" 2>&1)"
  compare_status=$?
  set -e
  if [[ "$compare_status" -eq 0 ]]; then
    printf '%s\n' "$compare_output"
    test_pass "gitlab_like and workstation_like render identically to the pre-seam module (all attributes)"
  else
    test_fail "seam is NOT a no-op for a null consumer: $(tr '\n' ' ' <<< "$compare_output")"
  fi
fi

# root/main.tf reads the floor with try(..., null) so a site config that predates
# ballooning still evaluates. The cost of that tolerance: a TYPO in this site's key
# would silently fall back to null and quietly disable ballooning. This assertion is
# the compensating control — the keys must actually be present and coherent here.
test_start "cicd-balloon.11" "site config declares a coherent ceiling/floor pair"
site_config="${REPO_ROOT}/site/config.yaml"
ceiling="$(yq -r '.cicd.runner_ram_mb // ""' "$site_config")"
floor="$(yq -r '.cicd.runner_ram_floor_mb // ""' "$site_config")"
if [[ ! "$ceiling" =~ ^[1-9][0-9]*$ ]]; then
  test_fail "site/config.yaml cicd.runner_ram_mb must be a positive integer (got: '${ceiling}')"
elif [[ "$ceiling" -ne 61440 ]]; then
  # V1.1: 60 GiB is operator-approved and derived in SPRINT-046 A1 as a bound, not a
  # guess. A silent re-edit of the ceiling must not sail through review.
  test_fail "cicd.runner_ram_mb is ${ceiling}, expected the operator-approved 61440 (60 GiB); if this is a deliberate change, update SPRINT-046 A1 and this assertion together"
elif [[ ! "$floor" =~ ^[1-9][0-9]*$ ]]; then
  test_fail "site/config.yaml cicd.runner_ram_floor_mb must be a positive integer (got: '${floor}') — a missing/typo'd key would silently disable ballooning via try(..., null)"
elif (( floor >= ceiling )); then
  test_fail "cicd.runner_ram_floor_mb (${floor}) must be below cicd.runner_ram_mb (${ceiling}); a balloon floor at or above the ceiling is not a float range"
else
  test_pass "site config: ceiling=${ceiling} MiB, floor=${floor} MiB (floor < ceiling)"
fi

# The module carries a lifecycle precondition on a NON-null floor: 0 < floor < ceiling.
# site/config.yaml is checked above, but the root module reads the floor through
# try(..., null) and other sites supply their own config — so the guard has to live in the
# module, and it has to actually fire. Prove it fires on BOTH edges.
#
#   floor >= ceiling -> qemu gets balloon >= memory. Not a float range.
#   floor == 0       -> PVE reads balloon:0 as "balloon device DISABLED". A site that wrote
#                       0 would look opted-in and silently get a FIXED VM — precisely the
#                       failure this seam exists to prevent. Opting out is spelled null.
#
# Each case must be rejected BY THE PRECONDITION (matched on its error text), not by some
# incidental plan error that would happen to make the test green for the wrong reason.
check_precondition_rejects() {
  local id="$1" desc="$2" from="$3" to="$4"
  test_start "$id" "$desc"
  local dir="${TMP_DIR}/badfloor-${id}"
  prepare_fixture "$dir" "$provider_version"
  # cicd_like is ram_mb=40960 / ram_floating_mb=12288.
  sed -i.bak "s/ram_floating_mb = ${from}/ram_floating_mb = ${to}/" "${dir}/main.tf"
  # OpenTofu hard-wraps a long error_message across lines, so the phrase is not contiguous
  # in the raw output. Flatten whitespace before matching, or this assertion would report
  # "failed for the wrong reason" on a precondition that in fact fired correctly.
  local flattened
  if ! grep -q "ram_floating_mb = ${to}" "${dir}/main.tf"; then
    test_fail "could not construct the ${desc} fixture"
  elif run_plan "$dir"; then
    test_fail "module PLANNED a VM with ram_floating_mb=${to} against ram_mb=40960; the lifecycle precondition is dead"
  else
    flattened="$(tr '\n' ' ' < "${dir}/assert.out" | tr -s '[:space:]' ' ')"
    if grep -Fq 'Resource precondition failed' <<< "$flattened" \
      && grep -Fq 'must be greater than 0 and below ram_mb (ceiling)' <<< "$flattened"; then
      test_pass "ram_floating_mb=${to} is refused at plan time by the module precondition"
    else
      test_fail "ram_floating_mb=${to} fixture failed, but NOT via the precondition: ${flattened}"
    fi
  fi
}

check_precondition_rejects "cicd-balloon.12" "module refuses a balloon floor at the ceiling" 12288 40960
check_precondition_rejects "cicd-balloon.13" "module refuses a zero balloon floor (balloon:0 means DISABLED, not a zero floor)" 12288 0

runner_summary
