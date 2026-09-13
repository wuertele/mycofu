#!/usr/bin/env bash
# rotate-sops-recipient.sh — attended M1 SOPS age recipient rotation driver.
#
# Plan citations:
# - A4 M1 envelope and ordered steps: docs/sprints/SPRINT-049.md:337
# - Prove-negative stdout redirection requirement: docs/sprints/SPRINT-049.md:377
# - V2.3 hermetic sentinel ratchet: docs/sprints/SPRINT-049.md:947
# - S6/P9 MR-4 consolidation: docs/sprints/drafts/SPRINT-049-REVIEW-MERGE-NOTES.md:49

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOPS_CONFIG="${ROTATE_SOPS_CONFIG:-${REPO_DIR}/.sops.yaml}"
SECRETS_FILE="${ROTATE_SOPS_SECRETS_FILE:-${REPO_DIR}/site/sops/secrets.yaml}"
MANIFEST="${ROTATE_SOPS_MANIFEST:-${REPO_DIR}/site/rotation-manifest.yaml}"
CANONICAL_KEY_PATH="${ROTATE_SOPS_CANONICAL_KEY_PATH:-${REPO_DIR}/operator.age.key}"
ESCROW_BASE="${ROTATE_ESCROW_BASE:-${HOME}/.mycofu-escrow}"
UTC_STAMP="${ROTATE_UTC_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
ESCROW_DIR="${ESCROW_BASE}/${UTC_STAMP}"
ESCROW_OLD_KEY="${ESCROW_DIR}/operator.age.key"
NEW_KEY_PATH="${ROTATE_SOPS_NEW_KEY_PATH:-${ESCROW_DIR}/operator.age.key.new}"
EVIDENCE_DIR="${ROTATE_EVIDENCE_DIR:-${REPO_DIR}/build/drt/DRT-009/${UTC_STAMP}}"
# The M1 cicd holder preflight must probe the SAME site config that
# register-runner.sh uses at delivery time (register-runner.sh:45 pins
# ${REPO_DIR}/site/config.yaml). Do NOT expose an override env var —
# any divergence would let preflight probe one cicd IP while delivery
# hits a different one (P2 review finding — issue #802 rework r2).
SITE_CONFIG="${REPO_DIR}/site/config.yaml"
SOPS_FILE_LIST=""
I_MEAN_IT=0

# OPERATIVE_KEY is the age key file that can decrypt SOPS RIGHT NOW. Every
# mutating sops call passes it explicitly as SOPS_AGE_KEY_FILE=... — never
# inherited from the ambient environment (issue #802 defect 1). The value is
# reassigned in Step 4 after the old key is moved into escrow, and asserted
# to still decrypt before proceeding (issue #802 defect 2).
OPERATIVE_KEY=""

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Usage:
  framework/scripts/rotate-sops-recipient.sh --i-mean-it

Without --i-mean-it the script prints the mutation plan and exits 2.
EOF
}

print_plan() {
  cat <<EOF
Plan: rotate the M1 SOPS age recipient.
  1. Verify check-rotation-manifest.sh, current-key decrypts, clean git tree.
  2. Generate a new age key at: ${NEW_KEY_PATH}
  3. Add the new public recipient to every .sops.yaml creation rule and updatekeys all matched SOPS files.
  4. Escrow the old key at: ${ESCROW_OLD_KEY}
  5. Update the sops_age_key SOPS entry from the new key path.
  6. Deliver and probe every holder declared on the manifest M1 row.
  7. Commit both-keys state, then retire the old recipient and commit again.
  8. Prove the escrowed old key no longer decrypts ${SECRETS_FILE}; stdout is redirected.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --i-mean-it)
      I_MEAN_IT=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$I_MEAN_IT" -ne 1 ]]; then
  print_plan
  exit 2
fi

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: ${tool}" >&2
    exit 1
  fi
}

# Tool list covers this driver's direct use AND the register-runner.sh
# holder-delivery subprocess (Step 5): scp/curl/jq/ssh are register-runner's
# hard prereqs and would otherwise abort BETWEEN escrow (Step 4) and delivery
# (Step 5). Verifying them here keeps that gap inside the transactional
# preflight envelope (P1 review finding — issue #802 rework r2).
for tool in age-keygen sops yq git python3 grep find sort chmod mkdir mv install ssh scp curl jq; do
  require_tool "$tool"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rotate-sops-recipient.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
SOPS_FILE_LIST="${WORK_DIR}/sops-files.txt"

extract_public_recipient() {
  local key_file="$1"
  local public=""
  if [[ ! -s "$key_file" ]]; then
    return 1
  fi
  public="$(grep -E '^# public key: age1' "$key_file" | sed 's/^# public key: //' | head -1)"
  if [[ -z "$public" ]]; then
    return 1
  fi
  printf '%s\n' "$public"
}

enumerate_sops_files() {
  local regex rel abs matched_any=0
  : > "$SOPS_FILE_LIST"
  while IFS= read -r regex; do
    [[ -n "$regex" ]] || continue
    matched_any=0
    while IFS= read -r rel; do
      if printf '%s\n' "$rel" | grep -E "$regex" >/dev/null 2>&1; then
        matched_any=1
        abs="${REPO_DIR}/${rel}"
        if [[ ! -r "$abs" ]]; then
          echo "ERROR: .sops.yaml matched unreadable file: ${rel}" >&2
          exit 1
        fi
        if yq -e 'has("sops")' "$abs" >/dev/null 2>&1; then
          printf '%s\n' "$abs" >> "$SOPS_FILE_LIST"
        fi
      fi
    done < <(cd "$REPO_DIR" && find . -path './.git' -prune -o -type f -print | sed 's#^\./##')
    if [[ "$matched_any" -ne 1 ]]; then
      echo "ERROR: .sops.yaml creation rule matched no files: ${regex}" >&2
      exit 1
    fi
  done < <(yq -r '.creation_rules[] | .path_regex // ""' "$SOPS_CONFIG")
  sort -u "$SOPS_FILE_LIST" -o "$SOPS_FILE_LIST"
  if [[ ! -s "$SOPS_FILE_LIST" ]]; then
    echo "ERROR: .sops.yaml creation rules matched no SOPS files" >&2
    exit 1
  fi
}

update_sops_recipients() {
  local mode="$1"
  local recipient="$2"
  python3 - "$SOPS_CONFIG" "$mode" "$recipient" <<'PY'
import re
import sys

path, mode, recipient = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().splitlines(True)
out = []
i = 0
changed = False

def split_recipients(value):
    value = value.strip().strip('"').strip("'")
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]

def render(indent, existing):
    global changed
    recips = split_recipients(existing)
    before = list(recips)
    if mode == "add":
        if recipient not in recips:
            recips.append(recipient)
    elif mode == "remove":
        recips = [item for item in recips if item != recipient]
    else:
        raise SystemExit(f"bad mode: {mode}")
    if recips != before:
        changed = True
    return f"{indent}age: {','.join(recips)}\n"

while i < len(lines):
    line = lines[i]
    match = re.match(r"^(\s*)age:\s*(.*?)(\s*)$", line.rstrip("\n"))
    if not match:
        out.append(line)
        i += 1
        continue
    indent, value, _ = match.groups()
    if value in (">-", "|", ">"):
        i += 1
        block_parts = []
        while i < len(lines):
            next_line = lines[i]
            if next_line.strip() and len(next_line) - len(next_line.lstrip(" ")) <= len(indent):
                break
            block_parts.append(next_line.strip())
            i += 1
        out.append(render(indent, " ".join(block_parts)))
        continue
    out.append(render(indent, value))
    i += 1

if mode == "remove":
    remaining = ",".join(split_recipients(recipient))
if changed:
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out)
PY
}

require_operative_key() {
  local reason="$1"
  if [[ -z "${OPERATIVE_KEY:-}" || ! -s "$OPERATIVE_KEY" ]]; then
    echo "ERROR: operative key missing (${reason}): ${OPERATIVE_KEY:-<unset>}" >&2
    exit 1
  fi
}

assert_operative_key_can_decrypt() {
  local reason="$1"
  require_operative_key "$reason"
  local file=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if ! SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops -d "$file" >/dev/null 2>&1; then
      echo "ERROR: operative key cannot decrypt ${file#${REPO_DIR}/} (${reason})" >&2
      exit 1
    fi
  done < "$SOPS_FILE_LIST"
}

sops_updatekeys_all() {
  require_operative_key "sops_updatekeys_all"
  local file=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    echo "  sops updatekeys ${file#${REPO_DIR}/}"
    SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops updatekeys -y "$file" >/dev/null
  done < "$SOPS_FILE_LIST"
}

decrypt_probe_all_with_key() {
  local key_path="$1"
  local label="$2"
  local file=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if ! SOPS_AGE_KEY_FILE="$key_path" sops -d "$file" >/dev/null; then
      echo "ERROR: ${label} cannot decrypt ${file#${REPO_DIR}/}" >&2
      exit 1
    fi
  done < "$SOPS_FILE_LIST"
}

sops_set_value_from_file() {
  local key="$1"
  local value_file="$2"
  require_operative_key "sops set ${key}"
  if [[ ! -s "$value_file" ]]; then
    echo "ERROR: value file for ${key} is missing or empty: ${value_file}" >&2
    exit 1
  fi
  # SOPS's `set` requires the value to be a JSON-encoded string; raw file
  # content exits 7 with "Value for --set is not valid JSON" (issue #806).
  # `jq -Rs .` slurps the file as one JSON string, preserving newlines and
  # quotes losslessly. Piping into `--value-file /dev/stdin` keeps the value
  # out of process listings AND avoids writing a JSON-encoded intermediate
  # to disk; this form is portable to older sops that lack `--value-stdin`
  # (the newer flag was rejected by the CI runner's sops with "flag provided
  # but not defined: -value-stdin" — issue #806 pipeline #1926).
  jq -Rs . < "$value_file" \
    | SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops set --value-file "$SECRETS_FILE" "[\"${key}\"]" /dev/stdin >/dev/null
}

# probe_writable_dir <path> <label>
# Fails closed if <path> is not writable. Uses `mktemp` rather than `test -w`
# because -w reports current mode bits, not effective writability under ACLs
# and root-vs-user rules; a successful mktemp is the effective check.
probe_writable_dir() {
  local dir="$1"
  local label="$2"
  local probe
  if [[ ! -d "$dir" ]]; then
    echo "ERROR: ${label} directory missing: ${dir}" >&2
    exit 1
  fi
  if ! probe="$(mktemp "${dir}/.rotate-sops-recipient.probe.XXXXXX" 2>/dev/null)"; then
    echo "ERROR: ${label} directory not writable: ${dir}" >&2
    exit 1
  fi
  rm -f "$probe"
}

# probe_holder_reachable <holder> <delivery>
# Attended-window reachability check run BEFORE any mutation. Fails closed if
# the holder cannot be reached: for cicd:register-runner the reachability
# gate is a batch-mode SSH probe at the manifest holder's advertised IP.
# Reads the IP from site/config.yaml — the same source register-runner uses.
probe_holder_reachable() {
  local holder="$1"
  local delivery="$2"
  case "$holder:$delivery" in
    workstation:local-file)
      # Locally delivered; the workstation is inherently reachable. The
      # canonical key parent dir writability check covers install-back.
      return 0
      ;;
    cicd:register-runner)
      local cicd_ip=""
      cicd_ip="$(yq -r '.vms.cicd.ip // ""' "$SITE_CONFIG" 2>/dev/null || printf '')"
      if [[ -z "$cicd_ip" || "$cicd_ip" == "null" ]]; then
        echo "ERROR: cicd IP missing from ${SITE_CONFIG}; holder cicd not reachable" >&2
        exit 1
      fi
      if ! ssh -n \
           -o BatchMode=yes \
           -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=accept-new \
           "root@${cicd_ip}" true >/dev/null 2>&1; then
        echo "ERROR: cicd SSH probe failed at root@${cicd_ip}; holder cicd not reachable" >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: unsupported M1 holder '${holder}' delivery '${delivery}' in ${MANIFEST}" >&2
      exit 1
      ;;
  esac
}

# preflight_transactional
# The transactionality requirement of issue #802: every prerequisite of the
# whole rotation is verified BEFORE the first mutation, so the driver cannot
# abort between the .sops.yaml edit and re-encryption, or between escrow
# and delivery. Anything genuinely unverifiable up front is called out.
#
# Unverifiable up front (accepted):
#   - Network liveness DURING the mutation window (SSH probe is a snapshot;
#     the actual delivery may still fail if the link drops mid-run).
#   - Sudden disk exhaustion between preflight and mutation.
#   - cicd's per-run replication state: register-runner.sh's
#     wait_for_runner_secret_replication (register-runner.sh:249) polls
#     `pvesr status` rows that only appear once the runner has produced
#     new replication activity. There is no meaningful pre-mutation
#     snapshot; retry-until-timeout is the mechanism.
#   - cicd's node placement (yq .vms.cicd.node) is stable across the
#     window; if HA relocates cicd between preflight and delivery,
#     register-runner.sh notices and re-derives the path. Not something
#     preflight can pin.
# Everything else — helper scripts, file readability/writability, holder
# reachability, current-key decryptability, git cleanliness — is checked here.
preflight_transactional() {
  # 1. Required helper scripts exist and are executable.
  # tofu-wrapper.sh is no longer listed here because the driver-internal
  # `tofu plan -detailed-exitcode` assertion it once fed was removed in
  # #817 (redundant with DRT-009's delta-digest assertion; unsatisfiable
  # against pre-existing image drift). The driver no longer invokes tofu.
  local helper
  for helper in check-rotation-manifest.sh register-runner.sh; do
    if [[ ! -x "${SCRIPT_DIR}/${helper}" ]]; then
      echo "ERROR: required helper not executable: ${SCRIPT_DIR}/${helper}" >&2
      exit 1
    fi
  done

  # 2. Required inputs readable.
  local path
  for path in "$SOPS_CONFIG" "$SECRETS_FILE" "$MANIFEST" "$SITE_CONFIG"; do
    if [[ ! -r "$path" ]]; then
      echo "ERROR: required file not readable: ${path}" >&2
      exit 1
    fi
  done

  # 3. Escrow target must not already exist. Reusing $ROTATE_UTC_STAMP across
  #    runs would otherwise silently overwrite a prior run's escrowed old key
  #    via Step 4's `mv` — destroying the recovery path anchored to the
  #    pre-rotation PBS backup. Fresh-stamp default (date -u ...) makes this
  #    only trigger on explicit reuse (P1 review finding — issue #802
  #    rework r2). Refuse rather than allow.
  if [[ -e "$ESCROW_OLD_KEY" ]]; then
    echo "ERROR: escrow target already exists: ${ESCROW_OLD_KEY}" >&2
    echo "  A prior run's escrowed old key would be overwritten. Move it aside or use a fresh ROTATE_UTC_STAMP." >&2
    exit 1
  fi

  # 4. Create the escrow + evidence directories only AFTER the git clean-tree
  #    check has passed (in Step 1 above) — so a rejected preflight for an
  #    already-dirty tree leaves no side-effect directories behind (P3
  #    review finding — issue #802 rework r2).
  mkdir -p "$ESCROW_DIR" "$EVIDENCE_DIR"

  # 5. Parent directories of paths the driver will mutate must be writable.
  probe_writable_dir "$(dirname "$SOPS_CONFIG")"      ".sops.yaml parent"
  probe_writable_dir "$(dirname "$SECRETS_FILE")"     "secrets.yaml parent"
  probe_writable_dir "$(dirname "$CANONICAL_KEY_PATH")" "canonical key parent"
  probe_writable_dir "$ESCROW_DIR"                    "escrow dir"
  probe_writable_dir "$EVIDENCE_DIR"                  "evidence dir"

  # 6. Every SOPS file matched by creation rules is readable AND its parent
  #    directory is writable (updatekeys rewrites the file in-place).
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if [[ ! -r "$file" ]]; then
      echo "ERROR: matched SOPS file not readable: ${file#${REPO_DIR}/}" >&2
      exit 1
    fi
    probe_writable_dir "$(dirname "$file")" "SOPS file parent (${file#${REPO_DIR}/})"
  done < "$SOPS_FILE_LIST"

  # 7. Every M1 holder is reachable now — before mutation.
  local holder delivery saw_any=0
  while IFS=$'\t' read -r holder delivery; do
    [[ -n "$holder" ]] || continue
    saw_any=1
    probe_holder_reachable "$holder" "$delivery"
  done < <(holders_for_m1)
  if [[ "$saw_any" -ne 1 ]]; then
    echo "ERROR: manifest M1 row has no holders" >&2
    exit 1
  fi
}

# Path set the rotation commits: .sops.yaml plus every file `sops updatekeys`
# re-encrypted (SOPS_FILE_LIST). Emits absolute paths, one per line, so both
# `git add` and `git status/diff` limiters can consume the same list. Derived
# from the same list that drove the re-encryption — single source (#813
# defect 1). Prior versions hardcoded `.sops.yaml` and the primary
# secrets.yaml, silently omitting every additional file matched by other
# `.sops.yaml` creation_rules; those files were re-encrypted but never
# committed.
rotation_commit_paths() {
  printf '%s\n' "$SOPS_CONFIG"
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    printf '%s\n' "$file"
  done < "$SOPS_FILE_LIST"
}

git_commit_if_needed() {
  local subject="$1"
  local body="$2"
  local -a stage_paths=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    stage_paths+=("$p")
  done < <(rotation_commit_paths)
  # Bash 3.2 + set -u empty-array guard idiom (tests/test_bash32_empty_
  # array_ratchet.sh, #410). stage_paths always contains at least
  # $SOPS_CONFIG in practice — enumerate_sops_files fails hard if
  # SOPS_FILE_LIST is empty — but the ratchet is static and requires the
  # guard on the expansion site.
  git -C "$REPO_DIR" add ${stage_paths[@]+"${stage_paths[@]}"}
  # Scope the commit to ONLY the rotation-commit paths — even if the operator
  # has unrelated content staged elsewhere (which preflight already rejects
  # up front), the trailing `-- <paths>` on `git commit` bounds THIS commit to
  # our set. Defense-in-depth against a preflight bypass — R1 codex finding.
  if git -C "$REPO_DIR" diff --cached --quiet -- ${stage_paths[@]+"${stage_paths[@]}"}; then
    echo "  No staged changes for: ${subject}"
    return 0
  fi
  git -C "$REPO_DIR" commit -m "${subject}" -m "${body}" -- ${stage_paths[@]+"${stage_paths[@]}"}
  echo "  Operator push command: git push origin $(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
}

# assert_commit_paths_clean — post-commit completeness check for #813 defect 1.
# After Step 7's second commit, every rotation-commit path must be clean in
# `git status --porcelain`. A residual dirty file means `sops updatekeys`
# re-encrypted it but the commit missed it — the exact "hil secrets left
# uncommitted" signature. Fails closed with the offending paths.
assert_commit_paths_clean() {
  local -a paths=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    paths+=("$p")
  done < <(rotation_commit_paths)
  local dirty
  # Bash 3.2 + set -u empty-array guard (see git_commit_if_needed).
  dirty="$(git -C "$REPO_DIR" status --porcelain -- ${paths[@]+"${paths[@]}"})"
  if [[ -n "$dirty" ]]; then
    echo "ERROR: rotation left uncommitted mutations in rotation-commit paths (#813 defect 1):" >&2
    printf '%s\n' "$dirty" | sed 's/^/  /' >&2
    exit 1
  fi
}

holders_for_m1() {
  yq -r '.[] | select(.match == "sops_age_key") | .holders[]? | [.name, .delivery] | @tsv' "$MANIFEST"
}

deliver_and_probe_holders() {
  require_operative_key "deliver_and_probe_holders"
  local holder delivery saw_holder=0
  while IFS=$'\t' read -r holder delivery; do
    [[ -n "$holder" ]] || continue
    saw_holder=1
    case "$holder:$delivery" in
      workstation:local-file)
        install -m 0400 "$NEW_KEY_PATH" "$CANONICAL_KEY_PATH"
        # Verify against CANONICAL_KEY_PATH — the delivered file at its
        # operator-facing location — with an explicit prefix (not the
        # ambient env). This is the delivery-verification probe, distinct
        # from the phase-aware assert_operative_key_can_decrypt above.
        SOPS_AGE_KEY_FILE="$CANONICAL_KEY_PATH" sops -d "$SECRETS_FILE" >/dev/null
        echo "  Holder workstation probe OK"
        ;;
      cicd:register-runner)
        # register-runner.sh reads SOPS_AGE_KEY_FILE to locate the key it
        # will deliver to /var/lib/mycofu-secrets/age-key on cicd. Pass the
        # operative key path explicitly so it does not depend on whatever
        # the parent shell exported (or on the mid-run canonical path).
        SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" "${SCRIPT_DIR}/register-runner.sh" --deliver-secrets
        echo "  Holder cicd delivery/probe OK"
        ;;
      *)
        echo "ERROR: unsupported M1 holder '${holder}' delivery '${delivery}' in ${MANIFEST}" >&2
        exit 1
        ;;
    esac
  done < <(holders_for_m1)
  if [[ "$saw_holder" -ne 1 ]]; then
    echo "ERROR: manifest M1 row has no holders" >&2
    exit 1
  fi
}

prove_negative_old_key() {
  local stderr_file="${WORK_DIR}/prove-negative.stderr"
  local evidence_file="${EVIDENCE_DIR}/prove-negative.txt"
  local rc=0
  set +e
  SOPS_AGE_KEY_FILE="$ESCROW_OLD_KEY" sops -d "$SECRETS_FILE" >/dev/null 2>"$stderr_file"
  rc=$?
  set -e
  {
    printf 'path=%s\n' "$SECRETS_FILE"
    printf 'escrow_key_path=%s\n' "$ESCROW_OLD_KEY"
    printf 'exit=%s\n' "$rc"
    printf 'stderr=\n'
    sed 's/[[:cntrl:]]//g' "$stderr_file"
  } > "$evidence_file"
  if [[ "$rc" -eq 0 ]]; then
    echo "ERROR: old escrow key still decrypts ${SECRETS_FILE}; see ${evidence_file}" >&2
    exit 1
  fi
  echo "  Prove-negative evidence: ${evidence_file}"
}

echo "=== Step 1: Preflight ==="
"${SCRIPT_DIR}/check-rotation-manifest.sh"
enumerate_sops_files
# The canonical age key must exist. The prior "fallback to ESCROW_OLD_KEY if
# canonical missing" branch was dead code once preflight_transactional
# started refusing runs whose escrow target already exists: any state where
# canonical was missing AND escrow was present would fail preflight before
# reaching Step 3 anyway. Verify-first over idempotent-resume, per issue
# #802 scope item 3.
if [[ ! -s "$CANONICAL_KEY_PATH" ]]; then
  echo "ERROR: current age key missing at ${CANONICAL_KEY_PATH}" >&2
  exit 1
fi
OPERATIVE_KEY="$CANONICAL_KEY_PATH"
decrypt_probe_all_with_key "$OPERATIVE_KEY" "current key"

# --- Clean-tree preflight (issue #800 secondary + codex R1 hardening) ---
#
# Three failure modes to prevent, each with a targeted check:
#
# 1. Pre-existing STAGED content anywhere in the tree. `git commit -m ...`
#    without `--` bundles every staged change into whatever we commit next.
#    Even with the `--` scoping applied to git_commit_if_needed's commit,
#    the operator's expectation is a clean rotation commit — pre-staged
#    unrelated content is a smell we should refuse up front.
#
# 2. Tracked MODIFICATIONS on any rotation-commit path. Those would silently
#    enter our commits via `git add <rotation-commit path>`. This is the
#    original #800-secondary concern.
#
# 3. UNTRACKED files matching a `.sops.yaml` creation_rule that also parse
#    as SOPS envelopes. `enumerate_sops_files` walks the tree with `find`
#    and includes any such file in SOPS_FILE_LIST — the same list our
#    commits now derive from (#813 defect 1 fix). Pre-#813 the commit set
#    was hardcoded, so untracked SOPS-shaped files were harmless. Post-#813
#    they would be staged and committed. Reject them and force an explicit
#    `git add` (or a gitignore) before rotation. Untracked scratch that is
#    NOT SOPS-shaped is fine — that's the whole point of #800-secondary.
#
# Aligning tracked-modification check with build-image.sh:304's shape.

# Check 1: no pre-existing staged content anywhere.
if ! git -C "$REPO_DIR" diff --cached --quiet; then
  echo "ERROR: git tree has pre-existing staged changes; commit or unstage them before starting rotation:" >&2
  git -C "$REPO_DIR" diff --cached --name-only | sed 's/^/  /' >&2
  exit 1
fi

# Check 2: no tracked modifications on rotation-commit paths.
# Portable list-collection (macOS ships bash 3.2 which lacks readarray).
_rotate_commit_paths_pre=()
while IFS= read -r _p; do
  [[ -n "$_p" ]] || continue
  _rotate_commit_paths_pre+=("$_p")
done < <(rotation_commit_paths)
# Bash 3.2 + set -u empty-array guard (tests/test_bash32_empty_
# array_ratchet.sh, #410). _rotate_commit_paths_pre always contains at
# least $SOPS_CONFIG in practice; enumerate_sops_files fails hard if
# SOPS_FILE_LIST is empty. Guard is static-ratchet compliance.
if ! git -C "$REPO_DIR" diff --quiet HEAD -- ${_rotate_commit_paths_pre[@]+"${_rotate_commit_paths_pre[@]}"}; then
  echo "ERROR: rotation-commit paths have pending tracked modifications; commit or stash them first:" >&2
  git -C "$REPO_DIR" status --porcelain -- ${_rotate_commit_paths_pre[@]+"${_rotate_commit_paths_pre[@]}"} | sed 's/^/  /' >&2
  exit 1
fi

# Check 3: no untracked SOPS-shaped files. SOPS_FILE_LIST was populated by
# `find` (not `git ls-files`) so untracked SOPS-format files under the
# creation-rule regex ARE in the list; check each entry's git tracking
# status.
_untracked_sops_files=""
while IFS= read -r _sops_abs; do
  [[ -n "$_sops_abs" ]] || continue
  _sops_rel="${_sops_abs#${REPO_DIR}/}"
  if ! git -C "$REPO_DIR" ls-files --error-unmatch -- "$_sops_rel" >/dev/null 2>&1; then
    _untracked_sops_files+="  ${_sops_rel}"$'\n'
  fi
done < "$SOPS_FILE_LIST"
if [[ -n "$_untracked_sops_files" ]]; then
  echo "ERROR: SOPS-encrypted files matched by .sops.yaml creation_rules are not tracked in git:" >&2
  printf '%s' "$_untracked_sops_files" >&2
  echo "  Remediate one of:" >&2
  echo "    1. \`git add\` them so they enter the rotation commits, OR" >&2
  echo "    2. Move them out from under the matched \`.sops.yaml\` path_regex, OR" >&2
  echo "    3. Delete them if they are stale." >&2
  echo "  (\`.gitignore\` alone does NOT satisfy this preflight — enumerate_sops_files" >&2
  echo "  uses \`find\` and includes ignored files that still match the regex and parse" >&2
  echo "  as SOPS envelopes. The check is on git tracking, not ignore state.)" >&2
  exit 1
fi

preflight_transactional
echo "  Preflight OK"

echo "=== Step 2: Generate new key ==="
if [[ -s "$NEW_KEY_PATH" ]]; then
  echo "  Reusing existing new key path: ${NEW_KEY_PATH}"
else
  age-keygen -o "$NEW_KEY_PATH" >/dev/null
  chmod 0400 "$NEW_KEY_PATH"
  echo "  New key generated at: ${NEW_KEY_PATH}"
fi
NEW_PUBLIC_RECIPIENT="$(extract_public_recipient "$NEW_KEY_PATH")"
OLD_PUBLIC_RECIPIENT="$(extract_public_recipient "$OPERATIVE_KEY")"

echo "=== Step 3: Add new recipient and update keys ==="
update_sops_recipients add "$NEW_PUBLIC_RECIPIENT"
sops_updatekeys_all

echo "=== Step 4: Escrow old key before SOPS mutation ==="
if [[ -s "$CANONICAL_KEY_PATH" ]]; then
  mv "$CANONICAL_KEY_PATH" "$ESCROW_OLD_KEY"
fi
chmod 0400 "$ESCROW_OLD_KEY"
# The mv above may have invalidated whatever path SOPS_AGE_KEY_FILE
# (ambient or explicit) previously pointed at — including OPERATIVE_KEY
# if it was set to CANONICAL_KEY_PATH. Reassign to the new key path (which
# both recipients accept post-Step-3) and assert it decrypts before any
# further sops call runs. This is the fix for issue #802 defect 2.
OPERATIVE_KEY="$NEW_KEY_PATH"
assert_operative_key_can_decrypt "post-escrow (Step 4)"
sops_set_value_from_file "sops_age_key" "$NEW_KEY_PATH"
echo "  Old key escrowed at: ${ESCROW_OLD_KEY}"

echo "=== Step 5: Distribute and probe holders ==="
deliver_and_probe_holders

echo "=== Step 6: Commit both-keys state ==="
git_commit_if_needed \
  "rotation: add new SOPS age recipient" \
  "Premises: A4 requires add-recipient before old-key retirement (docs/sprints/SPRINT-049.md:351), holder delivery before commit (docs/sprints/SPRINT-049.md:363), and MR-4 consolidation per S6 (docs/sprints/drafts/SPRINT-049-REVIEW-MERGE-NOTES.md:49).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"

echo "=== Step 7: Retire old recipient ==="
update_sops_recipients remove "$OLD_PUBLIC_RECIPIENT"
sops_updatekeys_all
git_commit_if_needed \
  "rotation: retire old SOPS age recipient" \
  "Premises: A4 retires the old recipient only after holder delivery and both-keys commit (docs/sprints/SPRINT-049.md:370), then updatekeys all matched files (docs/sprints/SPRINT-049.md:374), with prove-negative next (docs/sprints/SPRINT-049.md:377).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"

# The absolute zero-changes plan assertion that used to live here (issue
# #817) was the same wrong idea #791 removed from DRT-009: `tofu plan
# -detailed-exitcode` exits 2 whenever the plan shows ANY change, and under
# `set -e` that aborts the driver. It is unsatisfiable both from a fresh
# clone (placeholder image tfvars) and from a provisioned checkout
# (legitimate dev/prod image drift), so the driver always reported FAIL
# after a completely correct rotation. DRT-009 brackets this driver with
# `capture_pre_m1_plan_digest` (framework/dr-tests/tests/DRT-009-key-rotation.sh:669)
# and `assert_m1_plan_delta_zero` (:673 / :450-460): the tolerant delta
# form that survives pre-existing drift. Duplicating the property here
# with the intolerant absolute form added no coverage and one failure
# mode (design-taste principle 11).

# Assert commit-set completeness (#813 defect 1). If sops updatekeys re-encrypted
# a SOPS file that git_commit_if_needed didn't stage, that path is dirty here.
# Fails closed before Step 8 so the operator sees the divergence, not the
# next `git push` picking up a stray file.
assert_commit_paths_clean

echo "=== Step 8: Prove-negative old key ==="
prove_negative_old_key

echo "=== SOPS recipient rotation complete ==="
