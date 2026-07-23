#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
MODULE="${REPO_ROOT}/framework/nix/modules/gitlab-runner.nix"
REGISTER="${REPO_ROOT}/framework/scripts/register-runner.sh"
CICD_TOFU="${REPO_ROOT}/framework/tofu/modules/cicd/main.tf"
ROOT_TOFU="${REPO_ROOT}/framework/tofu/root/main.tf"
SITE_CONFIG="${REPO_ROOT}/site/config.yaml"
FIXTURES="${REPO_ROOT}/tests/fixtures/gitlab-runner"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
json_has() { echo "$1" | jq -e --arg f "$2" --arg v "$3" '(.[$f] // []) | index($v)' >/dev/null; }
grep -q 'runner_disk_gb: 256' "$SITE_CONFIG" || fail "site config must provision at least 256GB for cicd /nix image-build scratch"
# These greps assert the WIRING, not the formatting. `tofu fmt` aligns `=` across a
# run of arguments, so adding a longer attribute name (ram_floating_mb) to either
# block re-pads every sibling line. Match the wiring and tolerate the padding.
grep -Eq 'root_disk_gb[[:space:]]+= coalesce\(try\(local\.config\.cicd\.runner_disk_gb, null\), 256\)' "$ROOT_TOFU" || fail "root module must thread cicd.runner_disk_gb with a null-safe 256GB compatibility default"
grep -Eq 'vda_size_gb[[:space:]]+= var\.root_disk_gb' "$CICD_TOFU" || fail "cicd module must apply root_disk_gb to vda_size_gb"
grep -q 'nix.settings.min-free = 8589934592' "$MODULE" || fail "runner min-free must stay at least 8GB"
grep -q 'nix.settings.max-free = 34359738368' "$MODULE" || fail "runner max-free must stay at least 32GB"
ok "cicd root disk and runner reactive GC thresholds preserve HIL build headroom"
bad_runner_disk_config="$(mktemp "${TMPDIR:-/tmp}/runner-disk-config.XXXXXX.yaml")"
bad_runner_disk_output="$(mktemp "${TMPDIR:-/tmp}/runner-disk-validate.XXXXXX.out")"
cp "$SITE_CONFIG" "$bad_runner_disk_config"
yq -i '.cicd.runner_disk_gb = 32' "$bad_runner_disk_config"
if VALIDATE_SITE_CONFIG_CONFIG="$bad_runner_disk_config" \
   "${REPO_ROOT}/framework/scripts/validate-site-config.sh" >"$bad_runner_disk_output" 2>&1; then
  fail "validate-site-config accepted cicd.runner_disk_gb below 256"
elif grep -q 'cicd.runner_disk_gb must be at least 256' "$bad_runner_disk_output"; then
  ok "validate-site-config rejects cicd.runner_disk_gb below 256"
else
  cat "$bad_runner_disk_output" >&2
  fail "validate-site-config rejected low cicd.runner_disk_gb for the wrong reason"
fi
rm -f "$bad_runner_disk_config" "$bad_runner_disk_output"
option_default="$(awk '
  /runnerBudget\.maxConcurrent = lib.mkOption/ { in_opt = 1 }
  in_opt && /default =/ { gsub(/;/, "", $3); print $3; exit }
' "$MODULE")"
[[ "$option_default" =~ ^[0-9]+$ ]] || fail "could not parse runnerBudget.maxConcurrent default"
[[ "$option_default" -ge 4 ]] || fail "runnerBudget.maxConcurrent default ${option_default} is below floor 4"
ok "runnerBudget.maxConcurrent default is ${option_default}"
if grep -q 'systemd.paths.gitlab-runner-set-concurrent' "$MODULE"; then
  fail "legacy set-concurrent path unit still appears in module source"
fi
paths_json="$(nix eval --json '.#nixosConfigurations.cicd.config.systemd.paths')"
echo "$paths_json" | jq -e 'has("gitlab-runner-set-concurrent") | not' >/dev/null \
  || fail "legacy set-concurrent path unit still appears in evaluated systemd.paths"
ok "legacy set-concurrent path unit is absent from source and evaluated config"
# The runner budget's cold-start cgroup backstop is sized from the balloon floor.
# That floor is a site value delivered to the VM's balloon floating floor via
# OpenTofu (config.yaml cicd.runner_ram_floor_mb). The evaluated NixOS
# runnerBudget.floorMb (which sizes the static MemoryHigh/MemoryMax and the
# script's RUNNER_BUDGET_FLOOR_MB) MUST equal it, or the cgroup floor drifts from
# the balloon floor: over-protect and kill builds, or under-protect the host.
config_floor="$(yq -r '.cicd.runner_ram_floor_mb' "$SITE_CONFIG")"
[[ "$config_floor" =~ ^[0-9]+$ ]] || fail "could not read cicd.runner_ram_floor_mb from site config"
eval_floor="$(nix eval --json '.#nixosConfigurations.cicd.config.mycofu.runnerBudget.floorMb' | jq -r '.')"
[[ "$eval_floor" =~ ^[0-9]+$ ]] || fail "could not eval mycofu.runnerBudget.floorMb"
[[ "$eval_floor" == "$config_floor" ]] \
  || fail "runnerBudget.floorMb ($eval_floor) != config.yaml cicd.runner_ram_floor_mb ($config_floor); the cgroup backstop floor has drifted from the balloon floor"
ok "runnerBudget.floorMb tracks config.yaml cicd.runner_ram_floor_mb ($eval_floor)"
# Behavior ratchets via nix eval (not source-file string greps): assert
# the actual derived ExecStart paths contain the dependencies and
# commands we require. Catches regressions a string-grep would miss
# (e.g., wrapper renamed but logic dropped, or `exec true` substituted
# for the GC command).
get_exec_start() {
  nix build --no-link --print-out-paths --no-warn-dirty \
    ".#nixosConfigurations.cicd.config.systemd.services.$1.serviceConfig.ExecStart"
}
exec_budget="$(get_exec_start mycofu-runner-budget)"
[ -x "$exec_budget" ] || fail "runner-budget ExecStart not executable: $exec_budget"
grep -q '/nix/store/[^[:space:]]*diffutils[^[:space:]]*' "$exec_budget" \
  || fail "runner-budget ExecStart does not reference diffutils (cmp will not resolve)"
grep -q '/nix/store/[^[:space:]]*procps[^[:space:]]*' "$exec_budget" \
  || fail "runner-budget ExecStart does not reference procps (pgrep will not resolve)"
ok "runner-budget ExecStart resolves cmp and pgrep dependencies"
# Both nix-gc.service and mycofu-generation-cleanup.service must skip
# when gitlab-runner has active build children, AND must still actually
# invoke nix-collect-garbage when not skipping. TasksCurrent is the
# cgroup-based check (catches grandchildren that pgrep -P would miss).
for service in nix-gc mycofu-generation-cleanup; do
  exec_path="$(get_exec_start "$service")"
  [ -x "$exec_path" ] || fail "${service} ExecStart not executable: $exec_path"
  grep -q 'TasksCurrent' "$exec_path" \
    || fail "${service} ExecStart missing busy-check (no TasksCurrent reference)"
  grep -q 'nix-collect-garbage' "$exec_path" \
    || fail "${service} ExecStart missing actual nix-collect-garbage command"
done
# nix-gc specifically must keep the --delete-older-than 7d retention.
exec_nix_gc="$(get_exec_start nix-gc)"
grep -q 'nix-collect-garbage --delete-older-than 7d' "$exec_nix_gc" \
  || fail "nix-gc ExecStart no longer uses --delete-older-than 7d retention"
ok "nix-gc and mycofu-generation-cleanup both have busy-check + GC command"
register_blocks="$(
  awk '/gitlab-runner register \\/,/--tag-list/ { print }' "$MODULE"
  awk '/GITLAB_RUNNER register \\/,/--executor shell/ { print }' "$REGISTER"
)"
if grep -Eq -- '--concurrent([[:space:]=]|$)' <<< "$register_blocks"; then
  fail "register invocation contains a --concurrent-shaped flag"
fi
ok "register invocations do not use --concurrent"
grep -q 'TIMEOUT=30' "$REGISTER" || fail "polling timeout missing"
grep -q 'while \[\[ $WAIT -lt $TIMEOUT \]\]' "$REGISTER" || fail "polling while loop missing"
grep -q 'head -1 /etc/gitlab-runner/config.toml' "$REGISTER" || fail "polling head -1 missing"
grep -q 'OBSERVED_CONCURRENT' "$REGISTER" || fail "polling observed concurrent variable missing"
grep -q '\-ge 1' "$REGISTER" || fail "polling lower bound missing"
grep -q '\-le 8' "$REGISTER" || fail "polling upper bound missing"
grep -q 'exit 1' "$REGISTER" || fail "polling failure path missing"
ok "register-runner.sh contains the end-state polling pattern"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/runner-concurrency.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
normalize_config() {
  local config_file="$1" tmp_file="${1}.tmp"
  [[ -e "$config_file" ]] || return 0
  if sed '/^\[/q' "$config_file" | grep -qE '^concurrent[[:space:]]*='; then
    sed "1,/^\[/{s/^concurrent[[:space:]]*=.*/concurrent = ${option_default}/;}" "$config_file" > "$tmp_file"
  else
    { echo "concurrent = ${option_default}"; cat "$config_file"; } > "$tmp_file"
  fi
  mv "$tmp_file" "$config_file"
}
runner_block() { sed -n '/^\[\[runners\]\]/,$p' "$1"; }
for name in fresh restored-no-key restored-stale restored-correct; do
  src="${FIXTURES}/${name}.toml"
  work="${TMP_DIR}/${name}.toml"
  cp "$src" "$work"
  runner_block "$work" > "${work}.runners.before"
  normalize_config "$work"
  [[ "$(head -1 "$work")" == "concurrent = ${option_default}" ]] || fail "${name}: first line is not concurrent = ${option_default}"
  runner_block "$work" > "${work}.runners.after"
  cmp -s "${work}.runners.before" "${work}.runners.after" || fail "${name}: [[runners]] block changed"
  cp "$work" "${work}.once"
  normalize_config "$work"
  cmp -s "${work}.once" "$work" || fail "${name}: second normalization changed the file"
done
ok "fixture matrix preserves runner blocks and is idempotent"
get_service_attr() {
  nix eval --json ".#nixosConfigurations.cicd.config.systemd.services.mycofu-runner-budget.$1"
}
list_has() {
  echo "$1" | jq -e --arg v "$2" 'index($v)' >/dev/null
}
after_list="$(get_service_attr after)"
wants_list="$(get_service_attr wants)"
before_list="$(get_service_attr before)"
list_has "$after_list"  "gitlab-runner-restore-config.service" || fail "runner-budget missing After=restore"
list_has "$after_list"  "gitlab-runner-register.service"       || fail "runner-budget missing After=register"
list_has "$wants_list"  "gitlab-runner-restore-config.service" || fail "runner-budget missing Wants=restore"
list_has "$wants_list"  "gitlab-runner-register.service"       || fail "runner-budget missing Wants=register"
list_has "$before_list" "gitlab-runner.service"                || fail "runner-budget missing Before=gitlab-runner"
ok "runner-budget service ordering is correct"
# Default StartLimitBurst=5/StartLimitIntervalSec=10s trips on the
# legitimate write cascade during switch-to-configuration (5+ writes
# to /etc/gitlab-runner/config.toml from restoreConfigScript +
# registerScript + gitlab-runner.service startup all in the same
# second), which fails the closure switch with status 4. Floor at
# 20 starts (4× the default) to prove the absorption capacity is
# preserved across future refactors.
start_limit_burst="$(get_service_attr startLimitBurst | jq -r '.')"
[[ "$start_limit_burst" =~ ^[0-9]+$ ]] || fail "runner-budget startLimitBurst is not numeric: $start_limit_burst"
[[ "$start_limit_burst" -ge 20 ]] || fail "runner-budget startLimitBurst ${start_limit_burst} is below floor 20 (deploy-time write cascade will trip systemd start limit)"
ok "runner-budget startLimitBurst is ${start_limit_burst} (>= 20)"
