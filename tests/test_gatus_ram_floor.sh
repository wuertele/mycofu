#!/usr/bin/env bash
#
# Regression test for issue #420: gatus VM ram_mb floor.
#
# Pipelines 1121 (dev tip da7a07c4) and 1124 (dev tip 62ba356) failed
# test:dev at gatus with kernel_oom_total>=3. Root cause: gatus had
# ram_mb=256, leaving ~24 MiB available after gatus.service and the
# NixOS base. certbot-renew's Python interpreter (~50 MiB virt /
# ~25 MiB rss) OOM-killed on every renewal timer firing. MR !316 bumped
# ram_mb to 512 to give certbot headroom.
#
# This test prevents reintroduction of the OOM by asserting that the
# gatus module never drops ram_mb below 512.
#
# A future framework refactor that parameterizes ram_mb via config.yaml
# (Option B in #420) MUST keep the floor: the module argument default
# or the config.yaml value must still be >= 512.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

GATUS_TF="${REPO_ROOT}/framework/tofu/modules/gatus/main.tf"
RAM_MB_FLOOR=512

test_start "1" "gatus module ram_mb assignment is at or above the OOM floor"

if [[ ! -f "${GATUS_TF}" ]]; then
  test_fail "gatus main.tf not found at expected path: ${GATUS_TF}"
  runner_summary
  exit 1
fi

# Extract the ram_mb assignment line. The module uses either a numeric
# literal (current shape: ram_mb = 512) or a variable reference (future
# parameterized shape: ram_mb = var.ram_mb). Catch both.
ram_line=$(grep -E '^\s*ram_mb\s*=' "${GATUS_TF}" | head -1 || true)

if [[ -z "${ram_line}" ]]; then
  test_fail "no ram_mb assignment found in gatus module"
  runner_summary
  exit 1
fi

# Strip everything before "=" and any trailing comments. Use POSIX
# bracket classes (NOT \s) for macOS/BSD sed compatibility.
ram_value=$(echo "${ram_line}" | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*#.*//; s/[[:space:]]+$//')

if [[ "${ram_value}" =~ ^[0-9]+$ ]]; then
  # Numeric literal — assert the floor directly.
  if [[ "${ram_value}" -ge "${RAM_MB_FLOOR}" ]]; then
    test_pass "gatus ram_mb = ${ram_value} (>= ${RAM_MB_FLOOR})"
  else
    test_fail "gatus ram_mb = ${ram_value} is below the ${RAM_MB_FLOOR} MB floor required to prevent certbot OOM (#420)"
  fi
elif [[ "${ram_value}" =~ ^var\. ]]; then
  # Parameterized via a variable. The default in variables.tf (or the
  # value passed by the caller in framework/tofu/root/main.tf) MUST
  # still be >= 512. Walk variables.tf for a default; if none, walk
  # callers; if neither floor can be proven, fail closed.
  vars_tf="${REPO_ROOT}/framework/tofu/modules/gatus/variables.tf"
  var_name="${ram_value#var.}"
  default_value=""

  if [[ -f "${vars_tf}" ]]; then
    # Extract the default within a variable "ram_mb" block, if present.
    default_value=$(awk -v vn="${var_name}" '
      $0 ~ "^[[:space:]]*variable[[:space:]]+\"" vn "\"" { in_block=1; next }
      in_block && /^[[:space:]]*}/ { in_block=0 }
      in_block && /^[[:space:]]*default[[:space:]]*=/ {
        sub(/.*=[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        print
        exit
      }
    ' "${vars_tf}")
  fi

  if [[ "${default_value}" =~ ^[0-9]+$ ]]; then
    if [[ "${default_value}" -ge "${RAM_MB_FLOOR}" ]]; then
      test_pass "gatus ram_mb = ${ram_value} with default ${default_value} (>= ${RAM_MB_FLOOR})"
    else
      test_fail "gatus ram_mb = ${ram_value} has default ${default_value} below the ${RAM_MB_FLOOR} MB floor (#420)"
    fi
  else
    # Parameterized without a proven floor in variables.tf — fail
    # closed. The introducing change should either (a) set a default
    # >= 512 in variables.tf, or (b) update this test to walk the
    # specific caller path that supplies the value.
    test_fail "gatus ram_mb is parameterized as ${ram_value} but no >=${RAM_MB_FLOOR} default proven in ${vars_tf} — see #420"
  fi
else
  test_fail "gatus ram_mb has unrecognized form: '${ram_value}' (expected numeric literal or var.<name>)"
fi

runner_summary
