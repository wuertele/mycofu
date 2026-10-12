#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "$SHIM_DIR" "${TMP_DIR}/site"

CONFIG="${TMP_DIR}/site/config.yaml"
KEY_FILE="${TMP_DIR}/operator.age.key"
SECRETS="${TMP_DIR}/site/sops/secrets.yaml"

cat > "$CONFIG" <<'EOF'
domain: example.test
operator_ssh_pubkey: ssh-ed25519 AAAATEST operator@example.test
regreener:
  install_timeout_sec: 1800
  ssh_timeout_sec: 600
proxmox:
  installer:
    iso: proxmox-ve_9.1-1.iso
    iso_sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    expected_version: "pve-manager/9.1"
    filesystem: ext4
nodes:
  - name: node1
    mgmt_ip: 192.0.2.11
    regreen_enabled: false
  - name: node2
    mgmt_ip: 192.0.2.12
    regreen_enabled: true
    amt_ip: 192.0.2.12
    amt_user: admin
    amt_password_ref: amt_password_test
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
EOF

cat > "${SHIM_DIR}/age" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${SHIM_DIR}/age"

cat > "${SHIM_DIR}/age-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
cat > "$out" <<'KEY'
# created: 2026-05-03T00:00:00Z
# public key: age1testrecipient000000000000000000000000000000000000000
AGE-SECRET-KEY-TEST
KEY
printf 'public key: age1testrecipient000000000000000000000000000000000000000\n'
EOF
chmod +x "${SHIM_DIR}/age-keygen"

cat > "${SHIM_DIR}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "rand" && "${2:-}" == "-hex" ]]; then
  printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
  exit 0
fi
exit 2
EOF
chmod +x "${SHIM_DIR}/openssl"

cat > "${SHIM_DIR}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 2
printf 'PRIVATE-KEY\n' > "$out"
printf 'ssh-ed25519 PUBLIC-KEY ci-runner\n' > "${out}.pub"
EOF
chmod +x "${SHIM_DIR}/ssh-keygen"

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"--input-type yaml --output-type yaml -e /dev/stdin"*)
    cat
    ;;
  -d\ *)
    cat "${@: -1}" >/dev/null
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/sops"

test_start "s034.r3.1" "bootstrap-sops accepts --force before config with regreener fields present"
set +e
BOOTSTRAP_OUTPUT="$(
  PATH="${SHIM_DIR}:${PATH}" \
  MYCOFU_BOOTSTRAP_SOPS_KEY_FILE="$KEY_FILE" \
  "${REPO_ROOT}/framework/scripts/bootstrap-sops.sh" --force "$CONFIG" \
    <<< $'root-pass\ntofu-pass\n' 2>&1
)"
BOOTSTRAP_RC=$?
set -e
if [[ "$BOOTSTRAP_RC" -eq 0 ]] && [[ -f "$SECRETS" ]] && [[ -f "$KEY_FILE" ]]; then
  test_pass "bootstrap-sops wrote temp SOPS file and age key"
else
  test_fail "bootstrap-sops failed (rc=${BOOTSTRAP_RC})"
  printf '%s\n' "$BOOTSTRAP_OUTPUT" >&2
fi

test_start "s034.r3.2" "bootstrap-sops produces existing secret contract"
missing=0
for key in \
  proxmox_api_user \
  proxmox_api_password \
  pdns_api_key \
  tofu_db_password \
  ssh_pubkey \
  ssh_privkey \
  operator_ssh_pubkey \
  vault_unseal_keys; do
  if ! grep -q "^${key}:" "$SECRETS"; then
    test_fail "missing generated key ${key}"
    missing=1
  fi
done
if [[ "$missing" -eq 0 ]]; then
  test_pass "all existing bootstrap keys are present"
fi

test_start "s034.r3.3" "bootstrap-sops does not require or generate AMT secrets"
if ! grep -q 'amt_password' "$SECRETS" && \
   ! grep -qi 'amt' <<< "$BOOTSTRAP_OUTPUT"; then
  test_pass "AMT credentials remain operator-seeded SOPS values"
else
  test_fail "bootstrap-sops unexpectedly handled AMT credentials"
fi

runner_summary
