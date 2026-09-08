#!/usr/bin/env bash
# test_nix_execreload_privilege_ratchet.sh — repo-wide guard for the #642 class.
#
# systemd runs ExecReload= control processes under the unit's own credentials.
# A unit with a non-root User= (or DynamicUser=true) whose ExecReload shells out
# to `systemctl` is therefore asking PID 1 to perform a unit-management
# operation (KillUnit/ReloadUnit) that requires root or polkit
# `manage-units` — neither of which our VMs have. The reload fails with
# "Access denied" and, because callers like certbot's deploy hooks fail soft,
# nothing goes red.
#
# This ratchet fails if any .nix under framework/nix/ or site/nix/ reintroduces
# that shape. The sanctioned forms are:
#   - direct same-user signalling:  ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
#   - an explicit privilege prefix: ExecReload = "+${pkgs.systemd}/bin/systemctl ...";
#
# RCA: docs/reports/rca-2026-07-18-vault-execreload-access-denied.md

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

# --- The detector -----------------------------------------------------------
#
# Emits one line per violation: "<file>:<line>: <reason>"
# Exits 0 always; callers inspect the output.
#
# Tier A: serviceConfig = { ... } blocks are brace-matched and analyzed
#         precisely (non-root user AND unprefixed systemctl ExecReload).
# Tier B: any ExecReload assigned outside such a block (e.g. a dotted-path
#         `systemd.services.foo.serviceConfig.ExecReload = ...`) cannot be
#         attributed to a User=, so it fails closed if it invokes systemctl
#         without a privilege prefix. Per .claude/rules/destruction-safety.md,
#         a check that cannot determine safety must FAIL, not skip.
scan_nix_file() {
  local file="$1"
  awk -v FNAME="$file" '
    # Strip Nix line comments up front. Anything after an unquoted # on a
    # line is a comment. We approximate by trimming after # when it is not
    # inside a "..." or ${...} span on the same line; for the ratchet class
    # (User=, ExecReload=, +/! prefix, systemctl token) this is enough.
    function strip_comment(s,   i, ch, out, in_q) {
      in_q = 0
      out = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (ch == "\"") in_q = !in_q
        if (ch == "#" && !in_q) break
        out = out ch
      }
      return out
    }

    function flush_block(   user_state) {
      if (!in_block) return
      # reload_seen is the "did the block contain an ExecReload assignment"
      # flag; reload_open is the "is the assignment still accumulating"
      # state within the block. We flag when the block ended after seeing an
      # unprivileged systemctl-invoking ExecReload under a non-provably-root
      # user (either a named non-root user, DynamicUser=true, or a
      # non-literal User= expression).
      if (reload_seen && reload_systemctl && !reload_privileged &&
          (user_present && user_value != "root")) {
        if (dynamic_user)         user_state = "DynamicUser=true"
        else if (user_value == "") user_state = "User=<non-literal, cannot prove root>"
        else                       user_state = "User=" user_value
        printf "%s:%d: unit with %s has ExecReload invoking systemctl without a + or ! privilege prefix\n", \
          FNAME, reload_line, user_state
      }
      in_block = 0; depth = 0
      user_present = 0; user_value = ""; dynamic_user = 0
      reload_seen = 0; reload_open = 0; reload_line = 0
      reload_systemctl = 0; reload_privileged = 0
    }

    # ---- global pre-processing: strip comments before every match --------
    { line = strip_comment($0) }

    # ---- enter a serviceConfig block --------------------------------------
    !in_block && line ~ /serviceConfig[[:space:]]*=[[:space:]]*\{/ {
      in_block = 1; depth = 0
      user_present = 0; user_value = ""; dynamic_user = 0
      reload_seen = 0; reload_open = 0; reload_line = 0
      reload_systemctl = 0; reload_privileged = 0
    }

    in_block {
      # User detection — fail-closed on non-literal values. Any `User = ...`
      # assignment marks the service as non-root UNLESS the value is the
      # string literal "root". A variable or expression (User = userVar;)
      # leaves user_value = "" and user_state reports it as non-provably
      # root; the check flags in that case rather than treating it as root.
      if (line !~ /DynamicUser/ && match(line, /(^|[^A-Za-z])User[[:space:]]*=/)) {
        user_present = 1
        rhs = substr(line, RSTART + RLENGTH)
        if (match(rhs, /^[[:space:]]*"[^"]*"/)) {
          seg = substr(rhs, RSTART, RLENGTH)
          match(seg, /"[^"]*"/)
          user_value = substr(seg, RSTART + 1, RLENGTH - 2)
        } else {
          user_value = ""  # non-literal expression
        }
      }
      if (line ~ /DynamicUser[[:space:]]*=[[:space:]]*true/) {
        user_present = 1
        dynamic_user = 1
      }

      # ExecReload — start accumulating from the assignment; keep looking
      # for systemctl / privilege prefix until the closing `;` (or the end
      # of the block). Handles multi-line and multi-string forms.
      if (!reload_open && match(line, /ExecReload[[:space:]]*=/)) {
        reload_seen = 1
        reload_open = 1
        reload_line = FNR
        reload_rest = substr(line, RSTART + RLENGTH)
      } else if (reload_open) {
        reload_rest = line
      } else {
        reload_rest = ""
      }

      if (reload_open) {
        if (reload_rest ~ /systemctl/) reload_systemctl = 1
        # A privilege prefix is `+` or `!` at the START of a command string.
        # Match the first character after the opening quote of any string
        # literal we see on the assignment.
        if (reload_rest ~ /"[+!]/) reload_privileged = 1
        # Statement terminator ends the assignment. A `;` inside a "..."
        # span is unlikely for ExecReload; keep the heuristic simple.
        if (reload_rest ~ /;/) reload_open = 0
      }

      # brace-depth tracking finds the end of the block
      n = gsub(/\{/, "{", line); m = gsub(/\}/, "}", line)
      depth += n - m
      if (depth <= 0) flush_block()
      next
    }

    # ---- Tier B: ExecReload outside any analyzed serviceConfig block -----
    # We cannot attribute a User=, so we fail-closed: if it invokes systemctl
    # and there is no `+`/`!` privilege prefix, flag it.
    line ~ /ExecReload[[:space:]]*=/ {
      rhs = substr(line, index(line, "ExecReload"))
      if (rhs ~ /systemctl/ && rhs !~ /"[+!]/) {
        printf "%s:%d: ExecReload invoking systemctl outside an analyzable serviceConfig block (cannot prove it runs as root)\n", FNAME, FNR
      }
    }

    END { flush_block() }
  ' "$file"
}

# --- Positive control: the detector must actually detect ---------------------

test_start "RATCHET.1" "detector flags a synthetic non-root systemctl ExecReload"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT

cat > "${fixture_dir}/bad.nix" <<'EOF'
{
  systemd.services.example = {
    serviceConfig = {
      Type = "simple";
      User = "example";
      Group = "example";
      ExecStart = "${pkgs.example}/bin/example";
      ExecReload = "${pkgs.systemd}/bin/systemctl kill -s HUP example.service";
    };
  };
}
EOF

if [[ -n "$(scan_nix_file "${fixture_dir}/bad.nix")" ]]; then
  test_pass "synthetic violation detected"
else
  test_fail "detector did NOT flag a known-bad unit — the ratchet is inert"
fi

test_start "RATCHET.2" "detector accepts the sanctioned forms"
cat > "${fixture_dir}/good.nix" <<'EOF'
{
  systemd.services.direct = {
    serviceConfig = {
      User = "direct";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
    };
  };
  systemd.services.prefixed = {
    serviceConfig = {
      User = "prefixed";
      ExecReload = "+${pkgs.systemd}/bin/systemctl kill --kill-whom=main -s HUP prefixed.service";
    };
  };
  systemd.services.rootunit = {
    serviceConfig = {
      ExecReload = "${pkgs.systemd}/bin/systemctl kill -s HUP rootunit.service";
    };
  };
  systemd.services.explicitroot = {
    serviceConfig = {
      User = "root";
      ExecReload = "${pkgs.systemd}/bin/systemctl kill -s HUP explicitroot.service";
    };
  };
}
EOF

good_hits="$(scan_nix_file "${fixture_dir}/good.nix")"
if [[ -z "${good_hits}" ]]; then
  test_pass "no false positives on direct-signal, +prefixed, root-unit, and explicit User=root forms"
else
  test_fail "false positive(s): ${good_hits}"
fi

# --- Regression fixtures for reviewer findings ------------------------------

test_start "RATCHET.2b" "detector flags multi-line ExecReload assignment"
# codex/agy/sub-claude review, P1: original detector only inspected the RHS
# on the same line as `ExecReload =`. Trivial reformatting bypassed it.
cat > "${fixture_dir}/multiline.nix" <<'EOF'
{
  systemd.services.multi = {
    serviceConfig = {
      User = "multi";
      ExecReload =
        "${pkgs.systemd}/bin/systemctl kill -s HUP multi.service";
    };
  };
}
EOF
if [[ -n "$(scan_nix_file "${fixture_dir}/multiline.nix")" ]]; then
  test_pass "multi-line assignment is flagged"
else
  test_fail "multi-line assignment bypasses the ratchet"
fi

test_start "RATCHET.2c" "detector flags non-literal User= (fail-closed)"
# agy P1: `User = someVar;` left nonroot_user empty in the original, so the
# unit was assumed to be root. Fail-closed default is safer.
cat > "${fixture_dir}/varuser.nix" <<'EOF'
{
  systemd.services.varuser = {
    serviceConfig = {
      User = serviceUser;
      ExecReload = "${pkgs.systemd}/bin/systemctl kill -s HUP varuser.service";
    };
  };
}
EOF
if [[ -n "$(scan_nix_file "${fixture_dir}/varuser.nix")" ]]; then
  test_pass "non-literal User= is treated as non-provably-root and flagged"
else
  test_fail "non-literal User= bypasses the ratchet"
fi

test_start "RATCHET.2d" "detector ignores commented-out lines"
# Cosmetic reformatting or a documentation snippet in a comment must not
# false-fail the ratchet.
cat > "${fixture_dir}/comment.nix" <<'EOF'
{
  systemd.services.commented = {
    serviceConfig = {
      User = "commented";
      # Historical bad shape kept as a WARNING in the comment:
      #   ExecReload = "${pkgs.systemd}/bin/systemctl kill -s HUP commented.service";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
    };
  };
}
EOF
comment_hits="$(scan_nix_file "${fixture_dir}/comment.nix")"
if [[ -z "${comment_hits}" ]]; then
  test_pass "commented ExecReload is ignored"
else
  test_fail "false positive on commented-out ExecReload: ${comment_hits}"
fi

# --- The ratchet itself ------------------------------------------------------

test_start "RATCHET.3" "no unprivileged systemctl ExecReload under framework/nix or site/nix"
violations=""
while IFS= read -r nix_file; do
  hits="$(scan_nix_file "${nix_file}")"
  [[ -n "${hits}" ]] && violations+="${hits}"$'\n'
done < <(find "${REPO_ROOT}/framework/nix" "${REPO_ROOT}/site/nix" -type f -name '*.nix' | sort)

if [[ -z "${violations//[$'\n' ]/}" ]]; then
  test_pass "clean sweep"
else
  test_fail "unprivileged systemctl ExecReload found:"$'\n'"${violations}"
fi

runner_summary
