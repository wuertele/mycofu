#!/usr/bin/env bash
# Shared hermetic fixture for Sprint 044 vdb park/adopt tests.

set -euo pipefail

vdb_fixture_make() {
  VDB_FIXTURE_REPO="${TMP_DIR}/vdb-repo"
  VDB_FIXTURE_SHIMS="${TMP_DIR}/vdb-shims"
  VDB_FIXTURE_STATE="${TMP_DIR}/vdb-state"
  VDB_EVENT_LOG="${TMP_DIR}/vdb-events.log"
  REAL_YQ_BIN="$(command -v yq)"

  rm -rf "$VDB_FIXTURE_REPO" "$VDB_FIXTURE_SHIMS" "$VDB_FIXTURE_STATE"
  mkdir -p \
    "${VDB_FIXTURE_REPO}/framework/scripts" \
    "${VDB_FIXTURE_REPO}/site" \
    "${VDB_FIXTURE_SHIMS}" \
    "${VDB_FIXTURE_STATE}/qm/pve01" \
    "${VDB_FIXTURE_STATE}/qm/pve02" \
    "${VDB_FIXTURE_STATE}/zfs/pve01" \
    "${VDB_FIXTURE_STATE}/zfs/pve02" \
    "${VDB_FIXTURE_STATE}/status/pve01" \
    "${VDB_FIXTURE_STATE}/status/pve02" \
    "${VDB_FIXTURE_STATE}/version"

  cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${VDB_FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
  cp "${REPO_ROOT}/framework/scripts/parked-vdb.sh" "${VDB_FIXTURE_REPO}/framework/scripts/parked-vdb.sh"
  chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh" "${VDB_FIXTURE_REPO}/framework/scripts/parked-vdb.sh"

  cat > "${VDB_FIXTURE_REPO}/site/config.yaml" <<'EOF'
environments:
  dev:
    vdb_park_bridge: true
  prod: {}
  shared: {}
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
proxmox:
  storage_pool: vmstore
storage:
  pool_name: vmstore
vms:
  app_dev:
    vmid: 101
    node: pve01
    backup: true
    data_disk_size: 50
  app2_dev:
    vmid: 102
    node: pve01
    backup: true
    data_disk_size: 20
  app_prod:
    vmid: 201
    node: pve01
    backup: true
    data_disk_size: 50
  shared_app:
    vmid: 301
    node: pve01
    backup: true
    data_disk_size: 50
  vendor_dev:
    vmid: 401
    node: pve01
    backup: true
    data_disk_size: 50
EOF
  cat > "${VDB_FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  cat > "${VDB_FIXTURE_REPO}/framework/scripts/vm-scope.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "classes" && "${2:-}" == "--format" && "${3:-}" == "json" ]]; then
  if [[ -n "${STUB_VM_SCOPE_FAIL:-}" ]]; then
    exit "$STUB_VM_SCOPE_FAIL"
  fi
  if [[ -n "${STUB_VM_SCOPE_UNKNOWN:-}" ]]; then
    cat <<'JSON'
{
  "app": {"category": "unknown", "control_plane": false},
  "app2": {"category": "nix", "control_plane": false},
  "shared_app": {"category": "nix", "control_plane": false},
  "vendor": {"category": "vendor", "control_plane": false}
}
JSON
    exit 0
  fi
  cat <<'JSON'
{
  "app": {"category": "nix", "control_plane": false},
  "app2": {"category": "nix", "control_plane": false},
  "shared_app": {"category": "nix", "control_plane": false},
  "vendor": {"category": "vendor", "control_plane": false}
}
JSON
  exit 0
fi
echo "unexpected vm-scope invocation: $*" >&2
exit 9
EOF
  chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/vm-scope.sh"

  echo "9.0.30" > "${VDB_FIXTURE_STATE}/version/pve01"
  echo "9.0.30" > "${VDB_FIXTURE_STATE}/version/pve02"
  cat > "${VDB_FIXTURE_STATE}/replication.json" <<'EOF'
[{"id":"101-0","guest":101,"target":"pve02"},{"id":"102-0","guest":102,"target":"pve02"}]
EOF
  : > "$VDB_EVENT_LOG"

  cat > "${VDB_FIXTURE_SHIMS}/yq" <<'EOF'
#!/usr/bin/env bash
exec "${REAL_YQ_BIN}" "$@"
EOF
  chmod +x "${VDB_FIXTURE_SHIMS}/yq"

  cat > "${VDB_FIXTURE_SHIMS}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

host=""
cmd=""
for arg in "$@"; do
  cmd="$arg"
  case "$arg" in
    root@*) host="$arg" ;;
  esac
done

case "$host" in
  root@10.0.0.1) node="pve01" ;;
  root@10.0.0.2) node="pve02" ;;
  *) node="pve01" ;;
esac

log() {
  printf '%s\n' "$*" >> "${VDB_EVENT_LOG}"
}

clean_cmd="${cmd//\'/}"
state="${VDB_FIXTURE_STATE}"

dataset_path() {
  printf '%s/zfs/%s/%s\n' "$state" "$node" "$1"
}

dataset_exists() {
  [[ -d "$(dataset_path "$1")" ]]
}

create_dataset() {
  local dataset="$1" guid="$2" size="$3"
  local path
  path="$(dataset_path "$dataset")"
  mkdir -p "$path/props"
  printf '%s\n' "$guid" > "$path/guid"
  printf '%s\n' "$size" > "$path/volsize"
  printf 'hash-%s\n' "$(basename "$dataset")" > "$path/sha256"
}

vm_config_path() {
  printf '%s/qm/%s/%s.conf\n' "$state" "$node" "$1"
}

vm_status_path() {
  printf '%s/status/%s/%s\n' "$state" "$node" "$1"
}

remove_config_key() {
  local vmid="$1" key="$2"
  local file
  file="$(vm_config_path "$vmid")"
  grep -v "^${key}:" "$file" > "${file}.tmp" || true
  mv "${file}.tmp" "$file"
}

add_config_line() {
  local vmid="$1" key="$2" value="$3"
  local file
  file="$(vm_config_path "$vmid")"
  remove_config_key "$vmid" "$key"
  printf '%s: %s\n' "$key" "$value" >> "$file"
}

if [[ "$clean_cmd" == "pvesh get /cluster/resources --type vm --output-format json" ]]; then
  if [[ -f "$state/cluster-resources-fail" ]]; then
    exit 7
  fi
  python3 - <<'PY'
import glob, json, os
state = os.environ["VDB_FIXTURE_STATE"]
rows = []
for path in glob.glob(os.path.join(state, "qm", "*", "*.conf")):
    node = path.split(os.sep)[-2]
    vmid = int(os.path.basename(path).split(".")[0])
    rows.append({"vmid": vmid, "name": f"vm-{vmid}", "node": node})
print(json.dumps(rows))
PY
  exit 0
fi

if [[ "$clean_cmd" == *"/cluster/ha/resources --output-format json"* ]]; then
  printf '%s\n' '[]'
  exit 0
fi

if [[ "$clean_cmd" == "pvesh get /cluster/replication --output-format json" ]]; then
  cat "$state/replication.json"
  exit 0
fi

if [[ "$clean_cmd" =~ pvesh\ set\ /cluster/replication/([^[:space:]]+)\ --disable\ ([01]) ]]; then
  log "pvesh disable ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  exit 0
fi

if [[ "$clean_cmd" == *"dpkg-query"*qemu-server* ]]; then
  cat "$state/version/$node"
  exit 0
fi

# #620: run_configure_backups probes PBS availability by SSHing to node
# pve01 and running `pvesm status`. Report pbs-nas as registered so
# post-success reconciliation runs configure-backups.sh (fixture stubs
# that script separately). Legacy inline "pvesm status | grep -q pbs-nas"
# callers get the same successful match.
if [[ "$clean_cmd" == *"pvesm status"* ]]; then
  if [[ "$clean_cmd" == *"pbs-nas"* ]]; then
    exit 0
  fi
  echo "pbs-nas pbs 1 100 200"
  exit 0
fi

if [[ "$clean_cmd" =~ qm\ status\ ([0-9]+) ]]; then
  vmid="${BASH_REMATCH[1]}"
  if [[ -f "$(vm_status_path "$vmid")" ]]; then
    status_value="$(cat "$(vm_status_path "$vmid")")"
    if [[ "$clean_cmd" == *"awk"* ]]; then
      printf '%s\n' "$status_value"
    else
      printf 'status: %s\n' "$status_value"
    fi
    exit 0
  fi
  exit 1
fi

if [[ "$clean_cmd" =~ qm\ stop\ ([0-9]+) ]]; then
  vmid="${BASH_REMATCH[1]}"
  count_file="$state/stop-count-${vmid}"
  count="$(cat "$count_file" 2>/dev/null || echo 0)"
  count=$((count + 1))
  echo "$count" > "$count_file"
  log "qm stop ${vmid}"
  if [[ ! -f "$state/stop-sticky-${vmid}" ]]; then
    echo stopped > "$(vm_status_path "$vmid")"
  fi
  exit 0
fi

if [[ "$clean_cmd" =~ qm\ start\ ([0-9]+) ]]; then
  vmid="${BASH_REMATCH[1]}"
  log "qm start ${vmid}"
  echo running > "$(vm_status_path "$vmid")"
  exit 0
fi

if [[ "$clean_cmd" =~ qm\ config\ ([0-9]+) ]]; then
  vmid="${BASH_REMATCH[1]}"
  file="$(vm_config_path "$vmid")"
  [[ -f "$file" ]] || exit 1
  if [[ "$clean_cmd" == *"/^unused[0-9]+:/"* ]]; then
    awk -F: '/^unused[0-9]+:/ {print $1; exit}' "$file"
  else
    cat "$file"
  fi
  exit 0
fi

if [[ "$clean_cmd" =~ qm\ set\ ([0-9]+)\ --delete\ ([a-z0-9]+) ]]; then
  vmid="${BASH_REMATCH[1]}"
  key="${BASH_REMATCH[2]}"
  file="$(vm_config_path "$vmid")"
  line="$(grep "^${key}:" "$file" 2>/dev/null || true)"
  log "qm delete ${vmid} ${key}"
  if [[ "$key" == scsi* ]]; then
    volid="$(printf '%s\n' "$line" | sed 's/^[^:]*:[[:space:]]*//;s/,.*//')"
    remove_config_key "$vmid" "$key"
    add_config_line "$vmid" unused0 "$volid"
  else
    volid="$(printf '%s\n' "$line" | sed 's/^[^:]*:[[:space:]]*//;s/,.*//')"
    remove_config_key "$vmid" "$key"
    if [[ "$volid" == vmstore:* ]]; then
      rm -rf "$(dataset_path "vmstore/data/${volid#vmstore:}")"
    fi
  fi
  exit 0
fi

if [[ "$clean_cmd" =~ qm\ set\ ([0-9]+)\ --(scsi[0-9]+)\ (.+)$ ]]; then
  vmid="${BASH_REMATCH[1]}"
  slot="${BASH_REMATCH[2]}"
  spec="${BASH_REMATCH[3]}"
  if [[ -f "$state/attach-fail-once-${vmid}" ]]; then
    rm -f "$state/attach-fail-once-${vmid}"
    log "qm attach-fail ${vmid} ${slot}"
    exit 5
  fi
  if [[ -f "$state/attach-fail-${vmid}" ]]; then
    log "qm attach-fail ${vmid} ${slot}"
    exit 5
  fi
  spec="${spec#\'}"
  spec="${spec%\'}"
  log "qm attach ${vmid} ${slot} ${spec}"
  add_config_line "$vmid" "$slot" "$spec"
  exit 0
fi

if [[ "$clean_cmd" =~ zfs\ list\ -H\ -o\ name,volsize\ -r\ ([^[:space:]]+) ]]; then
  if [[ -f "$state/scan-fail-${node}" ]]; then
    exit 8
  fi
  parent="${BASH_REMATCH[1]}"
  base="$(dataset_path "$parent")"
  if [[ -d "$base" ]]; then
    find "$base" -mindepth 1 -maxdepth 1 -type d | sort | while read -r path; do
      name="${parent}/$(basename "$path")"
      case "$name" in
        */mycofu-park-*-vdb)
          printf '%s\t%s\n' "$name" "$(cat "$path/volsize" 2>/dev/null || echo 50G)"
          ;;
      esac
    done
  fi
  exit 0
fi

if [[ "$clean_cmd" =~ zfs\ list\ -H\ -o\ name\ -r\ ([^[:space:]]+) ]]; then
  if [[ -f "$state/scan-fail-${node}" ]]; then
    exit 8
  fi
  parent="${BASH_REMATCH[1]}"
  base="$(dataset_path "$parent")"
  if [[ -d "$base" ]]; then
    find "$base" -mindepth 1 -maxdepth 1 -type d | sort | while read -r path; do
      name="${parent}/$(basename "$path")"
      case "$name" in
        */mycofu-park-*-vdb) printf '%s\n' "$name" ;;
      esac
    done
  fi
  exit 0
fi

if [[ "$clean_cmd" =~ zfs\ list\ -H\ -o\ name\ ([^[:space:]]+) ]]; then
  if [[ -f "$state/zfs-exists-fail-${node}" ]]; then
    exit 8
  fi
  dataset="${BASH_REMATCH[1]}"
  log "zfs list ${dataset}"
  if dataset_exists "$dataset"; then
    [[ "$clean_cmd" == *">/dev/null"* ]] || echo "$dataset"
    exit 0
  fi
  exit 1
fi

if [[ "$clean_cmd" =~ zfs\ get\ -H\ -o\ value\ guid\ ([^[:space:]]+) ]]; then
  dataset="${BASH_REMATCH[1]}"
  cat "$(dataset_path "$dataset")/guid"
  exit 0
fi

if [[ "$clean_cmd" =~ zfs\ get\ -H\ -o\ property,value\ all\ ([^[:space:]]+) ]]; then
  dataset="${BASH_REMATCH[1]}"
  prop_dir="$(dataset_path "$dataset")/props"
  if [[ -d "$prop_dir" ]]; then
    for prop in "$prop_dir"/*; do
      [[ -f "$prop" ]] || continue
      printf '%s\t%s\n' "$(basename "$prop")" "$(cat "$prop")"
    done
  fi
  exit 0
fi

if [[ "$clean_cmd" =~ zfs\ rename\ ([^[:space:]]+)\ ([^[:space:]]+) ]]; then
  old="${BASH_REMATCH[1]}"
  new="${BASH_REMATCH[2]}"
  log "zfs rename ${old} ${new}"
  if [[ -n "${STUB_RENAME_FAIL_NEW:-}" && "$new" == *"$STUB_RENAME_FAIL_NEW"* ]]; then
    exit 6
  fi
  old_path="$(dataset_path "$old")"
  new_path="$(dataset_path "$new")"
  mkdir -p "$(dirname "$new_path")"
  mv "$old_path" "$new_path"
  exit 0
fi

if [[ "$clean_cmd" =~ zfs\ set\ ([^=]+)=([^[:space:]]*)\ ([^[:space:]]+) ]]; then
  prop="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"
  dataset="${BASH_REMATCH[3]}"
  log "zfs set ${prop} ${dataset}"
  mkdir -p "$(dataset_path "$dataset")/props"
  printf '%s\n' "$value" > "$(dataset_path "$dataset")/props/${prop}"
  exit 0
fi

if [[ "$clean_cmd" =~ zfs\ inherit\ -r\ ([^[:space:]]+)\ ([^[:space:]]+) ]]; then
  prop="${BASH_REMATCH[1]}"
  dataset="${BASH_REMATCH[2]}"
  log "zfs inherit ${prop} ${dataset}"
  rm -f "$(dataset_path "$dataset")/props/${prop}"
  exit 0
fi

if [[ "$clean_cmd" =~ zfs\ destroy\ -r\ ([^[:space:]]+) ]]; then
  dataset="${BASH_REMATCH[1]}"
  log "zfs destroy ${dataset}"
  rm -rf "$(dataset_path "$dataset")"
  exit 0
fi

if [[ "$clean_cmd" =~ pvesm\ alloc\ ([^[:space:]]+)\ ([0-9]+)\ ([^[:space:]]+)\ ([^[:space:]]+) ]]; then
  storage="${BASH_REMATCH[1]}"
  vmid="${BASH_REMATCH[2]}"
  volname="${BASH_REMATCH[3]}"
  size="${BASH_REMATCH[4]}"
  log "pvesm alloc ${storage} ${vmid} ${volname} ${size}"
  create_dataset "${storage}/data/${volname}" "alloc-${vmid}-${volname}" "$size"
  exit 0
fi

if [[ "$clean_cmd" =~ sha256sum\ /dev/zvol/([^[:space:]]+) ]]; then
  dataset="${BASH_REMATCH[1]}"
  hash_file="$(dataset_path "$dataset")/sha256"
  if [[ "$clean_cmd" == *"awk"* ]]; then
    printf '%s\n' "$(cat "$hash_file")"
  else
    printf '%s  /dev/zvol/%s\n' "$(cat "$hash_file")" "$dataset"
  fi
  exit 0
fi

if [[ "$clean_cmd" == *"qm_rows=\$(qm list"* && "$clean_cmd" == *"grep -F mycofu-park-"* ]]; then
  if [[ -f "$state/reference-qm-list-fail-${node}" ]]; then
    exit 8
  fi
  if [[ -f "$state/reference-config-fail-${node}" || -f "$state/reference-scan-fail-${node}" ]]; then
    exit 9
  fi
  park="$(sed -n 's/.*grep -F \([^ >]*\).*/\1/p' <<< "$clean_cmd")"
  if grep -R "$park" "$state/qm" >/dev/null 2>&1; then
    grep -R "$park" "$state/qm"
    exit 0
  fi
  exit 1
fi

if [[ "$clean_cmd" == *"grep -F mycofu-park-"* ]]; then
  if [[ -f "$state/reference-scan-fail-${node}" ]]; then
    exit 9
  fi
  park="$(sed -n 's/.*grep -F \([^ ]*\).*/\1/p' <<< "$clean_cmd")"
  if grep -R "$park" "$state/qm" >/dev/null 2>&1; then
    grep -R "$park" "$state/qm"
    exit 0
  fi
  exit 1
fi

echo "unhandled ssh command on ${node}: ${cmd}" >&2
exit 99
EOF
  chmod +x "${VDB_FIXTURE_SHIMS}/ssh"
}

vdb_fixture_reset_log() {
  : > "$VDB_EVENT_LOG"
}

vdb_fixture_dataset_path() {
  printf '%s/zfs/%s/%s\n' "$VDB_FIXTURE_STATE" "$1" "$2"
}

vdb_fixture_create_dataset() {
  local node="$1" dataset="$2" guid="$3" size="$4" hash="${5:-}"
  local path
  path="$(vdb_fixture_dataset_path "$node" "$dataset")"
  mkdir -p "$path/props"
  printf '%s\n' "$guid" > "$path/guid"
  printf '%s\n' "$size" > "$path/volsize"
  if [[ -z "$hash" ]]; then
    hash="hash-$(basename "$dataset")"
  fi
  printf '%s\n' "$hash" > "$path/sha256"
}

vdb_fixture_set_prop() {
  local node="$1" dataset="$2" prop="$3" value="$4"
  mkdir -p "$(vdb_fixture_dataset_path "$node" "$dataset")/props"
  printf '%s\n' "$value" > "$(vdb_fixture_dataset_path "$node" "$dataset")/props/${prop}"
}

vdb_fixture_set_vm() {
  local node="$1" vmid="$2" status="$3" config="$4"
  mkdir -p "${VDB_FIXTURE_STATE}/qm/${node}" "${VDB_FIXTURE_STATE}/status/${node}"
  printf '%s\n' "$config" > "${VDB_FIXTURE_STATE}/qm/${node}/${vmid}.conf"
  printf '%s\n' "$status" > "${VDB_FIXTURE_STATE}/status/${node}/${vmid}"
}

vdb_fixture_remove_vm() {
  local node="$1" vmid="$2"
  rm -f "${VDB_FIXTURE_STATE}/qm/${node}/${vmid}.conf" "${VDB_FIXTURE_STATE}/status/${node}/${vmid}"
}

vdb_fixture_manifest() {
  local file="$1"
  shift
  {
    printf '{"version":1,"scope":"dev","entries":['
    local first=1
    local entry
    for entry in "$@"; do
      [[ "$first" -eq 0 ]] && printf ','
      first=0
      printf '%s' "$entry"
    done
    printf ']}\n'
  } > "$file"
}

vdb_fixture_entry() {
  local label="$1" vmid="$2" env="$3" size="$4"
  local pin="${5:-}" trust="${6:-trusted}"
  if [[ -z "$pin" ]]; then
    pin="pbs:backup/vm/${vmid}/pin"
  fi
  jq -n \
    --arg label "$label" \
    --argjson vmid "$vmid" \
    --arg env "$env" \
    --arg size "$size" \
    --arg pin "$pin" \
    --arg trust "$trust" \
    '{label: $label, module: ("module." + $label), vmid: $vmid, env: $env, kind: "application", reason: "replace", data_disk_size_gb: ($size|tonumber), expected_disks: ["scsi0","scsi1"], pin: {volid: $pin, trust: $trust}}'
}

vdb_fixture_run_lib() {
  local script="$1"
  shift
  PATH="${VDB_FIXTURE_SHIMS}:${PATH}" \
    REAL_YQ_BIN="$REAL_YQ_BIN" \
    VDB_FIXTURE_STATE="$VDB_FIXTURE_STATE" \
    VDB_EVENT_LOG="$VDB_EVENT_LOG" \
    bash -c "cd \"$VDB_FIXTURE_REPO\" && source framework/scripts/vdb-park-lib.sh && $script" "$@"
}

vdb_fixture_run_cmd() {
  PATH="${VDB_FIXTURE_SHIMS}:${PATH}" \
    REAL_YQ_BIN="$REAL_YQ_BIN" \
    VDB_FIXTURE_STATE="$VDB_FIXTURE_STATE" \
    VDB_EVENT_LOG="$VDB_EVENT_LOG" \
    "$@"
}
