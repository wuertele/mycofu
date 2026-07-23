#!/usr/bin/env bash
# Shared OpenTofu binary resolver.
#
# MYCOFU_TOFU_BIN is the operator-controlled override used for workstation
# policy cases, such as a macOS-local signed tofu binary.

mycofu_resolve_tofu_bin() {
  if [[ -n "${MYCOFU_TOFU_BIN:-}" ]]; then
    if [[ ! -x "${MYCOFU_TOFU_BIN}" ]]; then
      echo "ERROR: MYCOFU_TOFU_BIN is not executable: ${MYCOFU_TOFU_BIN}" >&2
      return 1
    fi
    printf '%s\n' "${MYCOFU_TOFU_BIN}"
    return 0
  fi

  if command -v tofu >/dev/null 2>&1; then
    command -v tofu
    return 0
  fi

  echo "ERROR: Required tool not found: tofu" >&2
  echo "Run 'nix develop' from the repo root, or set MYCOFU_TOFU_BIN." >&2
  return 1
}
