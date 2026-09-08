#!/usr/bin/env bash
# rebuild_fixture_helpers.sh — shared helpers for the full-rebuild
# hermetic fixtures:
#   - tests/test_rebuild_ha_flow.sh
#   - tests/test_rebuild_pbs_install_before_preboot_restore.sh
#   - tests/test_rebuild_preboot_restore.sh
#   - tests/test_rebuild_restore_pin_file.sh
#
# DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS lists every framework script that
# rebuild-cluster.sh invokes during a full rebuild and that ALL FOUR of
# these hermetic fixtures shim out as a silent noop. When a new generic
# dependency is added to rebuild-cluster.sh (as MR !263 did with
# configure-node-kernel.sh, which caused pipeline failures 903/904 when
# only some fixtures were updated), it is added HERE ONCE instead of in
# every fixture.
#
# This default is the INTERSECTION of the four fixtures' historical
# inline lists. Scripts that a given fixture handles SPECIALLY — a logged
# stub, an exit-99 guard, or an assertion target — are deliberately NOT
# in this default, because nooping them would clobber that fixture's
# special stub and change its behavior. Each fixture passes those
# scripts that it noops but the others treat specially as extra
# arguments to setup_rebuild_fixture_noops. The per-fixture differences
# are therefore intrinsic, not accidental drift; only the shared base is
# centralized here.
#
# Sourced by fixtures via:
#   source "${REPO_ROOT}/tests/lib/rebuild_fixture_helpers.sh"

# Sprint 049 MR-3 hermeticity: scrub any inherited SOPS_AGE_KEY_FILE from
# the ambient environment (runner-service systemd Environment=, operator
# shell export, or ambient shell state) so rebuild-cluster.sh's Step 0
# prereq check falls back to the fixture's synthetic
# ${REPO_DIR}/operator.age.key. This mirrors the STUB_* scrub above:
# hermetic tests must not depend on any real-VM secret path being present
# in the outer environment.
unset SOPS_AGE_KEY_FILE

# shellcheck disable=SC2034  # consumed by setup_rebuild_fixture_noops
DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS=(
  verify-nas-prereqs.sh
  configure-node-network.sh
  configure-node-kernel.sh
  configure-node-storage.sh
  form-cluster.sh
  configure-storage.sh
  build-all-images.sh
  ensure-app-secrets.sh
  check-plan-images-present.sh
  backup-now.sh
  init-vault.sh
  configure-vault.sh
  configure-replication.sh
  configure-gitlab.sh
  register-runner.sh
  configure-sentinel-gatus.sh
  configure-metrics.sh
  validate.sh
)

# make_noop_script <path> — write an executable shim at <path> that
# succeeds silently. Used both for the noop-script list and for ad-hoc
# PATH shims inside the fixtures. Creates the parent directory if absent
# so callers need not pre-create it.
make_noop_script() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${path}"
}

# setup_rebuild_fixture_noops <repo_dir> [extra_script ...]
# Create a silent-noop shim under <repo_dir>/framework/scripts for every
# script in DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS, plus any fixture-
# specific extras passed as additional arguments.
#
# When a NEW generic dependency is added to rebuild-cluster.sh (one that
# ALL four fixtures should noop), add it to DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS
# above — NOT to each fixture's extras. A script belongs in `extras` only
# when at least one OTHER fixture stubs it specially.
#
# Ordering: call this BEFORE writing any fixture-specific special stub for a
# script, because it overwrites ${repo_dir}/framework/scripts/${script}. In
# practice this never collides — scripts a fixture stubs specially are, by
# definition, not in the shared base and are not passed as extras by that
# fixture — but keep the call ahead of special-stub writes to be safe.
setup_rebuild_fixture_noops() {
  local repo_dir="${1:-}"
  [[ -n "${repo_dir}" ]] || {
    echo "setup_rebuild_fixture_noops: repo_dir (arg 1) is required" >&2
    return 1
  }
  shift
  local script
  for script in "${DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS[@]}"; do
    make_noop_script "${repo_dir}/framework/scripts/${script}"
  done
  for script in "$@"; do
    make_noop_script "${repo_dir}/framework/scripts/${script}"
  done
}
