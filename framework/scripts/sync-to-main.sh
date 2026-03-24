#!/usr/bin/env bash
# sync-to-main.sh — Sync framework changes from dev branch to main.
#
# The main branch (pushed to GitHub) contains framework/ and docs but not site/.
# The dev branch (pushed to private GitLab) contains everything.
#
# Usage: framework/scripts/sync-to-main.sh "description of framework changes"

set -euo pipefail

# --- Parse arguments ---
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 \"commit message\"" >&2
  exit 1
fi
COMMIT_MSG="$1"

# --- Verify clean working tree ---
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: Working tree has uncommitted changes. Commit or stash first." >&2
  exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "dev" ]]; then
  echo "ERROR: Must be on the dev branch (currently on: $CURRENT_BRANCH)" >&2
  exit 1
fi

# --- Sync to main ---
echo "Checking out main..."
git checkout main

echo "Applying framework changes from dev..."
git diff main..dev -- framework/ docs/ README.md architecture.md GETTING-STARTED.md OPERATIONS.md .gitlab-ci.yml | git apply --allow-empty

echo "Staging and committing..."
git add -A
if git diff --cached --quiet; then
  echo "No changes to commit."
  git checkout dev
  exit 0
fi
git commit -m "$COMMIT_MSG"

echo "Pushing main to origin (GitHub)..."
git push origin main

echo "Checking out dev..."
git checkout dev

echo "Merging main into dev..."
git merge main --no-edit

echo "Pushing dev to gitlab..."
git push gitlab dev

echo "Done. Framework changes synced to main and merged back."
