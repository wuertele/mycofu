#!/usr/bin/env bash
# configure-nas.sh — Deploy PostgreSQL and backup on NAS, verify NFS export
#
# Usage:
#   framework/scripts/configure-nas.sh                    # Deploy PostgreSQL, verify NFS
#   framework/scripts/configure-nas.sh --dry-run           # Show what would be done
#   framework/scripts/configure-nas.sh --verify            # Verify current state only
#   framework/scripts/configure-nas.sh --password <pass>   # Provide password directly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_PATH="${REPO_DIR}/site/config.yaml"
DRY_RUN=0
VERIFY_ONLY=0
PG_PASSWORD=""
ERRORS=0

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)    CONFIG_PATH="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --verify)    VERIFY_ONLY=1; shift ;;
    --password)  PG_PASSWORD="$2"; shift 2 ;;
    -*)          echo "Unknown option: $1" >&2; exit 2 ;;
    *)           echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_PATH}" >&2
  exit 2
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not installed" >&2
  exit 2
fi

# --- Read config ---
NAS_IP=$(yq '.nas.ip' "$CONFIG_PATH")
NAS_HOSTNAME=$(yq '.nas.hostname' "$CONFIG_PATH")
NAS_SSH_USER=$(yq '.nas.ssh_user // "root"' "$CONFIG_PATH")
NAS_NFS_EXPORT=$(yq '.nas.nfs_export' "$CONFIG_PATH")
NAS_PG_PORT=$(yq '.nas.postgres_port' "$CONFIG_PATH")
NAS_URL=$(yq '.platforms.nas.url // ""' "$CONFIG_PATH")
MGMT_SUBNET=$(yq '.management.subnet' "$CONFIG_PATH")
FIRST_NODE_IP=$(yq '.nodes[0].mgmt_ip' "$CONFIG_PATH")
FIRST_NODE_NAME=$(yq '.nodes[0].name' "$CONFIG_PATH")
POSTGRES_METHOD=$(yq '.nas.postgres_method // "native"' "$CONFIG_PATH")

# Conditional sudo — root doesn't need it, and some NAS configs don't have it
if [[ "$NAS_SSH_USER" == "root" ]]; then
  SUDO=""
else
  SUDO="sudo "
fi

# Collect environment names for schema creation
ENV_NAMES=()
while IFS= read -r env; do
  ENV_NAMES+=("$env")
done < <(yq '.environments | keys | .[]' "$CONFIG_PATH")

PG_DB="tofu_state"
PG_USER="tofu"

# --- SSH helpers ---
# Synology's root SSH session has a minimal PATH that excludes /usr/local/bin
# where Docker and other packages are installed. Prepend it explicitly.
NAS_PATH_PREFIX="PATH=/usr/local/bin:\$PATH"

ssh_nas() {
  local cmd="$1"
  ssh -n -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "${NAS_SSH_USER}@${NAS_IP}" "${NAS_PATH_PREFIX}; $cmd" 2>/dev/null
}

ssh_nas_sudo() {
  local cmd="$1"
  ssh -n -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "${NAS_SSH_USER}@${NAS_IP}" "${NAS_PATH_PREFIX}; ${SUDO}$cmd" 2>/dev/null
}

ssh_node() {
  local ip="$1"; shift
  ssh -n -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

# Run psql as the postgres system user on the NAS
psql_nas() {
  local sql="$1"
  ssh_nas "${SUDO}su - postgres -c \"psql -tAc \\\"${sql}\\\"\""
}

# --- Password resolution (3-tier cascade) ---
resolve_password() {
  # 1. --password flag (already set)
  if [[ -n "$PG_PASSWORD" ]]; then
    echo "  ✓ Password provided via --password flag"
    return 0
  fi

  # 2. SOPS decryption
  local sops_file="${REPO_DIR}/site/sops/secrets.yaml"
  local key_file="${REPO_DIR}/operator.age.key"
  if [[ -f "$sops_file" && -f "$key_file" ]] && command -v sops &>/dev/null; then
    local decrypted
    decrypted=$(SOPS_AGE_KEY_FILE="$key_file" sops -d "$sops_file" 2>/dev/null) || true
    if [[ -n "$decrypted" ]]; then
      PG_PASSWORD=$(echo "$decrypted" | yq '.tofu_db_password' 2>/dev/null) || true
      if [[ -n "$PG_PASSWORD" && "$PG_PASSWORD" != "null" ]]; then
        echo "  ✓ Password read from SOPS secrets"
        return 0
      fi
    fi
  fi

  # 3. Interactive prompt
  if [[ -t 0 ]]; then
    read -sp "  PostgreSQL password: " PG_PASSWORD
    echo ""
    if [[ -n "$PG_PASSWORD" ]]; then
      echo "  ✓ Password provided interactively"
      return 0
    fi
  fi

  echo "  ✗ No password available (use --password, SOPS, or interactive prompt)" >&2
  return 1
}

# --- Check NAS connectivity ---
check_connectivity() {
  echo ""
  echo "--- Connectivity ---"
  if ! ping -c 1 -W 3 "$NAS_IP" &>/dev/null; then
    echo "  ✗ NAS (${NAS_IP}) is not reachable"
    return 1
  fi
  echo "  ✓ NAS (${NAS_IP}) reachable"

  if ! ssh_nas "echo ok" &>/dev/null; then
    echo "  ✗ SSH to ${NAS_SSH_USER}@${NAS_IP} failed"
    return 1
  fi
  echo "  ✓ SSH to ${NAS_SSH_USER}@${NAS_IP} working"
  return 0
}

# ============================================================
# Native PostgreSQL
# ============================================================

deploy_postgres_native() {
  echo ""
  echo "=== PostgreSQL Deployment (native) ==="

  if ! check_connectivity; then
    return 1
  fi

  # Check PostgreSQL is running
  echo ""
  echo "--- PostgreSQL service ---"
  if ssh_nas "pg_isready -h localhost" &>/dev/null; then
    echo "  ✓ PostgreSQL is running"
  else
    echo "  PostgreSQL is not running, attempting to start..."
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would run: synoservice --start pkgctl-PostgreSQL"
    else
      ssh_nas_sudo "synoservice --start pkgctl-PostgreSQL" || true
      sleep 3
      if ssh_nas "pg_isready -h localhost" &>/dev/null; then
        echo "  ✓ PostgreSQL started"
      else
        echo "  ✗ Failed to start PostgreSQL"
        return 1
      fi
    fi
  fi

  # Create user (idempotent)
  echo ""
  echo "--- User and database ---"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would create user '${PG_USER}' if not exists"
    echo "  [DRY RUN] Would create database '${PG_DB}' if not exists"
    for env in "${ENV_NAMES[@]}"; do
      echo "  [DRY RUN] Would create schema '${env}' if not exists"
    done
  else
    # Create user if not exists
    local user_exists
    user_exists=$(ssh_nas "${SUDO}su - postgres -c \"psql -tAc \\\"SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}';\\\"\"") || user_exists=""
    if [[ "$user_exists" == "1" ]]; then
      echo "  ✓ User '${PG_USER}' already exists"
    else
      # Pipe SQL via stdin to avoid shell expansion of special chars in password
      echo "CREATE ROLE ${PG_USER} WITH LOGIN PASSWORD '${PG_PASSWORD}';" \
        | ssh -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
              "${NAS_SSH_USER}@${NAS_IP}" "${NAS_PATH_PREFIX}; ${SUDO}su - postgres -c 'psql'" 2>/dev/null
      echo "  ✓ Created user '${PG_USER}'"
    fi

    # Create database if not exists
    local db_exists
    db_exists=$(ssh_nas "${SUDO}su - postgres -c \"psql -tAc \\\"SELECT 1 FROM pg_database WHERE datname='${PG_DB}';\\\"\"") || db_exists=""
    if [[ "$db_exists" == "1" ]]; then
      echo "  ✓ Database '${PG_DB}' already exists"
    else
      ssh_nas "${SUDO}su - postgres -c \"psql -c \\\"CREATE DATABASE ${PG_DB} OWNER ${PG_USER};\\\"\""
      echo "  ✓ Created database '${PG_DB}'"
    fi

    # Create schemas
    echo ""
    echo "--- Schemas ---"
    for env in "${ENV_NAMES[@]}"; do
      ssh_nas "${SUDO}su - postgres -c \"psql -d ${PG_DB} -c \\\"CREATE SCHEMA IF NOT EXISTS ${env} AUTHORIZATION ${PG_USER};\\\"\""
      echo "  ✓ Schema '${env}' exists"
    done
  fi

  # Configure pg_hba.conf for remote access
  echo ""
  echo "--- Remote access (pg_hba.conf) ---"
  # Ask PostgreSQL for the actual hba_file path (Synology DSM overrides this to /etc/postgresql/)
  local hba_file
  hba_file=$(ssh_nas "${SUDO}su - postgres -c \"psql -tAc 'SHOW hba_file;'\"" | tr -d '[:space:]')
  if [[ -z "$hba_file" ]]; then
    hba_file="/var/services/pgsql/pg_hba.conf"
    echo "  ⊘ Could not query hba_file, falling back to ${hba_file}"
  fi
  local hba_line="host ${PG_DB} ${PG_USER} ${MGMT_SUBNET} md5"
  local hba_exists
  hba_exists=$(ssh_nas "grep -c '${PG_USER}' ${hba_file} || true")

  if [[ "$hba_exists" -ge 1 ]]; then
    echo "  ✓ pg_hba.conf already has ${PG_USER} access rule (${hba_file})"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would append to ${hba_file}: ${hba_line}"
      echo "  [DRY RUN] Would reload PostgreSQL"
    else
      ssh_nas "echo '${hba_line}' >> ${hba_file}"
      echo "  ✓ Added pg_hba.conf rule: ${hba_line} (${hba_file})"
      ssh_nas "${SUDO}su - postgres -c 'pg_ctl reload -D /var/services/pgsql'" || \
        ssh_nas "kill -HUP \$(head -1 /var/services/pgsql/postmaster.pid)" || true
      echo "  ✓ PostgreSQL reloaded"
    fi
  fi

  # Configure listen_addresses for remote access
  echo ""
  echo "--- Listen addresses ---"
  local listen_all
  listen_all=$(ssh_nas "grep -c \"listen_addresses = '\\*'\" /var/services/pgsql/postgresql.conf || true")
  if [[ "$listen_all" -ge 1 ]]; then
    echo "  ✓ PostgreSQL already listening on all interfaces"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would set listen_addresses = '*' in postgresql.conf"
      echo "  [DRY RUN] Would restart PostgreSQL"
    else
      # Replace or append listen_addresses
      local has_listen
      has_listen=$(ssh_nas "grep -c 'listen_addresses' /var/services/pgsql/postgresql.conf || true")
      if [[ "$has_listen" -ge 1 ]]; then
        ssh_nas "sed -i \"s/^[#]*listen_addresses.*/listen_addresses = '*'/\" /var/services/pgsql/postgresql.conf"
      else
        ssh_nas "echo \"listen_addresses = '*'\" >> /var/services/pgsql/postgresql.conf"
      fi
      echo "  ✓ Set listen_addresses = '*'"
      # Restart required for listen_addresses change
      ssh_nas_sudo "synoservice --restart pkgctl-PostgreSQL" || \
        ssh_nas "${SUDO}su - postgres -c 'pg_ctl restart -D /var/services/pgsql'" || true
      echo "  Waiting for PostgreSQL to restart..."
      sleep 3
      local attempts=0
      while (( attempts < 10 )); do
        if ssh_nas "pg_isready -h localhost" &>/dev/null; then
          echo "  ✓ PostgreSQL restarted and ready"
          break
        fi
        (( attempts++ ))
        sleep 2
      done
      if (( attempts >= 10 )); then
        echo "  ✗ Timed out waiting for PostgreSQL restart"
        return 1
      fi
    fi
  fi

  return 0
}

verify_postgres_native() {
  echo ""
  echo "--- PostgreSQL verification (native) ---"
  local fail=0

  # pg_isready
  if ssh_nas "pg_isready -h localhost" &>/dev/null; then
    echo "  ✓ PostgreSQL is running (pg_isready)"
  else
    echo "  ✗ PostgreSQL is not running"
    fail=1
  fi

  # TCP port check — verify PostgreSQL is accepting connections on the network interface
  if ssh_nas "pg_isready -h 0.0.0.0 -p ${NAS_PG_PORT}" &>/dev/null 2>&1; then
    echo "  ✓ Accepting connections on port ${NAS_PG_PORT} (all interfaces)"
  else
    echo "  ✗ Not accepting connections on port ${NAS_PG_PORT}"
    fail=1
  fi

  # Database exists
  local db_exists
  db_exists=$(ssh_nas "${SUDO}su - postgres -c \"psql -tAc \\\"SELECT 1 FROM pg_database WHERE datname='${PG_DB}';\\\"\"") || db_exists=""
  if [[ "$db_exists" == "1" ]]; then
    echo "  ✓ Database '${PG_DB}' exists"
  else
    echo "  ✗ Database '${PG_DB}' not found"
    fail=1
  fi

  # User exists
  local user_exists
  user_exists=$(ssh_nas "${SUDO}su - postgres -c \"psql -tAc \\\"SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}';\\\"\"") || user_exists=""
  if [[ "$user_exists" == "1" ]]; then
    echo "  ✓ User '${PG_USER}' exists"
  else
    echo "  ✗ User '${PG_USER}' not found"
    fail=1
  fi

  # Schema check
  for env in "${ENV_NAMES[@]}"; do
    local schema_exists
    schema_exists=$(ssh_nas "${SUDO}su - postgres -c \"psql -d ${PG_DB} -tAc \\\"SELECT 1 FROM information_schema.schemata WHERE schema_name='${env}';\\\"\"") || schema_exists=""
    if [[ "$schema_exists" == "1" ]]; then
      echo "  ✓ Schema '${env}' exists"
    else
      echo "  ✗ Schema '${env}' not found"
      fail=1
    fi
  done

  # pg_hba.conf has tofu entry
  local hba_file_v
  hba_file_v=$(ssh_nas "${SUDO}su - postgres -c \"psql -tAc 'SHOW hba_file;'\"" | tr -d '[:space:]')
  if [[ -z "$hba_file_v" ]]; then
    hba_file_v="/var/services/pgsql/pg_hba.conf"
  fi
  local hba_ok
  hba_ok=$(ssh_nas "grep -c '${PG_USER}' ${hba_file_v} || true")
  if [[ "$hba_ok" -ge 1 ]]; then
    echo "  ✓ pg_hba.conf has ${PG_USER} access rule (${hba_file_v})"
  else
    echo "  ✗ pg_hba.conf missing ${PG_USER} access rule (${hba_file_v})"
    fail=1
  fi

  return $fail
}

# ============================================================
# Docker PostgreSQL (fallback)
# ============================================================

# --- Detect docker compose command ---
detect_compose_cmd() {
  if ssh_nas_sudo "docker compose version" &>/dev/null; then
    echo "docker compose"
  elif ssh_nas "docker-compose version" &>/dev/null; then
    echo "docker-compose"
  else
    echo ""
  fi
}

deploy_postgres_docker() {
  echo ""
  echo "=== PostgreSQL Deployment (Docker) ==="

  if ! check_connectivity; then
    return 1
  fi

  # Detect docker compose command
  echo ""
  echo "--- Docker ---"
  local compose_cmd
  compose_cmd=$(detect_compose_cmd)
  if [[ -z "$compose_cmd" ]]; then
    echo "  ✗ Neither 'docker compose' nor 'docker-compose' found on NAS"
    echo "    Install Docker via Synology Package Center"
    return 1
  fi
  echo "  ✓ Compose command: ${compose_cmd}"

  # Create data directory
  echo ""
  echo "--- Data directory ---"
  if ssh_nas_sudo "test -d /volume1/docker/postgres/data"; then
    echo "  ✓ /volume1/docker/postgres/data already exists"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would create /volume1/docker/postgres/data (owner 999:999)"
    else
      ssh_nas_sudo "mkdir -p /volume1/docker/postgres/data"
      ssh_nas_sudo "chown 999:999 /volume1/docker/postgres/data"
      echo "  ✓ Created /volume1/docker/postgres/data (owner 999:999)"
    fi
  fi

  # Generate docker-compose.yml — use $$ to escape $ for Docker Compose
  echo ""
  echo "--- Docker Compose configuration ---"
  local escaped_password="${PG_PASSWORD//\$/\$\$}"
  local compose_content
  compose_content=$(cat <<EOF
# Auto-generated by configure-nas.sh from site/config.yaml
# Manual edits will be overwritten.

services:
  postgres:
    image: postgres:16
    container_name: tofu-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${PG_DB}
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${escaped_password}
    ports:
      - "${NAS_PG_PORT}:5432"
    volumes:
      - /volume1/docker/postgres/data:/var/lib/postgresql/data
    shm_size: 256mb
EOF
)

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would deploy /volume1/docker/postgres/docker-compose.yml:"
    echo "$compose_content" | sed 's/^/    /'
  else
    echo "$compose_content" | ssh -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "${NAS_SSH_USER}@${NAS_IP}" "${NAS_PATH_PREFIX}; ${SUDO}tee /volume1/docker/postgres/docker-compose.yml > /dev/null" 2>/dev/null
    echo "  ✓ Deployed /volume1/docker/postgres/docker-compose.yml"
  fi

  # Start/recreate container
  echo ""
  echo "--- Container ---"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would run: ${compose_cmd} up -d"
  else
    ssh_nas_sudo "${compose_cmd} -f /volume1/docker/postgres/docker-compose.yml up -d" &>/dev/null
    echo "  ✓ Container started (${compose_cmd} up -d)"

    # Wait for pg_isready
    echo "  Waiting for PostgreSQL to become ready..."
    local attempts=0
    while (( attempts < 15 )); do
      if ssh_nas_sudo "docker exec tofu-postgres pg_isready -U ${PG_USER}" &>/dev/null; then
        echo "  ✓ PostgreSQL is ready"
        break
      fi
      (( attempts++ ))
      sleep 2
    done
    if (( attempts >= 15 )); then
      echo "  ✗ Timed out waiting for PostgreSQL to become ready"
      return 1
    fi

    # Create schemas
    echo ""
    echo "--- Schemas ---"
    for env in "${ENV_NAMES[@]}"; do
      if ssh_nas_sudo "docker exec tofu-postgres psql -U ${PG_USER} -d ${PG_DB} -c 'CREATE SCHEMA IF NOT EXISTS ${env};'" &>/dev/null; then
        echo "  ✓ Schema '${env}' exists"
      else
        echo "  ✗ Failed to create schema '${env}'"
        (( ERRORS++ ))
      fi
    done
  fi

  return 0
}

verify_postgres_docker() {
  echo ""
  echo "--- PostgreSQL verification (Docker) ---"
  local fail=0

  # TCP port check
  if ssh_nas "pg_isready -h 0.0.0.0 -p ${NAS_PG_PORT}" &>/dev/null 2>&1 || \
     ssh_nas "echo | ${SUDO}docker exec -i tofu-postgres pg_isready -h 0.0.0.0 -p 5432" &>/dev/null 2>&1; then
    echo "  ✓ TCP port ${NAS_PG_PORT} is listening"
  else
    echo "  ✗ TCP port ${NAS_PG_PORT} is not listening"
    fail=1
  fi

  # Container status
  local container_status
  container_status=$(ssh_nas_sudo "docker inspect -f '{{.State.Status}}' tofu-postgres" 2>/dev/null) || container_status=""
  if [[ "$container_status" == "running" ]]; then
    echo "  ✓ Container 'tofu-postgres' is running"
  else
    echo "  ✗ Container 'tofu-postgres' is not running (status: ${container_status:-not found})"
    fail=1
  fi

  # pg_isready
  if ssh_nas_sudo "docker exec tofu-postgres pg_isready -U ${PG_USER}" &>/dev/null; then
    echo "  ✓ pg_isready reports accepting connections"
  else
    echo "  ✗ pg_isready failed"
    fail=1
  fi

  # Schema check
  for env in "${ENV_NAMES[@]}"; do
    local schema_exists
    schema_exists=$(ssh_nas_sudo "docker exec tofu-postgres psql -U ${PG_USER} -d ${PG_DB} -tAc \"SELECT 1 FROM information_schema.schemata WHERE schema_name='${env}';\"" 2>/dev/null) || schema_exists=""
    if [[ "$schema_exists" == "1" ]]; then
      echo "  ✓ Schema '${env}' exists"
    else
      echo "  ✗ Schema '${env}' not found"
      fail=1
    fi
  done

  return $fail
}

# ============================================================
# PostgreSQL backup (both methods)
# ============================================================

deploy_backup() {
  echo ""
  echo "--- PostgreSQL backup (daily pg_dump) ---"

  local backup_dir="/volume1/backups"
  local backup_script="/usr/local/bin/pg-backup-tofu.sh"
  local cron_marker="pg-backup-tofu"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would create ${backup_dir}"
    echo "  [DRY RUN] Would deploy ${backup_script}"
    echo "  [DRY RUN] Would add cron entry for daily backup at 02:00"
    return 0
  fi

  # Create backup directory
  ssh_nas "${SUDO}mkdir -p ${backup_dir}"
  echo "  ✓ Backup directory ${backup_dir} exists"

  # Deploy backup script (method-specific)
  local script_content
  if [[ "$POSTGRES_METHOD" == "native" ]]; then
    script_content='#!/bin/sh
# pg-backup-tofu.sh — deployed by configure-nas.sh
# Daily pg_dump of tofu_state database with retention cleanup
BACKUP_DIR="/volume1/backups"
DB="tofu_state"
RETENTION_DAYS=7
STAMP=$(date +%Y%m%d)
su - postgres -c "pg_dump -Fc ${DB}" > "${BACKUP_DIR}/${DB}_${STAMP}.dump" 2>/dev/null
find "${BACKUP_DIR}" -name "${DB}_*.dump" -mtime +${RETENTION_DAYS} -delete 2>/dev/null
exit 0'
  else
    script_content='#!/bin/sh
# pg-backup-tofu.sh — deployed by configure-nas.sh
# Daily pg_dump of tofu_state database with retention cleanup
PATH=/usr/local/bin:$PATH
BACKUP_DIR="/volume1/backups"
DB="tofu_state"
PG_USER="tofu"
RETENTION_DAYS=7
STAMP=$(date +%Y%m%d)
docker exec tofu-postgres pg_dump -U "${PG_USER}" -Fc "${DB}" > "${BACKUP_DIR}/${DB}_${STAMP}.dump" 2>/dev/null
find "${BACKUP_DIR}" -name "${DB}_*.dump" -mtime +${RETENTION_DAYS} -delete 2>/dev/null
exit 0'
  fi

  echo "$script_content" | ssh -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "${NAS_SSH_USER}@${NAS_IP}" "${NAS_PATH_PREFIX}; cat > ${backup_script} && chmod +x ${backup_script}" 2>/dev/null
  echo "  ✓ Deployed ${backup_script}"

  # Idempotent cron entry: remove any existing entry, then add fresh one.
  # This ensures repeated runs never accumulate duplicate cron jobs.
  ssh_nas "sed -i '/${cron_marker}/d' /etc/crontab"
  ssh_nas "printf '0\t2\t*\t*\t*\troot\t${backup_script} # ${cron_marker}\n' >> /etc/crontab"
  echo "  ✓ Cron entry: daily at 02:00 (7-day retention)"

  return 0
}

verify_backup() {
  echo ""
  echo "--- PostgreSQL backup verification ---"
  local fail=0

  # Check script exists
  if ssh_nas "test -x /usr/local/bin/pg-backup-tofu.sh"; then
    echo "  ✓ Backup script /usr/local/bin/pg-backup-tofu.sh exists"
  else
    echo "  ✗ Backup script /usr/local/bin/pg-backup-tofu.sh not found"
    fail=1
  fi

  # Check cron entry
  local cron_exists
  cron_exists=$(ssh_nas "grep -c 'pg-backup-tofu' /etc/crontab || true")
  if [[ "$cron_exists" -ge 1 ]]; then
    echo "  ✓ Cron entry exists in /etc/crontab"
  else
    echo "  ✗ Cron entry not found in /etc/crontab"
    fail=1
  fi

  return $fail
}

# ============================================================
# NFS verification (shared by both methods)
# ============================================================

verify_nfs() {
  echo ""
  echo "--- NFS verification ---"
  local fail=0

  # Check showmount from workstation (if available)
  if command -v showmount &>/dev/null; then
    local exports
    exports=$(showmount -e "$NAS_IP" 2>/dev/null) || exports=""
    if echo "$exports" | grep -q "$NAS_NFS_EXPORT"; then
      echo "  ✓ NFS export ${NAS_NFS_EXPORT} visible from workstation"
    else
      echo "  ✗ NFS export ${NAS_NFS_EXPORT} not visible from workstation"
      fail=1
    fi
  else
    echo "  ⊘ showmount not available on workstation — skipping local check"
  fi

  # Check showmount from first Proxmox node
  if ping -c 1 -W 3 "$FIRST_NODE_IP" &>/dev/null; then
    local node_exports
    node_exports=$(ssh_node "$FIRST_NODE_IP" "showmount -e ${NAS_IP} 2>/dev/null") || node_exports=""
    if echo "$node_exports" | grep -q "$NAS_NFS_EXPORT"; then
      echo "  ✓ NFS export ${NAS_NFS_EXPORT} visible from ${FIRST_NODE_NAME}"
    else
      echo "  ✗ NFS export ${NAS_NFS_EXPORT} not visible from ${FIRST_NODE_NAME}"
      fail=1
    fi

    # Mount/unmount test
    local test_mount="/mnt/nfs-test-$$"
    if ssh_node "$FIRST_NODE_IP" "mkdir -p ${test_mount} && mount -t nfs ${NAS_IP}:${NAS_NFS_EXPORT} ${test_mount} && umount ${test_mount} && rmdir ${test_mount}" &>/dev/null; then
      echo "  ✓ NFS mount/unmount test succeeded from ${FIRST_NODE_NAME}"
    else
      # Clean up on failure
      ssh_node "$FIRST_NODE_IP" "umount ${test_mount} 2>/dev/null; rmdir ${test_mount} 2>/dev/null" || true
      echo "  ✗ NFS mount test failed from ${FIRST_NODE_NAME}"
      fail=1
    fi
  else
    echo "  ⊘ ${FIRST_NODE_NAME} (${FIRST_NODE_IP}) not reachable — skipping node NFS checks"
  fi

  if [[ $fail -ne 0 ]]; then
    echo ""
    echo "  NFS is not configured. Create the shared folder in DSM:"
    echo "    1. Open ${NAS_URL:-https://${NAS_IP}:5001}"
    echo "    2. Control Panel → Shared Folder → Create"
    echo "       Name: pbs-datastore"
    echo "       Location: volume1"
    echo "       Path will be: ${NAS_NFS_EXPORT}"
    echo "    3. Control Panel → File Services → NFS → Enable NFS"
    echo "    4. Edit the shared folder → NFS Permissions → Create:"
    echo "       Hostname/IP: ${MGMT_SUBNET}"
    echo "       Privilege: Read/Write"
    echo "       Squash: Map root to admin"
    echo "       Security: sys"
    echo "       Enable async: Yes"
  fi

  return $fail
}

# ============================================================
# Main
# ============================================================

echo ""
echo "=== NAS Configuration ==="
echo "Hostname: ${NAS_HOSTNAME}"
echo "IP:       ${NAS_IP}"
echo "SSH user: ${NAS_SSH_USER}"
echo "PG mode:  ${POSTGRES_METHOD}"
echo "PG port:  ${NAS_PG_PORT}"
echo "NFS:      ${NAS_NFS_EXPORT}"
echo ""

# --- Verify-only mode ---
if [[ $VERIFY_ONLY -eq 1 ]]; then
  VFAIL=0
  if [[ "$POSTGRES_METHOD" == "native" ]]; then
    verify_postgres_native || VFAIL=1
  else
    verify_postgres_docker || VFAIL=1
  fi
  verify_backup || VFAIL=1
  verify_nfs || VFAIL=1
  echo ""
  if [[ $VFAIL -eq 0 ]]; then
    echo "All checks passed."
    exit 0
  else
    echo "Some checks failed. See above."
    exit 1
  fi
fi

# --- Deploy mode ---
if [[ $DRY_RUN -eq 0 ]]; then
  echo "--- Password resolution ---"
  if ! resolve_password; then
    exit 1
  fi
fi

# Deploy PostgreSQL
if [[ "$POSTGRES_METHOD" == "native" ]]; then
  if ! deploy_postgres_native; then
    (( ERRORS++ ))
  fi
else
  if ! deploy_postgres_docker; then
    (( ERRORS++ ))
  fi
fi

# Deploy backup
deploy_backup || (( ERRORS++ ))

# Verify PostgreSQL and backup (skip if dry-run)
if [[ $DRY_RUN -eq 0 ]]; then
  echo ""
  echo "=== Post-Deploy Verification ==="
  if [[ "$POSTGRES_METHOD" == "native" ]]; then
    verify_postgres_native || (( ERRORS++ ))
  else
    verify_postgres_docker || (( ERRORS++ ))
  fi
  verify_backup || (( ERRORS++ ))
fi

# Verify NFS (always, even in dry-run)
verify_nfs || (( ERRORS++ ))

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "FAILED: ${ERRORS} error(s) encountered."
  exit 1
fi

echo "Done."
exit 0
