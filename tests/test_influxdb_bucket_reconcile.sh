#!/usr/bin/env bash
# Hermetic test for framework/catalog/influxdb/bucket-reconcile.sh.
#
# Spins up a small Python mock InfluxDB API server that tracks bucket
# state in memory, then invokes the reconciler against it with various
# inputs and asserts the right side-effects (or no side-effects).
#
# Requires: python3, curl, jq, bash.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/framework/catalog/influxdb/bucket-reconcile.sh"

source "${REPO_ROOT}/tests/lib/runner.sh"

WORK="$(mktemp -d -t influxdb-bucket-reconcile-test-XXXXXX)"
SERVER_PORT=0
SERVER_PID=0
SERVER_STATE="${WORK}/server-state.json"
SERVER_LOG="${WORK}/server.log"

cleanup() {
  if [[ "$SERVER_PID" -ne 0 ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- Pick an ephemeral port (avoid hardcoded port collisions) ---
SERVER_PORT="$(python3 -c 'import socket,sys
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# --- Write the mock server ---
cat > "${WORK}/mock_server.py" <<'PYEOF'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

STATE_FILE = os.environ["STATE_FILE"]

def load():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {"buckets": {}, "next_id": 1, "calls": []}

def save(s):
    with open(STATE_FILE, "w") as f:
        json.dump(s, f)

class H(BaseHTTPRequestHandler):
    def log_message(self, *args, **kw):
        pass  # silence default access log; we log via state["calls"]

    def _read_body(self):
        n = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(n) if n else b""

    def _record(self, action):
        s = load(); s["calls"].append(action); save(s)

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        p = urlparse(self.path); q = parse_qs(p.query)
        if p.path == "/health":
            self._send(200, {"status": "pass"})
            return
        if p.path == "/api/v2/orgs":
            org = (q.get("org") or [""])[0]
            self._record({"op": "list_orgs", "org": org})
            self._send(200, {"orgs": [{"id": "org-id-fake", "name": org}]})
            return
        if p.path == "/api/v2/buckets":
            s = load()
            buckets = list(s["buckets"].values())
            self._record({"op": "list_buckets"})
            self._send(200, {"buckets": buckets})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/api/v2/buckets":
            body = json.loads(self._read_body())
            s = load()
            bid = f"bucket-id-{s['next_id']}"
            s["next_id"] += 1
            b = {"id": bid, "name": body["name"], "orgID": body["orgID"],
                 "retentionRules": body.get("retentionRules", [])}
            s["buckets"][bid] = b
            s["calls"].append({"op": "create_bucket", "name": body["name"],
                                "retentionRules": body.get("retentionRules", [])})
            save(s)
            self._send(201, b)
            return
        self._send(404, {"error": "not found"})

    def do_PATCH(self):
        m = re.match(r"^/api/v2/buckets/([^/]+)$", self.path)
        if m:
            bid = m.group(1)
            body = json.loads(self._read_body())
            s = load()
            if bid not in s["buckets"]:
                self._send(404, {"error": "bucket not found"}); return
            s["buckets"][bid]["retentionRules"] = body.get("retentionRules", [])
            s["calls"].append({"op": "patch_bucket", "id": bid,
                                "retentionRules": body.get("retentionRules", [])})
            save(s)
            self._send(200, s["buckets"][bid])
            return
        self._send(404, {"error": "not found"})

if __name__ == "__main__":
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

# --- Start the server ---
STATE_FILE="$SERVER_STATE" python3 "${WORK}/mock_server.py" "$SERVER_PORT" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait until /health responds
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

# --- Common fixture setup helpers ---
reset_state() {
  echo '{"buckets":{},"next_id":1,"calls":[]}' > "$SERVER_STATE"
}

write_setup_json() {
  cat > "${WORK}/setup.json" <<EOF
{
  "org": "homelab",
  "bucket": "default",
  "retention": "30d",
  "username": "admin"
}
EOF
}

write_token() {
  echo "test-admin-token" > "${WORK}/token"
}

write_buckets_json() {
  cat > "${WORK}/buckets.json" <<EOF
${1}
EOF
}

remove_buckets_json() {
  rm -f "${WORK}/buckets.json"
}

# Run the reconciler with the standard env. Returns the script's exit code
# in $? and writes stdout+stderr to ${WORK}/output.log.
run_reconciler() {
  set +e
  INFLUXDB_HOST="http://127.0.0.1:${SERVER_PORT}" \
  INFLUXDB_TOKEN_FILE="${WORK}/token" \
  INFLUXDB_BUCKETS_FILE="${WORK}/buckets.json" \
  INFLUXDB_SETUP_FILE="${WORK}/setup.json" \
  INFLUXDB_INSECURE=0 \
  INFLUXDB_WAIT_TIMEOUT=5 \
    bash "$SCRIPT" >"${WORK}/output.log" 2>&1
  local rc=$?
  set -e
  return $rc
}

calls_count_of() {
  jq --arg op "$1" '[.calls[] | select(.op == $op)] | length' "$SERVER_STATE"
}

# ============================================================================
# Test cases
# ============================================================================

# --- T1: script passes bash -n ---
test_start "1" "bucket-reconcile.sh passes bash -n"
if bash -n "$SCRIPT"; then
  test_pass "syntax check passes"
else
  test_fail "syntax check failed"
fi

# --- T2: script is executable ---
test_start "2" "bucket-reconcile.sh is executable"
if [[ -x "$SCRIPT" ]]; then
  test_pass "executable bit set"
else
  test_fail "script is not executable"
fi

# --- T3: skips when buckets.json absent ---
test_start "3" "exits 0 with skip message when buckets.json is absent"
reset_state; write_setup_json; write_token; remove_buckets_json
if run_reconciler && grep -q "skipping bucket reconciliation" "${WORK}/output.log"; then
  if [[ "$(calls_count_of list_buckets)" == "0" ]]; then
    test_pass "exit 0, skip logged, no API calls made"
  else
    test_fail "made API calls despite no buckets.json"
  fi
else
  test_fail "expected exit 0 with skip message; log:"
  sed 's/^/    /' "${WORK}/output.log"
fi

# --- T4: creates missing buckets ---
test_start "4" "creates buckets that don't exist in InfluxDB"
reset_state; write_setup_json; write_token
write_buckets_json '[
  {"name": "default",           "retention": "30d"},
  {"name": "homeassistant_raw", "retention": "90d"},
  {"name": "homeassistant_1h",  "retention": "0"}
]'
if run_reconciler; then
  c="$(calls_count_of create_bucket)"
  if [[ "$c" == "3" ]]; then
    test_pass "created 3 buckets"
  else
    test_fail "expected 3 creates, got $c"
  fi
else
  test_fail "reconciler exited non-zero; log:"
  sed 's/^/    /' "${WORK}/output.log"
fi

# --- T5: retention values translate correctly ---
test_start "5" "retention strings parse to expected everySeconds"
default_secs="$(jq -r '
  [.buckets[] | select(.name == "default") | .retentionRules[0].everySeconds][0]
' "$SERVER_STATE")"
raw_secs="$(jq -r '
  [.buckets[] | select(.name == "homeassistant_raw") | .retentionRules[0].everySeconds][0]
' "$SERVER_STATE")"
infinite="$(jq -r '
  [.buckets[] | select(.name == "homeassistant_1h") | .retentionRules | length][0]
' "$SERVER_STATE")"
if [[ "$default_secs" == "2592000" && "$raw_secs" == "7776000" && "$infinite" == "0" ]]; then
  test_pass "30d=2592000s, 90d=7776000s, 0=empty rules"
else
  test_fail "got default=$default_secs raw=$raw_secs infinite_rules_len=$infinite"
fi

# --- T6: idempotent — running again creates nothing ---
test_start "6" "second run is a no-op (no creates, no patches)"
# Don't reset state — buckets exist from T4
echo '[]' > "${WORK}/server-state-marker"
prev_creates="$(calls_count_of create_bucket)"
prev_patches="$(calls_count_of patch_bucket)"
if run_reconciler; then
  cur_creates="$(calls_count_of create_bucket)"
  cur_patches="$(calls_count_of patch_bucket)"
  if [[ "$cur_creates" == "$prev_creates" && "$cur_patches" == "$prev_patches" ]]; then
    test_pass "no additional creates or patches"
  else
    test_fail "expected creates=$prev_creates patches=$prev_patches; got creates=$cur_creates patches=$cur_patches"
  fi
else
  test_fail "reconciler exited non-zero on idempotent re-run"
fi

# --- T7: updates retention when it differs ---
test_start "7" "PATCHes retention when buckets.json value differs from existing"
# Keep state from T4/T6, change default's retention from 30d to 60d
write_buckets_json '[
  {"name": "default", "retention": "60d"}
]'
prev_patches="$(calls_count_of patch_bucket)"
if run_reconciler; then
  cur_patches="$(calls_count_of patch_bucket)"
  default_secs="$(jq -r '
    [.buckets[] | select(.name == "default") | .retentionRules[0].everySeconds][0]
  ' "$SERVER_STATE")"
  if [[ "$cur_patches" == "$((prev_patches + 1))" && "$default_secs" == "5184000" ]]; then
    test_pass "one patch issued, retention now 5184000s (60d)"
  else
    test_fail "expected patches=+1 and 60d; got patches=$((cur_patches - prev_patches)) secs=$default_secs"
  fi
else
  test_fail "reconciler exited non-zero on update"
fi

# --- T8: never deletes buckets removed from buckets.json ---
test_start "8" "does NOT delete buckets that are absent from buckets.json"
# State has 'default', 'homeassistant_raw', 'homeassistant_1h' from T4
# buckets.json from T7 only mentions 'default' — the other two should survive
remaining="$(jq -r '[.buckets[] | .name] | sort | join(",")' "$SERVER_STATE")"
if [[ "$remaining" == "default,homeassistant_1h,homeassistant_raw" ]]; then
  test_pass "all 3 buckets still exist (no delete)"
else
  test_fail "expected all 3 buckets; got: $remaining"
fi

# --- T9: rejects malformed buckets.json ---
test_start "9" "exits 1 when buckets.json is not a JSON array"
write_buckets_json '{"name": "oops"}'
if ! run_reconciler; then
  if grep -q "must contain a JSON array" "${WORK}/output.log"; then
    test_pass "exit 1 with array-required error"
  else
    test_fail "exit 1 but message didn't mention array requirement; log:"
    sed 's/^/    /' "${WORK}/output.log"
  fi
else
  test_fail "expected non-zero exit on malformed JSON"
fi

# --- T10: rejects entries missing 'name' ---
test_start "10" "exits 1 when bucket entry is missing 'name'"
write_buckets_json '[{"retention": "30d"}]'
if ! run_reconciler; then
  if grep -q "non-empty 'name' string" "${WORK}/output.log"; then
    test_pass "exit 1 with name-required error"
  else
    test_fail "exit 1 but message didn't mention name requirement; log:"
    sed 's/^/    /' "${WORK}/output.log"
  fi
else
  test_fail "expected non-zero exit on missing name"
fi

# --- T11: missing token file ---
test_start "11" "exits 1 when token file is absent"
write_buckets_json '[{"name":"x","retention":"1d"}]'
rm -f "${WORK}/token"
if ! run_reconciler; then
  if grep -q "admin token file not found" "${WORK}/output.log"; then
    test_pass "exit 1 with token-not-found error"
  else
    test_fail "exit 1 but message didn't mention token; log:"
    sed 's/^/    /' "${WORK}/output.log"
  fi
else
  test_fail "expected non-zero exit when token absent"
fi

# --- T12: missing setup.json ---
test_start "12" "exits 1 when setup.json is absent"
write_token
rm -f "${WORK}/setup.json"
if ! run_reconciler; then
  if grep -q "setup.json not found" "${WORK}/output.log"; then
    test_pass "exit 1 with setup-not-found error"
  else
    test_fail "exit 1 but message didn't mention setup; log:"
    sed 's/^/    /' "${WORK}/output.log"
  fi
else
  test_fail "expected non-zero exit when setup.json absent"
fi

# --- T13: bad token (401) surfaces with informative error ---
# Restore inputs and switch mock to a 401-returning variant.
test_start "13" "401 from InfluxDB surfaces with operation + status + body"
reset_state; write_setup_json; write_token
write_buckets_json '[{"name":"x","retention":"1d"}]'
# Swap server: kill the current one and start a 401 variant for this test.
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
cat > "${WORK}/mock_server_401.py" <<'PYEOF'
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a, **k): pass
    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({"status": "pass"}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        body = json.dumps({"code": "unauthorized", "message": "unauthorized access"}).encode()
        self.send_response(401); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
python3 "${WORK}/mock_server_401.py" "$SERVER_PORT" >"${WORK}/server-401.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${SERVER_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! run_reconciler; then
  if grep -qE "API error: GET .*/api/v2/orgs -> HTTP 401" "${WORK}/output.log" \
      && grep -q "unauthorized access" "${WORK}/output.log"; then
    test_pass "exit 1 with operation, HTTP 401, and response body in error"
  else
    test_fail "exit 1 but error didn't include operation+status+body; log:"
    sed 's/^/    /' "${WORK}/output.log"
  fi
else
  test_fail "expected non-zero exit on 401"
fi
# Kill the 401 server before exit; trap cleanup will mop up if needed.
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=0

# --- T14: too many buckets (>100) → fail before any API calls ---
test_start "14" "buckets.json with >100 entries is rejected at validation time"
# Server is dead; we don't need it because validation runs before any API call.
write_token; write_setup_json
python3 -c '
import json
print(json.dumps([{"name": f"b{i:03d}", "retention": "1d"} for i in range(101)]))
' > "${WORK}/buckets.json"
if ! run_reconciler; then
  if grep -q "supports at most 100" "${WORK}/output.log"; then
    test_pass "exit 1 with at-most-100 message before any API call"
  else
    test_fail "exit 1 but message wasn't the count guardrail; log:"
    sed 's/^/    /' "${WORK}/output.log"
  fi
else
  test_fail "expected non-zero exit on >100 buckets"
fi

# --- T15: retention parser rejects invalid forms ---
test_start "15" "retention parser rejects negatives, decimals, leading zeros, and junk"
# We can't easily invoke parse_retention_seconds standalone without sourcing,
# so we test via the script's own input validation: place each bad value in
# buckets.json and confirm a clean die instead of a shell arithmetic crash.
for bad in '-1d' '1.5h' '010d' 'abc' '5 d'; do
  write_token; write_setup_json
  cat > "${WORK}/buckets.json" <<EOF
[{"name":"x","retention":"${bad}"}]
EOF
  # Server is dead from T13/T14; the validation we want to test runs at
  # entry, before /health is queried. Use a very short wait timeout so
  # the test fails fast if the validation doesn't trigger.
  INFLUXDB_WAIT_TIMEOUT=2 run_reconciler && rc=$? || rc=$?
  if [[ $rc -ne 0 ]] && grep -q "Invalid retention string: '${bad}'" "${WORK}/output.log"; then
    : # OK
  else
    test_fail "expected reject for '${bad}', got rc=$rc; log:"
    sed 's/^/    /' "${WORK}/output.log"
    break
  fi
done
test_pass "rejected all 5 invalid retention forms with clean die"

runner_summary
