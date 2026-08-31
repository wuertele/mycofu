#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/s042-isolation.XXXXXX")"
WORK="${TMP_DIR}/repo"
BASE_PATCH="${TMP_DIR}/base.patch"
BASE_MAP="${TMP_DIR}/base.tsv"
AFTER_MAP="${TMP_DIR}/after.tsv"
WORKTREE_CREATED=0

cleanup() {
  if [[ "$WORKTREE_CREATED" -eq 1 ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$WORK" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

NIX_STORE_ARGS=()
if [[ -n "${MYCOFU_NIX_STORE:-}" ]]; then
  NIX_STORE_ARGS=(--store "$MYCOFU_NIX_STORE")
fi

NIX_INPUT_ARGS=()
if [[ -n "${MYCOFU_NIXPKGS_PATH:-}" ]]; then
  NIX_INPUT_ARGS+=(--override-input nixpkgs "path:${MYCOFU_NIXPKGS_PATH}")
fi
if [[ -n "${MYCOFU_NIXPKGS_UNSTABLE_PATH:-}" ]]; then
  NIX_INPUT_ARGS+=(--override-input nixpkgs-unstable "path:${MYCOFU_NIXPKGS_UNSTABLE_PATH}")
fi

nix_eval() {
  # bash 3.2 (macOS) + `set -u` errors on ${arr[@]} when the array is
  # empty; ${arr[@]+"${arr[@]}"} expands to nothing in that case.
  nix \
    ${NIX_STORE_ARGS[@]+"${NIX_STORE_ARGS[@]}"} \
    eval \
    ${NIX_INPUT_ARGS[@]+"${NIX_INPUT_ARGS[@]}"} \
    "$@"
}

prepare_work_repo() {
  local worktree_err="${TMP_DIR}/worktree-add.err"
  local clone_err="${TMP_DIR}/clone.err"

  git -C "$REPO_ROOT" diff --binary > "$BASE_PATCH"

  if git -C "$REPO_ROOT" worktree add --detach "$WORK" HEAD > /dev/null 2> "$worktree_err"; then
    WORKTREE_CREATED=1
  else
    if ! git clone --no-local "$REPO_ROOT" "$WORK" > /dev/null 2> "$clone_err"; then
      echo "ERROR: failed to create isolated work repo" >&2
      echo "git worktree add stderr:" >&2
      sed 's/^/  /' "$worktree_err" >&2
      echo "git clone fallback stderr:" >&2
      sed 's/^/  /' "$clone_err" >&2
      return 1
    fi
  fi

  reset_work_repo
}

reset_work_repo() {
  git -C "$WORK" reset -q HEAD -- . >/dev/null 2>&1 || true
  git -C "$WORK" checkout -- . >/dev/null 2>&1 || true
  git -C "$WORK" clean -fd >/dev/null 2>&1 || true
  if [[ -s "$BASE_PATCH" ]]; then
    (cd "$WORK" && git apply --whitespace=nowarn "$BASE_PATCH")
  fi
}

discover_roles() {
  local json="${TMP_DIR}/roles.json"
  local err="${TMP_DIR}/discover-roles.err"
  local rc

  set +e
  (cd "$WORK" && nix_eval .#packages.x86_64-linux \
    --apply 'a: builtins.attrNames a' --json > "$json" 2> "$err")
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR: failed to discover image roles with nix eval" >&2
    sed 's/^/  /' "$err" >&2
    return "$rc"
  fi

  jq -r '.[] | select(endswith("-image")) | sub("-image$"; "")' "$json"
}

eval_all() {
  # A single `nix eval --json --apply` returns { "<role>-image": outPath }
  # for every *-image package. This collapses the ~13 nix invocations per
  # probe (one cold evaluator start each) into one, sharing the evaluator's
  # per-invocation caches and amortizing cold-start cost across all roles
  # (#464 — batching only; no added concurrency). Semantics are preserved by
  # design:
  #
  #   * outPath is compared, not drvPath. The prior loop used --raw against a
  #     derivation, which yields outPath. outPath forces at least as much
  #     evaluation as drvPath (both instantiate the derivation and therefore
  #     trip the NixOS module-system assertions used to surface
  #     under-inclusion, e.g. grafana/influxdb). Preserving --raw's outPath
  #     semantics keeps the changed_roles comparison byte-identical.
  #   * The apply maps over exactly the discovered baseline roles ($ALL_ROLES,
  #     with the -image suffix), NOT builtins.attrNames p. This matches the
  #     prior loop's `for role in $ALL_ROLES` iteration for strict parity: a
  #     role that disappears from the flake during a probe hard-fails here
  #     (attribute-missing is uncatchable, so it drops to the fallback and is
  #     named), exactly as the old per-role --raw did, instead of being
  #     silently omitted from the TSV. Enumerating the explicit list also means
  #     non-image packages (host tools, checks) are never forced.
  #   * builtins.tryEval wraps each role's outPath so a single-role failure
  #     produces a per-role sentinel instead of aborting the whole eval
  #     opaquely, preserving the prior loop's per-role error attribution
  #     (#464 refinement 3) — but ONLY for catchable throws (throw / assert /
  #     module-system assertions). Uncatchable failures (builtins.abort,
  #     infinite recursion, IFD input errors) still terminate the single
  #     invocation; when that happens the fallback re-runs the old per-role
  #     --raw loop to surface the specific role's stderr for attribution.
  local output="$1"
  : > "$output"
  local json="${TMP_DIR}/eval-all.json"
  local err="${TMP_DIR}/eval-all.err"
  local rc
  local flake_ref="${MYCOFU_ISO_FLAKE_REF:-.#packages.x86_64-linux}"

  # The Nix list of exactly the discovered baseline roles, "<role>-image",
  # mirroring the prior loop's iteration over $ALL_ROLES.
  # shellcheck disable=SC2086
  local roles_nix
  roles_nix="$(printf '"%s-image" ' $ALL_ROLES)"

  # A visibly artificial sentinel that cannot collide with a real Nix store
  # path (contains `<<`/`>>` and a colon — none appear in a store path, which
  # is always `/nix/store/<hash>-<name>`).
  local sentinel='<<mycofu:tryEval-fail>>'

  set +e
  (cd "$WORK" && nix_eval --json "$flake_ref" --apply "
    p:
    builtins.listToAttrs (
      builtins.map (n:
        let r = builtins.tryEval p.\${n}.outPath;
        in {
          name = n;
          value = if r.success then r.value else \"${sentinel}\";
        }
      ) [ ${roles_nix} ]
    )
  " > "$json" 2> "$err")
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    # Uncatchable-error attribution fallback: the single invocation died
    # before per-role tryEval could kick in. Replay the old per-role loop to
    # name the specific role(s) whose eval blew up, so operators aren't left
    # with just "single nix eval failed".
    echo "ERROR: single nix eval of image roles failed; probing per-role for attribution" >&2
    sed 's/^/  /' "$err" >&2
    local role
    for role in $ALL_ROLES; do
      local role_err="${TMP_DIR}/eval-${role}-fallback.err"
      set +e
      (cd "$WORK" && nix_eval --raw "${flake_ref}.${role}-image" > /dev/null 2> "$role_err")
      local role_rc=$?
      set -e
      if [[ "$role_rc" -ne 0 ]]; then
        echo "  failing role: ${role}" >&2
        sed 's/^/    /' "$role_err" >&2
      fi
    done
    return "$rc"
  fi

  # Per-role tryEval failure ⇒ real regression (#464 refinement 3): probes
  # must not cause eval failures (that is the under-inclusion test's job).
  # Preserve the prior loop's behavior (return non-zero, name the role)
  # rather than silently collapsing the failure into the changed-set.
  local failed
  failed="$(jq -r --arg sentinel "$sentinel" '
    to_entries[] |
    select(.value == $sentinel) |
    (.key | sub("-image$"; ""))
  ' "$json")"
  if [[ -n "$failed" ]]; then
    echo "ERROR: failed to eval image derivation for role(s):" >&2
    sed 's/^/  /' <<< "$failed" >&2
    return 1
  fi

  # Emit "<role>\t<outPath>" pairs matching the prior TSV shape so
  # map_lookup/changed_roles keep working unchanged.
  jq -r 'to_entries[] | "\(.key | sub("-image$"; ""))\t\(.value)"' "$json" > "$output"
}

map_lookup() {
  local role="$1"
  local file="$2"
  awk -F '\t' -v r="$role" '$1 == r { print $2 }' "$file"
}

changed_roles() {
  local base="$1"
  local after="$2"
  local role
  while IFS=$'\t' read -r role base_path; do
    local after_path
    after_path="$(map_lookup "$role" "$after")"
    if [[ "$base_path" != "$after_path" ]]; then
      printf '%s\n' "$role"
    fi
  done < "$base" | sort
}

normalize_roles() {
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "$@" | sort
}

assert_probe() {
  local id="$1"
  local desc="$2"
  shift 2
  local expected_file="${TMP_DIR}/${id}.expected"
  local actual_file="${TMP_DIR}/${id}.actual"

  normalize_roles "$@" > "$expected_file"
  eval_all "$AFTER_MAP"
  changed_roles "$BASE_MAP" "$AFTER_MAP" > "$actual_file"

  if cmp -s "$expected_file" "$actual_file"; then
    local rendered
    rendered="$(tr '\n' ' ' < "$actual_file" | sed 's/[[:space:]]*$//')"
    [[ -n "$rendered" ]] || rendered="none"
    test_pass "$desc changed exactly: $rendered"
  else
    test_fail "$desc changed-role set mismatch"
    echo "Expected:" >&2
    sed 's/^/  /' "$expected_file" >&2
    echo "Actual:" >&2
    sed 's/^/  /' "$actual_file" >&2
  fi

  reset_work_repo
}

assert_edit_applied() {
  local file="$1"
  local marker="$2"
  local desc="$3"

  if grep -Fq "$marker" "$file"; then
    return 0
  fi

  test_fail "$desc probe edit did not apply"
  reset_work_repo
  return 1
}

all_roles_args() {
  # shellcheck disable=SC2086
  printf '%s\n' $ALL_ROLES
}

# Library mode: when sourced with MYCOFU_ISO_LIB_ONLY=1, stop here so a unit
# test can exercise eval_all's failure-attribution path (#464 refinement 3)
# against a fixture flake without running the full 19-probe matrix. All
# functions above are defined; nothing below (worktree setup, probes) runs.
if [[ "${MYCOFU_ISO_LIB_ONLY:-0}" == "1" ]]; then
  return 0
fi

echo "[setup] preparing isolated work repo"
prepare_work_repo
echo "[setup] discovering image roles"
ALL_ROLES="$(discover_roles | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [[ -z "$ALL_ROLES" ]]; then
  test_start "s042.iso.roles" "discover flake image roles"
  test_fail "no image roles discovered"
  runner_summary
fi

test_start "s042.iso.base" "baseline image evals"
eval_all "$BASE_MAP"
test_pass "baseline evaluated roles: $ALL_ROLES"

test_start "s042.iso.A" "grafana dashboard change rehashes grafana only"
printf '\n' >> "$WORK/site/apps/grafana/dashboards/cluster-overview.json"
assert_probe "A" "grafana dashboard" grafana

test_start "s042.iso.A2" "grafana app config change rehashes grafana only"
printf '\n; sprint-042 sentinel\n' >> "$WORK/site/apps/grafana/grafana.ini"
assert_probe "A2" "grafana.ini" grafana

test_start "s042.iso.A3" "influxdb app config change rehashes influxdb only"
printf '\n' >> "$WORK/site/apps/influxdb/buckets.json"
assert_probe "A3" "influxdb buckets.json" influxdb

test_start "s042.iso.B" "shared base module rehashes every role"
printf '\n# sprint-042 sentinel\n' >> "$WORK/framework/nix/modules/base.nix"
# shellcheck disable=SC2046
assert_probe "B" "shared base module" $(all_roles_args)

test_start "s042.iso.B2" "shared vm-runtime lib rehashes every role"
printf '\n# sprint-042 sentinel\n' >> "$WORK/framework/nix/lib/vm-runtime.nix"
# shellcheck disable=SC2046
assert_probe "B2" "shared vm-runtime lib" $(all_roles_args)

test_start "s042.iso.B3" "Option A certbot module rehashes every role"
printf '\n# sprint-042 sentinel\n' >> "$WORK/framework/nix/modules/certbot.nix"
# shellcheck disable=SC2046
assert_probe "B3" "shared certbot module" $(all_roles_args)

test_start "s042.iso.C" "roon catalog change rehashes roon only"
perl -0pi -e 's/was here 2026\.03\.16a/was here 2026.03.16a s042/' "$WORK/framework/catalog/roon/module.nix"
if assert_edit_applied "$WORK/framework/catalog/roon/module.nix" "s042" "roon catalog"; then
  assert_probe "C" "roon catalog" roon
fi

test_start "s042.iso.C2" "cluster-dashboard transitive dep rehashes influxdb only"
perl -0pi -e 's/cluster-dashboard-static/cluster-dashboard-static-s042/' "$WORK/framework/catalog/cluster-dashboard/module.nix"
if assert_edit_applied "$WORK/framework/catalog/cluster-dashboard/module.nix" "cluster-dashboard-static-s042" "cluster-dashboard catalog"; then
  assert_probe "C2" "cluster-dashboard catalog" influxdb
fi

test_start "s042.iso.C3" "benchmarks/grafana change rehashes grafana only"
printf '\n' >> "$WORK/benchmarks/grafana/dashboard.json"
assert_probe "C3" "benchmarks grafana dashboard" grafana

test_start "s042.iso.D" "new unrelated site/apps directory rehashes zero roles"
mkdir -p "$WORK/site/apps/__probe__"
printf '{}\n' > "$WORK/site/apps/__probe__/x.json"
git -C "$WORK" add site/apps/__probe__/x.json
assert_probe "D" "unrelated site/apps directory"

test_start "s042.iso.D2" "new unrelated catalog directory rehashes zero roles"
mkdir -p "$WORK/framework/catalog/__probe__"
printf '{}\n' > "$WORK/framework/catalog/__probe__/module.nix"
git -C "$WORK" add framework/catalog/__probe__/module.nix
assert_probe "D2" "unrelated catalog directory"

test_start "s042.iso.D3" "new unrelated host file rehashes zero roles"
printf '{}\n' > "$WORK/site/nix/hosts/__probe__.nix"
git -C "$WORK" add site/nix/hosts/__probe__.nix
assert_probe "D3" "unrelated host file"

test_start "s042.iso.E" "HIL fixture change rehashes hil-boot only"
printf '\n# sprint-042 sentinel\n' >> "$WORK/tests/hil/bfnet/config.yaml"
assert_probe "E" "HIL fixture" hil-boot

test_start "s042.iso.E2" "site/config.yaml change rehashes hil-boot only"
printf '\n# sprint-042 sentinel\n' >> "$WORK/site/config.yaml"
assert_probe "E2" "site config" hil-boot

test_start "s042.iso.E3" "dns host change does not rehash hil-boot"
perl -0pi -e 's{  system\.stateVersion = "24\.11";}{  environment.etc."s042-dns-probe".text = "dns\\n";\n  system.stateVersion = "24.11";}' "$WORK/site/nix/hosts/dns.nix"
if assert_edit_applied "$WORK/site/nix/hosts/dns.nix" "s042-dns-probe" "dns host file"; then
  assert_probe "E3" "dns host file" dns
fi

test_start "s042.iso.F" "cicd-owned provider file rehashes cicd only"
perl -0pi -e 's{runHook postInstall}{echo s042-provider-probe >/dev/null\n    runHook postInstall}' "$WORK/framework/nix/lib/bpg-proxmox-provider.nix"
if assert_edit_applied "$WORK/framework/nix/lib/bpg-proxmox-provider.nix" "s042-provider-probe" "bpg/proxmox provider"; then
  assert_probe "F" "bpg/proxmox provider" cicd
fi

test_start "s042.iso.F2" "MeshCmd host-tool package rehashes hil-boot only"
perl -0pi -e 's{runHook postInstall}{echo s042-meshcmd-probe >/dev/null\n    runHook postInstall}' "$WORK/framework/nix/pkgs/meshcmd/default.nix"
if assert_edit_applied "$WORK/framework/nix/pkgs/meshcmd/default.nix" "s042-meshcmd-probe" "MeshCmd host-tool package"; then
  assert_probe "F2" "MeshCmd host-tool package" hil-boot
fi

if [[ ! -s "$BASE_PATCH" ]] && [[ -n "$(git -C "$WORK" status --porcelain)" ]]; then
  test_start "s042.iso.clean" "isolated repo clean after probes"
  test_fail "probe work repo is not clean after reset"
else
  test_start "s042.iso.clean" "isolated repo clean after probes"
  test_pass "no probe residue remains"
fi

runner_summary
