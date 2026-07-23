#!/usr/bin/env bash
# tofu-wrapper.sh — Decrypt SOPS secrets, export env vars, exec tofu.
#
# Usage:
#   framework/scripts/tofu-wrapper.sh init
#   framework/scripts/tofu-wrapper.sh plan
#   framework/scripts/tofu-wrapper.sh apply
#   framework/scripts/tofu-wrapper.sh destroy
#   # Any tofu subcommand works — arguments are passed through.

set -euo pipefail

# --- Locate repo root (find directory containing flake.nix) ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "${dir}/flake.nix" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root (no flake.nix found)." >&2
  exit 1
}

REPO_DIR="$(find_repo_root)"
TOFU_BIN_LIB="${REPO_DIR}/framework/scripts/lib/tofu-bin.sh"
if [[ -f "$TOFU_BIN_LIB" ]]; then
  source "$TOFU_BIN_LIB"
else
  mycofu_resolve_tofu_bin() {
    if [[ -n "${MYCOFU_TOFU_BIN:-}" ]]; then
      if [[ ! -x "${MYCOFU_TOFU_BIN}" ]]; then
        echo "ERROR: MYCOFU_TOFU_BIN is not executable: ${MYCOFU_TOFU_BIN}" >&2
        return 1
      fi
      printf '%s\n' "${MYCOFU_TOFU_BIN}"
    elif command -v tofu >/dev/null 2>&1; then
      command -v tofu
    else
      echo "ERROR: Required tool not found: tofu" >&2
      return 1
    fi
  }
fi
TOFU_BIN="$(mycofu_resolve_tofu_bin)" || exit 1
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
export VAULT_REQUIREMENTS_REPO_DIR="${REPO_DIR}"
# Guard: vault-requirements-lib.sh may not exist in test fixture repos.
# Without it, manifest-based AppRole discovery is skipped (hardcoded list still works).
if [[ -f "${REPO_DIR}/framework/scripts/vault-requirements-lib.sh" ]]; then
  source "${REPO_DIR}/framework/scripts/vault-requirements-lib.sh"
fi

# --- Validate config consistency ---
VALIDATE_SCRIPT="${REPO_DIR}/framework/scripts/validate-site-config.sh"
if [[ -x "$VALIDATE_SCRIPT" ]]; then
  "$VALIDATE_SCRIPT" || exit 1
fi

# --- Check prerequisites ---

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: SOPS secrets file not found: ${SECRETS_FILE}" >&2
  echo "Run framework/scripts/bootstrap-sops.sh first." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# Check for SOPS age key
if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
  elif [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
    export SOPS_AGE_KEY_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  else
    echo "ERROR: No SOPS age key found." >&2
    echo "Set SOPS_AGE_KEY_FILE, or place your key at:" >&2
    echo "  ${REPO_DIR}/operator.age.key" >&2
    echo "  ${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" >&2
    exit 1
  fi
fi

# --- Check required tools ---
# `nix` is required because the sovereignty bootstrap below uses
# `nix build` to materialize the vendored bpg/proxmox provider when
# TF_CLI_CONFIG_FILE isn't already exported by the environment.
for tool in sops yq jq nix; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    echo "Run 'nix develop' from the repo root to enter the dev shell." >&2
    exit 1
  fi
done

# --- Sovereignty: ensure TF_CLI_CONFIG_FILE points at a terraformrc
# with a filesystem_mirror block so `tofu init` never reaches the
# OpenTofu registry / github.com.
#
# Layers:
#   1. If TF_CLI_CONFIG_FILE is set (typical for `nix develop` and
#      the cicd runner once the new image is deployed), validate it.
#      Refuse to proceed if it's missing filesystem_mirror.
#   2. If not set AND this is a sovereign mycofu repo (detected via
#      the presence of framework/nix/lib/bpg-proxmox-provider.nix),
#      self-bootstrap by building that derivation. Same mechanism
#      tests/test_sovereign_tofu_init.sh uses.
#   3. If not set AND not in a sovereign repo (e.g. a unit-test
#      fixture flake that lacks the provider derivation), proceed
#      without enforcement — the wrapper is being exercised in a
#      context where sovereignty isn't applicable.
#
# The bootstrap path decouples the wrapper from the cicd image deploy
# ordering: until the new image lands on the runner, the wrapper
# still produces a sovereign tofu invocation by building the provider
# on-the-fly. The build is cached in the nix store after first run.
PROVIDER_NIX="${REPO_DIR}/framework/nix/lib/bpg-proxmox-provider.nix"
if [[ -z "${TF_CLI_CONFIG_FILE:-}" ]] && [[ -f "$PROVIDER_NIX" ]]; then
  echo "TF_CLI_CONFIG_FILE not set — bootstrapping from flake..." >&2
  # Capture stdout (the store path) separately from stderr; nix's
  # dirty-tree warnings would otherwise corrupt BOOTSTRAP_OUT.
  BOOTSTRAP_ERR="$(mktemp -t tofu-wrapper-bootstrap.XXXXXX)"
  if ! BOOTSTRAP_OUT="$(nix build --no-link --print-out-paths \
        "${REPO_DIR}#bpg-proxmox-provider" 2>"$BOOTSTRAP_ERR")"; then
    echo "ERROR: failed to build bpg-proxmox-provider derivation:" >&2
    cat "$BOOTSTRAP_ERR" >&2
    rm -f "$BOOTSTRAP_ERR"
    echo "       Run 'nix develop' from the repo root, or fix the build." >&2
    exit 1
  fi
  rm -f "$BOOTSTRAP_ERR"
  export TF_CLI_CONFIG_FILE="${BOOTSTRAP_OUT}/etc/terraformrc"
fi
if [[ -n "${TF_CLI_CONFIG_FILE:-}" ]]; then
  if [[ ! -r "$TF_CLI_CONFIG_FILE" ]]; then
    echo "ERROR: TF_CLI_CONFIG_FILE=$TF_CLI_CONFIG_FILE is not readable." >&2
    exit 1
  fi
  if ! grep -q 'filesystem_mirror' "$TF_CLI_CONFIG_FILE"; then
    echo "ERROR: TF_CLI_CONFIG_FILE=$TF_CLI_CONFIG_FILE does not contain a" >&2
    echo "       filesystem_mirror block. Refusing to proceed — tofu would" >&2
    echo "       fall back to registry-direct installation." >&2
    exit 1
  fi
fi

# --- Decrypt secrets (never written to disk) ---
echo "Decrypting secrets..."
SECRETS_JSON=$(sops -d --output-type json "$SECRETS_FILE")

PROXMOX_USER=$(echo "$SECRETS_JSON" | jq -r '.proxmox_api_user')
PROXMOX_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.proxmox_api_password')
TOFU_DB_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.tofu_db_password')
SSH_PUBKEY=$(echo "$SECRETS_JSON" | jq -r '.ssh_pubkey')
PDNS_API_KEY=$(echo "$SECRETS_JSON" | jq -r '.pdns_api_key')

# --- Read non-secret config values ---
NAS_IP=$(yq -r '.nas.ip' "$CONFIG_FILE")
NAS_PG_PORT=$(yq -r '.nas.postgres_port' "$CONFIG_FILE")
POSTGRES_SSL=$(yq -r '.nas.postgres_ssl // false' "$CONFIG_FILE")
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG_FILE")
GITHUB_REMOTE_URL=$(yq -r '.github.remote_url // ""' "$CONFIG_FILE")

# --- Export Proxmox provider env vars ---
export PROXMOX_VE_ENDPOINT="https://${FIRST_NODE_IP}:8006/"
export PROXMOX_VE_USERNAME="${PROXMOX_USER}"
export PROXMOX_VE_PASSWORD="${PROXMOX_PASSWORD}"
export PROXMOX_VE_INSECURE="true"

# --- Build PostgreSQL connection string ---
# Export as env var — the pg backend reads PG_CONN_STR at runtime.
# Do NOT use -backend-config: those values get baked into the stored hash
# but plan/apply compute the hash from HCL only, causing a permanent mismatch.
PG_CONN_STR="postgres://tofu:${TOFU_DB_PASSWORD}@${NAS_IP}:${NAS_PG_PORT}/tofu_state"
if [[ "$POSTGRES_SSL" != "true" ]]; then
  PG_CONN_STR="${PG_CONN_STR}?sslmode=disable"
fi
export PG_CONN_STR

# --- Export TF vars from secrets ---
export TF_VAR_ssh_pubkey="${SSH_PUBKEY}"
export TF_VAR_pdns_api_key="${PDNS_API_KEY}"
export TF_VAR_github_remote_url="${GITHUB_REMOTE_URL}"

# Application pre-deploy secrets (set by operator, stable across deploys)
INFLUXDB_ADMIN_TOKEN=$(echo "$SECRETS_JSON" | jq -r '.influxdb_admin_token // empty')
export TF_VAR_influxdb_admin_token="${INFLUXDB_ADMIN_TOKEN}"

GRAFANA_ADMIN_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.grafana_admin_password // empty')
export TF_VAR_grafana_admin_password="${GRAFANA_ADMIN_PASSWORD}"

GRAFANA_INFLUXDB_TOKEN=$(echo "$SECRETS_JSON" | jq -r '.grafana_influxdb_token // empty')
export TF_VAR_grafana_influxdb_token="${GRAFANA_INFLUXDB_TOKEN}"

TAILSCALE_AUTH_KEY=$(echo "$SECRETS_JSON" | jq -r '.tailscale_auth_key // empty')
export TF_VAR_tailscale_auth_key="${TAILSCALE_AUTH_KEY}"

# Vault AppRole credentials for vault-agent (generated by configure-vault.sh)
EXPORTED_APPROLE_ROLES=" dns1_prod dns2_prod dns1_dev dns2_dev gatus gitlab cicd influxdb_dev influxdb_prod testapp_dev testapp_prod grafana_dev grafana_prod "
for ROLE in dns1_prod dns2_prod dns1_dev dns2_dev gatus gitlab cicd influxdb_dev influxdb_prod testapp_dev testapp_prod grafana_dev grafana_prod; do
  ROLE_ID=$(echo "$SECRETS_JSON" | jq -r ".vault_approle_${ROLE}_role_id // empty")
  SECRET_ID=$(echo "$SECRETS_JSON" | jq -r ".vault_approle_${ROLE}_secret_id // empty")
  export "TF_VAR_vault_approle_${ROLE}_role_id=${ROLE_ID}"
  export "TF_VAR_vault_approle_${ROLE}_secret_id=${SECRET_ID}"
done

# Discover additional AppRoles from catalog manifests (if library is loaded)
if type list_enabled_catalog_apps_with_approle &>/dev/null; then
APP=""
APP_ENV=""
ROLE_KEY=""
SECRET_KEY=""
ROLE_NAME=""
MANIFEST_KEYS=""
while IFS= read -r APP; do
  [[ -z "$APP" ]] && continue
  while IFS= read -r APP_ENV; do
    [[ -z "$APP_ENV" || "$APP_ENV" == "null" ]] && continue
    MANIFEST_KEYS="$(resolve_sops_keys "$APP" "$APP_ENV")" || exit 1
    while IFS=$'\t' read -r ROLE_KEY SECRET_KEY; do
      ROLE_NAME="${ROLE_KEY#vault_approle_}"
      ROLE_NAME="${ROLE_NAME%_role_id}"
      case "$EXPORTED_APPROLE_ROLES" in
        *" ${ROLE_NAME} "*) continue ;;
      esac
      ROLE_ID=$(echo "$SECRETS_JSON" | jq -r ".[\"${ROLE_KEY}\"] // empty")
      SECRET_ID=$(echo "$SECRETS_JSON" | jq -r ".[\"${SECRET_KEY}\"] // empty")
      export "TF_VAR_${ROLE_KEY}=${ROLE_ID}"
      export "TF_VAR_${SECRET_KEY}=${SECRET_ID}"
      EXPORTED_APPROLE_ROLES+=" ${ROLE_NAME} "
    done <<< "$MANIFEST_KEYS"
  done < <(yq -r ".applications.${APP}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null || true)
done < <(list_enabled_catalog_apps_with_approle)
fi  # end manifest-based AppRole discovery

# SSH host keys from SOPS — per-VM ed25519 keys for deterministic host key
# fingerprints. Delivered via CIDATA write_files. Keys are pre-deploy secrets
# (generated once by new-site.sh, stable across deploys).
SSH_HOST_KEYS_JSON=$(echo "$SECRETS_JSON" | jq -c '.ssh_host_keys // {}')
export TF_VAR_ssh_host_keys_json="${SSH_HOST_KEYS_JSON}"

# Post-deploy secrets (vault unseal keys, runner registration token) are NOT
# exported as TF_VARs. They are delivered via SSH by init-vault.sh and
# register-runner.sh, not via CIDATA. This prevents the CIDATA recreation
# cycle where post-deploy secrets flow back into CIDATA and trigger VM
# recreation on the next apply.

# SOPS age key — read from the operator's age key file, not from SOPS
# (the age key is the one secret that isn't in SOPS because it decrypts SOPS)
if [[ -f "${SOPS_AGE_KEY_FILE}" ]]; then
  SOPS_AGE_KEY_CONTENT=$(cat "${SOPS_AGE_KEY_FILE}")
  export TF_VAR_sops_age_key="${SOPS_AGE_KEY_CONTENT}"
else
  export TF_VAR_sops_age_key=""
fi

# SSH private key for runner node access (may not exist)
SSH_PRIVKEY=$(echo "$SECRETS_JSON" | jq -r '.ssh_privkey // empty')
export TF_VAR_ssh_privkey="${SSH_PRIVKEY}"

# --- Change to framework/tofu/root/ working directory ---
cd "${REPO_DIR}/framework/tofu/root"

# --- Symlink site overrides if present ---
OVERRIDE_SRC="${REPO_DIR}/site/tofu/overrides.tf"
if [[ -f "$OVERRIDE_SRC" ]] && [[ ! -L "overrides.tf" ]]; then
  ln -sf "$OVERRIDE_SRC" overrides.tf
fi

# --- Check for image-versions file (build artifact in site/tofu/) ---
IMAGE_VERSIONS="${REPO_DIR}/site/tofu/image-versions.auto.tfvars"
if [[ ! -f "$IMAGE_VERSIONS" ]]; then
  echo "WARNING: image-versions.auto.tfvars not found — generating placeholder sentinels; tofu apply will be blocked until valid image filenames are present." >&2
  mkdir -p "${REPO_DIR}/site/tofu"
  # Strip HCL comments before extracting role names so a commented-out module
  # block (`#`, `//`, or `/* ... */`) cannot fabricate a placeholder for a
  # dead role (#539). A placeholder for a role no active module consumes is
  # not merely noise: it trips the image gate with a confusing "invalid
  # image value" error instead of the clear tofu key-not-found or
  # missing-manifest signal that not-fabricating produces (G4: teeth over
  # misleading pass).
  #
  # The awk pass strips HCL comments and then emits `var.image_versions["<role>"]`
  # matches directly (via awk's own `match()`), so the extractor pipeline never
  # includes a `grep -o` that can exit 1 on zero matches — a `main.tf` where
  # every reference is inside a comment now yields an empty ROLES rather than
  # tripping `set -euo pipefail`.
  #
  # Comment markers inside quoted strings are handled: `in_string` toggles on
  # `"` (with `\"` escape handling) so a URL like `"https://..."` does not
  # cause the `//` to swallow the rest of the line, and a `/*` inside a string
  # does not silently open a fake block comment. HCL's nested-string case
  # (`"...${var.image_versions["role"]}..."`) is safe by accident: the
  # `in_string` state flips at every `"` boundary but the character stream is
  # preserved verbatim, so `match()` still finds the reference. HCL heredocs
  # (`<<EOT ... EOT`) are NOT modeled — a reference embedded in a heredoc
  # would be dropped if preceded by a `#`; that shape does not occur in the
  # current tree and is a follow-up if it ever does.
  #
  # This is scoped comment-and-string stripping, not a full HCL lexer.
  ROLES=$(awk '
    BEGIN { in_block = 0 }
    {
      line = $0
      sub(/\r$/, "", line)           # tolerate CRLF-authored patches
      L = length(line); i = 1
      code = ""
      in_string = 0                  # HCL double-quoted string
      while (i <= L) {
        c = substr(line, i, 1)
        two = substr(line, i, 2)
        if (in_block) {
          if (two == "*/") { in_block = 0; i += 2 } else { i++ }
          continue
        }
        if (in_string) {
          # Escapes: preserve `\x` verbatim so `\"` does not exit the string.
          if (c == "\\" && i < L) { code = code c substr(line, i+1, 1); i += 2; continue }
          if (c == "\"") { in_string = 0 }
          code = code c
          i++
          continue
        }
        if (two == "/*") { in_block = 1; i += 2; continue }
        if (two == "//") break
        if (c == "#") break
        if (c == "\"") { in_string = 1 }
        code = code c
        i++
      }
      # Emit every var.image_versions["<role>"] ref found in the stripped code.
      # Doing the match here (rather than piping to `grep -o`) means the
      # extractor pipeline is `awk | sort -u`; both exit 0 on empty input, so
      # a main.tf with zero uncommented refs no longer trips set -euo pipefail.
      while (match(code, /var\.image_versions\["[^"]+"/)) {
        ref = substr(code, RSTART, RLENGTH)
        sub(/^var\.image_versions\["/, "", ref)
        sub(/"$/, "", ref)
        print ref
        code = substr(code, RSTART + RLENGTH)
      }
    }
  ' main.tf 2>/dev/null | sort -u)
  # Fabricate PLACEHOLDER_<role> ONLY for the intersection of (roles referenced
  # in main.tf) and (the authoritative role universe the image producers build).
  # The universe is derived from the SAME three sources that
  # build-all-images.sh and merge-image-versions.sh read, so fabrication and
  # production can never diverge (G1: derive relationships, don't maintain
  # parallel lists — this replaces the earlier disabled-app blacklist +
  # infra-collision safety net with one derivation).
  #
  # The universe is the union of:
  #   - framework/images.yaml roles         (infrastructure)
  #   - site/images.yaml roles              (site-specific infra)
  #   - applications.yaml enabled==true     (catalog apps)
  #
  # A role referenced in main.tf but absent from this universe is either:
  #   (a) An app whose applications.yaml entry is disabled OR entirely absent
  #       (#505 disabled case, #520 absent-from-fresh-site case). Its VM
  #       module in main.tf is count=0, so OpenTofu does not index
  #       image_versions for it at plan time. A placeholder is pure downside:
  #       it trips the image gate and blocks cold rebuild from a fresh clone
  #       (DRT-002) even though nothing consumes the image.
  #   (b) A genuinely broken manifest — the pipeline cannot build an image
  #       for it either, so a placeholder here would only defer the failure
  #       to the image gate with a confusing "invalid image value" message.
  #       Not fabricating surfaces the gap as a clear tofu key-not-found
  #       error pointing at the missing manifest entry (G4: teeth over
  #       misleading pass).
  AUTHORITATIVE_ROLES=""
  for _manifest in "${REPO_DIR}/framework/images.yaml" "${REPO_DIR}/site/images.yaml"; do
    [[ -f "$_manifest" ]] || continue
    AUTHORITATIVE_ROLES+="$(yq -r '.roles // {} | keys | .[]' "$_manifest" 2>/dev/null || true)"$'\n'
  done
  if [[ -f "$APPS_CONFIG" ]]; then
    AUTHORITATIVE_ROLES+="$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)"$'\n'
  fi
  # G4 fail-closed: if main.tf references image_versions keys but the
  # authoritative role universe is empty (all three sources missing / empty),
  # refuse to fabricate. Silently emitting `image_versions = {}` would let
  # validate_image_versions_file find zero invalid entries and pass apply
  # through — the same false-pass shape #520 exists to close, just at a
  # different point in the pipeline. A "cannot determine what to fabricate"
  # state is a broken-manifest signal, not a legitimate one; block with a
  # clear error rather than silently disarm the image gate.
  if [[ -n "$ROLES" ]] && ! grep -q '[^[:space:]]' <<< "$AUTHORITATIVE_ROLES"; then
    echo "ERROR: cannot fabricate image-versions placeholders — the authoritative role" >&2
    echo "       universe is empty. main.tf references image_versions keys, but neither" >&2
    echo "       framework/images.yaml (${REPO_DIR}/framework/images.yaml) nor" >&2
    echo "       site/images.yaml (${REPO_DIR}/site/images.yaml) yielded any roles, and" >&2
    echo "       no enabled apps were found in applications.yaml (${APPS_CONFIG})." >&2
    echo "       This looks like a broken framework/site checkout. Restore the manifests" >&2
    echo "       before proceeding — a silent empty tfvars would disarm the image gate." >&2
    exit 1
  fi
  {
    echo '# Placeholder — generated by tofu-wrapper.sh (no build artifacts available)'
    echo 'image_versions = {'
    for role in $ROLES; do
      grep -qxF "$role" <<< "$AUTHORITATIVE_ROLES" || continue
      echo "  \"${role}\" = \"PLACEHOLDER_${role}\""
    done
    echo '}'
  } > "$IMAGE_VERSIONS"
fi

# --- Image filename validation ---
validate_image_versions_file() {
  local image_versions_file="$1"
  local tofu_command="$2"
  local allow_placeholder_images="$3"
  local IMAGE_FILENAME_PATTERN='^[a-z][a-z0-9]*(-[a-z0-9]+)*-[a-z0-9]{8}(-dev)?\.img$'
  local invalid_images=""
  local unparseable_lines=""
  local line=""
  local trimmed_line=""
  local role=""
  local value=""
  local in_image_versions_block=0
  local total_candidate_lines=0
  local validated_entries=0
  local parser_skipped_lines=0
  local issue_header=""
  local issue_details=""

  while IFS= read -r line; do
    trimmed_line="${line#"${line%%[![:space:]]*}"}"
    trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"

    if [[ "$in_image_versions_block" -eq 0 ]]; then
      if [[ "$trimmed_line" =~ ^image_versions[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]]; then
        in_image_versions_block=1
      elif [[ "$trimmed_line" =~ ^image_versions[[:space:]]*=[[:space:]]*\{.*$ ]]; then
        in_image_versions_block=1
        total_candidate_lines=$((total_candidate_lines + 1))
        unparseable_lines+="  ${trimmed_line}"$'\n'
        [[ "$trimmed_line" == *"}"* ]] && in_image_versions_block=0
      fi
      continue
    fi

    if [[ -z "$trimmed_line" || "$trimmed_line" =~ ^# || "$trimmed_line" =~ ^// ]]; then
      continue
    fi

    if [[ "$trimmed_line" == "}" ]]; then
      in_image_versions_block=0
      continue
    fi

    total_candidate_lines=$((total_candidate_lines + 1))
    if [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$ ]]; then
      validated_entries=$((validated_entries + 1))
      role="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if [[ ! "$value" =~ $IMAGE_FILENAME_PATTERN ]]; then
        invalid_images+="  ${role}: ${value}"$'\n'
      fi
    else
      unparseable_lines+="  ${trimmed_line}"$'\n'
      [[ "$trimmed_line" == *"}"* ]] && in_image_versions_block=0
    fi
  done < "$image_versions_file"

  if [[ "$validated_entries" -ne "$total_candidate_lines" ]]; then
    parser_skipped_lines=1
    if [[ -z "$unparseable_lines" ]]; then
      unparseable_lines+="  <unable to identify skipped image_versions lines>"$'\n'
    fi
  fi

  if [[ -n "$invalid_images" ]]; then
    issue_details+="Invalid image values:"$'\n'
    issue_details+="${invalid_images}"
  fi

  if [[ "$parser_skipped_lines" -eq 1 ]]; then
    [[ -n "$issue_details" ]] && issue_details+=$'\n'
    issue_details+="Unparseable image_versions entries:"$'\n'
    issue_details+="${unparseable_lines}"
  fi

  if [[ -z "$invalid_images" && "$parser_skipped_lines" -eq 0 ]]; then
    return 0
  fi

  if [[ -n "$invalid_images" && "$parser_skipped_lines" -eq 1 ]]; then
    issue_header="Invalid or unparseable image values detected in image-versions.auto.tfvars"
  elif [[ -n "$invalid_images" ]]; then
    issue_header="Invalid image values detected in image-versions.auto.tfvars"
  else
    issue_header="Unparseable image_versions entries detected in image-versions.auto.tfvars"
  fi

  case "$tofu_command" in
    apply)
      if [[ "$allow_placeholder_images" -eq 1 ]]; then
        echo "WARNING: ${issue_header}, but proceeding due to --allow-placeholder-images:" >&2
        printf '%s' "$issue_details" >&2
        return 0
      fi
      echo "ERROR: ${issue_header}:" >&2
      printf '%s' "$issue_details" >&2
      echo "Run build-image.sh or build-all-images.sh to populate valid image filenames, or pass --allow-placeholder-images to bypass this guard." >&2
      return 1
      ;;
    plan)
      echo "WARNING: ${issue_header}; tofu plan will continue, but tofu apply will be blocked:" >&2
      printf '%s' "$issue_details" >&2
      return 0
      ;;
  esac

  return 0
}

# --- Control-plane converge-vs-recreate safety fence (G7) ---
# Modeled on validate_image_versions_file above: inspect the plan before
# apply and fail closed with a clear message. The pipeline converges
# control-plane (gitlab/cicd/pbs) IN PLACE autonomously — that is the common
# case and it works. The one genuinely-impossible case is RECREATING a
# control-plane VM from within the pipeline: destroying+creating the runner
# or coordinator the pipeline itself runs on. When the plan would replace
# (delete+create) or destroy a control-plane VM, we fail closed and route the
# operator to the workstation (rebuild-cluster.sh --scope control-plane),
# which is the sanctioned recreation path (Tier 2, architecture.md §10.3).
#
# Context-aware: enforced only in the pipeline (CI env var, the same signal
# restore-before-start.sh uses). On the workstation the guard is advisory —
# the workstation IS the sanctioned recreation path, so it must not block.
#
# Control-plane membership comes from vm-scope.sh (control_plane flag), never
# a hardcoded list. Fails closed in three indeterminate cases: (1) `tofu state
# list` errors (backend down, state lock, uninitialized — issue #538), (2) the
# plan cannot be produced, (3) vm-scope.sh cannot classify the plan. If we
# can't prove the apply won't recreate a control-plane VM, we stop.
guard_control_plane_recreate() {
  # Args: the full tofu arg list ("$@"), starting with the subcommand.
  # Returns 0 to proceed with the apply, 1 to block.
  if [[ -z "${CI:-}" ]]; then
    echo "NOTE: control-plane converge-vs-recreate guard is advisory on the" >&2
    echo "      workstation (the sanctioned recreation path); not enforcing." >&2
    return 0
  fi

  # Discriminate first-deploy (state list succeeded, no VMs) from indeterminate
  # (state list errored — postgres backend down, network hiccup, state lock).
  # Per .claude/rules/destruction-safety.md "When a Safety Check Cannot
  # Determine State", the correct default is FAIL, not SKIP. The pre-fix code
  # was `if ! "$TOFU_BIN" state list 2>/dev/null | grep -q ...; then return 0`,
  # which swallowed the exit code and treated a backend outage identically to
  # first-deploy — silently disabling this fence at exactly the wrong time.
  # Mirrors the VMID-change guard's state-exists precondition below, and
  # naturally no-ops in hermetic fixtures that stub an empty `tofu state`.
  #
  # First-deploy expectations: the pipeline runs `tofu init` before this
  # apply, and post-init `tofu state list` returns rc=0 with empty stdout on
  # a genuine first deploy — that path returns 0 below. If `tofu init`
  # failed (backend uninitialized), `tofu state list` errors and this guard
  # fails closed, which is the correct behavior: an uninitialized backend
  # means we cannot prove anything about the plan, and the pipeline should
  # stop with a clear diagnostic rather than proceed unguarded.
  #
  # Capture stderr into a tmpfile so the operator gets the real cause (pq
  # error / state lock / missing init) in one round trip, not just an exit
  # code. The `<<<` here-string on the grep sidesteps SIGPIPE / pipefail
  # concerns for the success-path scan.
  local state_stdout state_stderr_file state_rc
  state_stderr_file="$(mktemp -t cp-guard-state.XXXXXX)"
  set +e
  state_stdout="$("$TOFU_BIN" state list 2>"$state_stderr_file")"
  state_rc=$?
  set -e
  if [[ $state_rc -ne 0 ]]; then
    echo "ERROR (G7): control-plane safety fence cannot determine tofu state" >&2
    echo "       (${TOFU_BIN} state list exit ${state_rc}). Failing closed:" >&2
    echo "       cannot prove this apply won't recreate a control-plane VM." >&2
    echo "       Common causes: postgres backend unreachable, state lock held," >&2
    echo "       network partition to the NAS, backend not initialized." >&2
    if [[ -s "$state_stderr_file" ]]; then
      echo "       tofu state list stderr:" >&2
      sed 's/^/         /' "$state_stderr_file" >&2
    fi
    echo "       Investigate the backend before rerunning; do not bypass this" >&2
    echo "       fence." >&2
    rm -f "$state_stderr_file"
    return 1
  fi
  rm -f "$state_stderr_file"
  if ! grep -q "proxmox_virtual_environment_vm" <<< "$state_stdout"; then
    # First deploy: state is queryable but contains no VMs yet.
    return 0
  fi

  local vm_scope="${REPO_DIR}/framework/scripts/vm-scope.sh"
  if [[ ! -x "$vm_scope" ]]; then
    echo "ERROR (G7): control-plane safety fence cannot run — vm-scope.sh not" >&2
    echo "       found at ${vm_scope}. Failing closed." >&2
    return 1
  fi

  # Build plan args that mirror the pending apply: keep -target/-var/-input,
  # drop apply-only and wrapper-only flags, add -json's plan file + var-file.
  local plan_out plan_json
  plan_out="$(mktemp -t cp-guard-plan.XXXXXX)"
  plan_json="$(mktemp -t cp-guard-json.XXXXXX)"
  local -a plan_args=("plan" "-input=false" "-out=${plan_out}")
  local a
  for a in "${@:2}"; do
    case "$a" in
      -auto-approve|-no-color|-json) continue ;;
      --allow-vmid-change|--allow-placeholder-images) continue ;;
      *) plan_args+=("$a") ;;
    esac
  done
  [[ -f "$IMAGE_VERSIONS" ]] && plan_args+=("-var-file=${IMAGE_VERSIONS}")

  local plan_rc
  set +e
  "$TOFU_BIN" "${plan_args[@]}" >/dev/null 2>&1
  plan_rc=$?
  set -e
  if [[ $plan_rc -ne 0 ]]; then
    rm -f "$plan_out" "$plan_json"
    echo "ERROR (G7): control-plane safety fence could not produce a plan" >&2
    echo "       (tofu plan exit ${plan_rc}). Failing closed: cannot prove this" >&2
    echo "       apply won't recreate a control-plane VM." >&2
    echo "       A control-plane VM that must be recreated is a workstation" >&2
    echo "       operation: rebuild-cluster.sh --scope control-plane." >&2
    return 1
  fi

  set +e
  "$TOFU_BIN" show -json "$plan_out" > "$plan_json" 2>/dev/null
  local show_rc=$?
  set -e
  if [[ $show_rc -ne 0 || ! -s "$plan_json" ]]; then
    rm -f "$plan_out" "$plan_json"
    echo "ERROR (G7): control-plane safety fence could not render plan JSON" >&2
    echo "       (tofu show exit ${show_rc}). Failing closed." >&2
    return 1
  fi

  local offenders detect_rc
  set +e
  offenders="$("$vm_scope" control-plane-recreate --plan-json "$plan_json" 2>&1)"
  detect_rc=$?
  set -e
  rm -f "$plan_out" "$plan_json"

  case "$detect_rc" in
    0)
      return 0
      ;;
    3)
      echo "ERROR (G7): this pipeline apply would RECREATE a control-plane VM:" >&2
      printf '%s\n' "$offenders" | sed 's/^/       /' >&2
      echo "       The pipeline may converge control-plane in place, but it must" >&2
      echo "       never destroy+create the runner/coordinator it runs on." >&2
      echo "       Recreate control-plane from the workstation instead:" >&2
      echo "         framework/scripts/rebuild-cluster.sh --scope control-plane" >&2
      # --- R13/R14 seam -------------------------------------------------
      # This route-to-workstation branch is the attach point for the
      # roadmap node-resident / ping-pong executor (R13/R14): a future
      # executor running OUTSIDE the pipeline's own control plane would
      # replace this "stop and tell the operator to use the workstation"
      # with "enqueue this control-plane recreation to that executor",
      # letting the pipeline hand off the genuinely-impossible-from-within
      # case rather than fail closed. Until that executor exists, failing
      # closed and routing to the workstation is the correct behavior.
      return 1
      ;;
    *)
      echo "ERROR (G7): control-plane safety fence could not classify the plan" >&2
      echo "       (vm-scope.sh exit ${detect_rc}). Failing closed." >&2
      printf '%s\n' "$offenders" | sed 's/^/       /' >&2
      return 1
      ;;
  esac
}

# --- VMID change protection ---
# On apply, check if any VMIDs in config.yaml differ from the current state.
# A VMID change means the old VM is destroyed and a new one is created with
# a different ID, breaking PBS backup continuity.
#
# Fails closed in indeterminate cases: (1) `tofu state list` errors (backend
# down, state lock, uninitialized — issue #540, symmetric to #538's CP-guard
# fix), (2) `tofu state show` errors after the resource was confirmed in
# state (backend went down between calls). Per
# .claude/rules/destruction-safety.md "When a Safety Check Cannot Determine
# State", the correct default is FAIL, not SKIP. Same pattern as
# guard_control_plane_recreate above (see #538).
guard_vmid_changes() {
  # No args; reads CONFIG_FILE / APPS_CONFIG / TOFU_BIN from the outer scope.
  # Returns 0 to proceed with the apply, 1 to block.
  local vmid_state_stderr_file vmid_state_list vmid_state_rc

  # Discriminate first-deploy (state list succeeded, no VMs) from
  # indeterminate (state list errored — backend down, state lock, network
  # partition, uninitialized backend).
  #
  # Pre-fix (#540) code was `if "$TOFU_BIN" state list 2>/dev/null | grep -q
  # "..."; then`, which swallowed the exit code and treated a backend outage
  # identically to first-deploy — silently disabling this guard precisely
  # when the state backend was degraded and accidental VMID renames were
  # most dangerous to PBS backup continuity. Adversarial review of MR !407
  # (#538, CP-guard fix) flagged this as the same class of failure in the
  # same file; scoped out of #538 to keep that MR focused.
  #
  # First-deploy expectations: the pipeline runs `tofu init` before this
  # apply, and post-init `tofu state list` returns rc=0 with empty stdout
  # on a genuine first deploy — that path returns 0 below. If `tofu init`
  # failed (uninitialized backend), the rc check here fails closed, which
  # is the correct behavior: an uninitialized backend means we cannot prove
  # anything about the state, and the pipeline should stop with a clear
  # diagnostic rather than proceed unguarded.
  #
  # Capture stderr into a tmpfile so the operator gets the real cause (pq
  # error / state lock / missing init) in one round trip, not just an exit
  # code.
  vmid_state_stderr_file="$(mktemp -t vmid-guard-state.XXXXXX)"
  set +e
  vmid_state_list="$("$TOFU_BIN" state list 2>"$vmid_state_stderr_file")"
  vmid_state_rc=$?
  set -e
  if [[ $vmid_state_rc -ne 0 ]]; then
    echo "ERROR (G7): VMID-change guard cannot determine tofu state" >&2
    echo "       (${TOFU_BIN} state list exit ${vmid_state_rc}). Failing closed:" >&2
    echo "       cannot prove this apply won't silently rename a VMID and break" >&2
    echo "       PBS backup continuity for precious-state VMs." >&2
    echo "       Common causes: postgres backend unreachable, state lock held," >&2
    echo "       network partition to the NAS, backend not initialized." >&2
    if [[ -s "$vmid_state_stderr_file" ]]; then
      echo "       tofu state list stderr:" >&2
      sed 's/^/         /' "$vmid_state_stderr_file" >&2
    fi
    echo "       Investigate the backend before rerunning; do not use" >&2
    echo "       --allow-vmid-change to work around a backend issue." >&2
    rm -f "$vmid_state_stderr_file"
    return 1
  fi
  rm -f "$vmid_state_stderr_file"

  # First deploy: state is queryable but contains no VMs yet. Nothing to
  # compare against.
  if ! grep -q "proxmox_virtual_environment_vm" <<< "$vmid_state_list"; then
    return 0
  fi

  local VMID_CHANGES=""
  local vm_key PLANNED_VMID VM_ADDR CURRENT_VMID HAS_BACKUP
  local vmid_show_stderr_file vmid_show_output vmid_show_rc
  local app_key env APP_MODULE
  local vmid_expected_outer vmid_expected_inner vmid_addr_re

  # Hoist the vmid_show stderr temp file above the loops (#543 item 1):
  # pre-fix code called `mktemp` inside every loop iteration and paired
  # each with an explicit `rm -f`. All happy-path exits cleaned up but a
  # SIGINT during a loop iteration would leak the last-in-flight file, and
  # the per-iteration syscall was wasted work. Now the file is created
  # once and truncated (`: > "$file"`) before each capture; a SIGINT still
  # leaks at most this one file (vs one per VM pre-fix). We stay in bash
  # 3.2 territory: no RETURN trap, and no script-level EXIT trap because
  # the wrapper is invoked from external scripts with their own cleanup.
  vmid_show_stderr_file="$(mktemp -t vmid-guard-show.XXXXXX)"

  # Check infrastructure VMs.
  # Null-safe: `.vms // {}` handles a missing/null `.vms` block; without
  # this, an operator config with no VMs would trip `set -e` inside yq's
  # keys pipeline. Symmetric to the `.applications // {}` handling in the
  # app loop below (#543 item 3).
  for vm_key in $(yq -r '.vms // {} | keys | .[]' "$CONFIG_FILE"); do
    PLANNED_VMID=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG_FILE")
    [[ -z "$PLANNED_VMID" || "$PLANNED_VMID" == "null" ]] && continue
    # Resolve the expected tofu state address for this vm_key (#542).
    # The pre-fix filter was `grep -i "$(echo "$vm_key" | tr '_' '-')"`
    # against the cached state list — it fails structurally in two ways:
    #   (1) The `tr '_' '-'` transform breaks for every vm_key whose
    #       outer module preserves underscores. For dns1_prod the search
    #       string becomes "dns1-prod" but the state address is
    #       `module.dns_prod.module.dns1.proxmox_virtual_environment_vm.vm`
    #       — no substring "dns1-prod" anywhere. The DNS pair members
    #       are the failure the issue names; other underscore-preserving
    #       state addresses fall in the same class.
    #   (2) Unanchored substring matches allow false positives: a
    #       hypothetical `db` vm_key would match a `db-replica` state
    #       address and `head -1` would pick whichever printed first.
    # Fix: derive the exact expected state address from vm_key using the
    # main.tf naming convention, then anchor the match with grep -E:
    #   - DNS pair-structured (dns[12]_<env>): outer = dns_<env>,
    #     inner = dns[12] (matches dns-pair module's `module "dns1"` /
    #     `module "dns2"`).
    #   - Everything else: outer = vm_key; the inner may be absent
    #     (direct proxmox-vm wrap, e.g. pbs, hil_boot) or exactly one
    #     intermediate module segment (e.g. module.vault_prod.module.vault.…,
    #     module.gitlab.module.gitlab.…). `(\.module\.[^.]+)?` makes
    #     the inner optional and pins it to exactly one segment when
    #     present, blocking substring collisions between sibling names.
    # `(\[[0-9]+\])?` accepts optional `[N]` index between outer and
    # inner. In main.tf, all app-catalog modules use `count = try(...) ? 1
    # : 0` (framework/tofu/root/main.tf:801/844/889/928/969/1007/1047/1099
    # — influxdb, grafana, roon, workstation), producing state addresses
    # like `module.influxdb_dev[0].module.influxdb.…`. No current infra
    # module uses count, but adding the optional index here is free
    # future-proofing and closes the same substring-collision surface
    # covered by the outer/inner anchors.
    case "$vm_key" in
      dns[12]_prod) vmid_expected_outer="dns_prod"; vmid_expected_inner="${vm_key%_prod}" ;;
      dns[12]_dev)  vmid_expected_outer="dns_dev";  vmid_expected_inner="${vm_key%_dev}" ;;
      *)            vmid_expected_outer="$vm_key";  vmid_expected_inner="" ;;
    esac
    if [[ -n "$vmid_expected_inner" ]]; then
      vmid_addr_re="^module\.${vmid_expected_outer}(\[[0-9]+\])?\.module\.${vmid_expected_inner}\.proxmox_virtual_environment_vm\.vm$"
    else
      vmid_addr_re="^module\.${vmid_expected_outer}(\[[0-9]+\])?(\.module\.[^.]+)?\.proxmox_virtual_environment_vm\.vm$"
    fi
    # `|| true` protects the assignment under `set -o pipefail` when the
    # grep produces no matches (a normal case: this vm_key does not
    # correspond to any state address yet — first-create).
    VM_ADDR=$(grep -E "$vmid_addr_re" <<< "$vmid_state_list" | head -1) || true
    # Not in state yet — first-create of this VM; nothing to compare.
    [[ -z "$VM_ADDR" ]] && continue
    # Read the current vm_id, failing closed on backend error. Pre-fix
    # (#540) used `state show ... 2>/dev/null | ... || echo ""`, which
    # swallowed both the exit code and any stderr, and fed an empty
    # CURRENT_VMID into the comparison — a real backend problem looked
    # identical to "no drift".
    # Truncate the hoisted stderr file so a prior iteration's error text
    # cannot leak into this iteration's diagnostics (#543 item 1).
    : > "$vmid_show_stderr_file"
    set +e
    vmid_show_output="$("$TOFU_BIN" state show "$VM_ADDR" 2>"$vmid_show_stderr_file")"
    vmid_show_rc=$?
    set -e
    if [[ $vmid_show_rc -ne 0 ]]; then
      echo "ERROR (G7): VMID-change guard cannot read current VMID for ${vm_key}" >&2
      echo "       (${TOFU_BIN} state show '${VM_ADDR}' exit ${vmid_show_rc})." >&2
      echo "       Failing closed: cannot prove the planned VMID matches the" >&2
      echo "       current one, so cannot prove PBS backup continuity is safe." >&2
      if [[ -s "$vmid_show_stderr_file" ]]; then
        echo "       tofu state show stderr:" >&2
        sed 's/^/         /' "$vmid_show_stderr_file" >&2
      fi
      rm -f "$vmid_show_stderr_file"
      return 1
    fi
    # Anchor `^ *vm_id *=` (#543 item 2) so a nested-attribute line like
    # `template_vm_id = ...` or a comment mentioning "vm_id" cannot be
    # picked as the vm_id line. `awk '{print $3}'` still extracts the
    # value column (real tofu output aligns "vm_id" with spaces around
    # "=", e.g. `  vm_id                     = 150`).
    CURRENT_VMID=$(grep -E '^ *vm_id *=' <<< "$vmid_show_output" | head -1 | awk '{print $3}') || true
    # rc=0 but empty CURRENT_VMID: state show succeeded but produced no
    # parseable `vm_id` line. Pre-fix (#540) used `... || echo ""` which
    # treated this as "no drift" — same class of silent fail-open as the
    # backend-error swallow above. Codex adversarial review of MR !408
    # flagged this as still-live P1 in the refactor; fail closed with G7
    # so the OpenTofu output that broke the parse surfaces to the operator.
    if [[ -z "$CURRENT_VMID" ]]; then
      echo "ERROR (G7): VMID-change guard could not parse current VMID for ${vm_key}" >&2
      echo "       from ${TOFU_BIN} state show '${VM_ADDR}' output. Failing closed:" >&2
      echo "       cannot prove the planned VMID matches the current one, so cannot" >&2
      echo "       prove PBS backup continuity is safe." >&2
      echo "       Common causes: OpenTofu state schema changed, resource address" >&2
      echo "       does not correspond to a proxmox_virtual_environment_vm, or the" >&2
      echo "       vm_id attribute was renamed." >&2
      echo "       tofu state show output:" >&2
      sed 's/^/         /' <<< "$vmid_show_output" >&2
      # P2-1 (adversarial review of the initial #543 fix, codex P2): the
      # hoisted vmid_show_stderr_file is created once at function scope;
      # failure-path returns must clean it up too, else every fail-closed
      # parse-error return leaks the temp file.
      rm -f "$vmid_show_stderr_file"
      return 1
    fi
    if [[ "$CURRENT_VMID" != "$PLANNED_VMID" ]]; then
      HAS_BACKUP=$(yq -r ".vms.${vm_key}.backup // false" "$CONFIG_FILE")
      VMID_CHANGES+="  ${vm_key}: ${CURRENT_VMID} → ${PLANNED_VMID}"
      [[ "$HAS_BACKUP" == "true" ]] && VMID_CHANGES+=" (HAS PRECIOUS STATE)"
      VMID_CHANGES+=$'\n'
    fi
  done

  # Check application VMs.
  # Symmetric to the infra loop (#543 item 4): drop `2>/dev/null` from
  # the outer app-loop yq so a malformed applications.yaml surfaces its
  # parse error rather than silently skipping every app VM. Null-safety
  # for the outer `.applications` is via `// {}`. The inner
  # `.environments` call does NOT get `// {}` — the app is already gated
  # on `.value.enabled == true`, so an enabled-but-envless application
  # is a config-schema bug the operator wants to see as a hard failure,
  # not silently skip. (Also: adding `// {}` here would match a residual
  # classifier-allowlist pattern that `tests/test_vm_scope_no_residual
  # _allowlists.sh` forbids outside a specific set of approved files.)
  for app_key in $(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG"); do
    for env in $(yq -r ".applications.${app_key}.environments | keys | .[]" "$APPS_CONFIG"); do
      PLANNED_VMID=$(yq -r ".applications.${app_key}.environments.${env}.vmid" "$APPS_CONFIG")
      [[ -z "$PLANNED_VMID" || "$PLANNED_VMID" == "null" ]] && continue
      APP_MODULE="${app_key}_${env}"
      # Same anchored-match strategy as the infra loop (#542). App main.tf
      # convention is `module "<app>_<env>"` wrapping proxmox-vm via a
      # submodule named after the app (module.<app>_<env>.module.<app>.vm).
      # `(\[[0-9]+\])?` accepts the optional `[N]` index that appears in
      # state when the outer module uses `count = try(...) ? 1 : 0` — the
      # standard catalog-app enable pattern in framework/tofu/root/main.tf
      # (influxdb, grafana, roon, workstation all use count). Without this,
      # the guard silently misses drift for every catalog app because
      # `module.influxdb_dev[0].module.influxdb.…` fails an anchor that
      # only allows `module.influxdb_dev.module.…`. `(\.module\.[^.]+)?`
      # allows either the wrapped or direct shape and pins the inner to
      # exactly one segment when present.
      vmid_addr_re="^module\.${APP_MODULE}(\[[0-9]+\])?(\.module\.[^.]+)?\.proxmox_virtual_environment_vm\.vm$"
      VM_ADDR=$(grep -E "$vmid_addr_re" <<< "$vmid_state_list" | head -1) || true
      [[ -z "$VM_ADDR" ]] && continue
      # Truncate the hoisted stderr file (#543 item 1).
      : > "$vmid_show_stderr_file"
      set +e
      vmid_show_output="$("$TOFU_BIN" state show "$VM_ADDR" 2>"$vmid_show_stderr_file")"
      vmid_show_rc=$?
      set -e
      if [[ $vmid_show_rc -ne 0 ]]; then
        echo "ERROR (G7): VMID-change guard cannot read current VMID for ${APP_MODULE}" >&2
        echo "       (${TOFU_BIN} state show '${VM_ADDR}' exit ${vmid_show_rc})." >&2
        echo "       Failing closed: cannot prove the planned VMID matches the" >&2
        echo "       current one, so cannot prove PBS backup continuity is safe." >&2
        if [[ -s "$vmid_show_stderr_file" ]]; then
          echo "       tofu state show stderr:" >&2
          sed 's/^/         /' "$vmid_show_stderr_file" >&2
        fi
        rm -f "$vmid_show_stderr_file"
        return 1
      fi
      # Same anchored parse as the infra loop (#543 item 2).
      CURRENT_VMID=$(grep -E '^ *vm_id *=' <<< "$vmid_show_output" | head -1 | awk '{print $3}') || true
      # rc=0 but empty CURRENT_VMID: same class as the infra loop above.
      if [[ -z "$CURRENT_VMID" ]]; then
        echo "ERROR (G7): VMID-change guard could not parse current VMID for ${APP_MODULE}" >&2
        echo "       from ${TOFU_BIN} state show '${VM_ADDR}' output. Failing closed:" >&2
        echo "       cannot prove the planned VMID matches the current one, so cannot" >&2
        echo "       prove PBS backup continuity is safe." >&2
        echo "       Common causes: OpenTofu state schema changed, resource address" >&2
        echo "       does not correspond to a proxmox_virtual_environment_vm, or the" >&2
        echo "       vm_id attribute was renamed." >&2
        echo "       tofu state show output:" >&2
        sed 's/^/         /' <<< "$vmid_show_output" >&2
        # P2-1: clean up the hoisted temp file on the fail-closed
        # app-loop parse-error return.
        rm -f "$vmid_show_stderr_file"
        return 1
      fi
      if [[ "$CURRENT_VMID" != "$PLANNED_VMID" ]]; then
        HAS_BACKUP=$(yq -r ".applications.${app_key}.backup // false" "$APPS_CONFIG")
        VMID_CHANGES+="  ${APP_MODULE}: ${CURRENT_VMID} → ${PLANNED_VMID}"
        [[ "$HAS_BACKUP" == "true" ]] && VMID_CHANGES+=" (HAS PRECIOUS STATE)"
        VMID_CHANGES+=$'\n'
      fi
    done
  done

  # Clean up the hoisted stderr temp file at every happy-path return
  # (#543 item 1). rm -f is idempotent so a double-call from a failure
  # path that already removed the file is safe.
  rm -f "$vmid_show_stderr_file"
  if [[ -n "$VMID_CHANGES" ]]; then
    echo "ERROR: VMID changes detected:" >&2
    printf '%s' "$VMID_CHANGES" >&2
    echo "PBS backup continuity will break for affected VMs." >&2
    echo "Use --allow-vmid-change to proceed." >&2
    return 1
  fi
  return 0
}

ALLOW_VMID_CHANGE=0
ALLOW_PLACEHOLDER_IMAGES=0
for arg in "$@"; do
  case "$arg" in
    --allow-vmid-change) ALLOW_VMID_CHANGE=1 ;;
    --allow-placeholder-images) ALLOW_PLACEHOLDER_IMAGES=1 ;;
  esac
done

TOFU_COMMAND="${1:-}"

if [[ "$TOFU_COMMAND" == "apply" && $ALLOW_VMID_CHANGE -eq 0 ]]; then
  if ! guard_vmid_changes; then
    exit 1
  fi
fi

# --- Image value validation gate ---
if [[ "$TOFU_COMMAND" == "plan" || "$TOFU_COMMAND" == "apply" ]]; then
  if ! validate_image_versions_file "$IMAGE_VERSIONS" "$TOFU_COMMAND" "$ALLOW_PLACEHOLDER_IMAGES"; then
    exit 1
  fi
fi

# --- Control-plane converge-vs-recreate gate ---
# Runs only on apply. See guard_control_plane_recreate above for rationale.
if [[ "$TOFU_COMMAND" == "apply" ]]; then
  if ! guard_control_plane_recreate "$@"; then
    exit 1
  fi
fi

# Strip wrapper-only flags before passing args to tofu
TOFU_ARGS=()
for arg in "$@"; do
  if [[ "$arg" != "--allow-vmid-change" && "$arg" != "--allow-placeholder-images" ]]; then
    TOFU_ARGS+=("$arg")
  fi
done

# --- Run tofu ---
# Pass image-versions from site/tofu/ for commands that accept -var-file
# -var-file is conditional (only when $IMAGE_VERSIONS exists AND the subcommand
# is one of plan/apply/destroy/refresh) because: (1) image-versions.auto.tfvars
# is a build artifact generated by build-image.sh/build-all-images.sh and is
# not always present (fresh checkout, init-only invocations, or bring-up
# steps that run before any image build); (2) this wrapper only needs to
# feed image_versions to the standard plan/apply flow. Many OpenTofu
# subcommands (init/validate/output/show/state/import/console/test/providers
# on tofu 1.11+) also accept -var-file, but they do not need image_versions
# to do their job here; unconditional pass-through is not required and is
# not attempted. See #63.
FIRST_ARG="${TOFU_ARGS[0]:-}"
if [[ -f "$IMAGE_VERSIONS" ]] && [[ "$FIRST_ARG" == "plan" || "$FIRST_ARG" == "apply" || "$FIRST_ARG" == "destroy" || "$FIRST_ARG" == "refresh" ]]; then
  exec "$TOFU_BIN" "${TOFU_ARGS[0]}" -var-file="$IMAGE_VERSIONS" "${TOFU_ARGS[@]:1}"
else
  exec "$TOFU_BIN" "${TOFU_ARGS[@]}"
fi
