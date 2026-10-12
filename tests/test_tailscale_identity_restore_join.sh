#!/usr/bin/env bash
#
# Regression fixture for #1002/#407. It renders the module's real restore/join
# shell bodies and drives them through the recreated-VM decision, proving:
#   - a late Vault token restores the stored identity without consuming the
#     fallback key (A);
#   - a clean HTTP 404 (genuine first deploy) still enrolls via the auth key
#     (B, C);
#   - a fetched-but-uninstallable identity never falls through to enrollment
#     (E); an unsettled Starting state fails closed rather than bypassing the
#     NeedsLogin gate (D); a settled Running node stays connected without
#     re-enrolling (H);
#   - the #1002 incident and every ambiguity FAIL CLOSED: NeedsLogin with no
#     Vault token (F), or a transient/indeterminate Vault result — 5xx,
#     connection failure, 403, malformed 200, recoverable soft-deleted 404, or
#     a routing/unmounted-error 404 (G) — must never fresh-enroll; and a
#     fetched-but-uninstallable payload (I) fails closed rather than orphaning
#     a recoverable record. Enrollment is reached ONLY on a clean {"errors":[]}
#     404. All fail-closed paths exit non-zero so systemd (Restart=on-failure)
#     retries until Vault answers, instead of enrolling on a timing coincidence
#     with an expired key. restore.sh's in-process fetch+install path is
#     covered directly (J).
# A code-shape assertion would not catch a branch that exists but is ordered,
# rendered, or invoked incorrectly.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

MODULE="${TAILSCALE_MODULE_UNDER_TEST:-${REPO_ROOT}/framework/nix/modules/tailscale.nix}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BIN_DIR="${TMP_DIR}/bin"
RENDER_DIR="${TMP_DIR}/rendered"
mkdir -p "${BIN_DIR}" "${RENDER_DIR}"

# Render the module-owned shell bodies instead of copying their decisions into
# the fixture. Protect Nix's escaped shell interpolation before replacing the
# actual Nix interpolations with fixture paths and PATH-resolved tools.
python3 - "${MODULE}" "${RENDER_DIR}" <<'PY'
import os
import re
import sys

module_path, output_dir = sys.argv[1:]
with open(module_path, encoding="utf-8") as handle:
    source = handle.read()


def extract(pattern, label):
    match = re.search(pattern, source, re.MULTILINE | re.DOTALL)
    if not match or not match.group(1).strip():
        raise SystemExit("ERROR: empty or missing {} body in {}".format(label, module_path))
    return match.group(1)


identity_common = extract(
    r"^  identityCommon = ''\n(.*?)^  '';\n",
    "identityCommon",
)


def script_body(binding, script_name):
    return extract(
        r'^  {} = pkgs\.writeShellScript "{}" \'\'\n(.*?)^  \'\';\n'.format(
            re.escape(binding), re.escape(script_name)
        ),
        binding,
    )


sentinel = "@@NIX_ESCAPED_SHELL_INTERPOLATION@@"
path_bindings = {
    "authKeyPath": "$FIX_AUTH_KEY",
    "identityFile": "$FIX_IDENTITY_FILE",
    "stateDir": "$FIX_STATE_DIR",
    "vaultTokenPath": "$FIX_TOKEN_FILE",
    "roleOverrideFile": "$FIX_ROLE_FILE",
}


def render(binding, script_name, filename):
    common = identity_common.replace("''${", sentinel)
    body = script_body(binding, script_name).replace("''${", sentinel)
    body = body.replace("${identityCommon}", common)
    body = re.sub(r"\$\{pkgs\.[^}]+\}/bin/([A-Za-z0-9._+-]+)", r"\1", body)
    body = re.sub(
        r"\$\{config\.systemd\.package\}/bin/([A-Za-z0-9._+-]+)",
        r"\1",
        body,
    )
    body = body.replace("${tailscaleCli}", "tailscale")
    for nix_name, fixture_path in path_bindings.items():
        body = body.replace("${" + nix_name + "}", fixture_path)

    # Escaped shell variables are still hidden, so any interpolation left at
    # this point is an unhandled Nix form and must make extraction drift loud.
    if "${" in body:
        leftovers = sorted(set(re.findall(r"\$\{[^}\n]+\}", body)))
        raise SystemExit(
            "ERROR: unrendered Nix interpolation(s) in {}: {}".format(
                binding, ", ".join(leftovers) or "unknown ${ form"
            )
        )

    body = body.replace(sentinel, "${")
    output_path = os.path.join(output_dir, filename)
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write("#!/usr/bin/env bash\n")
        handle.write(body)
    os.chmod(output_path, 0o755)


render("restoreIdentity", "tailscale-identity-restore", "restore.sh")
render("joinTailnet", "tailscale-join", "join.sh")
PY

RESTORE_SCRIPT="${RENDER_DIR}/restore.sh"
JOIN_SCRIPT="${RENDER_DIR}/join.sh"
# One invocation each: `bash -n a b` parses only `a` and passes `b` as $1, so
# a single call would silently never syntax-check the join body.
bash -n "${RESTORE_SCRIPT}"
bash -n "${JOIN_SCRIPT}"

cat > "${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'curl'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FIX_CURL_LOG}"

if [[ " $* " == *" -X POST "* ]]; then
  exit 0
fi

# Emulate the identity-lookup GET: curl -sk -o <file> -w '%{http_code}' ...
# — body to the -o target, HTTP status code to stdout. The mode selects the
# status so the fetch can distinguish 404 (definitive absence) from a
# transient error (503 / connection failure).
OUT_FILE=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then OUT_FILE="$arg"; fi
  prev="$arg"
done

emit_body() {  # <body>
  if [[ -n "$OUT_FILE" ]]; then printf '%s' "$1" > "$OUT_FILE"; else printf '%s' "$1"; fi
}

case "${FIX_VAULT_MODE}" in
  identity)
    body="$(python3 - "${FIX_VAULT_PAYLOAD}" <<'PY'
import json
import sys
print(json.dumps({"data": {"data": {"format": "tar-b64", "value": sys.argv[1]}}}))
PY
)"
    emit_body "$body"
    printf '200'
    ;;
  absent)
    # Genuine never-written KV v2 secret: valid JSON, no .data -> absence (10).
    emit_body '{"errors":[]}'
    printf '404'
    ;;
  softdeleted404)
    # Soft-deleted/destroyed version: the 404 carries recoverable version
    # metadata, so it must NOT be treated as absence (fail closed).
    emit_body '{"data":{"metadata":{"deletion_time":"2026-01-01T00:00:00Z","destroyed":false,"version":3}}}'
    printf '404'
    ;;
  routererror404)
    # Unsupported route / unmounted KV engine: 404 with a NON-empty errors
    # array. Not proof the secret is absent -> must fail closed, not enroll.
    emit_body '{"errors":["no handler for route \"secret/data/tailscale/nodes/wuertele.com/gitlab\""]}'
    printf '404'
    ;;
  malformed200)
    # A 200 whose body is not parseable -> indeterminate (fail closed).
    emit_body 'not-json{{{'
    printf '200'
    ;;
  forbidden)
    emit_body '{"errors":["permission denied"]}'
    printf '403'
    ;;
  transient5xx)
    emit_body '{"errors":["Vault is sealed"]}'
    printf '503'
    ;;
  transient)
    # Connection failure: curl exits non-zero and reports http_code 000.
    printf '000'
    exit 7
    ;;
  *)
    echo "unexpected FIX_VAULT_MODE=${FIX_VAULT_MODE}" >&2
    exit 2
    ;;
esac
EOF

cat > "${BIN_DIR}/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'tailscale'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FIX_TAILSCALE_LOG}"

case "${1:-}" in
  status)
    backend_state="$(cat "${FIX_BACKEND_STATE}")"
    tailscale_ip="$(cat "${FIX_BACKEND_IP}")"
    if [[ -n "${tailscale_ip}" ]]; then
      printf '{"BackendState":"%s","Self":{"TailscaleIPs":["%s"]}}\n' "${backend_state}" "${tailscale_ip}"
    else
      printf '{"BackendState":"%s","Self":{"TailscaleIPs":[]}}\n' "${backend_state}"
    fi
    ;;
  up)
    # A non-NeedsLogin state already owns a profile. Keep that on-disk state
    # intact so case D pins the restore branch's no-wipe property rather than
    # prescribing the pre-existing fallback behavior of `tailscale up`.
    if [[ "$(cat "${FIX_BACKEND_STATE}")" == "NeedsLogin" ]]; then
      mkdir -p "${FIX_STATE_DIR}"
      printf 'fresh-enrollment-identity\n' > "${FIX_STATE_DIR}/tailscaled.state"
    fi
    printf 'fresh-enrollment-identity\n' > "${FIX_DAEMON_IDENTITY}"
    printf 'Running\n' > "${FIX_BACKEND_STATE}"
    printf '100.64.0.42\n' > "${FIX_BACKEND_IP}"
    ;;
  *)
    echo "unexpected tailscale command: $*" >&2
    exit 2
    ;;
esac
EOF

cat > "${BIN_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'systemctl'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FIX_SYSTEMCTL_LOG}"

stop_daemon() {
  if [[ -f "${FIX_DAEMON_RUNNING}" ]]; then
    mkdir -p "${FIX_STATE_DIR}"
    command cat "${FIX_DAEMON_IDENTITY}" > "${FIX_STATE_DIR}/tailscaled.state"
    rm -f "${FIX_DAEMON_RUNNING}"
  fi
  printf 'Stopped\n' > "${FIX_BACKEND_STATE}"
  : > "${FIX_BACKEND_IP}"
}

start_daemon() {
  : > "${FIX_DAEMON_RUNNING}"
  if [[ -f "${FIX_STATE_DIR}/tailscaled.state" ]]; then
    command cat "${FIX_STATE_DIR}/tailscaled.state" > "${FIX_DAEMON_IDENTITY}"
  else
    : > "${FIX_DAEMON_IDENTITY}"
  fi

  if cmp -s "${FIX_DAEMON_IDENTITY}" "${FIX_RESTORED_IDENTITY}"; then
    printf 'Running\n' > "${FIX_BACKEND_STATE}"
    printf '100.64.0.41\n' > "${FIX_BACKEND_IP}"
  else
    printf 'NeedsLogin\n' > "${FIX_BACKEND_STATE}"
    : > "${FIX_BACKEND_IP}"
  fi
}

case "$*" in
  "stop tailscaled.service") stop_daemon ;;
  "start tailscaled.service") start_daemon ;;
  "restart tailscaled.service")
    stop_daemon
    start_daemon
    ;;
  *)
    echo "unexpected systemctl command: $*" >&2
    exit 2
    ;;
esac
EOF

# Resolve the real cp BEFORE BIN_DIR is ever prepended to PATH, and pass it
# through the environment: NixOS (the CI runner) has no /bin/cp, so the shim
# must not hardcode a filesystem-hierarchy path.
FIX_REAL_CP="$(command -v cp)"
export FIX_REAL_CP
cat > "${BIN_DIR}/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FIX_CP_FAIL:-0}" -eq 1 ]]; then
  exit 1
fi
exec "${FIX_REAL_CP}" "$@"
EOF

cat > "${BIN_DIR}/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'sleep'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FIX_SLEEP_LOG}"
EOF

cat > "${BIN_DIR}/hostname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'hostname'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FIX_HOSTNAME_LOG}"
printf 'gitlab\n'
EOF

cat > "${BIN_DIR}/dnsdomainname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'dnsdomainname'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FIX_DNSDOMAINNAME_LOG}"
printf 'prod.wuertele.com\n'
EOF

cat > "${BIN_DIR}/base64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'base64'
  printf ' <%s>' "$@"
  printf '\n'
} >> "${FIX_BASE64_LOG}"
python3 -c '
import base64
import sys
data = sys.stdin.buffer.read()
decode = "-d" in sys.argv[1:] or "--decode" in sys.argv[1:]
try:
    result = base64.b64decode(data) if decode else base64.b64encode(data)
except Exception as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)
sys.stdout.buffer.write(result)
' "$@"
EOF

chmod +x "${BIN_DIR}/curl" "${BIN_DIR}/tailscale" \
  "${BIN_DIR}/systemctl" "${BIN_DIR}/sleep" "${BIN_DIR}/hostname" \
  "${BIN_DIR}/dnsdomainname" "${BIN_DIR}/base64" "${BIN_DIR}/cp"

AUTH_SENTINEL="tskey-auth-fixture-sentinel-1002"

new_case() {
  CASE_DIR="$(mktemp -d "${TMP_DIR}/case.XXXXXX")"
  export FIX_AUTH_KEY="${CASE_DIR}/auth-key"
  export FIX_IDENTITY_FILE="${CASE_DIR}/vault-agent/tailscale-identity"
  export FIX_STATE_DIR="${CASE_DIR}/tailscale-state"
  export FIX_TOKEN_FILE="${CASE_DIR}/vault-agent/token"
  export FIX_ROLE_FILE="${CASE_DIR}/role"
  export FIX_BACKEND_STATE="${CASE_DIR}/backend-state"
  export FIX_BACKEND_IP="${CASE_DIR}/backend-ip"
  export FIX_DAEMON_RUNNING="${CASE_DIR}/daemon-running"
  export FIX_DAEMON_IDENTITY="${CASE_DIR}/daemon-identity"
  export FIX_RESTORED_IDENTITY="${CASE_DIR}/payload/tailscaled.state"
  export FIX_CURL_LOG="${CASE_DIR}/curl.log"
  export FIX_TAILSCALE_LOG="${CASE_DIR}/tailscale.log"
  export FIX_SYSTEMCTL_LOG="${CASE_DIR}/systemctl.log"
  export FIX_SLEEP_LOG="${CASE_DIR}/sleep.log"
  export FIX_HOSTNAME_LOG="${CASE_DIR}/hostname.log"
  export FIX_DNSDOMAINNAME_LOG="${CASE_DIR}/dnsdomainname.log"
  export FIX_BASE64_LOG="${CASE_DIR}/base64.log"

  mkdir -p "${FIX_STATE_DIR}" "$(dirname "${FIX_TOKEN_FILE}")" "${CASE_DIR}/payload"
  printf 'NeedsLogin\n' > "${FIX_BACKEND_STATE}"
  : > "${FIX_BACKEND_IP}"
  : > "${FIX_DAEMON_RUNNING}"
  : > "${FIX_DAEMON_IDENTITY}"
  : > "${FIX_CURL_LOG}"
  : > "${FIX_TAILSCALE_LOG}"
  : > "${FIX_SYSTEMCTL_LOG}"
  : > "${FIX_SLEEP_LOG}"
  : > "${FIX_HOSTNAME_LOG}"
  : > "${FIX_DNSDOMAINNAME_LOG}"
  : > "${FIX_BASE64_LOG}"
  export FIX_CP_FAIL=0

  printf 'vault-restored-identity-for-1002\n' > "${CASE_DIR}/payload/tailscaled.state"
  export FIX_VAULT_PAYLOAD
  FIX_VAULT_PAYLOAD="$(tar -C "${CASE_DIR}/payload" -cf - . | PATH="${BIN_DIR}:${PATH}" base64 -w0)"
}

file_digest() {
  cksum "$1" | awk '{ print $1 ":" $2 }'
}

test_start "A" "late token restores the Vault identity without consuming the fallback key"
new_case
printf '%s\n' "${AUTH_SENTINEL}" > "${FIX_AUTH_KEY}"
export FIX_VAULT_MODE=identity

set +e
RESTORE_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${RESTORE_SCRIPT}" 2>&1)"
RESTORE_STATUS=$?
set -e

RESTORE_DIR_EMPTY=0
if [[ -z "$(find "${FIX_STATE_DIR}" -mindepth 1 -print -quit)" ]]; then
  RESTORE_DIR_EMPTY=1
fi

printf 'late-vault-token\n' > "${FIX_TOKEN_FILE}"
set +e
JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
JOIN_STATUS=$?
set -e

CASE_A_OK=1
[[ "${RESTORE_STATUS}" -eq 0 ]] || CASE_A_OK=0
grep -Fq 'no Vault token after 60s' <<< "${RESTORE_OUTPUT}" || CASE_A_OK=0
[[ "${RESTORE_DIR_EMPTY}" -eq 1 ]] || CASE_A_OK=0
[[ "${JOIN_STATUS}" -eq 0 ]] || CASE_A_OK=0
[[ -f "${FIX_STATE_DIR}/tailscaled.state" ]] || CASE_A_OK=0
if [[ -f "${FIX_STATE_DIR}/tailscaled.state" ]]; then
  [[ "$(file_digest "${FIX_STATE_DIR}/tailscaled.state")" == "$(file_digest "${CASE_DIR}/payload/tailscaled.state")" ]] || CASE_A_OK=0
fi
grep -Fq 'systemctl <stop> <tailscaled.service>' "${FIX_SYSTEMCTL_LOG}" || CASE_A_OK=0
grep -Fq 'systemctl <start> <tailscaled.service>' "${FIX_SYSTEMCTL_LOG}" || CASE_A_OK=0
if grep -Fq 'systemctl <restart> <tailscaled.service>' "${FIX_SYSTEMCTL_LOG}"; then CASE_A_OK=0; fi
if grep -Fq 'tailscale <up>' "${FIX_TAILSCALE_LOG}"; then CASE_A_OK=0; fi
if grep -Fq "${AUTH_SENTINEL}" "${FIX_TAILSCALE_LOG}"; then CASE_A_OK=0; fi

if [[ "${CASE_A_OK}" -eq 1 ]]; then
  test_pass "tailscaled stopped before the byte-exact restore, started afterward, and tailscale up was not called"
else
  test_fail "late restore did not preempt fallback enrollment"
  printf '    restore output:\n%s\n    join output:\n%s\n' "${RESTORE_OUTPUT}" "${JOIN_OUTPUT}" >&2
fi

test_start "B" "absent Vault identity preserves auth-key enrollment and writes the new identity"
new_case
printf '%s\n' "${AUTH_SENTINEL}" > "${FIX_AUTH_KEY}"
export FIX_VAULT_MODE=absent

set +e
PATH="${BIN_DIR}:${PATH}" "${RESTORE_SCRIPT}" >/dev/null 2>&1
RESTORE_STATUS=$?
set -e
printf 'late-vault-token\n' > "${FIX_TOKEN_FILE}"

set +e
JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
JOIN_STATUS=$?
set -e

CASE_B_OK=1
[[ "${RESTORE_STATUS}" -eq 0 && "${JOIN_STATUS}" -eq 0 ]] || CASE_B_OK=0
grep -Fq "tailscale <up> <--auth-key> <${AUTH_SENTINEL}>" "${FIX_TAILSCALE_LOG}" || CASE_B_OK=0
grep -Fq '<-X> <POST>' "${FIX_CURL_LOG}" || CASE_B_OK=0
[[ -f "${FIX_STATE_DIR}/tailscaled.state" ]] || CASE_B_OK=0
if [[ -f "${FIX_STATE_DIR}/tailscaled.state" ]]; then
  [[ "$(file_digest "${FIX_STATE_DIR}/tailscaled.state")" != "$(file_digest "${CASE_DIR}/payload/tailscaled.state")" ]] || CASE_B_OK=0
fi

if [[ "${CASE_B_OK}" -eq 1 ]]; then
  test_pass "fallback key was consumed, fresh identity connected, and Vault POST was attempted"
else
  test_fail "missing Vault identity did not preserve the existing fallback path"
  printf '    join output:\n%s\n' "${JOIN_OUTPUT}" >&2
fi

test_start "C" "missing Vault identity and missing auth key fails with an explicit diagnostic"
new_case
export FIX_VAULT_MODE=absent
printf 'available-vault-token\n' > "${FIX_TOKEN_FILE}"
rm -f "${FIX_AUTH_KEY}"

set +e
JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
JOIN_STATUS=$?
set -e

if [[ "${JOIN_STATUS}" -eq 1 ]] \
   && grep -Fq "no Vault identity to restore and no fallback auth key at ${FIX_AUTH_KEY}; cannot enroll this node" <<< "${JOIN_OUTPUT}" \
   && ! grep -Fq 'No such file or directory' <<< "${JOIN_OUTPUT}"; then
  test_pass "missing auth key exits 1 with the actionable message and no redirection error"
else
  test_fail "missing auth key did not fail through the explicit capability check"
  printf '    join output:\n%s\n' "${JOIN_OUTPUT}" >&2
fi

test_start "D" "an unsettled Starting backend state fails closed and never enrolls or wipes state"
new_case
printf '%s\n' "${AUTH_SENTINEL}" > "${FIX_AUTH_KEY}"
printf 'available-vault-token\n' > "${FIX_TOKEN_FILE}"
export FIX_VAULT_MODE=identity
printf 'pre-existing-local-identity\n' > "${FIX_STATE_DIR}/tailscaled.state"
printf 'pre-existing-local-identity\n' > "${FIX_DAEMON_IDENTITY}"
# Pinned Starting: a fresh node passes through Starting toward NeedsLogin, so
# wait_for_backend_state must NOT accept Starting as a terminal decision state
# — otherwise a mid-startup sample could bypass the NeedsLogin gate and enroll.
printf 'Starting\n' > "${FIX_BACKEND_STATE}"
PREEXISTING_DIGEST="$(file_digest "${FIX_STATE_DIR}/tailscaled.state")"

set +e
JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
JOIN_STATUS=$?
set -e

CASE_D_OK=1
[[ "${JOIN_STATUS}" -ne 0 ]] || CASE_D_OK=0
grep -Fq 'did not become ready' <<< "${JOIN_OUTPUT}" || CASE_D_OK=0
if grep -Fq 'tailscale <up>' "${FIX_TAILSCALE_LOG}"; then CASE_D_OK=0; fi
if grep -Fq "${AUTH_SENTINEL}" "${FIX_TAILSCALE_LOG}"; then CASE_D_OK=0; fi
[[ "$(file_digest "${FIX_STATE_DIR}/tailscaled.state")" == "${PREEXISTING_DIGEST}" ]] || CASE_D_OK=0

if [[ "${CASE_D_OK}" -eq 1 ]]; then
  test_pass "unsettled Starting exited non-zero for a systemd retry, with no enrollment and state untouched"
else
  test_fail "Starting was treated as a terminal decision state (it must settle or fail closed)"
  printf '    join status: %s\n    join output:\n%s\n' "${JOIN_STATUS}" "${JOIN_OUTPUT}" >&2
fi

test_start "H" "a settled Running node with a stored identity stays connected without enrolling or wiping"
new_case
printf '%s\n' "${AUTH_SENTINEL}" > "${FIX_AUTH_KEY}"
printf 'available-vault-token\n' > "${FIX_TOKEN_FILE}"
export FIX_VAULT_MODE=identity
printf 'pre-existing-local-identity\n' > "${FIX_STATE_DIR}/tailscaled.state"
printf 'pre-existing-local-identity\n' > "${FIX_DAEMON_IDENTITY}"
printf 'Running\n' > "${FIX_BACKEND_STATE}"
printf '100.64.0.7\n' > "${FIX_BACKEND_IP}"
RUNNING_DIGEST="$(file_digest "${FIX_STATE_DIR}/tailscaled.state")"

set +e
JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
JOIN_STATUS=$?
set -e

CASE_H_OK=1
[[ "${JOIN_STATUS}" -eq 0 ]] || CASE_H_OK=0
grep -Fq 'already connected and Vault identity is present' <<< "${JOIN_OUTPUT}" || CASE_H_OK=0
if grep -Fq 'tailscale <up>' "${FIX_TAILSCALE_LOG}"; then CASE_H_OK=0; fi
if grep -Eq 'systemctl <(stop|restart)> <tailscaled\.service>' "${FIX_SYSTEMCTL_LOG}"; then CASE_H_OK=0; fi
[[ "$(file_digest "${FIX_STATE_DIR}/tailscaled.state")" == "${RUNNING_DIGEST}" ]] || CASE_H_OK=0

if [[ "${CASE_H_OK}" -eq 1 ]]; then
  test_pass "Running exited 0 via the already-connected path with no enrollment and state untouched"
else
  test_fail "Running node did not take the already-connected no-op path"
  printf '    join status: %s\n    join output:\n%s\n' "${JOIN_STATUS}" "${JOIN_OUTPUT}" >&2
fi

test_start "E" "a fetched identity that cannot be installed never falls through to enrollment"
new_case
printf '%s\n' "${AUTH_SENTINEL}" > "${FIX_AUTH_KEY}"
printf 'available-vault-token\n' > "${FIX_TOKEN_FILE}"
export FIX_VAULT_MODE=identity
export FIX_CP_FAIL=1

set +e
JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
JOIN_STATUS=$?
set -e

if [[ "${JOIN_STATUS}" -eq 1 ]] \
   && grep -Fq 'could not be installed (INSTALL_RC=1)' <<< "${JOIN_OUTPUT}" \
   && ! grep -Fq 'tailscale <up>' "${FIX_TAILSCALE_LOG}" \
   && ! grep -Fq "${AUTH_SENTINEL}" "${FIX_TAILSCALE_LOG}"; then
  test_pass "local install (cp) failure exited 1 and refused replacement enrollment"
else
  test_fail "local install failure did not fail closed without enrolling"
  printf '    join output:\n%s\n' "${JOIN_OUTPUT}" >&2
fi

test_start "F" "NeedsLogin with no Vault token fails closed and never fresh-enrolls (#1002 incident)"
new_case
printf '%s\n' "${AUTH_SENTINEL}" > "${FIX_AUTH_KEY}"
export FIX_VAULT_MODE=identity
# Deliberately do NOT write the token file: the incident is the token never
# arriving before the join's wait expires (prod DNS/Vault not up yet). The old
# code fell through to fresh enrollment with the expired auth key here.

set +e
JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
JOIN_STATUS=$?
set -e

CASE_F_OK=1
[[ "${JOIN_STATUS}" -ne 0 ]] || CASE_F_OK=0
grep -Fq 'refusing to fresh-enroll on a transient' <<< "${JOIN_OUTPUT}" || CASE_F_OK=0
if grep -Fq 'tailscale <up>' "${FIX_TAILSCALE_LOG}"; then CASE_F_OK=0; fi
if grep -Fq "${AUTH_SENTINEL}" "${FIX_TAILSCALE_LOG}"; then CASE_F_OK=0; fi

if [[ "${CASE_F_OK}" -eq 1 ]]; then
  test_pass "no token failed closed for a systemd retry, with no enrollment and the auth key untouched"
else
  test_fail "no-token path did not fail closed (it must never fresh-enroll on a transient)"
  printf '    join status: %s\n    join output:\n%s\n' "${JOIN_STATUS}" "${JOIN_OUTPUT}" >&2
fi

test_start "G" "NeedsLogin with a token but an ambiguous Vault result fails closed (never enrolls)"
# Every non-definitive result must fail closed: 5xx (curl exits 0, status
# 503), connection failure (curl exits non-zero, status 000 — also exercises
# the set +e capture guard), 403 permission denied, a malformed 200 body, and
# a KV v2 soft-deleted 404 whose data is still recoverable. None may enroll.
CASE_G_OK=1
for MODE in transient5xx transient forbidden malformed200 softdeleted404 routererror404; do
  new_case
  printf '%s\n' "${AUTH_SENTINEL}" > "${FIX_AUTH_KEY}"
  printf 'available-vault-token\n' > "${FIX_TOKEN_FILE}"
  export FIX_VAULT_MODE="${MODE}"

  set +e
  JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
  JOIN_STATUS=$?
  set -e

  [[ "${JOIN_STATUS}" -ne 0 ]] || { CASE_G_OK=0; }
  grep -Fq 'Vault unreachable or indeterminate' <<< "${JOIN_OUTPUT}" || CASE_G_OK=0
  if grep -Fq 'tailscale <up>' "${FIX_TAILSCALE_LOG}"; then CASE_G_OK=0; fi
  if grep -Fq "${AUTH_SENTINEL}" "${FIX_TAILSCALE_LOG}"; then CASE_G_OK=0; fi
  if [[ "${CASE_G_OK}" -eq 0 ]]; then
    printf '    mode %s: join status: %s\n    join output:\n%s\n' "${MODE}" "${JOIN_STATUS}" "${JOIN_OUTPUT}" >&2
    break
  fi
done

if [[ "${CASE_G_OK}" -eq 1 ]]; then
  test_pass "every ambiguous Vault result (5xx, conn-fail, 403, malformed 200, soft-deleted 404, router-error 404) failed closed"
else
  test_fail "a transient Vault error did not fail closed (it must never fresh-enroll on a transient)"
fi

test_start "I" "a fetched identity whose payload fails to extract fails closed, never enrolls"
new_case
printf '%s\n' "${AUTH_SENTINEL}" > "${FIX_AUTH_KEY}"
printf 'available-vault-token\n' > "${FIX_TOKEN_FILE}"
export FIX_VAULT_MODE=identity
# A well-formed 200 (format+value present -> fetch returns 0/found), but the
# payload decodes to something tar cannot extract -> identity_install_payload
# returns 2. This must fail closed (a transient extraction hiccup on a valid,
# recoverable record must not orphan it via fresh enrollment), NOT enroll.
FIX_VAULT_PAYLOAD="$(printf 'this-is-not-a-tar-archive' | PATH="${BIN_DIR}:${PATH}" base64 -w0)"

set +e
JOIN_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${JOIN_SCRIPT}" 2>&1)"
JOIN_STATUS=$?
set -e

CASE_I_OK=1
[[ "${JOIN_STATUS}" -ne 0 ]] || CASE_I_OK=0
grep -Fq 'could not be installed' <<< "${JOIN_OUTPUT}" || CASE_I_OK=0
if grep -Fq 'tailscale <up>' "${FIX_TAILSCALE_LOG}"; then CASE_I_OK=0; fi
if grep -Fq "${AUTH_SENTINEL}" "${FIX_TAILSCALE_LOG}"; then CASE_I_OK=0; fi

if [[ "${CASE_I_OK}" -eq 1 ]]; then
  test_pass "an uninstallable fetched payload failed closed with no enrollment"
else
  test_fail "an install failure fell through to fresh enrollment (it must fail closed)"
  printf '    join status: %s\n    join output:\n%s\n' "${JOIN_STATUS}" "${JOIN_OUTPUT}" >&2
fi

test_start "J" "restore.sh in-process fetch+install restores the identity and leaves errexit intact"
new_case
export FIX_VAULT_MODE=identity
printf 'available-vault-token\n' > "${FIX_TOKEN_FILE}"   # token present BEFORE restore runs

set +e
RESTORE_OUTPUT="$(PATH="${BIN_DIR}:${PATH}" "${RESTORE_SCRIPT}" 2>&1)"
RESTORE_STATUS=$?
set -e

CASE_J_OK=1
[[ "${RESTORE_STATUS}" -eq 0 ]] || CASE_J_OK=0
grep -Fq 'restored identity into' <<< "${RESTORE_OUTPUT}" || CASE_J_OK=0
[[ -f "${FIX_STATE_DIR}/tailscaled.state" ]] || CASE_J_OK=0
if [[ -f "${FIX_STATE_DIR}/tailscaled.state" ]]; then
  [[ "$(file_digest "${FIX_STATE_DIR}/tailscaled.state")" == "$(file_digest "${CASE_DIR}/payload/tailscaled.state")" ]] || CASE_J_OK=0
fi

if [[ "${CASE_J_OK}" -eq 1 ]]; then
  test_pass "restore.sh ran its in-process fetch+install path and byte-exactly restored the identity"
else
  test_fail "restore.sh in-process happy path did not restore the identity cleanly"
  printf '    restore status: %s\n    restore output:\n%s\n' "${RESTORE_STATUS}" "${RESTORE_OUTPUT}" >&2
fi

runner_summary
