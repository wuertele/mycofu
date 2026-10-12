#!/usr/bin/env bash
# Shared hermetic fixtures for Sprint 038 PBS backup compliance tests.
#
# The canned pvesh payloads model the JSON shape observed on wuertele's
# Proxmox VE 9.1-style API for:
#   - pvesh get /cluster/resources --type vm --output-format json
#   - pvesh get /cluster/backup --output-format json
#   - pvesh get /nodes/<node>/storage/pbs-nas/content --vmid <id> --output-format json

set -euo pipefail

pbs_fixture_setup() {
  TMP_DIR="$(mktemp -d -t pbs-compliance.XXXXXX)"
  FIXTURE_REPO="${TMP_DIR}/repo"
  SHIM_DIR="${TMP_DIR}/shims"
  STUB_STATE_DIR="${TMP_DIR}/state"

  mkdir -p \
    "${FIXTURE_REPO}/framework/scripts" \
    "${FIXTURE_REPO}/site" \
    "${SHIM_DIR}" \
    "${STUB_STATE_DIR}"

  cp "${REPO_ROOT}/framework/scripts/configure-backups.sh" \
    "${FIXTURE_REPO}/framework/scripts/configure-backups.sh"
  cp "${REPO_ROOT}/framework/scripts/list-backup-backed-vmids.sh" \
    "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh"
  chmod +x \
    "${FIXTURE_REPO}/framework/scripts/configure-backups.sh" \
    "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh"

  cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
pbs:
  backup_schedule: "02:00"
vms:
  gitlab:
    vmid: 150
    backup: true
  vault_dev:
    vmid: 303
    backup: true
  vault_prod:
    vmid: 403
    backup: true
  scratch_dev:
    vmid: 304
    backup: false
EOF

  cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  cat > "${STUB_STATE_DIR}/resources.json" <<'EOF'
[
  {"type":"qemu","vmid":150,"name":"gitlab","node":"pve01"},
  {"type":"qemu","vmid":303,"name":"vault-dev","node":"pve02"},
  {"type":"qemu","vmid":403,"name":"vault-prod","node":"pve03"}
]
EOF

  pbs_fixture_write_jobs "$(pbs_fixture_expected_jobs)"
  : > "${STUB_STATE_DIR}/invocations.log"

  cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${*: -1}"

case "${cmd}" in
  *'pvesh get /cluster/resources --type vm --output-format json'*)
    cat "${STUB_STATE_DIR}/resources.json"
    ;;
  *'pvesh get /cluster/backup --output-format json'*)
    cat "${STUB_STATE_DIR}/jobs.json"
    ;;
  *'pvesh set /cluster/backup/'*|*'pvesh create /cluster/backup'*)
    printf '%s\n' "${cmd}" >> "${STUB_STATE_DIR}/invocations.log"
    if [[ "${cmd}" == *"--exclude ''"* || "${cmd}" == *'--exclude ""'* ]]; then
      echo "invalid empty exclude write: ${cmd}" >&2
      exit 64
    fi
    if [[ "${STUB_DISABLE_STATE_UPDATE:-0}" != "1" ]]; then
      STUB_CMD="${cmd}" python3 - <<'PY'
import json
import os
import shlex

jobs_file = os.path.join(os.environ["STUB_STATE_DIR"], "jobs.json")
cmd = os.environ["STUB_CMD"]
tokens = shlex.split(cmd)

if len(tokens) < 3:
    raise SystemExit("bad pvesh command")

mode = tokens[1]
path = tokens[2]
if mode == "set":
    job_id = path.rstrip("/").split("/")[-1]
    start = 3
elif mode == "create":
    job_id = os.environ.get("STUB_CREATE_ID", "backup-compliance")
    start = 3
else:
    raise SystemExit("unsupported pvesh mode")

opts = {}
delete_keys = []
i = start
while i < len(tokens):
    token = tokens[i]
    if not token.startswith("--"):
        i += 1
        continue
    key = token[2:]
    if i + 1 < len(tokens) and not tokens[i + 1].startswith("--"):
        value = tokens[i + 1]
        i += 2
    else:
        value = "1"
        i += 1
    if key == "delete":
        if value == "1":
            raise SystemExit("--delete requires a field name")
        delete_keys.extend(part for part in value.split(",") if part)
        continue
    if key == "exclude" and value == "":
        raise SystemExit("invalid empty exclude write")
    if key in {"enabled", "all"} and value in {"0", "1"}:
        opts[key] = int(value)
    else:
        opts[key] = value

with open(jobs_file, "r", encoding="utf-8") as fh:
    jobs = json.load(fh)

if mode == "create":
    job = {"id": job_id}
    job.update(opts)
    jobs.append(job)
else:
    for job in jobs:
        if str(job.get("id", "")) == job_id:
            for key in delete_keys:
                job.pop(key, None)
            job.update(opts)
            break
    else:
        raise SystemExit(f"job not found: {job_id}")

with open(jobs_file, "w", encoding="utf-8") as fh:
    json.dump(jobs, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
    fi
    ;;
  *)
    echo "unexpected ssh invocation: $*" >&2
    exit 98
    ;;
esac
EOF
  chmod +x "${SHIM_DIR}/ssh"

  export PATH="${SHIM_DIR}:${PATH}"
  export STUB_STATE_DIR
}

pbs_fixture_teardown() {
  rm -rf "${TMP_DIR}"
}

pbs_fixture_expected_jobs() {
  cat <<'EOF'
[
  {
    "id": "job1",
    "enabled": 1,
    "storage": "pbs-nas",
    "mode": "snapshot",
    "compress": "zstd",
    "all": 0,
    "exclude": "",
    "notes-template": "Precious state -- automated by configure-backups.sh",
    "schedule": "02:00",
    "vmid": "150,303,403"
  }
]
EOF
}

pbs_fixture_write_jobs() {
  printf '%s\n' "$1" > "${STUB_STATE_DIR}/jobs.json"
}

pbs_fixture_write_resources() {
  printf '%s\n' "$1" > "${STUB_STATE_DIR}/resources.json"
}

pbs_fixture_reset_invocations() {
  : > "${STUB_STATE_DIR}/invocations.log"
}

pbs_fixture_invocations() {
  cat "${STUB_STATE_DIR}/invocations.log"
}

pbs_fixture_set_count() {
  grep -c 'pvesh set /cluster/backup/' "${STUB_STATE_DIR}/invocations.log" 2>/dev/null || true
}

pbs_fixture_create_count() {
  grep -c 'pvesh create /cluster/backup' "${STUB_STATE_DIR}/invocations.log" 2>/dev/null || true
}

pbs_fixture_run_configure() {
  set +e
  OUTPUT="$(
    cd "${FIXTURE_REPO}" &&
    framework/scripts/configure-backups.sh "$@" 2>&1
  )"
  STATUS=$?
  set -e
}

pbs_fixture_standard_job_with_drift() {
  local field="$1"

  case "${field}" in
    enabled)
      pbs_fixture_expected_jobs | jq '.[0].enabled = 0'
      ;;
    storage)
      pbs_fixture_expected_jobs | jq '.[0].storage = "local"'
      ;;
    mode)
      pbs_fixture_expected_jobs | jq '.[0].mode = "suspend"'
      ;;
    compress)
      pbs_fixture_expected_jobs | jq '.[0].compress = "lzo"'
      ;;
    all)
      pbs_fixture_expected_jobs | jq '.[0].all = 1'
      ;;
    exclude)
      pbs_fixture_expected_jobs | jq '.[0].exclude = "999"'
      ;;
    notes-template)
      pbs_fixture_expected_jobs | jq '.[0]."notes-template" = "legacy unmarked job"'
      ;;
    schedule)
      pbs_fixture_expected_jobs | jq '.[0].schedule = "03:00"'
      ;;
    vmid)
      pbs_fixture_expected_jobs | jq '.[0].vmid = "150,303"'
      ;;
    *)
      echo "unknown field: ${field}" >&2
      return 1
      ;;
  esac
}

assert_exit_status() {
  local expected="$1"
  local label="$2"

  if [[ "${STATUS}" -eq "${expected}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected exit %s, got %s\n' "${expected}" "${STATUS}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_has() {
  local needle="$1"
  local label="$2"

  if grep -Fq -- "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing output: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_lacks() {
  local needle="$1"
  local label="$2"

  if ! grep -Fq -- "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    unexpected output: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_invocations_have() {
  local needle="$1"
  local label="$2"
  local invocations

  invocations="$(pbs_fixture_invocations)"
  if grep -Fq -- "${needle}" <<< "${invocations}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing invocation text: %s\n' "${needle}" >&2
    printf '    invocations:\n%s\n' "${invocations}" >&2
  fi
}

assert_invocations_lack() {
  local needle="$1"
  local label="$2"
  local invocations

  invocations="$(pbs_fixture_invocations)"
  if ! grep -Fq -- "${needle}" <<< "${invocations}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    unexpected invocation text: %s\n' "${needle}" >&2
    printf '    invocations:\n%s\n' "${invocations}" >&2
  fi
}

assert_invocation_count() {
  local actual="$1"
  local expected="$2"
  local label="$3"

  if [[ "${actual}" == "${expected}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected count %s, got %s\n' "${expected}" "${actual}" >&2
    printf '    invocations:\n%s\n' "$(pbs_fixture_invocations)" >&2
  fi
}
