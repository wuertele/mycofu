#!/usr/bin/env bash
# test_reclaim_keep_set.sh — conservative image-store reclaim behavior.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
SSH_LOG="${TMP_DIR}/ssh.log"
HELPER="${TMP_DIR}/deployed-helper.sh"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/framework" "${FIXTURE_REPO}/site" "$SHIM_DIR"
cp "${REPO_ROOT}/framework/scripts/reclaim-images.sh" "${FIXTURE_REPO}/framework/scripts/reclaim-images.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/reclaim-images.sh"

cat > "${FIXTURE_REPO}/framework/images.yaml" <<'EOF'
roles:
  vault: {}
EOF
cat > "${FIXTURE_REPO}/site/images.yaml" <<'EOF'
roles: {}
EOF
cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
proxmox:
  image_storage_path: /images
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
EOF

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
query="${2:-}"
file="${3:-}"
case "$query" in
  ".proxmox.image_storage_path // \"/var/lib/vz/template/iso\"")
    echo "/images"
    ;;
  ".roles // {} | keys | .[]")
    case "$file" in
      */framework/images.yaml) echo "vault" ;;
      *) ;;
    esac
    ;;
  ".nodes[] | [.name, .mgmt_ip] | @tsv")
    printf 'pve01\t127.0.0.1\n'
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
cmd="${*: -1}"
printf '%s\n' "$cmd" >> "${SSH_LOG}"
case "$cmd" in
  find\ /images\ -maxdepth\ 1\ -type\ f\ -name\ \'vault-\*.img\'*)
    cat <<ROWS
vault-deployed001.img	1000.0
vault-inuse002.img	2000.0
vault-grace003.img	199000.0
vault-prune004.img	3000.0
vault-new005.img	9000.0
vault-new006.img	8000.0
vault-new007.img	7000.0
vault-new008.img	6000.0
vault-new009.img	5000.0
ROWS
    ;;
  *"qm list"* )
    echo "vault-inuse002.img"
    ;;
  find\ /images\ -maxdepth\ 1\ -type\ f\ -name\ \'vault-\*.img.partial.\*\'*)
    echo "vault-stale.img.partial.1234.abcd"
    ;;
  rm\ -f\ /images/*)
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

cat > "$HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STUB_DEPLOYED_HELPER_FAIL:-0}" == "1" ]]; then
  echo "strict fetch failed" >&2
  exit 7
fi
echo "vault-deployed001.img"
EOF
chmod +x "$HELPER"

export PATH="${SHIM_DIR}:${PATH}"
export SSH_LOG
export MYCOFU_RECLAIM_DEPLOYED_HELPER="$HELPER"
export MYCOFU_RECLAIM_NOW=200000

run_reclaim() {
  set +e
  OUT="$(cd "$FIXTURE_REPO" && framework/scripts/reclaim-images.sh --dry-run --role vault 2>&1)"
  RC=$?
  set -e
}

test_start "RIK.1" "dry-run keep set includes deployed, in-use, grace, and last-five"
: > "$SSH_LOG"
unset STUB_DEPLOYED_HELPER_FAIL
run_reclaim
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "KEEP pve01:vault-deployed001.img reason=deployed" <<< "$OUT" &&
   grep -Fq "KEEP pve01:vault-inuse002.img reason=in-use" <<< "$OUT" &&
   grep -Fq "KEEP pve01:vault-grace003.img reason=last-five" <<< "$OUT" &&
   grep -Fq "KEEP pve01:vault-new005.img reason=last-five" <<< "$OUT" &&
   grep -Fq "PRUNE pve01:vault-prune004.img reason=unreferenced dry-run" <<< "$OUT" &&
   grep -Fq "SWEEP pve01:vault-stale.img.partial.1234.abcd reason=stale-partial dry-run" <<< "$OUT"; then
  test_pass "dry-run logs the expected keep/prune/sweep decisions"
else
  test_fail "unexpected dry-run reclaim output"
  printf '%s\n' "$OUT" >&2
fi

test_start "RIK.2" "--strict deployed helper failure fails before deletes"
export STUB_DEPLOYED_HELPER_FAIL=1
: > "$SSH_LOG"
set +e
FAIL_OUT="$(cd "$FIXTURE_REPO" && framework/scripts/reclaim-images.sh --apply --role vault 2>&1)"
FAIL_RC=$?
set -e
if [[ "$FAIL_RC" -ne 0 ]] &&
   grep -Fq "strict fetch failed" <<< "$FAIL_OUT" &&
   ! grep -Fq "rm -f /images/" "$SSH_LOG"; then
  test_pass "strict metadata failure stops apply-mode reclaim before rm"
else
  test_fail "strict failure did not fail closed"
  printf 'rc=%s\nout:\n%s\nssh:\n%s\n' "$FAIL_RC" "$FAIL_OUT" "$(cat "$SSH_LOG")" >&2
fi

test_start "RIK.3" "reclaim CI job is schedule/web gated only"
JOB_BLOCK="$(awk '/^reclaim:image-store:/{flag=1} flag{print} /^# --- Deploy Dev ---/{flag=0}' "${REPO_ROOT}/.gitlab-ci.yml")"
if grep -Fq 'CI_PIPELINE_SOURCE == "schedule"' <<< "$JOB_BLOCK" &&
   grep -Fq 'CI_PIPELINE_SOURCE == "web"' <<< "$JOB_BLOCK" &&
   ! grep -Eq 'merge_request_event|CI_COMMIT_BRANCH|push' <<< "$JOB_BLOCK"; then
  test_pass "reclaim:image-store rules contain schedule/web and no push branch rule"
else
  test_fail "reclaim:image-store rules are not schedule/web only"
  printf '%s\n' "$JOB_BLOCK" >&2
fi

test_start "RIK.4" "reclaim CI shards share per-role build-image resource_group"
if grep -Fq 'resource_group: build-image-${ROLE}' <<< "$JOB_BLOCK" &&
   grep -Fq 'framework/scripts/reclaim-images.sh --apply --role "$ROLE"' <<< "$JOB_BLOCK" &&
   grep -Fq -- '- hil-boot' <<< "$JOB_BLOCK" &&
   ! grep -Fq 'resource_group: reclaim-image-store' <<< "$JOB_BLOCK"; then
  test_pass "reclaim serializes with same-role image build/upload jobs"
else
  test_fail "reclaim/image upload serialization contract missing"
  printf '%s\n' "$JOB_BLOCK" >&2
fi

test_start "RIK.5" "reclaim schedule does not trigger broad regression job"
REGRESSION_BLOCK="$(awk '/^regression:/{flag=1} flag{print} /^bench:scheduled:/{flag=0}' "${REPO_ROOT}/.gitlab-ci.yml")"
RECLAIM_EXCLUDE_LINE="$(grep -nF 'CI_PIPELINE_SOURCE == "schedule" && $RECLAIM_IMAGE_STORE == "1"' <<< "$REGRESSION_BLOCK" | head -1 | cut -d: -f1 || true)"
BROAD_SCHEDULE_LINE="$(grep -nF 'CI_PIPELINE_SOURCE == "schedule"' <<< "$REGRESSION_BLOCK" | tail -1 | cut -d: -f1 || true)"
if [[ -n "$RECLAIM_EXCLUDE_LINE" && -n "$BROAD_SCHEDULE_LINE" ]] &&
   [[ "$RECLAIM_EXCLUDE_LINE" -lt "$BROAD_SCHEDULE_LINE" ]] &&
   grep -A1 -F 'CI_PIPELINE_SOURCE == "schedule" && $RECLAIM_IMAGE_STORE == "1"' <<< "$REGRESSION_BLOCK" | grep -Fq 'when: never'; then
  test_pass "regression schedule excludes RECLAIM_IMAGE_STORE=1 before broad schedule rule"
else
  test_fail "regression schedule can still match reclaim schedule"
  printf '%s\n' "$REGRESSION_BLOCK" >&2
fi

runner_summary
