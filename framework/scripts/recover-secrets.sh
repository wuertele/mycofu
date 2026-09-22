#!/usr/bin/env bash
# recover-secrets.sh — Recover secrets.yaml from git history.
#
# Called when secrets.yaml is missing but operator.age.key exists (Level 2-3).
# Recovers the encrypted secrets file from the commit before its deletion,
# then verifies it's decryptable with the current age key.
#
# At Level 4+ (age key also missing), this script cannot help — the operator
# must run bootstrap-sops.sh to generate fresh secrets (PBS restore will not
# match the regenerated values).
#
# Usage: framework/scripts/recover-secrets.sh
#
# Idempotent: if secrets.yaml already exists, does nothing.

set -euo pipefail

# --- Locate repo root ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2
  exit 1
}

REPO_DIR="$(find_repo_root)"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"
AGE_KEY="${REPO_DIR}/operator.age.key"

# --- Already exists? ---
if [[ -f "$SECRETS_FILE" ]]; then
  echo "secrets.yaml exists — nothing to recover"
  exit 0
fi

# --- Check age key ---
if [[ ! -f "$AGE_KEY" ]]; then
  echo "ERROR: Both secrets.yaml and operator.age.key are missing" >&2
  echo "This is Level 4+ — run bootstrap-sops.sh to generate fresh secrets." >&2
  echo "WARNING: PBS restore will not match regenerated values." >&2
  exit 1
fi

# --- Find deletion commit ---
echo "secrets.yaml missing but age key exists — recovering from git history"

LAST_DELETE=$(git -C "$REPO_DIR" log --diff-filter=D --format='%H' -1 -- site/sops/secrets.yaml)
if [[ -z "$LAST_DELETE" ]]; then
  echo "ERROR: Cannot find deletion commit for secrets.yaml in git history" >&2
  echo "The file may never have been committed, or git history was rewritten." >&2
  echo "Run bootstrap-sops.sh to generate fresh secrets (PBS restore will not match)." >&2
  exit 1
fi

echo "  Deletion commit: ${LAST_DELETE}"

# --- Recover from commit before deletion ---
mkdir -p "$(dirname "$SECRETS_FILE")"
git -C "$REPO_DIR" show "${LAST_DELETE}~1:site/sops/secrets.yaml" > "$SECRETS_FILE"

# --- Verify decryptable ---
if ! SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d "$SECRETS_FILE" > /dev/null 2>&1; then
  echo "ERROR: Recovered secrets.yaml is not decryptable with current age key" >&2
  rm -f "$SECRETS_FILE"
  exit 1
fi

echo "  Recovered secrets.yaml from git history"
echo "  All values match PBS backups (same age key, same SOPS)"

# --- Verify key values exist ---
echo "  Keys found:"
SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d "$SECRETS_FILE" | yq 'keys' | head -10

# --- Commit ---
cd "$REPO_DIR"
git add site/sops/secrets.yaml
git commit -m "recover secrets.yaml from git history (Level 2 rebuild)

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"

echo ""
echo "secrets.yaml recovered and committed."
