#!/usr/bin/env bash
# V2.2: register-runner delivers cicd runner secrets to persistent paths.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

REGISTER_SCRIPT="${REPO_ROOT}/framework/scripts/register-runner.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

RUN_OUTPUT=""
RUN_STATUS=0

remote_file() {
  local root="$1"
  local remote_path="$2"
  printf '%s/%s' "$root" "${remote_path#/}"
}

first_line_number() {
  local pattern="$1"
  local file="$2"
  local line
  line="$(grep -Fn "$pattern" "$file" | head -1 | cut -d: -f1 || true)"
  [[ -n "$line" ]] && printf '%s\n' "$line"
}

full_register_sync_gate_observed() {
  local ssh_log="$1"
  grep -Fq 'pvesr schedule-now 160-0' "$ssh_log" || return 1
  [[ "$(grep -Fc 'pvesr status' "$ssh_log")" -ge 2 ]] || return 1
}

make_fixture() {
  local name="$1"
  local fixture="${TMP_DIR}/${name}"
  local repo="${fixture}/repo"
  local shims="${fixture}/shims"

  mkdir -p \
    "${repo}/framework/scripts" \
    "${repo}/site/sops" \
    "$shims" \
    "${fixture}/remote"

  cp "$REGISTER_SCRIPT" "${repo}/framework/scripts/register-runner.sh"
  chmod +x "${repo}/framework/scripts/register-runner.sh"
  printf 'fixture flake\n' > "${repo}/flake.nix"
  printf 'SYNTHETIC-AGE-KEY-SENTINEL\n' > "${fixture}/synthetic.age.key"
  printf 'SYNTHETIC-SOPS-CIPHERTEXT-SENTINEL\n' > "${repo}/site/sops/secrets.yaml"

  cat > "${repo}/site/config.yaml" <<'EOF'
domain: example.invalid
vms:
  cicd:
    ip: 10.0.0.61
    vmid: 160
    node: pve01
  gitlab:
    ip: 10.0.0.50
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
EOF

  cat > "${shims}/yq" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  .vms.cicd.ip) printf '%s\n' '10.0.0.61' ;;
  .vms.cicd.vmid) printf '%s\n' '160' ;;
  '.vms.cicd.node // ""') printf '%s\n' 'pve01' ;;
  .vms.gitlab.ip) printf '%s\n' '10.0.0.50' ;;
  .domain) printf '%s\n' 'example.invalid' ;;
  '.nodes[] | select(.name == "pve01") | .mgmt_ip') printf '%s\n' '10.0.0.11' ;;
  *) echo "yq shim: unexpected expression: ${2:-}" >&2; exit 1 ;;
esac
EOF
  chmod +x "${shims}/yq"

  cat > "${shims}/sops" <<'EOF'
#!/usr/bin/env bash
printf 'sops|%s\n' "$*" >> "${SOPS_LOG}"
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  case "${3:-}" in
    '["gitlab_runner_registration_token"]')
      printf '%s\n' 'SYNTHETIC-RUNNER-REGISTRATION-TOKEN'
      ;;
    '["gitlab_root_password"]')
      printf '%s\n' 'SYNTHETIC-GITLAB-ROOT-PASSWORD'
      ;;
    '["ssh_privkey"]')
      echo "sops shim: local ssh_privkey extraction is forbidden" >&2
      exit 88
      ;;
    *)
      echo "sops shim: unexpected extract key: ${3:-}" >&2
      exit 1
      ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "--set" ]]; then
  exit 0
fi
echo "sops shim: unexpected args: $*" >&2
exit 1
EOF
  chmod +x "${shims}/sops"

  cat > "${shims}/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf 'curl|%s\n' "$args" >> "${CURL_LOG}"
case "$args" in
  *'/oauth/token'*)
    printf '%s\n' '{"access_token":"SYNTHETIC-ACCESS-TOKEN"}'
    ;;
  *'/api/v4/runners/verify'*)
    printf '%s\n' '{"id":101}'
    ;;
  *'/api/v4/runners/all'*)
    printf '%s\n' '[{"id":101,"status":"online","tag_list":["infra","deploy"]}]'
    ;;
  *'/api/v4/user/runners'*)
    printf '%s\n' '{"token":"SYNTHETIC-FRESH-RUNNER-TOKEN"}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
EOF
  chmod +x "${shims}/curl"

  cat > "${shims}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_SCP_FAIL:-0}" == "1" ]]; then
  echo "scp shim injected failure" >&2
  exit 42
fi
items=()
skip_next=0
for arg in "$@"; do
  if [[ "$skip_next" -eq 1 ]]; then
    skip_next=0
    continue
  fi
  case "$arg" in
    -o) skip_next=1 ;;
    -*) ;;
    *) items+=("$arg") ;;
  esac
done
if [[ "${#items[@]}" -lt 2 ]]; then
  echo "scp shim: expected source and destination in: $*" >&2
  exit 1
fi
src="${items[$((${#items[@]} - 2))]}"
dest="${items[$((${#items[@]} - 1))]}"
printf 'scp|%s|%s\n' "$src" "$dest" >> "${SCP_LOG}"
remote_path="${dest#*:}"
target="${REMOTE_ROOT}/${remote_path#/}"
mkdir -p "$(dirname "$target")"
cp "$src" "$target"
EOF
  chmod +x "${shims}/scp"

  cat > "${shims}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd=""
for arg in "$@"; do
  cmd="$arg"
done
printf 'ssh|%s\n' "$cmd" >> "${SSH_LOG}"

remote_file() {
  printf '%s/%s' "$REMOTE_ROOT" "${1#/}"
}
mkdir -p "${REMOTE_ROOT}/.state"

if [[ "$cmd" == *"pvesr status"* ]]; then
  # Count `pvesr status` invocations so #812 can simulate "sync advances
  # after N polls" — needed to prove the raised timeout waits within its
  # budget for the healthy-but-slower-than-old-timeout case. The counter
  # is per-fixture (REMOTE_ROOT is fixture-scoped) and starts at 1 on the
  # first call.
  count_file="${REMOTE_ROOT}/.state/pvesr_status_count"
  count=0
  [[ -s "$count_file" ]] && count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"
  printf '%s\n' 'JobID Enabled Target LastSync NextSync Duration FailCount State'
  # Sync-advance modes:
  #   FAKE_PVESR_SYNC_AFTER_N unset  → prior behavior: sync flips on
  #     schedule-now (see below), then pvesr status reflects it.
  #   FAKE_PVESR_SYNC_AFTER_N=<N>    → status returns unsynced for the
  #     first N polls, synced thereafter. schedule-now is a no-op in this
  #     mode. #812 fixture uses this to simulate a healthy replica that
  #     takes longer than the old 300s timeout but less than the new
  #     1200s default.
  #   FAKE_PVESR_FAIL_COUNT=<n>      → override FailCount emitted on
  #     every row (default 0). Used to exercise the classifier's
  #     "FailCount>0" fault branch (#812 R1 codex/agy findings).
  fail_count="${FAKE_PVESR_FAIL_COUNT:-0}"
  if [[ -n "${FAKE_PVESR_SYNC_AFTER_N:-}" ]]; then
    if [[ "$count" -ge "$FAKE_PVESR_SYNC_AFTER_N" ]]; then
      printf '%s\n' "160-0 1 pve02 2999-01-01_00:00:00 - 00:00:01 ${fail_count} OK"
    else
      # UNCHANGED LastSync across polls — matches pvesr real behavior
      # (LastSync is updated atomically on job completion, not
      # incrementally during a run). The updated #812 classifier
      # correctly detects "did not advance since the wait started" by
      # comparing the current LastSync to the initial snapshot; a
      # constant value across polls is the "still running" or "stuck"
      # signal.
      printf '%s\n' "160-0 1 pve02 2020-01-01_00:00:00 - 00:00:01 ${fail_count} OK"
    fi
  elif [[ -f "${REMOTE_ROOT}/.state/pvesr_synced" ]]; then
    printf '%s\n' "160-0 1 pve02 2999-01-01_00:00:00 - 00:00:01 ${fail_count} OK"
  else
    printf '%s\n' "160-0 1 pve02 - - 00:00:00 ${fail_count} OK"
  fi
  exit 0
fi

if [[ "$cmd" == *"pvesr schedule-now 160-0"* ]]; then
  if [[ -n "${FAKE_PVESR_SYNC_AFTER_N:-}" ]]; then
    # In the delayed-advance mode, schedule-now is a no-op — the fixture
    # advances LastSync based on the poll count in the status branch.
    exit 0
  fi
  if [[ "${FAKE_PVESR_STUCK:-0}" != "1" ]]; then
    touch "${REMOTE_ROOT}/.state/pvesr_synced"
  fi
  exit 0
fi

if [[ "$cmd" == *"test -f /etc/gitlab-runner/config.toml"* &&
      "$cmd" == *"grep -q token"* ]]; then
  exit 1
fi

if [[ "$cmd" == *" register "* &&
      "$cmd" == *"--non-interactive"* &&
      "$cmd" == *"--executor shell"* ]]; then
  printf '%s\n' 'Verifying runner... is valid'
  exit 0
fi

case "$cmd" in
  "true") exit 0 ;;
  "test -f /etc/gitlab-runner/config.toml") exit 0 ;;
  "nix --version && tofu version && sops --version") printf '%s\n' 'tools present'; exit 0 ;;
  *"grep -q 'tls-ca-file'"*) exit 1 ;;
  *"grep -q 'builds_dir'"*) exit 1 ;;
  *"grep -q 'NIX_CONFIG'"*) exit 1 ;;
  *"head -1 /etc/gitlab-runner/config.toml"*) printf '%s\n' '8'; exit 0 ;;
  *"systemctl is-active gitlab-runner"*) printf '%s\n' 'active'; exit 0 ;;
  *"journalctl -u gitlab-runner"*) exit 0 ;;
  *"test -d /nix/persist/gitlab-runner"*) exit 0 ;;
  *"systemctl restart gitlab-runner-ssh-setup"*) exit 0 ;;
  *"systemctl restart gitlab-runner"*) exit 0 ;;
esac

if [[ "$cmd" == *"mkdir -p '/var/lib/mycofu-secrets'"* ]]; then
  mkdir -p "$(remote_file /var/lib/mycofu-secrets)"
  exit 0
fi

if [[ "$cmd" == *"SOPS_AGE_KEY_FILE='/var/lib/mycofu-secrets/age-key'"* &&
      "$cmd" == *"sops -d --extract '[\"ssh_privkey\"]'"* &&
      "$cmd" == *"'/var/lib/mycofu-secrets/ssh-privkey-secrets.yaml'"* &&
      "$cmd" == *"install -o root -g root -m 0400"* &&
      "$cmd" == *"'/var/lib/mycofu-secrets/framework-deploy-ssh-privkey'"* ]]; then
  age_file="$(remote_file /var/lib/mycofu-secrets/age-key)"
  ciphertext_file="$(remote_file /var/lib/mycofu-secrets/ssh-privkey-secrets.yaml)"
  dest_file="$(remote_file /var/lib/mycofu-secrets/framework-deploy-ssh-privkey)"
  if [[ ! -f "${REMOTE_ROOT}/.state/age_probe.ok" ]]; then
    echo "ssh shim: ssh_privkey decrypt attempted before age-key probe" >&2
    exit 40
  fi
  if [[ ! -s "$age_file" || ! -f "${age_file}.mode" || "$(cat "${age_file}.mode")" != "400 root" ]]; then
    echo "ssh shim: persistent age key is not installed before ssh_privkey decrypt" >&2
    exit 41
  fi
  if [[ ! -s "$ciphertext_file" ]]; then
    echo "ssh shim: missing ssh_privkey ciphertext" >&2
    exit 42
  fi
  rm -f "$ciphertext_file"
  if [[ "${FAKE_REMOTE_PRIVKEY_SOPS_FAIL:-0}" == "1" ]]; then
    exit 32
  fi
  mkdir -p "$(dirname "$dest_file")"
  printf '%s\n' 'SYNTHETIC-FRAMEWORK-DEPLOY-SSH-PRIVATE-KEY' > "$dest_file"
  printf '%s\n' '400 root' > "${dest_file}.mode"
  exit 0
fi

if [[ "$cmd" == *"install -o root -g root -m 0400"* ]]; then
  src="$(printf '%s\n' "$cmd" | sed -n "s/.*install -o root -g root -m 0400 '\([^']*\)' '\([^']*\)'.*/\1/p")"
  dest="$(printf '%s\n' "$cmd" | sed -n "s/.*install -o root -g root -m 0400 '\([^']*\)' '\([^']*\)'.*/\2/p")"
  if [[ -z "$src" || -z "$dest" ]]; then
    echo "ssh shim: could not parse install command: $cmd" >&2
    exit 1
  fi
  src_file="$(remote_file "$src")"
  dest_file="$(remote_file "$dest")"
  mkdir -p "$(dirname "$dest_file")"
  cp "$src_file" "$dest_file"
  printf '%s\n' '400 root' > "${dest_file}.mode"
  rm -f "$src_file"
  exit 0
fi

if [[ "$cmd" == *"stat -c '%a %U'"* ]]; then
  path="$(printf '%s\n' "$cmd" | sed -n "s/.*stat -c '%a %U' '\([^']*\)'.*/\1/p")"
  file="$(remote_file "$path")"
  [[ -s "$file" ]] || exit 1
  [[ -f "${file}.mode" ]] || exit 1
  [[ "$(cat "${file}.mode")" == "400 root" ]] || exit 1
  exit 0
fi

# SPRINT-049 MR-3 persistence probe: `stat -f -c %T <path>` returns the
# filesystem type at the file's mount point. On the real runner post-fix,
# /var/lib/mycofu-secrets is a bind (via gitlab-runner.nix fileSystems)
# to /nix/persist/mycofu-secrets (ext4). The shim emulates that success
# path unless FAKE_REMOTE_PERSIST_TYPE overrides the type for
# negative-case tests.
if [[ "$cmd" == *"stat -f -c %T"* ]]; then
  path="$(printf '%s\n' "$cmd" | sed -n "s/.*stat -f -c %T '\([^']*\)'.*/\1/p")"
  file="$(remote_file "$path")"
  [[ -e "$file" ]] || exit 1
  printf '%s\n' "${FAKE_REMOTE_PERSIST_TYPE:-ext2/ext3}"
  exit 0
fi

if [[ "$cmd" == *"sops -d '/var/lib/mycofu-secrets/sops-probe-secrets.yaml'"* ]]; then
  age_file="$(remote_file /var/lib/mycofu-secrets/age-key)"
  probe_file="$(remote_file /var/lib/mycofu-secrets/sops-probe-secrets.yaml)"
  if [[ ! -s "$age_file" || ! -f "${age_file}.mode" || "$(cat "${age_file}.mode")" != "400 root" ]]; then
    echo "ssh shim: persistent age key is not usable for decrypt probe" >&2
    rm -f "$probe_file"
    exit 30
  fi
  if [[ ! -s "$probe_file" ]]; then
    echo "ssh shim: missing probe ciphertext" >&2
    exit 1
  fi
  if [[ "${FAKE_REMOTE_SOPS_FAIL:-0}" == "1" ]]; then
    rm -f "$probe_file"
    exit 31
  fi
  rm -f "$probe_file"
  touch "${REMOTE_ROOT}/.state/age_probe.ok"
  exit 0
fi

if [[ "$cmd" == *"rm -f '/var/lib/mycofu-secrets/sops-probe-secrets.yaml'"* ]]; then
  rm -f "$(remote_file /var/lib/mycofu-secrets/sops-probe-secrets.yaml)"
  exit 0
fi

if [[ "$cmd" == *"rm -f '/var/lib/mycofu-secrets/ssh-privkey-secrets.yaml'"* ]]; then
  rm -f "$(remote_file /var/lib/mycofu-secrets/ssh-privkey-secrets.yaml)"
  exit 0
fi

exit 0
EOF
  chmod +x "${shims}/ssh"

  printf '%s\n' "$fixture"
}

run_register() {
  local fixture="$1"
  local fail_probe="${2:-0}"
  local fail_privkey="${3:-0}"
  local mode="${4:-register}"
  local pvesr_stuck="${5:-0}"
  local sync_timeout="${6:-1}"
  local sync_after_n="${7:-}"      # #812: for delayed-advance fixtures
  local poll_interval="${8:-}"     # #812: parameterized poll (default 5s in prod)
  local fail_count="${9:-}"        # #812 R1: FailCount>0 fault classification
  local repo="${fixture}/repo"
  local shims="${fixture}/shims"

  : > "${fixture}/ssh.log"
  : > "${fixture}/scp.log"
  : > "${fixture}/sops.log"
  : > "${fixture}/curl.log"
  # Reset the pvesr status counter between runs so back-to-back invocations
  # against the same fixture don't inherit the prior run's count.
  rm -f "${fixture}/remote/.state/pvesr_status_count" 2>/dev/null || true

  set +e
  RUN_OUTPUT="$(
    env \
      PATH="${shims}:${PATH}" \
      SOPS_AGE_KEY_FILE="${fixture}/synthetic.age.key" \
      REMOTE_ROOT="${fixture}/remote" \
      SSH_LOG="${fixture}/ssh.log" \
      SCP_LOG="${fixture}/scp.log" \
      SOPS_LOG="${fixture}/sops.log" \
      CURL_LOG="${fixture}/curl.log" \
      FAKE_REMOTE_SOPS_FAIL="$fail_probe" \
      FAKE_REMOTE_PRIVKEY_SOPS_FAIL="$fail_privkey" \
      FAKE_PVESR_STUCK="$pvesr_stuck" \
      FAKE_PVESR_SYNC_AFTER_N="$sync_after_n" \
      FAKE_PVESR_FAIL_COUNT="$fail_count" \
      SYNC_POLL_INTERVAL="$poll_interval" \
      bash -c 'cd "$1" && case "$2" in verify) framework/scripts/register-runner.sh --verify ;; deliver) framework/scripts/register-runner.sh --deliver-secrets --sync-timeout "$3" ;; *) framework/scripts/register-runner.sh ;; esac' bash "$repo" "$mode" "$sync_timeout" 2>&1
  )"
  RUN_STATUS=$?
  set -e
}

make_delivered_fixture() {
  local name="$1"
  local fixture

  fixture="$(make_fixture "$name")"
  run_register "$fixture" 0 0
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    echo "fixture setup failed for ${name}" >&2
    printf '%s\n' "$RUN_OUTPUT" >&2
  fi
  printf '%s\n' "$fixture"
}

SUCCESS_FIXTURE="$(make_fixture success)"
run_register "$SUCCESS_FIXTURE" 0

test_start "V2.2-success" "register-runner delivers age key and framework deploy ssh key"
AGE_REMOTE="$(remote_file "${SUCCESS_FIXTURE}/remote" /var/lib/mycofu-secrets/age-key)"
SSH_KEY_REMOTE="$(remote_file "${SUCCESS_FIXTURE}/remote" /var/lib/mycofu-secrets/framework-deploy-ssh-privkey)"
SSH_KEY_CIPHERTEXT_REMOTE="$(remote_file "${SUCCESS_FIXTURE}/remote" /var/lib/mycofu-secrets/ssh-privkey-secrets.yaml)"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq 'Runner registered' <<< "$RUN_OUTPUT" &&
   grep -Fq 'Delivered age-key to /var/lib/mycofu-secrets/age-key (probe OK)' <<< "$RUN_OUTPUT" &&
   grep -Fq 'Delivered framework deploy ssh-privkey to /var/lib/mycofu-secrets/framework-deploy-ssh-privkey' <<< "$RUN_OUTPUT" &&
   [[ "$(cat "$AGE_REMOTE")" == "SYNTHETIC-AGE-KEY-SENTINEL" ]] &&
   [[ "$(cat "${AGE_REMOTE}.mode")" == "400 root" ]] &&
   [[ "$(cat "$SSH_KEY_REMOTE")" == "SYNTHETIC-FRAMEWORK-DEPLOY-SSH-PRIVATE-KEY" ]] &&
   [[ "$(cat "${SSH_KEY_REMOTE}.mode")" == "400 root" ]] &&
   [[ ! -e "$SSH_KEY_CIPHERTEXT_REMOTE" ]]; then
  test_pass "delivery writes both persistent files with mode 0400 and existing registration completes"
else
  test_fail "successful delivery path failed"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "V2.2-register-mode-sync" "full register mode waits for cicd pvesr sync after secret delivery"
SETUP_RESTART_LINE="$(first_line_number "systemctl restart gitlab-runner-ssh-setup" "${SUCCESS_FIXTURE}/ssh.log")"
PVESR_SCHEDULE_LINE="$(first_line_number "pvesr schedule-now 160-0" "${SUCCESS_FIXTURE}/ssh.log")"
RUNNER_RESTART_LINE="$(grep -Fnx 'ssh|systemctl restart gitlab-runner' "${SUCCESS_FIXTURE}/ssh.log" | head -1 | cut -d: -f1 || true)"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq 'cicd replication jobs carrying /nix/persist' <<< "$RUN_OUTPUT" &&
   grep -Fq 'cicd secret delivery replication sync complete' <<< "$RUN_OUTPUT" &&
   full_register_sync_gate_observed "${SUCCESS_FIXTURE}/ssh.log" &&
   [[ -n "$SETUP_RESTART_LINE" && -n "$PVESR_SCHEDULE_LINE" && -n "$RUNNER_RESTART_LINE" ]] &&
   [[ "$SETUP_RESTART_LINE" -lt "$PVESR_SCHEDULE_LINE" ]] &&
   [[ "$PVESR_SCHEDULE_LINE" -lt "$RUNNER_RESTART_LINE" ]]; then
  test_pass "full register mode gates service start on pvesr schedule-now plus LastSync advancement"
else
  test_fail "full register mode did not prove runner-secret replication sync before service start"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${SUCCESS_FIXTURE}/ssh.log" >&2
fi

MISSING_SYNC_LOG="${TMP_DIR}/register-mode-without-sync.log"
printf '%s\n' 'ssh|systemctl restart gitlab-runner-ssh-setup' 'ssh|systemctl restart gitlab-runner' > "$MISSING_SYNC_LOG"
test_start "V2.2-register-mode-sync-meta" "sync assertion fails against a full-register trace without pvesr"
if ! full_register_sync_gate_observed "$MISSING_SYNC_LOG"; then
  test_pass "fixture assertion rejects a register trace with no pvesr schedule-now or LastSync poll"
else
  test_fail "sync assertion would not catch the pre-fix full-register omission"
  cat "$MISSING_SYNC_LOG" >&2
fi

test_start "V2.2-recording" "delivery decrypts ssh_privkey only on cicd after age-key delivery and probe"
AGE_INSTALL_LINE="$(first_line_number "install -o root -g root -m 0400 '/var/lib/mycofu-secrets/age-key.tmp' '/var/lib/mycofu-secrets/age-key'" "${SUCCESS_FIXTURE}/ssh.log")"
PROBE_LINE="$(first_line_number "SOPS_AGE_KEY_FILE='/var/lib/mycofu-secrets/age-key' sops -d '/var/lib/mycofu-secrets/sops-probe-secrets.yaml' >/dev/null" "${SUCCESS_FIXTURE}/ssh.log")"
PRIVKEY_DECRYPT_LINE="$(first_line_number "sops -d --extract '[\"ssh_privkey\"]'" "${SUCCESS_FIXTURE}/ssh.log")"
if grep -Fq "scp|${SUCCESS_FIXTURE}/synthetic.age.key|root@10.0.0.61:/var/lib/mycofu-secrets/age-key.tmp" "${SUCCESS_FIXTURE}/scp.log" &&
   grep -Fq "scp|${SUCCESS_FIXTURE}/repo/site/sops/secrets.yaml|root@10.0.0.61:/var/lib/mycofu-secrets/sops-probe-secrets.yaml" "${SUCCESS_FIXTURE}/scp.log" &&
   grep -Fq "scp|${SUCCESS_FIXTURE}/repo/site/sops/secrets.yaml|root@10.0.0.61:/var/lib/mycofu-secrets/ssh-privkey-secrets.yaml" "${SUCCESS_FIXTURE}/scp.log" &&
   grep -Fq "SOPS_AGE_KEY_FILE='/var/lib/mycofu-secrets/age-key' sops -d --extract '[\"ssh_privkey\"]' '/var/lib/mycofu-secrets/ssh-privkey-secrets.yaml'" "${SUCCESS_FIXTURE}/ssh.log" &&
   grep -Fq "install -o root -g root -m 0400 \"\$tmp\" '/var/lib/mycofu-secrets/framework-deploy-ssh-privkey'" "${SUCCESS_FIXTURE}/ssh.log" &&
   ! grep -Fq '["ssh_privkey"]' "${SUCCESS_FIXTURE}/sops.log" &&
   [[ -n "$AGE_INSTALL_LINE" && -n "$PROBE_LINE" && -n "$PRIVKEY_DECRYPT_LINE" ]] &&
   [[ "$AGE_INSTALL_LINE" -lt "$PROBE_LINE" ]] &&
   [[ "$PROBE_LINE" -lt "$PRIVKEY_DECRYPT_LINE" ]]; then
  test_pass "logs prove ciphertext transit, remote decrypt, local negative assertion, and ordering"
else
  test_fail "delivery logs do not prove the required copy/probe shape"
  cat "${SUCCESS_FIXTURE}/sops.log" >&2
  cat "${SUCCESS_FIXTURE}/scp.log" >&2
  cat "${SUCCESS_FIXTURE}/ssh.log" >&2
fi

test_start "V2.2-idempotent" "second delivery run is no-op safe"
run_register "$SUCCESS_FIXTURE" 0
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ "$(cat "$AGE_REMOTE")" == "SYNTHETIC-AGE-KEY-SENTINEL" ]] &&
   [[ "$(cat "${AGE_REMOTE}.mode")" == "400 root" ]] &&
   [[ "$(cat "$SSH_KEY_REMOTE")" == "SYNTHETIC-FRAMEWORK-DEPLOY-SSH-PRIVATE-KEY" ]] &&
   [[ "$(cat "${SSH_KEY_REMOTE}.mode")" == "400 root" ]]; then
  test_pass "second run leaves the same content and mode without error"
else
  test_fail "second delivery run was not idempotent"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

SYNC_FIXTURE="$(make_fixture replication-sync)"
run_register "$SYNC_FIXTURE" 0 0 deliver 0 0

test_start "V2.2-deliver-secrets-sync" "--deliver-secrets completes only after cicd pvesr sync advances"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq 'cicd replication jobs carrying /nix/persist' <<< "$RUN_OUTPUT" &&
   grep -Fq 'cicd secret delivery replication sync complete' <<< "$RUN_OUTPUT" &&
   grep -Fq '=== Delivery Complete ===' <<< "$RUN_OUTPUT" &&
   grep -Fq 'pvesr schedule-now 160-0' "${SYNC_FIXTURE}/ssh.log" &&
   grep -Fq 'pvesr status' "${SYNC_FIXTURE}/ssh.log" &&
   [[ ! -s "${SYNC_FIXTURE}/curl.log" ]] &&
   ! grep -Fq 'systemctl restart gitlab-runner"' "${SYNC_FIXTURE}/ssh.log"; then
  test_pass "deliver-only path gates completion on pvesr schedule-now plus LastSync advancement"
else
  test_fail "deliver-only path did not prove replication sync before completion"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${SYNC_FIXTURE}/ssh.log" >&2
fi

SYNC_TIMEOUT_FIXTURE="$(make_fixture replication-timeout)"
run_register "$SYNC_TIMEOUT_FIXTURE" 0 0 deliver 1 0

test_start "V2.2-deliver-secrets-sync-timeout" "--deliver-secrets fails loudly when cicd pvesr sync does not advance"
# Post-#812: error message is multi-line and includes measured elapsed +
# per-job status. Assert the shape (three key spans) instead of the
# pre-#812 one-liner.
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'cicd secret delivery replication did not sync within timeout' <<< "$RUN_OUTPUT" &&
   grep -Fq 'timeout=0s' <<< "$RUN_OUTPUT" &&
   grep -Fq 'last observed per-job status' <<< "$RUN_OUTPUT" &&
   grep -Fq 'pvesr schedule-now 160-0' "${SYNC_TIMEOUT_FIXTURE}/ssh.log" &&
   ! grep -Fq '=== Delivery Complete ===' <<< "$RUN_OUTPUT"; then
  test_pass "deliver-only path reports classified timeout and withholds Delivery Complete"
else
  test_fail "deliver-only sync timeout did not fail closed with the richer #812 message"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${SYNC_TIMEOUT_FIXTURE}/ssh.log" >&2
fi

# ---------------------------------------------------------------------
# #812 fixtures — raised default timeout catches the healthy-but-slow
# replica case that aborted DRT-009 G3 attempt 8 at exactly 300s.
#
# Setup: FAKE_PVESR_SYNC_AFTER_N=3 makes pvesr status return unsynced
# for the first two polls, synced on the third. With
# SYNC_POLL_INTERVAL=1 the third poll lands ~2s after start. Two runs
# against the same fixture shape:
#   1. --sync-timeout 1  → gate expires before third poll → FAIL (this
#      is the pre-#812 300s-vs-413s pattern in miniature — a healthy
#      replica that measurably exceeds the budget)
#   2. --sync-timeout 10 → gate waits, sees the sync at ~2s → PASS
#      (proves the raised timeout catches the actual failure mode)
#
# R-G-4 end-to-end: both runs traverse the full wait loop. The second
# doesn't just skip the loop; it actively iterates until the shim
# reports sync, which is what the operator needs the raised default to
# do against real 413s cicd jobs.
# ---------------------------------------------------------------------
SLOW_SYNC_FIXTURE="$(make_fixture replication-slow-sync)"
# Reviewer answer: this fixture would FAIL against the pre-#812 code
# (300s default, no --sync-timeout override on the second call would
# have shortened it — but this fixture uses explicit --sync-timeout 1
# for the old-timeout case and --sync-timeout 10 for the new one, so
# the assertion isolates the timeout-vs-poll-behavior interaction
# rather than the default-value bump alone). The default-value bump
# from 300 to 1200 is asserted by a separate static check below.
#
# FAKE_PVESR_SYNC_AFTER_N=5 with SYNC_POLL_INTERVAL=1: the shim's
# `pvesr status` returns advancing-but-old LastSync for polls 1..4
# and synced-past-delivery LastSync at poll 5+. The wait loop uses
# one status call before entering the loop (to enumerate jobs), then
# one status call per iteration. So:
#   iter 1 (poll 2): unsynced, elapsed=0, sleep 1
#   iter 2 (poll 3): unsynced, elapsed=1
#   iter 3 (poll 4): unsynced, elapsed=2
#   iter 4 (poll 5): SYNCED → exit at elapsed ~=3s
# --sync-timeout=1 → aborts at iter 2 (elapsed 1 >= 1) BEFORE poll 5.
# --sync-timeout=10 → waits through and passes at ~3s.
run_register "$SLOW_SYNC_FIXTURE" 0 0 deliver 0 1 5 1

test_start "#812-old-timeout-loses-race" "with an old-shape timeout (1s), a healthy replica whose LastSync doesn't advance in the window FAILS the gate"
# Realistic pvesr semantics (R1 codex/agy correction): LastSync updates
# atomically on job completion, not incrementally during a run. So during
# a 413s job the pre-loop and per-poll `pvesr status` fetches return the
# SAME LastSync value. The corrected classifier detects "did not advance
# since the wait started" by comparing current LastSync to the initial
# snapshot; a constant value across polls maps to that classification.
# This is the actual G3-attempt-8 pattern.
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'cicd secret delivery replication did not sync within timeout' <<< "$RUN_OUTPUT" &&
   grep -Fq 'timeout=1s' <<< "$RUN_OUTPUT" &&
   grep -Fq 'did not advance since the wait started' <<< "$RUN_OUTPUT" &&
   grep -Fq 'poll_interval=1s' <<< "$RUN_OUTPUT" &&
   grep -Fq 'initial_LastSync=2020-01-01_00:00:00' <<< "$RUN_OUTPUT" &&
   ! grep -Fq '=== Delivery Complete ===' <<< "$RUN_OUTPUT"; then
  test_pass "old-timeout race is detected AND classified as 'did not advance since the wait started' with initial_LastSync surfaced"
else
  test_fail "#812 old-timeout race did not fail with the classified diagnostic"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

# Re-run the SAME shim shape with the new-shape timeout (10s > ~3s
# advancement latency). Same fixture — different --sync-timeout only.
run_register "$SLOW_SYNC_FIXTURE" 0 0 deliver 0 10 5 1

test_start "#812-new-timeout-waits-through" "with new-shape timeout (10s), the same replica pattern PASSES the gate"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq 'cicd secret delivery replication sync complete' <<< "$RUN_OUTPUT" &&
   grep -Fq '=== Delivery Complete ===' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'did not sync within timeout' <<< "$RUN_OUTPUT"; then
  test_pass "raised timeout waits through the slow-sync window and reports Delivery Complete"
else
  test_fail "#812 raised-timeout wait did not pass through the slow-sync fixture"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

# FailCount>0 classification (agy P2-1 + codex R1 correction). A job with
# non-zero FailCount is a fault at the replication layer regardless of
# LastSync — must override the "advancing" branch. This fixture holds
# LastSync at the initial value AND reports FailCount=3. Pre-R1 the
# classifier used "has any real LastSync value" as the advancement
# proxy, so it treated `LastSync=2020-01-01 FailCount=3` as "jobs are
# advancing but slower than --sync-timeout" (mismatching the actual
# fault signal — verified by codex R2 pre-R1 overlay). The fix upgrades
# the diagnosis to name the FailCount>0 replication fault so the
# operator knows to check pvesr/journalctl, not just raise the timeout.
FAIL_COUNT_FIXTURE="$(make_fixture replication-failcount)"
run_register "$FAIL_COUNT_FIXTURE" 0 0 deliver 0 1 999 1 3

test_start "#812-failcount-classified" "FailCount>0 is classified as a replication fault, not as a slow replica"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'FailCount>0' <<< "$RUN_OUTPUT" &&
   grep -Fq 'replication fault' <<< "$RUN_OUTPUT" &&
   grep -Fq 'FailCount=3' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'advancing but slower' <<< "$RUN_OUTPUT" &&
   ! grep -Fq '=== Delivery Complete ===' <<< "$RUN_OUTPUT"; then
  test_pass "FailCount>0 classifier fires with fault language, not slow-replica language"
else
  test_fail "#812 FailCount classification missing or misfired"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

test_start "#812-default-timeout-value" "DELIVER_SECRETS_SYNC_TIMEOUT default is raised from 300s to 1200s"
# Static check on the source. Prior default (300s) aborted DRT-009 G3
# attempt 8 exactly at the 300s mark against jobs measured at 413s
# (issue #812 body). The header-comment above the assignment documents
# the derivation from measured reality. Mechanical assertion: the
# initial-value line has the new number. This is intentional narrow-
# targeting (Principle 11 count (c)) — the line-neighborhood grep tests
# a fact about the source, not a moving target.
if grep -Fq 'DELIVER_SECRETS_SYNC_TIMEOUT=1200' "${REPO_ROOT}/framework/scripts/register-runner.sh" &&
   ! grep -Fq 'DELIVER_SECRETS_SYNC_TIMEOUT=300' "${REPO_ROOT}/framework/scripts/register-runner.sh"; then
  test_pass "default is 1200s; the pre-#812 300s value is gone"
else
  test_fail "default timeout not raised to 1200s (or old 300s value still present)"
fi

FAIL_FIXTURE="$(make_fixture probe-failure)"
run_register "$FAIL_FIXTURE" 1

test_start "V2.2-probe-fail" "decrypt probe failure fails closed before success is reported"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Delivered age-key failed SOPS decrypt probe on cicd' <<< "$RUN_OUTPUT" &&
   ! grep -Fq '=== Registration Complete ===' <<< "$RUN_OUTPUT"; then
  test_pass "probe failure exits non-zero and never reports registration complete"
else
  test_fail "probe failure did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

PRIVKEY_FAIL_FIXTURE="$(make_fixture privkey-decrypt-failure)"
run_register "$PRIVKEY_FAIL_FIXTURE" 0 1

test_start "V2.2-privkey-decrypt-fail" "remote ssh_privkey decrypt failure fails closed before success is reported"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'framework deploy ssh-privkey remote decrypt/install failed' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'Runner secret delivery complete' <<< "$RUN_OUTPUT" &&
   ! grep -Fq '=== Registration Complete ===' <<< "$RUN_OUTPUT"; then
  test_pass "remote ssh_privkey decrypt failure exits non-zero and never reports registration complete"
else
  test_fail "remote ssh_privkey decrypt failure did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

# SPRINT-049 MR-3 persistence probe ratchet: if the delivered file lands on
# an ephemeral overlay tmpfs (the exact defect the gitlab-runner.nix
# fileSystems bind fixes), the persistence probe MUST fail closed before
# the ssh-setup service is restarted with the doomed state.
PERSIST_FAIL_FIXTURE="$(make_fixture persist-fail)"
set +e
PERSIST_OUTPUT="$(
  env \
    PATH="${PERSIST_FAIL_FIXTURE}/shims:${PATH}" \
    SOPS_AGE_KEY_FILE="${PERSIST_FAIL_FIXTURE}/synthetic.age.key" \
    REMOTE_ROOT="${PERSIST_FAIL_FIXTURE}/remote" \
    SSH_LOG="${PERSIST_FAIL_FIXTURE}/ssh.log" \
    SCP_LOG="${PERSIST_FAIL_FIXTURE}/scp.log" \
    SOPS_LOG="${PERSIST_FAIL_FIXTURE}/sops.log" \
    CURL_LOG="${PERSIST_FAIL_FIXTURE}/curl.log" \
    FAKE_REMOTE_SOPS_FAIL=0 \
    FAKE_REMOTE_PRIVKEY_SOPS_FAIL=0 \
    FAKE_REMOTE_PERSIST_TYPE=tmpfs \
    bash -c 'cd "$1" && framework/scripts/register-runner.sh' bash "${PERSIST_FAIL_FIXTURE}/repo" 2>&1
)"
PERSIST_STATUS=$?
set -e

test_start "V2.2-persist-fail" "delivery on ephemeral overlay tmpfs fails closed before ssh-setup restart"
if [[ "$PERSIST_STATUS" -ne 0 ]] &&
   grep -Fq "landed on ephemeral filesystem 'tmpfs'" <<< "$PERSIST_OUTPUT" &&
   ! grep -Fq 'Runner secret delivery complete' <<< "$PERSIST_OUTPUT" &&
   ! grep -Fq '=== Registration Complete ===' <<< "$PERSIST_OUTPUT" &&
   ! grep -Fq 'systemctl restart gitlab-runner-ssh-setup' "${PERSIST_FAIL_FIXTURE}/ssh.log"; then
  test_pass "persistence probe rejects overlay landing before service restart"
else
  test_fail "persistence probe did not fail closed on overlay landing"
  printf '%s\n' "$PERSIST_OUTPUT" >&2
fi

VERIFY_OK_FIXTURE="$(make_delivered_fixture verify-success)"
run_register "$VERIFY_OK_FIXTURE" 0 0 verify

test_start "V2.2-verify-success" "--verify validates persistent runner secrets and decrypt probe"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq 'Persistent age-key:   PASS' <<< "$RUN_OUTPUT" &&
   grep -Fq 'Persistent SSH key:   PASS' <<< "$RUN_OUTPUT" &&
   grep -Fq 'Age-key decrypt probe: PASS' <<< "$RUN_OUTPUT"; then
  test_pass "--verify passes when both persistent files are 0400 root and decrypt probe succeeds"
else
  test_fail "--verify did not pass with valid persistent runner secrets"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

VERIFY_MISSING_AGE_FIXTURE="$(make_delivered_fixture verify-missing-age)"
rm -f "$(remote_file "${VERIFY_MISSING_AGE_FIXTURE}/remote" /var/lib/mycofu-secrets/age-key)"
run_register "$VERIFY_MISSING_AGE_FIXTURE" 0 0 verify

test_start "V2.2-verify-missing-age" "--verify fails when persistent age-key file is missing"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Persistent age-key:   FAIL' <<< "$RUN_OUTPUT"; then
  test_pass "--verify fails closed on a missing persistent age-key"
else
  test_fail "--verify passed or missed a missing persistent age-key"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

VERIFY_AGE_MODE_FIXTURE="$(make_delivered_fixture verify-age-mode)"
printf '%s\n' '600 root' > "$(remote_file "${VERIFY_AGE_MODE_FIXTURE}/remote" /var/lib/mycofu-secrets/age-key).mode"
run_register "$VERIFY_AGE_MODE_FIXTURE" 0 0 verify

test_start "V2.2-verify-age-mode" "--verify fails when persistent age-key mode is wrong"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Persistent age-key:   FAIL' <<< "$RUN_OUTPUT"; then
  test_pass "--verify fails closed on wrong persistent age-key mode"
else
  test_fail "--verify passed or missed wrong persistent age-key mode"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

VERIFY_SSH_MODE_FIXTURE="$(make_delivered_fixture verify-ssh-mode)"
printf '%s\n' '600 root' > "$(remote_file "${VERIFY_SSH_MODE_FIXTURE}/remote" /var/lib/mycofu-secrets/framework-deploy-ssh-privkey).mode"
run_register "$VERIFY_SSH_MODE_FIXTURE" 0 0 verify

test_start "V2.2-verify-ssh-mode" "--verify fails when persistent ssh-privkey mode is wrong"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Persistent SSH key:   FAIL' <<< "$RUN_OUTPUT"; then
  test_pass "--verify fails closed on wrong persistent ssh-privkey mode"
else
  test_fail "--verify passed or missed wrong persistent ssh-privkey mode"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

VERIFY_PROBE_FAIL_FIXTURE="$(make_delivered_fixture verify-probe-failure)"
run_register "$VERIFY_PROBE_FAIL_FIXTURE" 1 0 verify

test_start "V2.2-verify-probe-fail" "--verify fails when persistent age-key cannot decrypt ciphertext"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Age-key decrypt probe: FAIL' <<< "$RUN_OUTPUT"; then
  test_pass "--verify fails closed on decrypt probe failure"
else
  test_fail "--verify passed or missed decrypt probe failure"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

VERIFY_MISSING_SSH_FIXTURE="$(make_delivered_fixture verify-missing-ssh)"
rm -f "$(remote_file "${VERIFY_MISSING_SSH_FIXTURE}/remote" /var/lib/mycofu-secrets/framework-deploy-ssh-privkey)"
run_register "$VERIFY_MISSING_SSH_FIXTURE" 0 0 verify

test_start "V2.2-verify-missing-ssh" "--verify fails when persistent ssh-privkey file is missing"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Persistent SSH key:   FAIL' <<< "$RUN_OUTPUT"; then
  test_pass "--verify fails closed on a missing persistent ssh-privkey"
else
  test_fail "--verify passed or missed a missing persistent ssh-privkey"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

runner_summary
