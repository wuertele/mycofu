#!/usr/bin/env bash
# Hermetic test for framework/scripts/configure-influxdb-tokens.sh.
#
# Runs the real script against a Python mock InfluxDB API and a fake SOPS
# binary backed by a plaintext JSON file. No live cluster or encrypted
# secrets are touched.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/framework/scripts/configure-influxdb-tokens.sh"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"

source "${REPO_ROOT}/tests/lib/runner.sh"

WORK="$(mktemp -d -t influxdb-token-test-XXXXXX)"
SERVER_PORT=0
SERVER_PID=0
SERVER_STATE="${WORK}/server-state.json"
SERVER_LOG="${WORK}/server.log"
FAKEBIN="${WORK}/fakebin"
SECRETS_FILE="${WORK}/secrets.json"
APPS_CONFIG="${WORK}/applications.yaml"
SETUP_JSON="${WORK}/setup.json"
TOKENS_JSON="${WORK}/tokens.json"
OUTPUT_LOG="${WORK}/output.log"

cleanup() {
  if [[ "$SERVER_PID" -ne 0 ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

SERVER_PORT="$(python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

mkdir -p "$FAKEBIN"
cat > "${FAKEBIN}/sops" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 4 && "$1" == "-d" && "$2" == "--extract" ]]; then
  if [[ "${FAKE_SOPS_FAIL_DECRYPT:-0}" == "1" ]]; then
    echo "fake sops decrypt failure" >&2
    exit 65
  fi
  expr="$3"
  file="$4"
  key="$(printf '%s' "$expr" | sed -E 's/^\["([^"]+)"\]$/\1/')"
  jq -r --arg key "$key" '.[$key] // empty' "$file"
  exit 0
fi

if [[ $# -eq 4 && "$1" == "-d" && "$2" == "--output-type" && "$3" == "json" ]]; then
  if [[ "${FAKE_SOPS_FAIL_DECRYPT:-0}" == "1" ]]; then
    echo "fake sops decrypt failure" >&2
    exit 65
  fi
  cat "$4"
  exit 0
fi

if [[ $# -eq 3 && "$1" == "--set" ]]; then
  if [[ "${FAKE_SOPS_FAIL_SET:-0}" == "1" ]]; then
    echo "fake sops set failure" >&2
    exit 65
  fi
  expr="$2"
  file="$3"
  key="$(printf '%s' "$expr" | sed -E 's/^\["([^"]+)"\][[:space:]].*$/\1/')"
  value_json="$(printf '%s' "$expr" | sed -E 's/^\["[^"]+"\][[:space:]]+//')"
  tmp="$(mktemp)"
  jq --arg key "$key" --argjson value "$value_json" '.[$key] = $value' "$file" > "$tmp"
  mv "$tmp" "$file"
  exit 0
fi

if [[ $# -eq 4 && "$1" == "unset" && "$2" == "--idempotent" ]]; then
  file="$3"
  expr="$4"
  key="$(printf '%s' "$expr" | sed -E 's/^\["([^"]+)"\]$/\1/')"
  tmp="$(mktemp)"
  jq --arg key "$key" 'del(.[$key])' "$file" > "$tmp"
  mv "$tmp" "$file"
  exit 0
fi

echo "unsupported fake sops invocation: $*" >&2
exit 64
BASH
chmod +x "${FAKEBIN}/sops"

cat > "$APPS_CONFIG" <<'EOF'
applications:
  influxdb:
    environments:
      prod:
        ip: 127.0.0.1
EOF

cat > "$SETUP_JSON" <<'EOF'
{
  "org": "homelab",
  "bucket": "default",
  "retention": "30d",
  "username": "admin"
}
EOF

cat > "$TOKENS_JSON" <<'EOF'
[
  {
    "name": "homeassistant_write",
    "bucket": "homeassistant_raw",
    "permissions": ["write"],
    "description": {
      "prod": "homeassistant-prod-influxdb-write",
      "dev": "homeassistant-dev-influxdb-write"
    },
    "sops_key": {
      "prod": "homeassistant_influxdb_write_token",
      "dev": "homeassistant_dev_influxdb_write_token"
    }
  },
  {
    "name": "homeassistant_read",
    "bucket": "homeassistant_raw",
    "permissions": ["read"],
    "description": {
      "prod": "homeassistant-prod-influxdb-read",
      "dev": "homeassistant-dev-influxdb-read"
    },
    "sops_key": {
      "prod": "homeassistant_influxdb_read_token",
      "dev": "homeassistant_dev_influxdb_read_token"
    }
  }
]
EOF

cat > "${WORK}/mock_server.py" <<'PYEOF'
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

STATE_FILE = os.environ["STATE_FILE"]

def load():
    with open(STATE_FILE) as f:
        return json.load(f)

def save(state):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f)

def record(op, **kwargs):
    state = load()
    call = {"op": op}
    call.update(kwargs)
    state["calls"].append(call)
    save(state)

class H(BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        pass

    def _read_json(self):
        n = int(self.headers.get("Content-Length", "0"))
        if n == 0:
            return {}
        return json.loads(self.rfile.read(n))

    def _send(self, code, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _authorized(self):
        return self.headers.get("Authorization") == "Token admin-token"

    def _require_auth(self):
        if self._authorized():
            return True
        self._send(401, {"code": "unauthorized", "message": "bad or missing admin token"})
        return False

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        state = load()

        if parsed.path == "/health":
            self._send(200, {"status": "pass"})
            return

        if parsed.path.startswith("/api/v2/") and not self._require_auth():
            return

        if parsed.path == "/api/v2/orgs":
            org = (query.get("org") or [""])[0]
            record("list_orgs", org=org)
            if org == state["org"]["name"]:
                self._send(200, {"orgs": [state["org"]]})
            else:
                self._send(200, {"orgs": []})
            return

        if parsed.path == "/api/v2/buckets":
            org_id = (query.get("orgID") or [""])[0]
            name = (query.get("name") or [""])[0]
            buckets = list(state["buckets"].values())
            buckets = [b for b in buckets if not org_id or b.get("orgID") == org_id]
            buckets = [b for b in buckets if not name or b.get("name") == name]
            record("list_buckets", orgID=org_id, name=name)
            self._send(200, {"buckets": buckets})
            return

        if parsed.path == "/api/v2/authorizations":
            org_id = (query.get("orgID") or [""])[0]
            limit = int((query.get("limit") or ["100"])[0])
            offset = int((query.get("offset") or ["0"])[0])
            auths = list(state["authorizations"].values())
            auths = [a for a in auths if not org_id or a.get("orgID") == org_id]
            record("list_authorizations", orgID=org_id, limit=limit, offset=offset)
            self._send(200, {"authorizations": auths[offset:offset + limit]})
            return

        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.startswith("/api/v2/") and not self._require_auth():
            return

        if self.path == "/api/v2/authorizations":
            body = self._read_json()
            state = load()
            aid = f"auth-{state['next_auth']}"
            token = f"token-{state['next_auth']}"
            state["next_auth"] += 1
            auth = {
                "id": aid,
                "token": token,
                "orgID": body["orgID"],
                "description": body["description"],
                "permissions": body["permissions"],
                "status": "active",
            }
            state["authorizations"][aid] = auth
            state["calls"].append({"op": "create_authorization", "id": aid})
            save(state)
            self._send(201, auth)
            return
        self._send(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path.startswith("/api/v2/") and not self._require_auth():
            return

        m = re.match(r"^/api/v2/authorizations/([^/]+)$", self.path)
        if m:
            aid = m.group(1)
            state = load()
            if aid in state.get("fail_delete_ids", []):
                state["calls"].append({"op": "delete_authorization_failed", "id": aid})
                save(state)
                self._send(500, {"error": "delete failed"})
                return
            state["authorizations"].pop(aid, None)
            state["calls"].append({"op": "delete_authorization", "id": aid})
            save(state)
            self._send(204)
            return
        self._send(404, {"error": "not found"})

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

reset_state() {
  cat > "$SERVER_STATE" <<'EOF'
{
  "org": {"id": "org-id-fake", "name": "homelab"},
  "buckets": {
    "bucket-id-raw": {
      "id": "bucket-id-raw",
      "name": "homeassistant_raw",
      "orgID": "org-id-fake",
      "retentionRules": [{"type": "expire", "everySeconds": 7776000}]
    }
  },
  "authorizations": {},
  "next_auth": 1,
  "calls": [],
  "fail_delete_ids": []
}
EOF
}

reset_state_without_bucket() {
  cat > "$SERVER_STATE" <<'EOF'
{
  "org": {"id": "org-id-fake", "name": "homelab"},
  "buckets": {},
  "authorizations": {},
  "next_auth": 1,
  "calls": [],
  "fail_delete_ids": []
}
EOF
}

reset_state_with_auth() {
  local status="$1" token="$2"
  jq -nc \
    --arg status "$status" \
    --arg token "$token" '
    {
      org: {id: "org-id-fake", name: "homelab"},
      buckets: {
        "bucket-id-raw": {
          id: "bucket-id-raw",
          name: "homeassistant_raw",
          orgID: "org-id-fake",
          retentionRules: [{type: "expire", everySeconds: 7776000}]
        }
      },
      authorizations: {
        "auth-existing": {
          id: "auth-existing",
          token: $token,
          orgID: "org-id-fake",
          description: "homeassistant-prod-influxdb-write",
          status: $status,
          permissions: [
            {
              action: "write",
              resource: {
                type: "buckets",
                id: "bucket-id-raw",
                orgID: "org-id-fake"
              }
            }
          ]
        }
      },
      next_auth: 1,
      calls: [],
      fail_delete_ids: []
    }' > "$SERVER_STATE"
}

reset_state_with_auth_without_token() {
  local status="$1"
  jq -nc \
    --arg status "$status" '
    {
      org: {id: "org-id-fake", name: "homelab"},
      buckets: {
        "bucket-id-raw": {
          id: "bucket-id-raw",
          name: "homeassistant_raw",
          orgID: "org-id-fake",
          retentionRules: [{type: "expire", everySeconds: 7776000}]
        }
      },
      authorizations: {
        "auth-existing": {
          id: "auth-existing",
          orgID: "org-id-fake",
          description: "homeassistant-prod-influxdb-write",
          status: $status,
          permissions: [
            {
              action: "write",
              resource: {
                type: "buckets",
                id: "bucket-id-raw",
                orgID: "org-id-fake"
              }
            }
          ]
        }
      },
      next_auth: 1,
      calls: [],
      fail_delete_ids: []
    }' > "$SERVER_STATE"
}

reset_state_many_authorizations() {
  python3 - <<'PY' > "$SERVER_STATE"
import json

authorizations = {}
for i in range(105):
    authorizations[f"auth-dummy-{i:03d}"] = {
        "id": f"auth-dummy-{i:03d}",
        "token": f"dummy-token-{i:03d}",
        "orgID": "org-id-fake",
        "description": f"dummy-{i:03d}",
        "status": "active",
        "permissions": [],
    }

authorizations["auth-target"] = {
    "id": "auth-target",
    "token": "target-token",
    "orgID": "org-id-fake",
    "description": "homeassistant-prod-influxdb-write",
    "status": "active",
    "permissions": [
        {
            "action": "write",
            "resource": {
                "type": "buckets",
                "id": "bucket-id-raw",
                "orgID": "org-id-fake",
            },
        }
    ],
}

print(json.dumps({
    "org": {"id": "org-id-fake", "name": "homelab"},
    "buckets": {
        "bucket-id-raw": {
            "id": "bucket-id-raw",
            "name": "homeassistant_raw",
            "orgID": "org-id-fake",
            "retentionRules": [{"type": "expire", "everySeconds": 7776000}],
        }
    },
    "authorizations": authorizations,
    "next_auth": 200,
    "calls": [],
    "fail_delete_ids": [],
}))
PY
}

write_secrets() {
  local ha_token="${1:-}"
  if [[ -n "$ha_token" ]]; then
    jq -nc --arg ha "$ha_token" \
      '{influxdb_admin_token: "admin-token", homeassistant_influxdb_write_token: $ha}' \
      > "$SECRETS_FILE"
  else
    printf '{"influxdb_admin_token":"admin-token"}\n' > "$SECRETS_FILE"
  fi
}

STATE_FILE="$SERVER_STATE" python3 "${WORK}/mock_server.py" "$SERVER_PORT" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

reset_state
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${SERVER_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! curl -sf "http://127.0.0.1:${SERVER_PORT}/health" >/dev/null 2>&1; then
  echo "FATAL: mock server did not come up" >&2
  cat "$SERVER_LOG" >&2
  exit 2
fi

run_script() {
  set +e
  PATH="${FAKEBIN}:$PATH" \
  MYCOFU_APPS_CONFIG="$APPS_CONFIG" \
  MYCOFU_INFLUXDB_SETUP_JSON="$SETUP_JSON" \
  MYCOFU_INFLUXDB_TOKENS_JSON="$TOKENS_JSON" \
  MYCOFU_SECRETS_FILE="$SECRETS_FILE" \
  MYCOFU_INFLUXDB_BASE_URL="http://127.0.0.1:${SERVER_PORT}" \
  MYCOFU_INFLUXDB_INSECURE=0 \
  MYCOFU_INFLUXDB_WAIT_TIMEOUT=5 \
  FAKE_SOPS_FAIL_SET="${FAKE_SOPS_FAIL_SET:-0}" \
  FAKE_SOPS_FAIL_DECRYPT="${FAKE_SOPS_FAIL_DECRYPT:-0}" \
    bash "$SCRIPT" prod "$@" >"$OUTPUT_LOG" 2>&1
  local rc=$?
  set -e
  return $rc
}

calls_count_of() {
  jq --arg op "$1" '[.calls[] | select(.op == $op)] | length' "$SERVER_STATE"
}

auth_count() {
  jq '.authorizations | length' "$SERVER_STATE"
}

auth_sequence() {
  jq -r '
    [.calls[]
      | select(.op == "create_authorization" or .op == "delete_authorization")
      | "\(.op):\(.id)"]
    | join(",")
  ' "$SERVER_STATE"
}

ha_secret_value() {
  jq -r '.homeassistant_influxdb_write_token // empty' "$SECRETS_FILE"
}

ha_read_secret_value() {
  jq -r '.homeassistant_influxdb_read_token // empty' "$SECRETS_FILE"
}

fail_deletes_for() {
  local auth_id="$1" tmp
  tmp="$(mktemp)"
  jq --arg auth_id "$auth_id" '.fail_delete_ids = [$auth_id]' "$SERVER_STATE" > "$tmp"
  mv "$tmp" "$SERVER_STATE"
}

set_write_permissions() {
  local permissions_json="$1" tmp
  tmp="$(mktemp)"
  jq --argjson permissions "$permissions_json" '
    map(if .name == "homeassistant_write" then .permissions = $permissions else . end)
  ' "$TOKENS_JSON" > "$tmp"
  mv "$tmp" "$TOKENS_JSON"
}

# ============================================================================
# Test cases
# ============================================================================

test_start "1" "InfluxDB token scripts pass bash -n"
if bash -n "$SCRIPT"; then
  test_pass "syntax checks pass"
else
  test_fail "syntax check failed"
fi

test_start "2" "InfluxDB token scripts are executable"
if [[ -x "$SCRIPT" ]]; then
  test_pass "executable bits set"
else
  test_fail "script executable bit is missing"
fi

test_start "3" "first run creates write-only bucket token and writes SOPS key"
reset_state
write_secrets
if run_script --token homeassistant_write; then
  if [[ "$(calls_count_of create_authorization)" == "1" ]] \
      && [[ "$(ha_secret_value)" == "token-1" ]] \
      && jq -e '
        ([.authorizations[]][0].description == "homeassistant-prod-influxdb-write")
        and
        ([.authorizations[]][0].permissions == [
          {
            "action": "write",
            "resource": {
              "type": "buckets",
              "id": "bucket-id-raw",
              "orgID": "org-id-fake"
            }
          }
        ])
      ' "$SERVER_STATE" >/dev/null; then
    test_pass "created one write-only auth and stored returned token"
  else
    test_fail "first run did not create expected write-only auth or SOPS token"
  fi
else
  test_fail "script exited non-zero on first run; log:"
  sed 's/^/    /' "$OUTPUT_LOG"
fi

test_start "4" "second run is a no-op when auth and SOPS token exist"
prev_creates="$(calls_count_of create_authorization)"
prev_deletes="$(calls_count_of delete_authorization)"
if run_script --token homeassistant_write; then
  if [[ "$(calls_count_of create_authorization)" == "$prev_creates" ]] \
      && [[ "$(calls_count_of delete_authorization)" == "$prev_deletes" ]] \
      && [[ "$(ha_secret_value)" == "token-1" ]]; then
    test_pass "no additional auth created or deleted"
  else
    test_fail "idempotent run changed auth state or SOPS token"
  fi
else
  test_fail "script exited non-zero on idempotent run; log:"
  sed 's/^/    /' "$OUTPUT_LOG"
fi

test_start "5" "config permission change without --rotate refuses to broaden existing auth"
set_write_permissions '["read","write"]'
prev_creates="$(calls_count_of create_authorization)"
if ! run_script --token homeassistant_write; then
  if grep -q "permissions do not match requested scope" "$OUTPUT_LOG" \
      && [[ "$(calls_count_of create_authorization)" == "$prev_creates" ]]; then
    test_pass "permission change requires explicit rotation"
  else
    test_fail "expected permission-mismatch failure without creating a token; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
  fi
else
  test_fail "expected permission change without --rotate to fail"
fi

test_start "6" "--rotate applies configured read/write scope and stores new token"
if run_script --token homeassistant_write --rotate; then
  if [[ "$(calls_count_of delete_authorization)" == "1" ]] \
      && [[ "$(calls_count_of create_authorization)" == "2" ]] \
      && [[ "$(ha_secret_value)" == "token-2" ]] \
      && [[ "$(auth_sequence)" == "create_authorization:auth-1,create_authorization:auth-2,delete_authorization:auth-1" ]] \
      && jq -e '
        ([.authorizations[]] | length == 1)
        and
        ([.authorizations[]][0].permissions | sort_by(.action) == [
          {
            "action": "read",
            "resource": {
              "type": "buckets",
              "id": "bucket-id-raw",
              "orgID": "org-id-fake"
            }
          },
          {
            "action": "write",
            "resource": {
              "type": "buckets",
              "id": "bucket-id-raw",
              "orgID": "org-id-fake"
            }
          }
        ])
      ' "$SERVER_STATE" >/dev/null; then
    test_pass "rotation replaced auth and broadened only to bucket read/write"
  else
    test_fail "rotation did not produce expected read/write auth and SOPS token"
  fi
else
  test_fail "script exited non-zero on explicit rotation; log:"
  sed 's/^/    /' "$OUTPUT_LOG"
fi
set_write_permissions '["write"]'

test_start "7" "matching auth with wrong SOPS token is refused"
reset_state_with_auth "active" "real-token"
write_secrets "wrong-token"
if ! run_script --token homeassistant_write; then
  if grep -q "does not match existing auth" "$OUTPUT_LOG" \
      && [[ "$(calls_count_of create_authorization)" == "0" ]] \
      && [[ "$(calls_count_of delete_authorization)" == "0" ]]; then
    test_pass "stale SOPS token is detected against retrievable auth token"
  else
    test_fail "expected token-mismatch refusal without auth changes; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
  fi
else
  test_fail "expected wrong SOPS token with matching auth to fail"
fi

test_start "8" "existing retrievable auth is restored into missing SOPS key"
reset_state_with_auth "active" "real-token"
write_secrets
if run_script --token homeassistant_write; then
  if [[ "$(ha_secret_value)" == "real-token" ]] \
      && [[ "$(calls_count_of create_authorization)" == "0" ]] \
      && [[ "$(calls_count_of delete_authorization)" == "0" ]]; then
    test_pass "existing auth token copied to SOPS without rotation"
  else
    test_fail "expected existing auth token to be restored to SOPS without auth changes"
  fi
else
  test_fail "script exited non-zero while restoring existing auth token; log:"
  sed 's/^/    /' "$OUTPUT_LOG"
fi

test_start "9" "inactive matching auth is refused unless rotated"
reset_state_with_auth "inactive" "real-token"
write_secrets "real-token"
if ! run_script --token homeassistant_write; then
  if grep -q "is not active" "$OUTPUT_LOG" \
      && [[ "$(calls_count_of create_authorization)" == "0" ]] \
      && [[ "$(calls_count_of delete_authorization)" == "0" ]]; then
    test_pass "inactive auth is not treated as healthy"
  else
    test_fail "expected inactive-auth refusal without auth changes; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
  fi
else
  test_fail "expected inactive matching auth to fail"
fi

test_start "10" "authorization listing paginates to find matching auth"
reset_state_many_authorizations
write_secrets "target-token"
if run_script --token homeassistant_write; then
  if [[ "$(calls_count_of list_authorizations)" == "2" ]] \
      && [[ "$(calls_count_of create_authorization)" == "0" ]] \
      && [[ "$(calls_count_of delete_authorization)" == "0" ]]; then
    test_pass "found matching auth beyond the first authorization page"
  else
    test_fail "expected paginated no-op; calls:"
    jq '.calls' "$SERVER_STATE"
  fi
else
  test_fail "script exited non-zero on paginated auth listing; log:"
  sed 's/^/    /' "$OUTPUT_LOG"
fi

test_start "11" "failed SOPS write during rotation leaves old auth valid"
reset_state_with_auth "active" "old-token"
write_secrets "old-token"
FAKE_SOPS_FAIL_SET=1
if ! run_script --token homeassistant_write --rotate; then
  FAKE_SOPS_FAIL_SET=0
  if grep -q "failed to store InfluxDB token" "$OUTPUT_LOG" \
      && [[ "$(auth_count)" == "1" ]] \
      && jq -e '.authorizations["auth-existing"].token == "old-token"' "$SERVER_STATE" >/dev/null; then
    test_pass "new auth was cleaned up and old auth was not deleted"
  else
    test_fail "expected failed rotation to preserve old auth and clean up new auth; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
    jq '.authorizations, .calls' "$SERVER_STATE"
  fi
else
  FAKE_SOPS_FAIL_SET=0
  test_fail "expected SOPS write failure during rotation to fail"
fi

test_start "12" "SOPS token without matching Influx auth fails unless rotated"
reset_state
write_secrets "stale-token"
if ! run_script --token homeassistant_write; then
  if grep -q "SOPS key 'homeassistant_influxdb_write_token' exists but InfluxDB auth" "$OUTPUT_LOG" \
      && [[ "$(calls_count_of create_authorization)" == "0" ]]; then
    test_pass "stale SOPS token is not silently replaced"
  else
    test_fail "expected stale-token refusal without creating auth; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
  fi
else
  test_fail "expected stale SOPS token without auth to fail"
fi

test_start "13" "missing homeassistant_raw bucket fails before token creation"
reset_state_without_bucket
write_secrets
if ! run_script --token homeassistant_write; then
  if grep -q "could not resolve bucket 'homeassistant_raw'" "$OUTPUT_LOG" \
      && [[ "$(calls_count_of create_authorization)" == "0" ]]; then
    test_pass "missing bucket is reported and no token is created"
  else
    test_fail "expected missing-bucket failure without creating auth; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
  fi
else
  test_fail "expected missing bucket to fail"
fi

test_start "14" "CI wires the InfluxDB token test and syntax checks"
if grep -Fq 'bash tests/test_influxdb_tokens.sh' "$CI_FILE" \
    && grep -Fq 'bash -n framework/scripts/configure-influxdb-tokens.sh' "$CI_FILE" \
    && grep -Fq 'bash -n tests/test_influxdb_tokens.sh' "$CI_FILE"; then
  test_pass "CI references generic script syntax, test syntax, and validate job"
else
  test_fail "CI is missing InfluxDB token test or syntax wiring"
fi

test_start "15" "matching auth without retrievable token is accepted when SOPS key exists"
reset_state_with_auth_without_token "active"
write_secrets "opaque-existing-token"
if run_script --token homeassistant_write; then
  if grep -q "did not expose a token value for SOPS comparison" "$OUTPUT_LOG" \
      && [[ "$(calls_count_of create_authorization)" == "0" ]] \
      && [[ "$(calls_count_of delete_authorization)" == "0" ]] \
      && [[ "$(ha_secret_value)" == "opaque-existing-token" ]]; then
    test_pass "hashed-token mode remains idempotent when auth scope and SOPS key exist"
  else
    test_fail "expected no-op acceptance for scoped auth without retrievable token; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
  fi
else
  test_fail "script exited non-zero for scoped auth without retrievable token; log:"
  sed 's/^/    /' "$OUTPUT_LOG"
fi

test_start "16" "SOPS decrypt failure fails before InfluxDB mutations"
reset_state
write_secrets
FAKE_SOPS_FAIL_DECRYPT=1
if ! run_script --token homeassistant_write; then
  FAKE_SOPS_FAIL_DECRYPT=0
  if grep -q "failed to decrypt SOPS secrets file" "$OUTPUT_LOG" \
      && [[ "$(calls_count_of list_orgs)" == "0" ]] \
      && [[ "$(calls_count_of create_authorization)" == "0" ]] \
      && [[ "$(calls_count_of delete_authorization)" == "0" ]]; then
    test_pass "decrypt errors are reported before any API mutation"
  else
    test_fail "expected decrypt failure before API calls; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
    jq '.calls' "$SERVER_STATE"
  fi
else
  FAKE_SOPS_FAIL_DECRYPT=0
  test_fail "expected SOPS decrypt failure to fail"
fi

test_start "17" "failed old-auth cleanup rolls back SOPS and deletes replacement auth"
reset_state_with_auth "active" "old-token"
write_secrets "old-token"
fail_deletes_for "auth-existing"
if ! run_script --token homeassistant_write --rotate; then
  if grep -q "failed to delete existing InfluxDB auth" "$OUTPUT_LOG" \
      && [[ "$(ha_secret_value)" == "old-token" ]] \
      && [[ "$(calls_count_of create_authorization)" == "1" ]] \
      && [[ "$(calls_count_of delete_authorization_failed)" == "1" ]] \
      && [[ "$(calls_count_of delete_authorization)" == "1" ]] \
      && [[ "$(auth_count)" == "1" ]] \
      && jq -e '
        (.authorizations["auth-existing"].token == "old-token")
        and (.authorizations["auth-1"] == null)
      ' "$SERVER_STATE" >/dev/null; then
    test_pass "rotation cleanup failure restored old secret and removed replacement auth"
  else
    test_fail "expected rollback to old token and replacement cleanup; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
    jq '.authorizations, .calls' "$SERVER_STATE"
  fi
else
  test_fail "expected old-auth cleanup failure to abort rotation"
fi

test_start "18" "--token homeassistant_read creates separate read-only bucket token and writes SOPS key"
reset_state
write_secrets
if run_script --token homeassistant_read; then
  if [[ "$(calls_count_of create_authorization)" == "1" ]] \
      && [[ "$(ha_read_secret_value)" == "token-1" ]] \
      && [[ "$(ha_secret_value)" == "" ]] \
      && jq -e '
        ([.authorizations[]][0].description == "homeassistant-prod-influxdb-read")
        and
        ([.authorizations[]][0].permissions == [
          {
            "action": "read",
            "resource": {
              "type": "buckets",
              "id": "bucket-id-raw",
              "orgID": "org-id-fake"
            }
          }
        ])
      ' "$SERVER_STATE" >/dev/null; then
    test_pass "created one read-only auth and stored returned token separately"
  else
    test_fail "read-only run did not create expected read-only auth or SOPS token"
  fi
else
  test_fail "script exited non-zero on read-only run; log:"
  sed 's/^/    /' "$OUTPUT_LOG"
fi

test_start "19" "unknown flag fails before API mutation"
reset_state
write_secrets
if ! run_script --bogus-flag; then
  if grep -q -- "unknown argument: --bogus-flag" "$OUTPUT_LOG" \
      && [[ "$(calls_count_of list_orgs)" == "0" ]] \
      && [[ "$(calls_count_of create_authorization)" == "0" ]]; then
    test_pass "unknown flag fails before API mutation"
  else
    test_fail "expected unknown flag to fail before API mutation; log:"
    sed 's/^/    /' "$OUTPUT_LOG"
    jq '.calls' "$SERVER_STATE"
  fi
else
  test_fail "expected unknown flag to fail"
fi

test_start "20" "InfluxDB client token SOPS keys are not deployment inputs"
deployment_token_refs="$(
  grep -R -n -E 'homeassistant(_dev)?_influxdb_(write|read)_token|TF_VAR_.*homeassistant.*influxdb' \
    "${REPO_ROOT}/framework/tofu" \
    "${REPO_ROOT}/site/tofu" \
    "${REPO_ROOT}/framework/nix" \
    "${REPO_ROOT}/framework/catalog" \
    "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh" 2>/dev/null \
    | grep -v '/README.md:' \
    || true
)"
if [[ -z "$deployment_token_refs" ]]; then
  test_pass "token keys are absent from OpenTofu, Nix image, and CIDATA paths"
else
  test_fail "InfluxDB client token key appears in deployment-input paths:"
  printf '%s\n' "$deployment_token_refs" | sed 's/^/    /'
fi

test_start "21" "site InfluxDB token config declares separate HA read and write scopes"
if jq -e '
  def token($name): .[] | select(.name == $name);
  ((token("homeassistant_write").bucket == "homeassistant_raw")
    and (token("homeassistant_write").permissions == ["write"])
    and (token("homeassistant_write").sops_key.prod == "homeassistant_influxdb_write_token"))
  and
  ((token("homeassistant_read").bucket == "homeassistant_raw")
    and (token("homeassistant_read").permissions == ["read"])
    and (token("homeassistant_read").sops_key.prod == "homeassistant_influxdb_read_token"))
' "${REPO_ROOT}/site/apps/influxdb/tokens.json" >/dev/null; then
  test_pass "site config drives separate least-privilege InfluxDB client token declarations"
else
  test_fail "site/apps/influxdb/tokens.json does not declare expected InfluxDB client token scopes"
fi

test_start "22" "generic reconciler creates all configured tokens by default"
reset_state
write_secrets
if run_script; then
  if [[ "$(calls_count_of create_authorization)" == "2" ]] \
      && [[ "$(ha_secret_value)" == "token-1" ]] \
      && [[ "$(ha_read_secret_value)" == "token-2" ]] \
      && jq -e '
        ([.authorizations[] | select(.description == "homeassistant-prod-influxdb-write")] | length == 1)
        and
        ([.authorizations[] | select(.description == "homeassistant-prod-influxdb-read")] | length == 1)
        and
        ([.authorizations[] | select(.description == "homeassistant-prod-influxdb-write")][0].permissions == [
          {
            "action": "write",
            "resource": {
              "type": "buckets",
              "id": "bucket-id-raw",
              "orgID": "org-id-fake"
            }
          }
        ])
        and
        ([.authorizations[] | select(.description == "homeassistant-prod-influxdb-read")][0].permissions == [
          {
            "action": "read",
            "resource": {
              "type": "buckets",
              "id": "bucket-id-raw",
              "orgID": "org-id-fake"
            }
          }
        ])
      ' "$SERVER_STATE" >/dev/null; then
    test_pass "generic reconciler created both configured least-privilege tokens"
  else
    test_fail "generic reconciler did not create expected token set"
    jq '.authorizations, .calls' "$SERVER_STATE"
  fi
else
  test_fail "generic reconciler exited non-zero; log:"
  sed 's/^/    /' "$OUTPUT_LOG"
fi

runner_summary
