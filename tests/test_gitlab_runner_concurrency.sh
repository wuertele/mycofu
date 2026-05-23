#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
MODULE="${REPO_ROOT}/framework/nix/modules/gitlab-runner.nix"
REGISTER="${REPO_ROOT}/framework/scripts/register-runner.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures/gitlab-runner"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
json_has() { echo "$1" | jq -e --arg f "$2" --arg v "$3" '(.[$f] // []) | index($v)' >/dev/null; }
option_default="$(awk '
  /runnerConcurrent = lib.mkOption/ { in_opt = 1 }
  in_opt && /default =/ { gsub(/;/, "", $3); print $3; exit }
' "$MODULE")"
[[ "$option_default" =~ ^[0-9]+$ ]] || fail "could not parse runnerConcurrent default"
[[ "$option_default" -ge 4 ]] || fail "runnerConcurrent default ${option_default} is below floor 4"
ok "runnerConcurrent default is ${option_default}"
grep -q 'systemd.paths.gitlab-runner-set-concurrent' "$MODULE" || fail "path unit missing"
grep -q 'PathChanged = "/etc/gitlab-runner/config.toml"' "$MODULE" || fail "path unit missing PathChanged"
grep -q 'Unit = "gitlab-runner-set-concurrent.service"' "$MODULE" || fail "path unit missing Unit"
# PathExists is a continuous condition that re-fires after each .service
# deactivation, creating a tight loop with our oneshot-without-
# RemainAfterExit .service. Observed: 31 fires in 1 second during deploy,
# switch-to-configuration exit status 4. Lock the absence in. Scoped to
# the systemd.paths block to avoid false-positives on legitimate uses
# elsewhere (e.g., unitConfig.ConditionPathExists in other units).
path_unit_block="$(awk '/systemd\.paths\.gitlab-runner-set-concurrent =/,/^  };$/' "$MODULE")"
if echo "$path_unit_block" | grep -qE '(^|[[:space:]])PathExists[[:space:]]*='; then
  fail "path unit has PathExists in pathConfig — this re-fires the oneshot .service in a tight loop until start-limit-hit"
fi
ok "set-concurrent path unit exists (PathChanged only, no PathExists loop)"
# Behavior ratchets via nix eval (not source-file string greps): assert
# the actual derived ExecStart paths contain the dependencies and
# commands we require. Catches regressions a string-grep would miss
# (e.g., wrapper renamed but logic dropped, or `exec true` substituted
# for the GC command).
get_exec_start() {
  nix build --no-link --print-out-paths --no-warn-dirty \
    ".#nixosConfigurations.cicd.config.systemd.services.$1.serviceConfig.ExecStart"
}
exec_set_concurrent="$(get_exec_start gitlab-runner-set-concurrent)"
[ -x "$exec_set_concurrent" ] || fail "set-concurrent ExecStart not executable: $exec_set_concurrent"
grep -q '/nix/store/[^[:space:]]*diffutils[^[:space:]]*' "$exec_set_concurrent" \
  || fail "set-concurrent ExecStart does not reference diffutils (cmp will not resolve)"
ok "set-concurrent ExecStart resolves cmp via diffutils"
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
grep -q '\^concurrent = ${EXPECTED_CONCURRENT}\$' "$REGISTER" || fail "polling concurrent pattern missing"
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
  nix eval --json ".#nixosConfigurations.cicd.config.systemd.services.gitlab-runner-set-concurrent.$1"
}
list_has() {
  echo "$1" | jq -e --arg v "$2" 'index($v)' >/dev/null
}
after_list="$(get_service_attr after)"
wants_list="$(get_service_attr wants)"
before_list="$(get_service_attr before)"
list_has "$after_list"  "gitlab-runner-restore-config.service" || fail "set-concurrent missing After=restore"
list_has "$after_list"  "gitlab-runner-register.service"       || fail "set-concurrent missing After=register"
list_has "$wants_list"  "gitlab-runner-restore-config.service" || fail "set-concurrent missing Wants=restore"
list_has "$wants_list"  "gitlab-runner-register.service"       || fail "set-concurrent missing Wants=register"
list_has "$before_list" "gitlab-runner.service"                || fail "set-concurrent missing Before=gitlab-runner"
ok "set-concurrent service ordering is correct"
# Default StartLimitBurst=5/StartLimitIntervalSec=10s trips on the
# legitimate write cascade during switch-to-configuration (5+ writes
# to /etc/gitlab-runner/config.toml from restoreConfigScript +
# registerScript + gitlab-runner.service startup all in the same
# second), which fails the closure switch with status 4. Floor at
# 20 starts (4× the default) to prove the absorption capacity is
# preserved across future refactors.
start_limit_burst="$(get_service_attr startLimitBurst | jq -r '.')"
[[ "$start_limit_burst" =~ ^[0-9]+$ ]] || fail "set-concurrent startLimitBurst is not numeric: $start_limit_burst"
[[ "$start_limit_burst" -ge 20 ]] || fail "set-concurrent startLimitBurst ${start_limit_burst} is below floor 20 (deploy-time write cascade will trip systemd start limit)"
ok "set-concurrent startLimitBurst is ${start_limit_burst} (>= 20)"
