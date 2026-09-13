#!/usr/bin/env bash
# Diagnose or disable macOS NetworkExtension Local Network privacy enforcement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
NE_PLIST="/Library/Preferences/com.apple.networkextension.plist"

usage() {
  cat >&2 <<'EOF'
Usage: bootstrap-macos-local-network-tools.sh <status|apply|restore|verify> [backup.plist]

Commands:
  status            Show current Network Privacy PathController/default rule state.
  apply             Back up and disable Network Privacy path-rule enforcement.
                    Must be run as root, for example with sudo.
  restore <backup>  Restore a backup created by apply. Must be run as root.
  verify            Verify CLI clients can reach the Mycofu management services.

Why this exists:
  macOS Local Network privacy can NECP-block user-launched CLI tools such as
  tofu, glab, and Homebrew Python even when routes and firewall rules are valid.
  Mycofu's workstation path requires these tools to connect directly to the
  NAS PostgreSQL backend and self-hosted GitLab on the management network.

Warning:
  apply changes the workstation-wide NetworkExtension Local Network privacy
  policy. It is not scoped to Mycofu processes. Keep the printed backup path
  so the previous policy can be restored.
EOF
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: this helper is only for macOS workstations." >&2
    exit 1
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: this command must run as root. Use sudo." >&2
    exit 1
  fi
}

restart_networkextension() {
  launchctl kickstart -k system/com.apple.nehelper >/dev/null 2>&1 || true
  launchctl kickstart -k system/com.apple.nesessionmanager >/dev/null 2>&1 || true
}

patch_plist() {
  /usr/bin/python3 - "$NE_PLIST" <<'PY'
import os
import plistlib
import shutil
import sys
import tempfile
import time

path = sys.argv[1]

def deref(objects, value):
    if isinstance(value, plistlib.UID):
        return objects[value.data]
    return value

st = os.stat(path)
stamp = time.strftime("%Y%m%d%H%M%S")
backup = f"{path}.mycofu-backup-{stamp}"
shutil.copy2(path, backup)

with open(path, "rb") as f:
    data = plistlib.load(f)

objects = data["$objects"]
controllers_disabled = 0
rules_allowed = 0
default_rule_allowed = 0

for obj in objects:
    if isinstance(obj, dict) and "IgnoreRouteRules" in obj and "Rules" in obj:
        if obj.get("Enabled") is not False:
            obj["Enabled"] = False
            controllers_disabled += 1

for obj in objects:
    if not isinstance(obj, dict):
        continue

    signing_identifier = deref(objects, obj.get("SigningIdentifier"))
    if "DenyMulticast" in obj and obj.get("DenyMulticast") is not False:
        obj["DenyMulticast"] = False
        obj["MulticastPreferenceSet"] = True
        rules_allowed += 1

    if signing_identifier == "PathRuleDefaultNonSystemIdentifier":
        if obj.get("DenyMulticast") is not False:
            obj["DenyMulticast"] = False
        if obj.get("MulticastPreferenceSet") is not True:
            obj["MulticastPreferenceSet"] = True
        default_rule_allowed += 1

fd, tmp = tempfile.mkstemp(
    prefix="com.apple.networkextension.",
    suffix=".plist",
    dir=os.path.dirname(path),
)
try:
    with os.fdopen(fd, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass

print(f"backup={backup}")
print(f"controllers_disabled={controllers_disabled}")
print(f"rules_allowed={rules_allowed}")
print(f"default_rule_allowed={default_rule_allowed}")
PY
}

show_status() {
  /usr/bin/python3 - "$NE_PLIST" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)
objects = data["$objects"]

for i, obj in enumerate(objects):
    if isinstance(obj, dict) and "IgnoreRouteRules" in obj and "Rules" in obj:
        print(f"PathController {i} Enabled= {obj.get('Enabled')}")
    if isinstance(obj, dict):
        sid = obj.get("SigningIdentifier")
        if isinstance(sid, plistlib.UID) and objects[sid.data] == "PathRuleDefaultNonSystemIdentifier":
            print(
                f"DefaultRule {i} DenyMulticast= {obj.get('DenyMulticast')} "
                f"MulticastPreferenceSet= {obj.get('MulticastPreferenceSet')}"
            )
PY
}

restore_backup() {
  local backup="$1"
  if [[ -z "$backup" || ! -f "$backup" ]]; then
    echo "ERROR: backup file not found: ${backup}" >&2
    exit 1
  fi
  install -m 0644 -o root -g wheel "$backup" "$NE_PLIST"
}

verify_clients() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: site config not found: $CONFIG_FILE" >&2
    exit 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: yq" >&2
    echo "Run 'nix develop' from the repo root to enter the dev shell." >&2
    exit 1
  fi

  local nas_ip nas_pg_port gitlab_ip
  nas_ip="$(yq -r '.nas.ip // ""' "$CONFIG_FILE")"
  nas_pg_port="$(yq -r '.nas.postgres_port // ""' "$CONFIG_FILE")"
  gitlab_ip="$(yq -r '.vms.gitlab.ip // ""' "$CONFIG_FILE")"
  if [[ -z "$nas_ip" || "$nas_ip" == "null" || -z "$nas_pg_port" || "$nas_pg_port" == "null" || -z "$gitlab_ip" || "$gitlab_ip" == "null" ]]; then
    echo "ERROR: site/config.yaml must define nas.ip, nas.postgres_port, and vms.gitlab.ip" >&2
    exit 1
  fi

  echo "== Python socket checks =="
  local python_bin="${MYCOFU_VERIFY_PYTHON:-/usr/local/bin/python3}"
  if [[ ! -x "$python_bin" && -x /opt/homebrew/bin/python3 ]]; then
    python_bin="/opt/homebrew/bin/python3"
  fi
  if [[ ! -x "$python_bin" ]]; then
    echo "SKIP: $python_bin not found or not executable"
  else
    "$python_bin" - "$nas_ip" "$nas_pg_port" "$gitlab_ip" <<'PY'
import socket
import sys

targets = [
    ("NAS PostgreSQL", sys.argv[1], int(sys.argv[2])),
    ("GitLab HTTPS", sys.argv[3], 443),
]
failed = False
for label, host, port in targets:
    s = socket.socket()
    s.settimeout(3)
    try:
        s.connect((host, port))
        print(f"{label} {host}:{port} ok")
    except OSError as exc:
        failed = True
        print(f"{label} {host}:{port} FAIL: {exc}")
    finally:
        s.close()
if failed:
    sys.exit(1)
PY
  fi

  echo ""
  echo "== glab =="
  if command -v glab >/dev/null 2>&1; then
    glab api /version
  else
    echo "SKIP: glab not found"
  fi

  echo ""
  echo "== tofu backend init =="
  if command -v nix >/dev/null 2>&1; then
    (cd "$REPO_DIR" && framework/scripts/tofu-wrapper.sh init -input=false -no-color)
  else
    echo "SKIP: nix not on PATH; enter nix develop or add /nix/var/nix/profiles/default/bin to PATH."
  fi
}

main() {
  require_macos
  local cmd="${1:-}"
  case "$cmd" in
    status)
      show_status
      ;;
    apply)
      require_root
      patch_plist
      restart_networkextension
      show_status
      ;;
    restore)
      require_root
      restore_backup "${2:-}"
      restart_networkextension
      show_status
      ;;
    verify)
      verify_clients
      ;;
    --help|-h|"")
      usage
      ;;
    *)
      echo "ERROR: unknown command: $cmd" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
