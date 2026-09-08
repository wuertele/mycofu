#!/usr/bin/env bash
# hil-boot-secret-env.sh — decrypt one SOPS key for explicit Nix derivation input.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  hil-boot-secret-env.sh CONFIG SOPS_KEY

Decrypt CONFIG's sibling sops/secrets.yaml and print SOPS_KEY to stdout.
The caller exports the result as MYCOFU_HIL_BOOT_ROOT_PASSWORD before
building hil-boot derivations with nix --impure.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

CONFIG="$1"
SOPS_KEY="$2"

if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
  echo "ERROR: SOPS_AGE_KEY_FILE is required for hil-boot secret injection" >&2
  exit 2
fi

if [[ ! -r "$SOPS_AGE_KEY_FILE" ]]; then
  echo "ERROR: SOPS_AGE_KEY_FILE is not readable: $SOPS_AGE_KEY_FILE" >&2
  exit 2
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config not found: $CONFIG" >&2
  exit 2
fi

case "$SOPS_KEY" in
  (*[!A-Za-z0-9_.-]*|"")
    echo "ERROR: unsafe SOPS key name: $SOPS_KEY" >&2
    exit 2
    ;;
esac

SOPS_FILE="$(dirname "$CONFIG")/sops/secrets.yaml"
if [[ ! -f "$SOPS_FILE" ]]; then
  echo "ERROR: SOPS file not found: $SOPS_FILE" >&2
  exit 2
fi

SOPS_ERR="$(mktemp "${TMPDIR:-/tmp}/hil-boot-sops.XXXXXX")"
cleanup() {
  rm -f "$SOPS_ERR"
}
trap cleanup EXIT

set +e
VALUE="$(sops -d --extract "[\"${SOPS_KEY}\"]" "$SOPS_FILE" 2>"$SOPS_ERR")"
SOPS_RC=$?
set -e
if [[ "$SOPS_RC" -ne 0 ]]; then
  echo "ERROR: failed to decrypt SOPS key '${SOPS_KEY}' from ${SOPS_FILE}" >&2
  if [[ -s "$SOPS_ERR" ]]; then
    sed 's/^/  sops: /' "$SOPS_ERR" >&2
  fi
  exit 2
fi
if [[ -z "$VALUE" || "$VALUE" == "null" ]]; then
  echo "ERROR: SOPS key '${SOPS_KEY}' is missing or empty in ${SOPS_FILE}" >&2
  exit 2
fi

printf '%s\n' "$VALUE"
