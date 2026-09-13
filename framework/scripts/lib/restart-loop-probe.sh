#!/usr/bin/env bash
# restart-loop-probe.sh — Inner probe body for check-service-restart-loop.sh.
#
# Runs INSIDE a target VM (sent via SSH stdin) AND directly under bash in
# hermetic tests (with stub systemctl/journalctl on PATH). Keep this file
# self-contained: no dependencies on the outer helper's variables beyond
# the two thresholds NRESTARTS_MAX and OOM_MAX in env.
#
# Output contract (read by the outer helper's parser):
#   UNIT <unit> NRestarts=<n> Result=<r> ActiveState=<s>
#   KERNEL kernel_oom_total=<n>
#   PROBE_OK
#
# A successful probe ALWAYS emits PROBE_OK on its final line. Absence
# means the probe could not complete (DBus wedged, systemctl gone, etc.)
# and the outer helper must treat it as a probe error per
# .claude/rules/destruction-safety.md fail-closed discipline.
#
# Thresholds:
#   NRESTARTS_MAX: emit UNIT line if NRestarts > NRESTARTS_MAX
#   OOM_MAX:       emit KERNEL line if kernel_oom_total >= OOM_MAX
# Always emit UNIT line if ActiveState=failed or Result=oom-kill,
# regardless of NRestarts.

NRMAX="${NRESTARTS_MAX:-10}"
OOMMAX="${OOM_MAX:-3}"

# State scope: include activating (auto-restart loop spends time here) and
# failed (StartLimitBurst landing state). --state=active alone misses both.
#
# Capture systemctl output and rc DIRECTLY (not via pipeline). Pipelines
# without `set -o pipefail` give you the rc of the last stage, so
# `systemctl ... | awk ...` followed by `$?` returns awk's rc (always 0),
# masking any systemctl failure. R2 codex+sub-claude empirically verified
# that pattern lets DBus-wedged VMs report PROBE_OK with no findings —
# the exact class of false-green this probe is built to prevent.
list_out=$(systemctl list-units \
           --state=active,activating,failed \
           --type=service \
           --no-legend 2>/dev/null)
list_rc=$?

if [ "$list_rc" -ne 0 ]; then
  # systemctl wholly unreachable (DBus down, container without systemd as
  # pid 1, etc.). Fail closed — no PROBE_OK. Outer helper treats absence
  # of PROBE_OK as a probe error per .claude/rules/destruction-safety.md.
  exit 0
fi

units=$(printf '%s\n' "$list_out" | awk '{print $1}')

for unit in $units; do
  # Filter empty/whitespace rows.
  [ -z "$unit" ] && continue

  show_out=$(systemctl show \
              -p NRestarts -p Result -p ActiveState \
              "$unit" 2>/dev/null)
  show_rc=$?
  if [ "$show_rc" -ne 0 ]; then
    # systemctl unavailable mid-loop. Without this exit, we'd silently
    # skip the rest of the units and still emit PROBE_OK.
    exit 0
  fi

  nr=$(printf '%s\n' "$show_out" | awk -F= '/^NRestarts=/{print $2; exit}')
  result=$(printf '%s\n' "$show_out" | awk -F= '/^Result=/{print $2; exit}')
  active=$(printf '%s\n' "$show_out" | awk -F= '/^ActiveState=/{print $2; exit}')

  # Defensive: skip if NRestarts is missing/non-numeric (template units etc.)
  case "$nr" in ''|*[!0-9]*) continue ;; esac

  flag=0
  if [ "$nr" -gt "$NRMAX" ]; then
    flag=1
  elif [ "$result" = "oom-kill" ]; then
    flag=1
  elif [ "$active" = "failed" ]; then
    flag=1
  fi

  if [ "$flag" -eq 1 ]; then
    printf 'UNIT %s NRestarts=%s Result=%s ActiveState=%s\n' \
           "$unit" "$nr" "$result" "$active"
  fi
done

# Per-VM kernel-OOM check. Same pipeline-rc pattern as above: capture
# journalctl output and rc DIRECTLY, then grep over the captured text.
# The previous `journalctl | grep -c "..." || echo 0` form masked
# journalctl failures as "0 OOMs" (R2 finding).
journal_out=$(journalctl --boot -k --no-pager 2>/dev/null)
journal_rc=$?
if [ "$journal_rc" -ne 0 ]; then
  # journalctl unavailable — fail closed.
  exit 0
fi

oom_total=$(printf '%s\n' "$journal_out" | grep -c "Out of memory: Killed")
# grep -c returns 1 with stdout "0" on no match — sanitize to 0.
case "$oom_total" in ''|*[!0-9]*) oom_total=0 ;; esac

if [ "$oom_total" -ge "$OOMMAX" ]; then
  printf 'KERNEL kernel_oom_total=%s\n' "$oom_total"
fi

# Sentinel: probe completed successfully. Outer helper treats absence
# as a fail-closed probe error.
printf 'PROBE_OK\n'
