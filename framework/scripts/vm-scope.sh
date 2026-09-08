#!/usr/bin/env bash
# vm-scope.sh - Single reader for VM-class scope/control-plane taxonomy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FRAMEWORK_MANIFEST="${VM_SCOPE_FRAMEWORK_MANIFEST:-${REPO_DIR}/framework/images.yaml}"
SITE_MANIFEST="${VM_SCOPE_SITE_MANIFEST:-${REPO_DIR}/site/images.yaml}"
APPS_CONFIG="${VM_SCOPE_APPS_CONFIG:-${REPO_DIR}/site/applications.yaml}"
TOFU_ROOT="${VM_SCOPE_TOFU_ROOT:-${REPO_DIR}/framework/tofu/root}"

usage() {
  cat >&2 <<'EOF'
Usage: vm-scope.sh <subcommand> [options]

Subcommands:
  validate
  classes --format json|tsv
  buildable-roles
  control-plane-modules
  control-plane-built-roles
  deployable-modules --env dev|prod --plan-json <file>
  backup-kind <module-or-role>
  control-plane-recreate --plan-json <file>
  target-envs --targets "<flags>"
  scope-impact --scope "<scope string>"
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

# Resolve yq binary. Default: first `yq` in PATH. Tests that shim PATH
# with a fake `yq` returning test-specific config (safe-apply.sh /
# rebuild-cluster.sh fixture tests use SHIM_DIR shims for this) can
# pre-export VM_SCOPE_YQ_BIN to the real yq so vm-scope.sh reads the
# actual manifests instead of the shim's response. The script-scoped
# name matches the convention used elsewhere in framework/scripts/
# (CERTBOT_CLUSTER_YQ_BIN in certbot-cluster.sh,
# VALIDATE_GITHUB_MIRROR_YQ_BIN in validate-github-mirror.sh,
# SYNC_TO_MAIN_YQ_BIN in sync-to-main.sh) — this keeps the shim-bypass
# handle for each script independent, so a fixture wanting to point
# vm-scope at the real yq does not also touch validate-github-mirror's
# resolution and vice versa. See framework/scripts/README.md for the
# full fixture-test env-var contract.
VM_SCOPE_YQ_BIN="${VM_SCOPE_YQ_BIN:-$(command -v yq 2>/dev/null || true)}"
if [[ -z "${VM_SCOPE_YQ_BIN}" || ! -x "${VM_SCOPE_YQ_BIN}" ]]; then
  echo "ERROR: yq not found; vm-scope.sh requires mikefarah yq v4 (override path via VM_SCOPE_YQ_BIN env var)" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found" >&2
  exit 1
fi
export VM_SCOPE_YQ_BIN

normalized_args=()
while [[ $# -gt 0 ]]; do
  if [[ "${1:-}" == "--targets" && $# -ge 2 ]]; then
    normalized_args+=("--targets=$2")
    shift 2
  elif [[ "${1:-}" == "--scope" && $# -ge 2 ]]; then
    normalized_args+=("--scope=$2")
    shift 2
  else
    normalized_args+=("$1")
    shift
  fi
done

export FRAMEWORK_MANIFEST SITE_MANIFEST APPS_CONFIG TOFU_ROOT
python3 - "${normalized_args[@]}" <<'PY'
import argparse
import json
import os
import re
import subprocess
import sys


VALID_SCOPES = {"env-bound", "prod-only", "dev-only", "shared"}
VALID_CATEGORIES = {"nix", "external", "vendor"}
BUILD_FIELDS = {
    "host_config",
    "flake_output",
    "build_script",
    "build_secret_config",
    "build_secret_ref",
}


class ScopeError(Exception):
    pass


def normalize(name):
    return str(name).replace("-", "_")


def die(message, code=1):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(code)


def load_yaml(path, default=None, required=True):
    if not os.path.exists(path):
        if required:
            raise ScopeError(f"required manifest not found: {path}")
        return default
    try:
        raw = subprocess.check_output(
            # Strict indexing (not .get with a fallback) enforces the
            # boundary contract with the bash wrapper: the wrapper has
            # already resolved and exported VM_SCOPE_YQ_BIN before this
            # heredoc runs, or it has already exited non-zero. A silent
            # `"yq"` fallback here would defeat the SHIM_DIR-bypass the
            # env var exists to provide.
            [os.environ["VM_SCOPE_YQ_BIN"], "-o=json", ".", path],
            stderr=subprocess.PIPE,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        detail = f"malformed YAML in {path}"
        if stderr:
            detail = f"{detail}: {stderr}"
        raise ScopeError(detail)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ScopeError(f"yq produced invalid JSON for {path}: {exc}") from exc
    if data is None:
        return {} if default is None else default
    return data


def bool_field(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    raise ScopeError(f"control_plane must be boolean, got {value!r}")


def validate_role_config(role, cfg, block, source_name):
    if not isinstance(cfg, dict):
        raise ScopeError(f"{source_name}:{block}.{role} must be a mapping")

    category = cfg.get("category")
    if category not in VALID_CATEGORIES:
        raise ScopeError(
            f"{source_name}:{block}.{role}.category must be one of "
            f"{', '.join(sorted(VALID_CATEGORIES))}"
        )

    scope = cfg.get("scope")
    if scope not in VALID_SCOPES:
        raise ScopeError(
            f"{source_name}:{block}.{role} missing required scope "
            f"(expected one of {', '.join(sorted(VALID_SCOPES))})"
        )

    control_plane = bool_field(cfg.get("control_plane"), False)

    if block == "roles" and category == "vendor":
        raise ScopeError(
            f"{source_name}:roles.{role} is category vendor; declare non-built "
            "classifier classes under non_built_roles"
        )
    if block == "non_built_roles" and category != "vendor":
        raise ScopeError(f"{source_name}:non_built_roles.{role}.category must be vendor")
    if category == "vendor" and any(field in cfg for field in BUILD_FIELDS):
        fields = ", ".join(sorted(field for field in BUILD_FIELDS if field in cfg))
        raise ScopeError(f"{source_name}:{block}.{role} vendor role has build field(s): {fields}")

    return category, scope, control_plane


def add_record(classes, seen, record):
    module = record["module"]
    previous = seen.get(module)
    if previous:
        raise ScopeError(
            f"duplicate normalized role name '{module}' declared in "
            f"{previous} and {record['source']}:{record['block']}.{record['role']}"
        )
    seen[module] = f"{record['source']}:{record['block']}.{record['role']}"
    classes[module] = record


def load_classes():
    framework_path = os.environ["FRAMEWORK_MANIFEST"]
    site_path = os.environ["SITE_MANIFEST"]
    apps_path = os.environ["APPS_CONFIG"]

    classes = {}
    seen = {}

    for source_name, path in (("framework", framework_path), ("site", site_path)):
        manifest = load_yaml(path, required=True)
        if not isinstance(manifest, dict):
            raise ScopeError(f"{source_name} manifest must be a mapping: {path}")

        for block, built in (("roles", True), ("non_built_roles", False)):
            entries = manifest.get(block) or {}
            if not isinstance(entries, dict):
                raise ScopeError(f"{source_name}:{block} must be a mapping")
            for role in entries:
                cfg = entries[role]
                category, scope, control_plane = validate_role_config(role, cfg, block, source_name)
                module = normalize(role)
                add_record(
                    classes,
                    seen,
                    {
                        "module": module,
                        "role": role,
                        "category": category,
                        "scope": scope,
                        "control_plane": control_plane,
                        "source": source_name,
                        "block": block,
                        "built": built,
                    },
                )

    apps = load_yaml(apps_path, default={"applications": {}}, required=False)
    app_entries = {}
    if isinstance(apps, dict):
        app_entries = apps.get("applications") or {}
    if not isinstance(app_entries, dict):
        raise ScopeError("site applications config .applications must be a mapping")

    for app in sorted(app_entries):
        cfg = app_entries[app]
        if not isinstance(cfg, dict) or cfg.get("enabled") is not True:
            continue
        module = normalize(app)
        add_record(
            classes,
            seen,
            {
                "module": module,
                "role": app,
                "category": "nix",
                "scope": "env-bound",
                "control_plane": False,
                "source": "applications",
                "block": "applications",
                "built": True,
            },
        )

    return classes


def sorted_modules(classes):
    return sorted(classes)


def strip_module_label(value):
    label = str(value)
    if label.startswith("module."):
        label = label[len("module.") :]
    label = re.sub(r"\[.*\]$", "", label)
    return normalize(label)


def resolve_label(label, classes):
    norm = strip_module_label(label)
    if norm in classes:
        return norm, None
    match = re.match(r"^(.+)_(dev|prod)$", norm)
    if match and match.group(1) in classes:
        return match.group(1), match.group(2)
    if match:
        # Numbered env labels such as dns1_dev are instances of dns.
        numbered_base = re.sub(r"[0-9]+$", "", match.group(1))
        if numbered_base in classes:
            return numbered_base, match.group(2)
    return None, None


def classify_target(label, classes):
    key, suffix_env = resolve_label(label, classes)
    if key is None:
        return None, None, None
    rec = classes[key]
    scope = rec["scope"]
    if suffix_env:
        if scope == "env-bound":
            return key, suffix_env, f"module.{strip_module_label(label)}"
        return key, None, f"module.{strip_module_label(label)}"
    if scope == "dev-only":
        return key, "dev", f"module.{key}"
    if scope == "prod-only":
        return key, "prod", f"module.{key}"
    if scope == "shared":
        return key, "shared", f"module.{key}"
    return key, None, f"module.{key}"


def backup_kind_for(label, classes):
    key, _suffix_env = resolve_label(label, classes)
    if key is None:
        raise ScopeError(f"unknown VM class for backup-kind: {label}")
    rec = classes[key]
    if rec["control_plane"]:
        return "control-plane"
    if rec["source"] == "applications":
        return "application"
    return "infrastructure"


def root_module_from_address(address):
    parts = str(address).split(".")
    if len(parts) < 2 or parts[0] != "module":
        return ""
    label = re.sub(r"\[.*\]$", "", parts[1])
    return f"module.{normalize(label)}"


def cmd_validate(_args, classes):
    print("VM scope manifests valid")
    return 0


def cmd_classes(args, classes):
    if args.format == "json":
        print(json.dumps({k: classes[k] for k in sorted_modules(classes)}, sort_keys=True))
    else:
        for key in sorted_modules(classes):
            rec = classes[key]
            print(
                "\t".join(
                    [
                        rec["module"],
                        rec["role"],
                        rec["category"],
                        rec["scope"],
                        "true" if rec["control_plane"] else "false",
                    ]
                )
            )
    return 0


def cmd_buildable_roles(_args, classes):
    roles = sorted(rec["role"] for rec in classes.values() if rec["category"] != "vendor")
    for role in roles:
        print(role)
    return 0


def cmd_control_plane_modules(_args, classes):
    # Preserve manifest insertion order (gitlab, cicd, then pbs from
    # non_built_roles) so callers that historically used the literal
    # `module.gitlab module.cicd module.pbs` get byte-identical output.
    # Matches control-plane-built-roles ordering.
    for key, rec in classes.items():
        if rec["control_plane"]:
            print(f"module.{key}")
    return 0


def cmd_control_plane_built_roles(_args, classes):
    for key, rec in classes.items():
        if not rec["control_plane"] or rec["category"] == "vendor":
            continue
        print(key)
    return 0


def cmd_target_envs(args, classes):
    targets = args.targets or ""
    if not targets.strip():
        print("dev prod")
        return 0

    envs = []
    for tok in targets.split():
        if not tok.startswith("-target=module."):
            raise ScopeError(
                f"converge_target_envs: malformed target token '{tok}' "
                "(expected -target=module.NAME)"
            )
        label = tok[len("-target=") :]
        key, env, _module = classify_target(label, classes)
        if key is None or env is None:
            prod_only = ["gitlab", "gatus"]
            shared = ["cicd", "pbs", "hil_boot"]
            raise ScopeError(
                f"converge_target_envs: unrecognized module '{strip_module_label(label)}' in TOFU_TARGETS\n"
                f"ERROR:   recognized patterns: *_dev, *_prod, {' '.join(prod_only)}, {' '.join(shared)}\n"
                "ERROR:   if this is a new module class, add it to converge_target_envs allowlist"
            )
        if env != "shared" and env not in envs:
            envs.append(env)

    if envs:
        print(" ".join(envs))
    return 0


def scope_json(impact="", reason="", unknown=""):
    return {"impact": impact, "reason": reason, "unknown_targets": unknown}


def cmd_scope_impact(args, classes):
    scope = args.scope or ""
    if scope == "":
        print(json.dumps(scope_json("prod_affecting", "full rebuilds always touch prod-affecting VMs")))
        return 0
    if scope == "control-plane":
        # Keep this cosmetic literal byte-stable for operator-facing output.
        print(json.dumps(scope_json("shared_control_plane", "control-plane scope targets shared VMs: gitlab, cicd, pbs")))
        return 0
    if scope == "data-plane":
        print(json.dumps(scope_json("prod_affecting", "data-plane scope includes prod data-plane VMs")))
        return 0
    if not scope.startswith("vm="):
        print(json.dumps(scope_json(reason="scope format is not recognized", unknown=scope or "unknown")))
        return 1

    raw_targets = scope[len("vm=") :]
    targets = [target for target in raw_targets.split(",") if target]
    if not targets:
        print(json.dumps(scope_json(reason="vm= scope must list at least one module name", unknown="(empty vm= scope)")))
        return 1

    dev_targets = []
    prod_targets = []
    shared_targets = []
    unknown_targets = []

    for target in targets:
        key, env, _module = classify_target(target, classes)
        if key is None or env is None:
            unknown_targets.append(target)
            continue
        rec = classes[key]
        if rec["control_plane"] or rec["scope"] == "shared":
            shared_targets.append(target)
        elif env == "prod":
            prod_targets.append(target)
        elif env == "dev":
            dev_targets.append(target)
        else:
            unknown_targets.append(target)

    if unknown_targets:
        print(json.dumps(scope_json(reason="scope includes unknown module name(s)", unknown=", ".join(unknown_targets))))
        return 1
    if shared_targets:
        print(json.dumps(scope_json("shared_control_plane", f"scope includes shared control-plane targets: {', '.join(shared_targets)}")))
        return 0
    if prod_targets:
        print(json.dumps(scope_json("prod_affecting", f"scope includes prod-affecting targets: {', '.join(prod_targets)}")))
        return 0
    print(json.dumps(scope_json("dev_only", f"all requested targets are dev-only: {', '.join(dev_targets)}")))
    return 0


def cmd_deployable_modules(args, classes):
    if args.env not in {"dev", "prod"}:
        raise ScopeError("--env must be dev or prod")
    try:
        with open(args.plan_json) as f:
            plan = json.load(f)
    except Exception as exc:
        raise ScopeError(f"failed to read plan JSON {args.plan_json}: {exc}") from exc

    deployable = set()
    for rc in plan.get("resource_changes", []):
        actions = ((rc.get("change") or {}).get("actions") or [])
        if actions in (["no-op"], ["read"]):
            continue
        module = root_module_from_address(rc.get("address", ""))
        if not module:
            continue
        key, env, normalized_module = classify_target(module, classes)
        if key is None or env is None:
            raise ScopeError(
                f"undeclared module in plan: {module}; declare its class in "
                "framework/images.yaml, site/images.yaml, or site/applications.yaml"
            )
        rec = classes[key]
        if rec["control_plane"]:
            print(f"WARNING: module {module} does not match any environment -- skipping", file=sys.stderr)
            continue
        if env == args.env:
            deployable.add(normalized_module)
        elif args.env == "dev" and rec["scope"] == "shared":
            deployable.add(normalized_module)

    for module in sorted(deployable):
        print(module)
    return 0


def cmd_backup_kind(args, classes):
    print(backup_kind_for(args.label, classes))
    return 0


def cmd_control_plane_recreate(args, classes):
    # Converge-vs-recreate classifier for the tofu-wrapper safety fence.
    #
    # Reads a `tofu show -json <plan>` document and reports every
    # control-plane VM whose planned action would DESTROY the VM
    # (replace = delete+create in either order, or a bare delete). The
    # pipeline converges control-plane in place (action "update") fine;
    # only a destroy of the runner/coordinator is the genuinely-impossible
    # case that must route to the workstation.
    #
    # Exit contract (consumed by tofu-wrapper.sh guard_control_plane_recreate):
    #   0 — no control-plane VM recreate in the plan (safe to apply)
    #   3 — at least one control-plane VM would be recreated (offenders on
    #       stdout, one "<action>\t<address>" per line)
    #   1 — the plan could not be inspected (missing/garbage/not-a-plan);
    #       the caller must fail closed ("can't prove safety -> stop").
    try:
        with open(args.plan_json) as f:
            plan = json.load(f)
    except Exception as exc:
        raise ScopeError(f"failed to read plan JSON {args.plan_json}: {exc}") from exc

    # A real `tofu show -json` plan always carries a resource_changes array
    # (possibly empty). Its absence means this is not a plan document — an
    # empty/garbage file. Fail closed rather than treat it as "no changes".
    if not isinstance(plan, dict) or "resource_changes" not in plan:
        raise ScopeError(
            f"plan JSON {args.plan_json} has no resource_changes array "
            "(not a tofu plan document?)"
        )

    offenders = []
    for rc in plan.get("resource_changes", []):
        # Only the VM resource itself constitutes VM recreation. A replace
        # of a child resource (cloud-init snippet, HA rule) under the same
        # module is in-place convergence, not a VM destroy.
        if rc.get("type") != "proxmox_virtual_environment_vm":
            continue
        actions = ((rc.get("change") or {}).get("actions") or [])
        # "delete" present => the VM is being destroyed: replace
        # (["delete","create"] / ["create","delete"]) or a bare ["delete"].
        # Pure "update"/"no-op"/"create" never carry "delete".
        if "delete" not in actions:
            continue
        module = root_module_from_address(rc.get("address", ""))
        if not module:
            continue
        key = strip_module_label(module)
        rec = classes.get(key)
        if rec and rec["control_plane"]:
            action = "replace" if "create" in actions else "delete"
            offenders.append((action, rc.get("address", "")))

    if offenders:
        for action, address in offenders:
            print(f"{action}\t{address}")
        return 3
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="vm-scope.sh")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("validate")

    p_classes = sub.add_parser("classes")
    p_classes.add_argument("--format", choices=["json", "tsv"], default="tsv")

    sub.add_parser("buildable-roles")
    sub.add_parser("control-plane-modules")
    sub.add_parser("control-plane-built-roles")

    p_deploy = sub.add_parser("deployable-modules")
    p_deploy.add_argument("--env", required=True)
    p_deploy.add_argument("--plan-json", required=True)

    p_kind = sub.add_parser("backup-kind")
    p_kind.add_argument("label")

    p_cp_recreate = sub.add_parser("control-plane-recreate")
    p_cp_recreate.add_argument("--plan-json", required=True)

    p_target_envs = sub.add_parser("target-envs")
    p_target_envs.add_argument("--targets", default="")

    p_scope = sub.add_parser("scope-impact")
    p_scope.add_argument("--scope", default="")

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args(sys.argv[1:])
    try:
        classes = load_classes()
        dispatch = {
            "validate": cmd_validate,
            "classes": cmd_classes,
            "buildable-roles": cmd_buildable_roles,
            "control-plane-modules": cmd_control_plane_modules,
            "control-plane-built-roles": cmd_control_plane_built_roles,
            "deployable-modules": cmd_deployable_modules,
            "backup-kind": cmd_backup_kind,
            "control-plane-recreate": cmd_control_plane_recreate,
            "target-envs": cmd_target_envs,
            "scope-impact": cmd_scope_impact,
        }
        return dispatch[args.cmd](args, classes)
    except ScopeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
PY
