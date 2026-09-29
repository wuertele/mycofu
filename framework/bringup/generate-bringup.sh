#!/usr/bin/env bash
# Bringup guide generator — shell wrapper
# Usage: ./framework/bringup/generate-bringup.sh [path/to/config.yaml] [output.md]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_PATH="${1:-${REPO_DIR}/site/config.yaml}"
OUTPUT_PATH="${2:-}"

# Check config exists
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_PATH}" >&2
  exit 2
fi

# Check Python 3
if ! command -v python3 &>/dev/null; then
  echo "ERROR: Python 3 is required but not installed" >&2
  exit 2
fi

# Check/install dependencies
for pkg in yaml jinja2; do
  if ! python3 -c "import ${pkg}" 2>/dev/null; then
    echo "Installing missing Python package: ${pkg}..."
    pip3 install --quiet "PyYAML" "Jinja2"
    break
  fi
done

# Run generator
if [[ -n "$OUTPUT_PATH" ]]; then
  python3 "${SCRIPT_DIR}/generate-bringup.py" "$CONFIG_PATH" "$OUTPUT_PATH"
else
  python3 "${SCRIPT_DIR}/generate-bringup.py" "$CONFIG_PATH"
fi
