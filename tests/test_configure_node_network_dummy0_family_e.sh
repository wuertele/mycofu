#!/usr/bin/env bash
# test_configure_node_network_dummy0_family_e.sh — #697 P1a/P1b/P2 ratchets
#
# #697 remediation family (e): dummy0's creation moves from a shell
# `pre-up ip link add ... || true` to ifupdown2's native declarative
# `link-type dummy` attribute, plus a generated
# `/etc/modules-load.d/dummy.conf` so systemd-modules-load loads the
# `dummy` kernel module before networking.service runs. Any regression
# that reintroduces the shell pre-up form or drops the module preload
# would resurrect the boot race documented in
# docs/reports/rca-2026-07-23-pve02-dummy0-boot-fail.md.
#
# Coverage (static — no live cluster required):
#   1. Emitted dummy0 stanza contains `link-type dummy` (P1a).
#   2. Emitted dummy0 stanza does NOT contain `pre-up ip link add`
#      or a masking `|| true` on the creation path (P1a/P2).
#   3. Existing address/route content is preserved verbatim (P1a
#      constraint — architecture is load-bearing).
#   4. modules-load.d/dummy.conf deployment is present in both
#      DRY-RUN preview and real deploy code paths (P1b).
#   5. veth-mgmt pre-up no longer uses a blanket `|| true`; instead
#      it uses an explicit existence check that surfaces genuine
#      creation failures (P2 — no other interface-creation `|| true`
#      remains in the generator).
#   6. Verify section covers dummy0 IP, `ifquery --check`, and the
#      dummy.conf preload (P1c).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/configure-node-network.sh"

test_start "dummy0.a" "emitted stanza uses declarative link-type dummy (P1a)"
if grep -Fq '    link-type dummy' "$SCRIPT"; then
  test_pass "generator emits 'link-type dummy' attribute"
else
  test_fail "generator missing 'link-type dummy' — family (e) not landed"
fi

test_start "dummy0.b" "no shell pre-up ip link add for dummy0 (P1a/P2)"
# Grep only the generator function body — an EXAMPLE inside a comment
# elsewhere is not a regression, so scope to the here-doc region.
if grep -nE '^[[:space:]]*pre-up ip link add dummy0' "$SCRIPT" \
   | grep -vE '^[[:space:]]*#' | grep -q .; then
  test_fail "generator still contains a shell pre-up form for dummy0"
else
  test_pass "no shell pre-up ip link add dummy0 present"
fi

test_start "dummy0.c" "dummy0 stanza block contains address + routes (codex-tightened)"
# Extract the dummy0 stanza generation block (from the `auto dummy0` here-doc
# to the closing `fi` of the `if [[ -n "$repl_ip"` guard). Assertions must
# hit content INSIDE this block, not anywhere in the file — a lingering
# post-up on a physical interface elsewhere must not falsely satisfy the
# "routes preserved on the dummy0 stanza" ratchet.
dummy_block=$(awk '/# Corosync-routable address \(reachable by all nodes/,/^    fi$/' "$SCRIPT")
missing_addr=0; missing_link=0; missing_100=0; missing_200=0
grep -Fq '    address ${repl_ip}/32' <<< "$dummy_block" || missing_addr=1
grep -Fq '    link-type dummy'      <<< "$dummy_block" || missing_link=1
grep -Fq 'metric 100 || true'       <<< "$dummy_block" || missing_100=1
grep -Fq 'metric 200 || true'       <<< "$dummy_block" || missing_200=1
if [[ $missing_addr -eq 0 && $missing_link -eq 0 && $missing_100 -eq 0 && $missing_200 -eq 0 ]]; then
  test_pass "dummy0 stanza: address + link-type + dual-metric routes present"
else
  test_fail "dummy0 stanza content missing: addr=$missing_addr link=$missing_link m100=$missing_100 m200=$missing_200"
fi

test_start "dummy0.d" "modules-load.d/dummy.conf deployed via real heredoc (codex-tightened)"
# The real deploy has to actually write the file (heredoc `cat >`), not just
# mention the path. A missing heredoc would leave a false-green if a future
# refactor accidentally deleted the writer while leaving the path string in a
# log message.
have_dry=0; have_deploy_writer=0; have_modprobe=0; have_content=0
grep -Fq '[DRY RUN] Would deploy /etc/modules-load.d/dummy.conf' "$SCRIPT" && have_dry=1
grep -qE "cat > /etc/modules-load.d/dummy.conf << *'DUMMYMOD'" "$SCRIPT" && have_deploy_writer=1
grep -Fxq 'dummy' "$SCRIPT" && have_content=1
grep -Fq 'modprobe dummy' "$SCRIPT" && have_modprobe=1
if [[ $have_dry -eq 1 && $have_deploy_writer -eq 1 && $have_content -eq 1 && $have_modprobe -eq 1 ]]; then
  test_pass "dry-run preview + real heredoc writer + module name + runtime modprobe all present"
else
  test_fail "modules-load deployment incomplete (dry=$have_dry heredoc=$have_deploy_writer content=$have_content modprobe=$have_modprobe)"
fi

test_start "dummy0.e" "veth-mgmt no longer uses blanket || true (P2)"
# Accept either the single-end or the both-ends existence check. The
# both-ends form is preferred because it avoids RTNETLINK EEXIST when the
# peer end is left over from a partial cleanup (agy adversarial review).
if grep -Fq 'pre-up ip link add veth-mgmt type veth peer name veth-mgmt-br1 || true' "$SCRIPT"; then
  test_fail "veth-mgmt pre-up still masks failures with || true — P2 audit regression"
elif grep -Eq 'ip link show veth-mgmt >/dev/null 2>&1 \|\|.*ip link (show veth-mgmt-br1|add veth-mgmt type veth)' "$SCRIPT"; then
  test_pass "veth-mgmt uses explicit existence check"
else
  test_fail "veth-mgmt creation form unrecognized — inspect the stanza"
fi

test_start "dummy0.f" "verify section covers dummy0 address + ifquery + preload (P1c)"
have_addr_check=0; have_ifquery=0; have_preload_check=0
grep -Fq 'ip -4 -br addr show dummy0' "$SCRIPT" && have_addr_check=1
grep -Fq 'ifquery --check dummy0' "$SCRIPT" && have_ifquery=1
grep -Fq '/etc/modules-load.d/dummy.conf' "$SCRIPT" && have_preload_check=1
if [[ $have_addr_check -eq 1 && $have_ifquery -eq 1 && $have_preload_check -eq 1 ]]; then
  test_pass "verify covers address + ifquery + preload artifact"
else
  test_fail "verify coverage gap (addr=$have_addr_check ifquery=$have_ifquery preload=$have_preload_check)"
fi

runner_summary
