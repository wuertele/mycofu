#!/usr/bin/env bash
# test_backup_now_per_vm_freshness.sh — #547 per-VM freshness anchor race,
# with #602 Option 2 (sleep-1 gap between anchor sample and vzdump).
#
# Reproduces the concurrent-scheduled-backup race that a run-wide freshness
# anchor cannot catch and that a per-VM anchor closes structurally.
#
# The race (as filed in #547):
#
#   1. backup-now.sh starts at T0. It sequentially backs up VM A, then VM B.
#   2. VM A's vzdump runs and lands normally.
#   3. Between VM A finishing and VM B starting, PBS's own scheduled backup
#      job runs for VM B at T_ghost, where T0 < T_ghost < (VM B's own
#      pre-vzdump sample).
#   4. backup-now.sh's vzdump for VM B is silently dropped (the FG-11
#      failure mode #97/!410 was designed to catch: vzdump exits 0 with no
#      data write).
#   5. The volid-diff for VM B picks up the scheduled backup's volid because
#      it is new relative to VM B's BEFORE snapshot.
#   6. With a run-wide anchor at T0, the ghost's ctime T_ghost > T0 passes
#      the freshness gate. The ghost is recorded as VM B's pin.
#   7. Operator sees success. Ghost is invisible.
#
# With a per-VM anchor sampled from PBS's own clock immediately before VM
# B's vzdump, the gate becomes ctime > pre_vzdump_epoch_for_B (strict).
# The ghost has ctime <= pre_vzdump_epoch_for_B by construction (it was
# created BEFORE we started B's vzdump), so it is rejected. That is the
# G3 structural elimination this test locks in.
#
# #602 followed up: strict > false-rejected small precious-state VMs
# (vault-dev, roon-dev) whose vzdump completed in the same wall-clock
# second as the anchor sample (ctime == pre_vzdump_epoch). Every dev
# deploy since #547 landed failed on
#   FATAL: PBS is configured but backup failed. Refusing to deploy.
#
# Option 2: backup_vm() now sleeps 1 s AFTER sample_pbs_epoch() and
# BEFORE ssh ... vzdump. This guarantees a real vzdump's ctime is at
# least pre_vzdump_epoch + 1 — strictly greater than the anchor — so the
# strict > gate accepts real backups while still rejecting same-second
# ghosts (which cannot originate from our vzdump under this discipline).
#
# G4 teeth for #547: run against the OLD run-wide-anchor code and PVMF.1
# flips to a false-pass — VM 313 records the ghost pin instead of
# failing closed. The fixture is calibrated so ghost ctime > T0 (which is
# what run-wide anchor sees) and ghost ctime < T_313_pre_vzdump (which is
# what per-VM anchor sees).
#
# G4 teeth for #602: PVMF.5 asserts a real backup with
# ctime == pre_vzdump_epoch + 1 (the smallest-VM Option-2 case) passes.
# Remove the sleep-1 gap and PVMF.5 still passes (ctime is set by the
# fixture, not real time) but exposes the un-guarded strict > check to
# real-world same-second landings — which PVMF.6 explicitly covers.
# PVMF.6 asserts a real backup with ctime == pre_vzdump_epoch (same-
# second) MUST FAIL under strict >, which is the specific defect that
# would return if we relaxed strict > to >=.
#
# G4 teeth for verify_backup_pins strict > (codex P2 finding on the
# Option 2 review): PVMF.6 tests the CAPTURE-time strict > at
# verify_backup_landed_in_pbs. PVMF.7 constructs a listing regression
# scenario where capture accepts (ctime = anchor + 1) but the final
# verify pass sees ctime == anchor — isolating verify_backup_pins'
# strict > check. Flipping <= to < at only one of the two call sites
# would not flip PVMF.6 red; PVMF.7 exists so both sites have their own
# regression witness.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
STATE_DIR="${TMP_DIR}/state"
SSH_LOG="${TMP_DIR}/ssh.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${FIXTURE_REPO}/build" "$SHIM_DIR" "$STATE_DIR"
cp "${REPO_ROOT}/framework/scripts/backup-now.sh" "${FIXTURE_REPO}/framework/scripts/backup-now.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/backup-now.sh"

cat > "${FIXTURE_REPO}/framework/scripts/vm-scope.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  control-plane-modules) ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/vm-scope.sh"

cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
certbot_cluster_expected_mode() { echo "staging"; }
EOF
cat > "${FIXTURE_REPO}/framework/scripts/vm-health-lib.sh" <<'EOF'
#!/usr/bin/env bash
VM_HEALTH_LAST_REASON=""
vm_health_check() { VM_HEALTH_LAST_REASON="ok"; return 0; }
EOF

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
proxmox:
  storage_pool: vmstore
vms:
  vault_dev:
    vmid: 303
    ip: 10.0.0.303
    backup: true
  influx_dev:
    vmid: 313
    ip: 10.0.0.313
    backup: true
EOF
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

# Two-VM yq shim. Order of the .vms iteration query is load-bearing —
# vault_dev must come before influx_dev so VM 303 backs up first and its
# pre_vzdump_epoch (sample #1) is strictly less than VM 313's pre_vzdump_epoch
# (sample #2). That's the ordering the race depends on.
cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
query="${2:-}"
case "$query" in
  ".nodes[].mgmt_ip") echo "127.0.0.1" ;;
  ".proxmox.storage_pool // \"vmstore\"") echo "vmstore" ;;
  ".vms | to_entries[] | select(.value.backup == true) | .key")
    printf 'vault_dev\ninflux_dev\n'
    ;;
  ".vms.vault_dev.vmid")  echo "303" ;;
  ".vms.vault_dev.ip")    echo "10.0.0.303" ;;
  ".vms.influx_dev.vmid") echo "313" ;;
  ".vms.influx_dev.ip")   echo "10.0.0.313" ;;
  ".applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key")
    ;;
  *)
    echo "unexpected yq query: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/yq"

# SSH shim with a scripted timeline. The script calls SSH with the same
# outer form regardless of intent, so we distinguish by the last-argument
# command pattern.
#
# Content-listing calls (5 total in this scenario):
#   1. initial EXISTING_PBS_JSON  → history-only for both VMs
#   2. VM 303 BEFORE               → history-only for both VMs
#   3. VM 303 AFTER                → 303 has history + fresh (ctime=T_303_fresh)
#   4. VM 313 BEFORE               → 303 has history + fresh; 313 has history only
#   5. VM 313 AFTER                → 313 has history + GHOST (ctime=T_ghost)
#
# date-clock calls (2 total in this scenario), used by sample_pbs_epoch:
#   1. VM 303 pre_vzdump_epoch     → T_303_pre = 1_000_000_010
#   2. VM 313 pre_vzdump_epoch     → T_313_pre = 1_000_000_040
#
# Fixed ctimes:
#   T_303_fresh = 1_000_000_015  (> T_303_pre; VM 303 backup lands cleanly)
#   T_ghost     = 1_000_000_020  (> T_303_pre so a run-wide anchor at
#                                 T_303_pre would ACCEPT — this is the bug
#                                 the pre-fix code exhibits;
#                                 < T_313_pre so the per-VM anchor for VM
#                                 313 REJECTS — this is what the fix
#                                 guarantees)
#
# The counters live in STATE_DIR so a fresh run_backup() call sees a fresh
# timeline.
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf '%s\n' "$cmd" >> "${SSH_LOG}"

# #591 marker capture. When vzdump is called with --notes-template, extract
# the marker value and save it per-VMID; the AFTER content listings then
# embed it in the "fresh" entry's notes field so the identity gate in
# verify_backup_landed_in_pbs / verify_backup_pins accepts our legitimate
# backups. Ghost entries in the "race" / "same_vm_ghost" scenarios below
# deliberately omit or mismatch this marker so the identity gate rejects
# them.
capture_notes_template_marker() {
  local vmid="$1"
  local marker=""
  marker="$(printf '%s\n' "$cmd" | sed -n "s/.*--notes-template '\([^']*\)'.*/\1/p")"
  if [[ -n "$marker" ]]; then
    printf '%s' "$marker" > "${STATE_DIR}/marker_${vmid}"
  fi
}
read_notes_template_marker() {
  local vmid="$1"
  cat "${STATE_DIR}/marker_${vmid}" 2>/dev/null || printf '%s' ""
}

# The MANAGED_MARKER written by configure-backups.sh's --notes-template.
# Ghost entries in race/tie/same_vm_ghost scenarios embed this so the
# identity gate has something plausible (not empty) to reject.
# Defined at shim top level so both the count==5 AFTER handler and the
# count>=6 FINAL_PBS_JSON --verify handler can reference it without
# tripping `set -u`.
SCHEDULED_MARKER='Precious state -- automated by configure-backups.sh'

case "$cmd" in
  "pvesm status 2>/dev/null | grep -q pbs-nas")
    exit 0
    ;;
  "date -u +%s")
    count_file="${STATE_DIR}/date_count"
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    scenario_now=$(cat "${STATE_DIR}/scenario" 2>/dev/null || echo race)
    if [[ "$scenario_now" == "clock_fail" && "$count" -eq 1 ]]; then
      # PVMF.4: SSH date sample for VM 303 returns nothing (simulating
      # a PBS SSH clock probe failure). sample_pbs_epoch signals failure
      # via empty stdout; backup_vm must fail-close the VM instead of
      # falling back to workstation clock.
      exit 1
    fi
    case "$count" in
      1) echo "1000000010" ;;   # T_303_pre_vzdump
      2) echo "1000000040" ;;   # T_313_pre_vzdump
      *)
        echo "unexpected date sample #${count}" >&2
        exit 9
        ;;
    esac
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    count_file="${STATE_DIR}/query_count"
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"

    T_303_fresh=1000000015
    T_ghost=1000000020

    case "$count" in
      1|2)
        # Initial existing + VM 303 BEFORE: both VMs have only historical
        # backups. has_history=1 fires so the first-deploy skip does not.
        jq -nc '[
          {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
          {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"}
        ]'
        ;;
      3|4)
        # VM 303 AFTER (count 3) and VM 313 BEFORE (count 4): VM 303's
        # fresh backup has landed; VM 313 still only has history.
        # Dispatch on scenario for VM 303's ctime so PVMF.5, PVMF.6 and
        # PVMF.7 can vary VM 303's landing time relative to its anchor
        # (T_303_pre = 1000000010). PVMF.1/PVMF.2/PVMF.3/PVMF.4 use the
        # default T_303_fresh = 1000000015.
        scenario=$(cat "${STATE_DIR}/scenario" 2>/dev/null || echo race)
        case "$scenario" in
          next_second|verify_regress|verify_identity_regress)
            T_303_use=1000000011   # T_303_pre + 1 (PVMF.5, PVMF.7, PVMF.9 accept)
            ;;
          same_second)
            T_303_use=1000000010   # T_303_pre (PVMF.6)
            ;;
          *)
            T_303_use="$T_303_fresh"
            ;;
        esac
        marker_303="$(read_notes_template_marker 303)"
        # PVMF.10 (comment_key): capture-time listing routes the marker
        # through `.comment` with `.notes` empty. Everything else uses
        # the `.notes` key.
        if [[ "$scenario" == "comment_key" ]]; then
          jq -nc --argjson tf "$T_303_use" --arg n303 "$marker_303" '[
            {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
            {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: "", comment: $n303},
            {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"}
          ]'
        else
          jq -nc --argjson tf "$T_303_use" --arg n303 "$marker_303" '[
            {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
            {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: $n303},
            {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"}
          ]'
        fi
        ;;
      5)
        # VM 313 AFTER: dispatch on scenario.
        scenario=$(cat "${STATE_DIR}/scenario" 2>/dev/null || echo race)
        marker_303="$(read_notes_template_marker 303)"
        marker_313="$(read_notes_template_marker 313)"
        # SCHEDULED_MARKER hoisted to shim top level so both the count==5
        # AFTER handler here and the count>=6 FINAL --verify handler
        # below reference the same constant. See the top-of-file
        # definition for the rationale.
        case "$scenario" in
          race)
            # The concurrent scheduled backup landed a ghost snapshot for
            # VM 313 while we were busy with VM 303. Its ctime sits
            # BETWEEN T_303_pre_vzdump and T_313_pre_vzdump. Pre-fix
            # code accepts; post-fix code rejects.
            jq -nc --argjson tf "$T_303_fresh" --argjson tg "$T_ghost" \
              --arg n303 "$marker_303" --arg nsched "$SCHEDULED_MARKER" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/ghost",   ctime: $tg,         size: 67890, format: "pbs-vm", notes: $nsched}
            ]'
            ;;
          tie)
            # Ghost's ctime EQUALS T_313_pre_vzdump. Under a
            # non-strict >= gate this would false-accept; under the
            # post-#547 strict > gate (codex P1 fix) it must be
            # rejected because we cannot distinguish "ghost landed
            # just before the anchor sample within the same PBS
            # second" from "ghost landed strictly after" without a
            # sub-second clock or a per-run marker.
            T_313_pre=1000000040
            jq -nc --argjson tf "$T_303_fresh" --argjson tg "$T_313_pre" \
              --arg n303 "$marker_303" --arg nsched "$SCHEDULED_MARKER" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/tie",     ctime: $tg,         size: 67890, format: "pbs-vm", notes: $nsched}
            ]'
            ;;
          healthy)
            # Both VMs land clean, fresh backups. Under --verify this
            # exercises the pin-map 7-column round-trip end to end:
            # pin_map_set writes both rows with pre_vzdump_epoch,
            # verify_backup_pins reads column 7 and gates on it,
            # pin_file_write_from_map turns the map into the JSON pin
            # file with both entries. A ctime just after T_313_pre keeps
            # it fresh under the per-VM gate for VM 313.
            T_313_fresh=1000000050
            jq -nc --argjson tf "$T_303_fresh" --argjson tf313 "$T_313_fresh" \
              --arg n303 "$marker_303" --arg n313 "$marker_313" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: $n313}
            ]'
            ;;
          next_second|verify_regress|verify_identity_regress)
            # PVMF.5 (next_second): Option 2 minimum gap. Both VMs' real
            # vzdump lands with ctime == pre_vzdump_epoch + 1 — the
            # smallest legitimate gap after the sleep-1 guarantee. Under
            # strict > this passes (1 > 0).
            #
            # PVMF.7 (verify_regress): capture time sees the same clean
            # +1 landings so capture-time strict > accepts, pin_map_set
            # writes 7-column rows, and the run advances to the
            # --verify final pass. verify_backup_pins then queries the
            # final content listing (count 6+) and sees a stale/regressed
            # listing where ctime == anchor — see the count>=6 case.
            #
            # PVMF.9 (verify_identity_regress): same +1 capture-time
            # landings so capture passes and the pin map records both;
            # the count>=6 case then serves a listing where the pinned
            # volid entries have their notes replaced by SCHEDULED_MARKER,
            # exercising verify_backup_pins' identity gate independently
            # of verify_backup_landed_in_pbs's (PVMF.8's target).
            T_303_next=1000000011   # 303_pre (1000000010) + 1
            T_313_next=1000000041   # 313_pre (1000000040) + 1
            jq -nc --argjson tf303 "$T_303_next" --argjson tf313 "$T_313_next" \
              --arg n303 "$marker_303" --arg n313 "$marker_313" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf303,      size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: $n313}
            ]'
            ;;
          comment_key)
            # PVMF.10: capture-time listing routes the marker through
            # `.comment` with `.notes` empty for both VMs' fresh
            # entries. Exercises pbs_backup_notes_carry_our_marker's
            # independent-any check (formerly `.notes // .comment`
            # short-circuit, which false-rejected this shape).
            T_313_fresh=1000000050
            jq -nc --argjson tf "$T_303_fresh" --argjson tf313 "$T_313_fresh" \
              --arg n303 "$marker_303" --arg n313 "$marker_313" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: "", comment: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: "", comment: $n313}
            ]'
            ;;
          same_second)
            # PVMF.6: Real backup lands with ctime == pre_vzdump_epoch
            # (same second as anchor sample). This is the #602 defect
            # scenario: without Option 2's sleep-1 gap, a small VM's
            # real vzdump could land in the same PBS-second as
            # sample_pbs_epoch and be false-rejected by strict >. The
            # test locks in the strict > behavior: same-second lands
            # ALWAYS fail the freshness gate, regardless of whether
            # they are ghost or real, because at 1-s resolution we
            # cannot tell them apart. Option 2 keeps this from biting
            # real backups by adding the sleep. Removing that sleep
            # would flip this test from "asserting rejection" to
            # "asserting real-backup rejection" — which is what #602
            # documented in production. The test asserts the code path
            # for `ctime == anchor` is REJECT; PVMF.5 asserts +1 is
            # ACCEPT; together they lock in the exact behavior Option 2
            # requires.
            T_303_same=1000000010   # 303_pre
            T_313_same=1000000040   # 313_pre
            jq -nc --argjson tf303 "$T_303_same" --argjson tf313 "$T_313_same" \
              --arg n303 "$marker_303" --arg n313 "$marker_313" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf303,      size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: $n313}
            ]'
            ;;
          same_vm_ghost)
            # PVMF.8: #591 residual same-VM window. VM 303 lands cleanly
            # with our marker. VM 313's vzdump silently drops (FG-11),
            # but a PBS-scheduled backup for VM 313 lands during our
            # vzdump-in-flight interval with ctime = T_313_pre + 5 —
            # strictly AFTER our anchor, so the freshness gate would
            # accept it. The scheduled backup carries the configure-
            # backups.sh MANAGED_MARKER in notes, NOT our per-run
            # marker. Only the identity gate rejects it.
            T_313_ghost=1000000045   # T_313_pre + 5 (passes strict > freshness)
            jq -nc --argjson tf "$T_303_fresh" --argjson tg "$T_313_ghost" \
              --arg n303 "$marker_303" --arg nsched "$SCHEDULED_MARKER" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/samevm-ghost", ctime: $tg,    size: 67890, format: "pbs-vm", notes: $nsched}
            ]'
            ;;
          *)
            echo "unexpected scenario: $scenario" >&2
            exit 9
            ;;
        esac
        ;;
      *)
        # PVMF.2 / PVMF.5 (--verify) issue one additional
        # pbs_content_json call after backup_vm returns for the
        # FINAL_PBS_JSON second-pass verify. Answer with the same
        # scenario's AFTER listing so verify_backup_pins sees the same
        # fresh pins the capture-time code just recorded.
        scenario=$(cat "${STATE_DIR}/scenario" 2>/dev/null || echo race)
        marker_303="$(read_notes_template_marker 303)"
        marker_313="$(read_notes_template_marker 313)"
        case "$scenario" in
          healthy)
            T_313_fresh=1000000050
            jq -nc --argjson tf "$T_303_fresh" --argjson tf313 "$T_313_fresh" \
              --arg n303 "$marker_303" --arg n313 "$marker_313" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: $n313}
            ]'
            ;;
          next_second)
            T_303_next=1000000011
            T_313_next=1000000041
            jq -nc --argjson tf303 "$T_303_next" --argjson tf313 "$T_313_next" \
              --arg n303 "$marker_303" --arg n313 "$marker_313" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf303,      size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: $n313}
            ]'
            ;;
          verify_regress)
            # PVMF.7: final content listing regresses to ctime == anchor
            # for BOTH VMs after the capture-time checks accepted them
            # at ctime == anchor + 1. This models a hypothetical stale
            # PBS cache or index divergence between capture and verify.
            # The specific point of the test is to independently exercise
            # verify_backup_pins' strict > gate. If someone relaxed
            # verify_backup_pins' check from <= to < (accepting equality)
            # while leaving verify_backup_landed_in_pbs untouched, PVMF.6
            # would still pass because that VM never reaches
            # verify_backup_pins. Only THIS test flips.
            T_303_same=1000000010   # T_303_pre — verify sees ctime == anchor
            T_313_same=1000000040   # T_313_pre
            jq -nc --argjson tf303 "$T_303_same" --argjson tf313 "$T_313_same" \
              --arg n303 "$marker_303" --arg n313 "$marker_313" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf303,      size: 67890, format: "pbs-vm", notes: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: $n313}
            ]'
            ;;
          verify_identity_regress)
            # PVMF.9 (codex-P2 review of #591): capture-time passed with
            # the correct marker (see the count 3/4/5 case just above
            # with T_303_next / T_313_next), but the --verify FINAL
            # content listing shows the pinned volid entries with their
            # notes REPLACED by SCHEDULED_MARKER. Models the concrete
            # concern: a scheduled backup job rewrote the notes on the
            # pinned volid entry between capture and verify (or a stale
            # PBS index served a different notes field on re-read).
            # Only verify_backup_pins' independent identity check
            # catches this — a code path that removed the verify-time
            # marker check but kept the capture-time one would still
            # false-pass PVMF.8 (which fires at capture time). PVMF.9
            # provides the second-call-site regression witness.
            T_303_next=1000000011
            T_313_next=1000000041
            jq -nc --argjson tf303 "$T_303_next" --argjson tf313 "$T_313_next" \
              --arg nsched "$SCHEDULED_MARKER" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf303,      size: 67890, format: "pbs-vm", notes: $nsched},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: $nsched}
            ]'
            ;;
          comment_key)
            # PVMF.10 (codex-P2 review of #591): Proxmox has surfaced
            # backup notes under two different keys — .notes and .comment
            # — across storage-plugin versions. Route the marker through
            # `.comment` (with `.notes` empty) to prove
            # pbs_backup_notes_carry_our_marker's independent-any check
            # accepts. Under the pre-fix `.notes // .comment` fallback,
            # this shape would false-reject (`.notes` empty non-null
            # short-circuits before .comment is considered).
            T_313_fresh=1000000050
            jq -nc --argjson tf "$T_303_fresh" --argjson tf313 "$T_313_fresh" \
              --arg n303 "$marker_303" --arg n313 "$marker_313" '[
              {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $tf,         size: 67890, format: "pbs-vm", notes: "", comment: $n303},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
              {vmid: 313, volid: "pbs-nas:backup/vm/313/fresh",   ctime: $tf313,      size: 67890, format: "pbs-vm", notes: "", comment: $n313}
            ]'
            ;;
          *)
            echo "unexpected default content query in scenario ${scenario} at count ${count}" >&2
            exit 9
            ;;
        esac
        ;;
    esac
    ;;
  "qm status 303") echo "status: running" ;;
  "qm status 313") echo "status: running" ;;
  vzdump\ 303\ --storage\ pbs-nas*)
    capture_notes_template_marker 303
    ;;
  vzdump\ 313\ --storage\ pbs-nas*)
    # #547 scenario: our vzdump for VM 313 is silently dropped (exits 0,
    # no data write). That is exactly the FG-11 failure mode. The AFTER
    # content listing surfaces the ghost from the concurrent scheduled
    # backup, and the freshness anchor is what tells us the ghost is not
    # ours.
    #
    # #591: even when vzdump-for-313 silently drops, the notes-template
    # marker still carries our BACKUP_NOW_RUN_ID. We capture it so
    # scenarios where a legitimate VM 313 backup does land (healthy,
    # next_second, verify_regress, same_second) can embed the correct
    # marker in the fresh entry. The race/tie/same_vm_ghost scenarios
    # ignore this and deliberately mismatch the notes.
    capture_notes_template_marker 313
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_backup() {
  local name="$1"
  local scenario="$2"
  shift 2
  : > "$SSH_LOG"
  # Reset per-run state including the #591 marker capture files so each
  # scenario starts from a fresh BACKUP_NOW_RUN_ID and cannot pick up a
  # prior run's marker (which would false-pass the identity gate).
  rm -f "${STATE_DIR}/query_count" "${STATE_DIR}/date_count" \
        "${STATE_DIR}/marker_303" "${STATE_DIR}/marker_313"
  printf '%s\n' "$scenario" > "${STATE_DIR}/scenario"
  set +e
  OUT="$(PATH="${SHIM_DIR}:${PATH}" SSH_LOG="$SSH_LOG" STATE_DIR="$STATE_DIR" \
    bash -c 'name="$1"; shift; cd "$0" && framework/scripts/backup-now.sh --env dev --pin-out "build/${name}.json" "$@"' \
    "$FIXTURE_REPO" "$name" "$@" 2>&1)"
  RC=$?
  set -e
  PIN_FILE="${FIXTURE_REPO}/build/${name}.json"
}

pin_has() {
  local vmid="$1"
  [[ -f "$PIN_FILE" ]] || return 1
  jq -e --arg v "$vmid" '.pins[$v] // empty' "$PIN_FILE" >/dev/null 2>&1
}
pin_volid() {
  local vmid="$1"
  jq -r --arg v "$vmid" '.pins[$v].volid // empty' "$PIN_FILE" 2>/dev/null
}

test_start "PVMF.1" "concurrent scheduled backup ghost for VM 313 fails the per-VM anchor"
run_backup race race
# Post-fix expectations:
#   * backup-now.sh exits non-zero (VM 313 failed the freshness gate)
#   * VM 303 recorded its legitimate fresh pin (pins.303.volid = fresh)
#   * VM 313 did NOT record any pin (the ghost was rejected)
#   * Failure message names the pre-vzdump anchor and points at the
#     concurrent-scheduled-backup possibility (operator-facing diagnostic)
#
# Under pre-fix code (run-wide BACKUP_RUN_START_EPOCH sampled once at T_303_pre):
#   * exit 0
#   * pins.313.volid == "pbs-nas:backup/vm/313/ghost"  ← the bug
if [[ "$RC" -ne 0 ]] \
   && pin_has 303 \
   && [[ "$(pin_volid 303)" == "pbs-nas:backup/vm/303/fresh" ]] \
   && ! pin_has 313 \
   && grep -Fq 'is not strictly after pre-vzdump anchor' <<< "$OUT" \
   && grep -Fq 'concurrent scheduled backup' <<< "$OUT"; then
  test_pass "per-VM anchor rejects ghost while accepting VM 303's legitimate backup"
else
  test_fail "concurrent-schedule race not closed (pre-fix behavior detected)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.2" "--verify healthy path: 7-column pin map round-trips through verify_backup_pins"
# Coverage for the --verify second pass. The three code paths the #547
# fix touches on this path are:
#   * pin_map_set writes 7 tab-separated columns (7th = pre_vzdump_epoch)
#   * verify_backup_pins reads column 7 and gates ctime strictly > that value
#   * pin_file_write_from_map reads 7 columns (7th discarded) to write
#     the JSON pin file
#
# Without at least one healthy 2-VM --verify run, a future refactor
# could silently drop column 7 from pin_map_set and neither the JSON
# pin file nor the "is not strictly after pre-vzdump anchor" diagnostic would catch
# it — the read-side would just fail-closed on every entry, and PVMF.1
# would keep passing because its ghost is rejected at capture time
# (before pin_map_set fires).
#
# Both VMs land clean, fresh backups. --verify runs. Assertions:
#   (a) exit 0
#   (b) both VMID 303 and 313 pins recorded in the JSON pin file
#   (c) the verifier's OK diagnostic line appears for both VMIDs
run_backup healthy_verify healthy --verify
if [[ "$RC" -eq 0 ]] \
   && pin_has 303 \
   && [[ "$(pin_volid 303)" == "pbs-nas:backup/vm/303/fresh" ]] \
   && pin_has 313 \
   && [[ "$(pin_volid 313)" == "pbs-nas:backup/vm/313/fresh" ]] \
   && grep -Fq 'OK: VMID 303' <<< "$OUT" \
   && grep -Fq 'OK: VMID 313' <<< "$OUT" \
   && grep -Fq 'Verified 2 backup(s)' <<< "$OUT"; then
  test_pass "--verify healthy path: pin-map 7-column round-trip works for both VMs"
else
  test_fail "--verify healthy path regressed (pin-map 7-column round-trip broken)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.3" "tie-edge: ghost ctime == pre_vzdump_epoch is rejected under strict >"
# Codex P1 adversarial case. A ghost that lands in the same PBS-second
# as our anchor sample has ctime == pre_vzdump_epoch. A non-strict >=
# gate would accept it (this is the false-accept edge codex flagged);
# the strict > gate we adopted rejects it.
run_backup tie tie
if [[ "$RC" -ne 0 ]] \
   && pin_has 303 \
   && ! pin_has 313 \
   && grep -Fq 'is not strictly after pre-vzdump anchor' <<< "$OUT"; then
  test_pass "tie-edge ghost (ctime == anchor) rejected under strict >"
else
  test_fail "tie-edge ghost was accepted (strict > regression)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.4" "sample_pbs_epoch failure fails the VM closed (no workstation-clock fallback)"
# Codex P2 fix: pre-#547 code silently fell back to the workstation clock
# on an SSH sample failure. A workstation clock that lags PBS could
# false-accept a ghost with ctime < workstation-now but > PBS-now. The
# post-#547 code fails the VM closed. This test asserts that behavior:
# when the very first PBS-clock SSH probe returns non-numeric, VM 303's
# backup is FAILED and no pin is recorded.
#
# Also asserts that no vzdump command was issued for VM 303 — the safety
# gate must fail closed BEFORE vzdump runs, not after. If someone
# reordered the sleep to before sample_pbs_epoch (say, to remove the
# sleep entirely by moving it into the sample call) and left the vzdump
# invocation unguarded, PVMF.4's rc check might still pass on a later
# failure, but the ssh_log would show vzdump was called. That's a
# subtle correctness regression this stronger check catches.
run_backup clock_fail clock_fail
if [[ "$RC" -ne 0 ]] \
   && ! pin_has 303 \
   && grep -Fq 'could not obtain a per-VM freshness anchor' <<< "$OUT" \
   && grep -Fq 'refusing to record a pin' <<< "$OUT" \
   && ! grep -Fq 'vzdump 303 ' "$SSH_LOG"; then
  test_pass "SSH clock probe failure fails the VM closed with an operator-facing diagnostic and no vzdump was issued"
else
  test_fail "sample_pbs_epoch failure was not fail-closed (workstation-clock fallback regression, or vzdump ran despite anchor failure?)"
  printf 'rc=%s\nout:\n%s\nssh_log:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$SSH_LOG" 2>/dev/null)" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.5" "Option 2 minimum gap: ctime == pre_vzdump_epoch + 1 is accepted"
# #602 defect: strict > (without Option 2's sleep-1) false-rejected
# small precious-state VMs whose vzdump completed in the same PBS-
# second as the anchor sample. Option 2 inserts a fixed 1-s sleep after
# sample_pbs_epoch() so a real backup's ctime is guaranteed to be at
# least pre_vzdump_epoch + 1 (strictly greater than the anchor).
#
# This test asserts the smallest legitimate gap (+1) is accepted:
#   * VM 303 fresh ctime = 1000000011 == T_303_pre + 1  → PASS
#   * VM 313 fresh ctime = 1000000041 == T_313_pre + 1  → PASS
#
# Guards against a future refactor accidentally tightening strict > to
# require e.g. > pre_vzdump_epoch + 1 (which would silently re-break
# small-VM backups). Uses --verify to also exercise the pin-map 7-column
# round-trip for the +1 case.
run_backup next_second_verify next_second --verify
if [[ "$RC" -eq 0 ]] \
   && pin_has 303 \
   && [[ "$(pin_volid 303)" == "pbs-nas:backup/vm/303/fresh" ]] \
   && pin_has 313 \
   && [[ "$(pin_volid 313)" == "pbs-nas:backup/vm/313/fresh" ]] \
   && grep -Fq 'OK: VMID 303' <<< "$OUT" \
   && grep -Fq 'OK: VMID 313' <<< "$OUT" \
   && grep -Fq 'Verified 2 backup(s)' <<< "$OUT"; then
  test_pass "Option 2 minimum gap (ctime == anchor + 1) accepted for both VMs"
else
  test_fail "Option 2 minimum gap false-rejected (Option 2 sleep-1 discipline broken?)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.6" "same-second landing (ctime == pre_vzdump_epoch) rejected under strict >"
# The direct #602 defect scenario, before Option 2's sleep-1 was in
# place: a small VM's real vzdump completes in the same PBS-second as
# sample_pbs_epoch's response (ctime == pre_vzdump_epoch).
#
# Under strict > this is REJECTED. That is the correct behavior at
# 1-s PBS ctime resolution — we cannot distinguish "landed just after
# the anchor" from "landed just before" (or from a ghost that landed
# in that same second). Option 2's sleep-1 guarantees our own vzdump
# NEVER produces this scenario for a real backup, so the rejection is
# never observed in production for legitimate work. If Option 2's
# sleep were removed, this test's failure mode becomes production's
# failure mode — every dev deploy going red on
#   FATAL: PBS is configured but backup failed. Refusing to deploy.
#
# Assertion locks the strict > check in place. NEVER relax `<=` to `<`
# in verify_backup_landed_in_pbs / verify_backup_pins — doing so
# reopens the silent-drop + same-second ghost misattribution window
# (#97 / FG-11). If Option 2 needs to be revisited, adjust the sleep,
# not the comparison.
run_backup same_second same_second
if [[ "$RC" -ne 0 ]] \
   && ! pin_has 303 \
   && ! pin_has 313 \
   && grep -Fq 'is not strictly after pre-vzdump anchor' <<< "$OUT"; then
  test_pass "same-second ctime (ctime == anchor) rejected — strict > invariant preserved"
else
  test_fail "same-second ctime was accepted — strict > has been relaxed (FG-11 window reopened)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.8" "same-VM residual window: ghost with ctime > anchor but wrong notes marker is rejected"
# #591: the per-VM freshness anchor + strict > gate closes the CROSS-VM
# race (PVMF.1). It cannot catch the residual SAME-VM window where a
# PBS-scheduled backup for the SAME VMID fires during our vzdump-in-
# flight interval and lands with ctime > anchor. If our vzdump is
# silently dropped (FG-11) but the scheduled snapshot landed, the
# volid-diff picks up exactly one new volid whose ctime satisfies the
# freshness gate — but which is not ours.
#
# The scenario `same_vm_ghost` reproduces exactly that:
#   * VM 303 lands cleanly with our BACKUP_NOW_MARKER in notes
#   * VM 313's vzdump silently drops (FG-11)
#   * A scheduled backup for VM 313 lands with ctime = T_313_pre + 5
#     (strictly after our anchor) but with notes carrying the
#     configure-backups.sh MANAGED_MARKER, not ours
#
# Pre-fix (freshness-only) code accepts the ghost because ctime > anchor.
# Post-fix (freshness + identity) code rejects because notes do not
# carry BACKUP_NOW_MARKER. That is the #591 structural closure.
#
# The two-VM harness matters for the assertion "VM 303 pinned, VM 313
# not pinned" — a single-VM version could not distinguish "the marker
# check works for the ghost VM" from "the marker check breaks
# unconditionally" (which would also fail VM 303). If PVMF.8 flips red
# but PVMF.2/PVMF.5's healthy scenarios stay green, the failure is
# scoped to the ghost VM — which is exactly what a marker-gate
# regression would look like.
run_backup same_vm_ghost same_vm_ghost
if [[ "$RC" -ne 0 ]] \
   && pin_has 303 \
   && [[ "$(pin_volid 303)" == "pbs-nas:backup/vm/303/fresh" ]] \
   && ! pin_has 313 \
   && grep -Fq "does not carry this run's identity marker" <<< "$OUT" \
   && grep -Fq 'scheduled PBS backup job' <<< "$OUT"; then
  # Note: we intentionally grep on the stable "does not carry this run's
  # identity marker" phrase and on the operator-facing "scheduled PBS
  # backup job" hint rather than on a `#591` inline reference. If a
  # future refactor drops the `(#591)` parenthetical from the Check-line
  # (harmless human-readable choice) this test should not flip red —
  # the load-bearing assertion is that the identity gate fired and named
  # the concurrent-scheduled scenario, not that a specific issue number
  # is quoted.
  test_pass "identity gate rejects same-VM ghost while accepting VM 303's legitimate backup"
else
  test_fail "same-VM residual window not closed (identity gate missing or misconfigured)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.7" "verify_backup_pins strict > independently locked under --verify"
# Codex P2 (adversarial review of the Option 2 commit): PVMF.6 tests
# `verify_backup_landed_in_pbs` strict > at capture time, but does NOT
# lock `verify_backup_pins` strict > independently. If someone relaxed
# ONLY `verify_backup_pins` (line ~727) from <= to < while leaving
# `verify_backup_landed_in_pbs` (line ~652) untouched, PVMF.6 would
# still pass (its rejection happens at capture time, before pin_map_set
# fires and long before verify_backup_pins runs).
#
# This test constructs a scenario where capture time accepts (ctime =
# anchor + 1) but the FINAL_PBS_JSON verify pass sees ctime == anchor —
# modelling a listing regression between capture and final verify. Only
# `verify_backup_pins`'s strict > check catches it. If that check were
# relaxed to <=, the test flips red.
#
# The scenario is contrived (a real PBS won't roll ctime backwards)
# but that is the point — the test isolates the second call site so
# every strict > site has its own regression witness.
run_backup verify_regress verify_regress --verify
if [[ "$RC" -ne 0 ]] \
   && grep -Fq 'is not strictly after pre-vzdump anchor' <<< "$OUT"; then
  test_pass "verify_backup_pins strict > gate rejects ctime == anchor in --verify final pass"
else
  test_fail "verify_backup_pins accepted ctime == anchor — strict > has been relaxed at the --verify call site"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.9" "verify_backup_pins identity gate independently locked under --verify (codex-P2 of #591)"
# Codex P2 review of #591: PVMF.8 exercises verify_backup_landed_in_pbs's
# identity gate (capture-time). If a future refactor removed only the
# `--verify` identity gate at verify_backup_pins (leaving the capture-
# time one), PVMF.8 would still pass because its rejection happens at
# capture time, before pin_map_set fires and long before
# verify_backup_pins runs.
#
# This scenario `verify_identity_regress`:
#   * Capture time: both VMs land with our marker (T_pre + 1), all
#     capture-time gates accept, pin_map_set writes 7-column rows.
#   * --verify pass: FINAL content listing shows the pinned volid
#     entries with notes REPLACED by SCHEDULED_MARKER — modelling
#     a scheduled backup rewriting notes on the pinned volid between
#     capture and verify.
#
# Only verify_backup_pins' independent identity check catches this.
# If someone relaxed the identity gate ONLY at that call site (e.g.
# by removing the pbs_backup_notes_carry_our_marker check inside
# verify_backup_pins while leaving the one in
# verify_backup_landed_in_pbs), this test flips red.
run_backup verify_identity_regress verify_identity_regress --verify
if [[ "$RC" -ne 0 ]] \
   && grep -Fq "does not carry this run's identity marker" <<< "$OUT" \
   && grep -Fq 'scheduled PBS backup job' <<< "$OUT"; then
  # Symmetric with PVMF.8 (agy-substitute P2 review of the fold-in
  # commit): the marker phrase is unique to the identity gate, but
  # asserting the operator-facing "scheduled PBS backup job" hint too
  # locks the whole diagnostic surface — a regression that emitted a
  # different diagnostic in the verify_backup_pins case would still
  # false-pass without this grep.
  test_pass "verify_backup_pins identity gate rejects marker-swap in --verify final pass"
else
  test_fail "verify_backup_pins accepted a scheduled-marker swap — identity gate relaxed at the --verify call site"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PVMF.10" "identity gate accepts marker delivered via .comment when .notes is empty (codex-P2 of #591)"
# Codex P2 review of #591: Proxmox has surfaced backup notes under
# two different keys — `.notes` and `.comment` — across storage-plugin
# versions. A pre-review implementation of pbs_backup_notes_carry_our_marker
# used `.notes // .comment` which short-circuits on the first non-null
# value, false-rejecting the shape `{notes:"", comment:"<marker>"}`
# (empty notes are non-null, so the `.comment` fallback never runs).
#
# The post-review implementation checks both keys independently.
# This scenario `comment_key` routes the fresh marker through `.comment`
# with `.notes: ""` for both VMs. Under the pre-review implementation
# this test would flip red; under the post-review implementation both
# VMs' pins are recorded and the run exits 0.
#
# If a future refactor collapses back to the `.notes // .comment`
# short-circuit (or otherwise breaks the two-key acceptance), this
# test flips red.
run_backup comment_key comment_key
if [[ "$RC" -eq 0 ]] \
   && pin_has 303 \
   && [[ "$(pin_volid 303)" == "pbs-nas:backup/vm/303/fresh" ]] \
   && pin_has 313 \
   && [[ "$(pin_volid 313)" == "pbs-nas:backup/vm/313/fresh" ]]; then
  test_pass "identity gate accepts marker via .comment when .notes is empty (both keys queried independently)"
else
  test_fail "identity gate rejected marker delivered via .comment (short-circuit regression)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

runner_summary
