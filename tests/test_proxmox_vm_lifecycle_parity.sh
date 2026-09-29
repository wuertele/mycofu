#!/usr/bin/env bash
#
# Structural drift test for the proxmox-vm module family (#368).
#
# Three OpenTofu modules define the SAME VM resource but must differ only
# in their lifecycle blocks (and one documented memory exception):
#
#   - framework/tofu/modules/proxmox-vm/                (base, data-plane)
#   - framework/tofu/modules/proxmox-vm-precious/       (base + prevent_destroy)
#   - framework/tofu/modules/proxmox-vm-field-updatable/ (closure-push variant)
#
# The modules exist as separate files because OpenTofu lifecycle blocks
# cannot be dynamic (no variables/ternaries/concat). That forces manual
# propagation of every OTHER resource attribute (disk layout, agent,
# network, initialization, provider workarounds) across all three files —
# a drift trap. This test catches drift structurally so a change that
# lands in one variant but not the others fails CI.
#
# Checks:
#
#   G0. PARSER-ASSUMPTION GUARD (fail closed). The comment stripper understands
#       only '#' line comments and assumes no '#' sits inside a string literal.
#       G0 rejects '//', '/* */', and in-string '#' so an unsupported construct
#       fails loudly instead of silently blinding a comparison.
#
#   A. NON-LIFECYCLE BODY PARITY (issue #368 Option 2). With the lifecycle
#      block normalized away, the three resource bodies must be identical.
#      The ONE documented body exception is field-updatable's elastic
#      `memory` (ballooning) block; it is normalized away for comparisons
#      that involve field-updatable, and only for those.
#
#   B. LIFECYCLE-ATTRIBUTE PARITY. The intended lifecycle DIFFERENCES are
#      pinned as relationships, so a lifecycle change in one variant that
#      is not mirrored per the documented contract is caught:
#        - ignore_changes(base) == ignore_changes(precious)                 (B1)
#        - ignore_changes(field) == ignore_changes(base) + disk[0].file_id  (B2)
#        - disk[0].file_id is ignored ONLY by field-updatable               (B2b)
#        - the HA-migration safety trio is present in all three             (B3)
#        - replace_triggered_by(base) == replace_triggered_by(precious) != []  (B4)
#        - replace_triggered_by(field) is empty                            (B5)
#        - prevent_destroy: absent(base), true(precious), true(field)      (B6)
#        - the lifecycle attribute-KEY set per variant matches the
#          documented contract, catching a NEW lifecycle attribute that
#          lands in one variant but not the others                        (B7)
#
# The checks are relationship-based (derived from the modules themselves)
# rather than hardcoding full expected contents, so the only literals are
# the documented intentional differences. A mutation self-check at the end
# injects body, ignore_changes, prevent_destroy, replace_triggered_by, and
# lifecycle-key drift onto throwaway copies and asserts each is detected,
# proving the comparisons have teeth.
#
# Hermetic: pure text parsing, no OpenTofu binary, no cluster access.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="${PARITY_REPO_ROOT:-${DEFAULT_REPO_ROOT}}"

source "${DEFAULT_REPO_ROOT}/tests/lib/runner.sh"

MODULES_DIR="${REPO_ROOT}/framework/tofu/modules"
BASE_VM="${MODULES_DIR}/proxmox-vm/vm.tf"
PRECIOUS_VM="${MODULES_DIR}/proxmox-vm-precious/vm.tf"
FIELD_VM="${MODULES_DIR}/proxmox-vm-field-updatable/vm.tf"

# The HA-migration safety members every variant must ignore. Losing any of
# these from a variant would make an HA failover (which changes node_name and
# the node-specific snippet IDs) plan a destroy/recreate of the VM.
HA_SAFETY_MEMBERS="disk[0].size
initialization
node_name"

# --- normalization helpers -------------------------------------------------

# Remove a brace-delimited block whose opening line matches the given ERE,
# using brace counting so nested blocks (e.g. precondition {}) and `${...}`
# interpolations inside strings are handled correctly.
strip_brace_block() {
  local header_re="$1"
  awk -v hre="${header_re}" '
    function braces(s,   i,c,n){ n=0; for(i=1;i<=length(s);i++){ c=substr(s,i,1); if(c=="{")n++; else if(c=="}")n-- } return n }
    BEGIN { instrip=0; depth=0 }
    {
      if (instrip==0 && $0 ~ hre) {
        instrip=1; depth=braces($0);
        if (depth<=0) instrip=0;
        next
      }
      if (instrip==1) {
        depth+=braces($0);
        if (depth<=0) instrip=0;
        next
      }
      print
    }
  '
}

# Normalize a vm.tf into a comparable resource body:
#   - strip comments (no string literal in these files contains '#')
#   - strip the lifecycle block
#   - optionally strip memory blocks (base `memory {` and field
#     `dynamic "memory" {`) — the one documented body exception
#   - collapse whitespace and drop blank lines
# Arg 2 = "nomem" to also strip memory blocks.
normalize_body() {
  local file="$1" mode="${2:-}"
  local text
  text="$(sed 's/#.*$//' "${file}")"
  text="$(printf '%s\n' "${text}" | strip_brace_block '^[[:space:]]*lifecycle[[:space:]]*\{')"
  if [[ "${mode}" == "nomem" ]]; then
    text="$(printf '%s\n' "${text}" | strip_brace_block '^[[:space:]]*(dynamic[[:space:]]+"memory"|memory)[[:space:]]*\{')"
  fi
  printf '%s\n' "${text}" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//' | grep -v '^[[:space:]]*$' || true
}

# Print the sorted, de-duplicated element tokens of a lifecycle array
# (ignore_changes or replace_triggered_by). Comments are stripped first.
#
# The array's extent is tracked by BRACKET-DEPTH counting: the opening `[`
# starts depth 1, and the array closes when depth returns to 0. Element
# tokens that contain their own balanced brackets (`disk[0].size`,
# `terraform_data.cidata_hash[0]`) net to zero and never trip the close, so
# the parser is correct for multi-line arrays, single-line arrays, empty
# arrays, and a final element sharing its line with the closing `]`.
lifecycle_array() {
  local file="$1" key="$2"
  sed 's/#.*$//' "${file}" | awk -v key="${key}" '
    function emit(s,   n,a,i,t){ n=split(s,a,","); for(i=1;i<=n;i++){ t=a[i]; gsub(/[[:space:]]/,"",t); if(t!="") print t } }
    function brackets(s,   i,c,n){ n=0; for(i=1;i<=length(s);i++){ c=substr(s,i,1); if(c=="[")n++; else if(c=="]")n-- } return n }
    {
      line=$0
      if (inarr==0) {
        if (line ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*\\[") {
          sub(/^[^[]*\[/,"",line)          # drop everything up to and incl. the opening [
          depth=1 + brackets(line)
          if (depth<=0) { sub(/\][^]]*$/,"",line); emit(line); next }  # opened & closed on one line
          emit(line); inarr=1; next
        }
        next
      }
      # inside the array
      if (depth + brackets(line) <= 0) { sub(/\][^]]*$/,"",line); emit(line); inarr=0; next }
      depth += brackets(line); emit(line)
    }
  ' | sort -u
}

# Print the sorted set of TOP-LEVEL attribute/block names inside the
# lifecycle block (e.g. ignore_changes, replace_triggered_by,
# prevent_destroy, precondition). Used to catch a lifecycle attribute that
# lands in one variant but not the others — drift the per-attribute checks
# below would otherwise miss because they only inspect the three known keys.
lifecycle_keys() {
  local file="$1"
  sed 's/#.*$//' "${file}" | awk '
    function braces(s,   i,c,n){ n=0; for(i=1;i<=length(s);i++){ c=substr(s,i,1); if(c=="{")n++; else if(c=="}")n-- } return n }
    BEGIN { inlc=0; depth=0 }
    inlc==0 && /^[[:space:]]*lifecycle[[:space:]]*\{/ { inlc=1; depth=braces($0); next }
    inlc==1 {
      # Exactly-4-space-indented "<name> =" or "<name> {" is a lifecycle-level
      # key; deeper (6-space) array elements / precondition bodies are excluded.
      if ($0 ~ /^    [A-Za-z_][A-Za-z0-9_]*[[:space:]]*[={]/) {
        t=$0; sub(/^[[:space:]]+/,"",t); sub(/[[:space:]]*[={].*$/,"",t); print t
      }
      depth += braces($0)
      if (depth<=0) inlc=0
    }
  ' | sort -u
}

# 0 if the (non-comment) lifecycle declares prevent_destroy = true.
has_prevent_destroy() {
  sed 's/#.*$//' "$1" | grep -Eq 'prevent_destroy[[:space:]]*=[[:space:]]*true'
}

# 0 if the (non-comment) file mentions prevent_destroy at all (with any value).
# Used to assert "absent in base" — not merely "not set to true", so a stray
# `prevent_destroy = false` in the base module is still caught.
declares_prevent_destroy() {
  sed 's/#.*$//' "$1" | grep -Eq 'prevent_destroy[[:space:]]*='
}

# --- assertion primitives (operate on file paths; used by real checks
#     AND by the mutation self-check) ----------------------------------------

# Returns 0 iff the normalized bodies are identical.
bodies_match() {
  local a="$1" b="$2" mode="${3:-}"
  diff <(normalize_body "${a}" "${mode}") <(normalize_body "${b}" "${mode}") >/dev/null 2>&1
}

# Returns 0 iff sorted ignore_changes(field) == sorted( ignore_changes(base) + extra ).
ignore_is_base_plus() {
  local base="$1" field="$2" extra="$3"
  diff \
    <( { lifecycle_array "${base}" "ignore_changes"; printf '%s\n' "${extra}"; } | sort -u ) \
    <( lifecycle_array "${field}" "ignore_changes" ) >/dev/null 2>&1
}

# Emit a description for every HCL construct the simple comment-stripping /
# brace-counting parser cannot handle safely; empty output means clean. The
# parser understands only '#' line comments and assumes no '#' appears inside a
# string literal (a '#' in a string would be wrongly stripped as a comment,
# silently blinding the drift comparison — the most dangerous failure mode).
# Balanced '${...}' interpolation is expected and allowed. This turns those
# ASSUMPTIONS into ENFORCED preconditions: if a future edit introduces an
# unsupported construct, the test fails loudly (fail closed) asking a
# maintainer to harden the parser, rather than silently passing.
unsupported_hcl_construct() {
  awk '
    {
      n=length($0); ins=0; esc=0
      for (i=1;i<=n;i++) {
        c=substr($0,i,1); d=substr($0,i+1,1)
        if (esc) { esc=0; continue }
        if (c=="\\") { esc=1; continue }
        if (c=="\"") { ins=!ins; continue }
        if (ins) {
          if (c=="#") print FILENAME " (line " FNR "): '\''#'\'' inside a string literal"
          continue
        }
        if (c=="#") break                                   # normal line comment
        if (c=="/" && d=="/") { print FILENAME " (line " FNR "): '\''//'\'' comment not supported"; break }
        if (c=="/" && d=="*") { print FILENAME " (line " FNR "): '\''/* */'\'' comment not supported"; break }
      }
    }
  ' "$1"
}

# --- Concern 0: parser-assumption guard (fail closed) ----------------------

test_start "G0" "vm.tf files use only parser-supported HCL constructs"
g0_findings=""
for f in "${BASE_VM}" "${PRECIOUS_VM}" "${FIELD_VM}"; do
  out="$(unsupported_hcl_construct "${f}")"
  [[ -n "${out}" ]] && g0_findings+="${out}"$'\n'
done
if [[ -z "${g0_findings}" ]]; then
  test_pass "no '//', '/* */', or in-string '#' — comment stripping and brace counting are safe"
else
  test_fail "unsupported HCL construct(s) found — harden the parser before trusting parity results:"
  printf '%s' "${g0_findings}" | sed 's/^/    /' >&2
fi

# --- Concern A: non-lifecycle body parity ----------------------------------

test_start "A1" "base and precious resource bodies are identical (lifecycle removed)"
if bodies_match "${BASE_VM}" "${PRECIOUS_VM}"; then
  test_pass "proxmox-vm and proxmox-vm-precious bodies match (differ only in lifecycle)"
else
  test_fail "proxmox-vm and proxmox-vm-precious resource bodies drifted"
  diff <(normalize_body "${BASE_VM}") <(normalize_body "${PRECIOUS_VM}") | sed 's/^/    /' >&2 || true
fi

test_start "A2" "base and field-updatable bodies match (lifecycle + memory removed)"
if bodies_match "${BASE_VM}" "${FIELD_VM}" "nomem"; then
  test_pass "proxmox-vm and proxmox-vm-field-updatable bodies match (memory block is the documented exception)"
else
  test_fail "proxmox-vm and proxmox-vm-field-updatable resource bodies drifted (outside the memory exception)"
  diff <(normalize_body "${BASE_VM}" nomem) <(normalize_body "${FIELD_VM}" nomem) | sed 's/^/    /' >&2 || true
fi

test_start "A3" "precious and field-updatable bodies match (lifecycle + memory removed)"
if bodies_match "${PRECIOUS_VM}" "${FIELD_VM}" "nomem"; then
  test_pass "proxmox-vm-precious and proxmox-vm-field-updatable bodies match (memory block is the documented exception)"
else
  test_fail "proxmox-vm-precious and proxmox-vm-field-updatable resource bodies drifted (outside the memory exception)"
  diff <(normalize_body "${PRECIOUS_VM}" nomem) <(normalize_body "${FIELD_VM}" nomem) | sed 's/^/    /' >&2 || true
fi

# --- Concern B: lifecycle-attribute parity ---------------------------------

BASE_IGNORE="$(lifecycle_array "${BASE_VM}" ignore_changes)"
PRECIOUS_IGNORE="$(lifecycle_array "${PRECIOUS_VM}" ignore_changes)"
FIELD_IGNORE="$(lifecycle_array "${FIELD_VM}" ignore_changes)"

test_start "B1" "ignore_changes(base) == ignore_changes(precious)"
if [[ "${BASE_IGNORE}" == "${PRECIOUS_IGNORE}" ]]; then
  test_pass "base and precious ignore_changes are in lockstep"
else
  test_fail "base and precious ignore_changes drifted"
  diff <(printf '%s\n' "${BASE_IGNORE}") <(printf '%s\n' "${PRECIOUS_IGNORE}") | sed 's/^/    /' >&2 || true
fi

test_start "B2" "ignore_changes(field) == ignore_changes(base) + disk[0].file_id"
if ignore_is_base_plus "${BASE_VM}" "${FIELD_VM}" "disk[0].file_id"; then
  test_pass "field-updatable ignore_changes is exactly base plus the documented disk[0].file_id"
else
  test_fail "field-updatable ignore_changes is not base plus exactly disk[0].file_id"
  diff \
    <( { printf '%s\n' "${BASE_IGNORE}"; printf '%s\n' 'disk[0].file_id'; } | sort -u ) \
    <(printf '%s\n' "${FIELD_IGNORE}") | sed 's/^/    /' >&2 || true
fi

test_start "B2b" "disk[0].file_id is ignored ONLY by field-updatable"
b2b_ok=true
if ! grep -Fxq 'disk[0].file_id' <<< "${FIELD_IGNORE}"; then
  test_fail "field-updatable must ignore disk[0].file_id (image updates via closure push)"
  b2b_ok=false
fi
if grep -Fxq 'disk[0].file_id' <<< "${BASE_IGNORE}"; then
  test_fail "base proxmox-vm must NOT ignore disk[0].file_id (image change recreates the VM)"
  b2b_ok=false
fi
if grep -Fxq 'disk[0].file_id' <<< "${PRECIOUS_IGNORE}"; then
  test_fail "proxmox-vm-precious must NOT ignore disk[0].file_id (image change recreates the VM)"
  b2b_ok=false
fi
if [[ "${b2b_ok}" == "true" ]]; then
  test_pass "disk[0].file_id ignored only by field-updatable — cannot silently leak into base/precious"
fi

test_start "B3" "HA-migration safety members are ignored in all three variants"
b3_ok=true
while IFS= read -r member; do
  [[ -z "${member}" ]] && continue
  for label in BASE PRECIOUS FIELD; do
    case "${label}" in
      BASE) set_contents="${BASE_IGNORE}" ;;
      PRECIOUS) set_contents="${PRECIOUS_IGNORE}" ;;
      FIELD) set_contents="${FIELD_IGNORE}" ;;
    esac
    if ! grep -Fxq "${member}" <<< "${set_contents}"; then
      test_fail "safety member '${member}' missing from ${label} ignore_changes"
      b3_ok=false
    fi
  done
done <<< "${HA_SAFETY_MEMBERS}"
if [[ "${b3_ok}" == "true" ]]; then
  test_pass "disk[0].size, node_name, initialization ignored in base, precious, and field-updatable"
fi

BASE_REPLACE="$(lifecycle_array "${BASE_VM}" replace_triggered_by)"
PRECIOUS_REPLACE="$(lifecycle_array "${PRECIOUS_VM}" replace_triggered_by)"
FIELD_REPLACE="$(lifecycle_array "${FIELD_VM}" replace_triggered_by)"

test_start "B4" "replace_triggered_by(base) == replace_triggered_by(precious), non-empty"
if [[ -n "${BASE_REPLACE}" && "${BASE_REPLACE}" == "${PRECIOUS_REPLACE}" ]]; then
  test_pass "base and precious share a non-empty replace_triggered_by (CIDATA-change recreation)"
else
  test_fail "base and precious replace_triggered_by drifted or are empty"
  printf '    base: [%s] precious: [%s]\n' "${BASE_REPLACE//$'\n'/,}" "${PRECIOUS_REPLACE//$'\n'/,}" >&2
fi

test_start "B5" "replace_triggered_by(field) is empty"
if [[ -z "${FIELD_REPLACE}" ]]; then
  test_pass "field-updatable has no replace_triggered_by (CIDATA absorbed via overlay reboot)"
else
  test_fail "field-updatable unexpectedly declares replace_triggered_by: [${FIELD_REPLACE//$'\n'/,}]"
fi

test_start "B6" "prevent_destroy: absent(base), true(precious), true(field-updatable)"
b6_ok=true
if declares_prevent_destroy "${BASE_VM}"; then
  test_fail "base proxmox-vm must NOT declare prevent_destroy at all (data-plane VMs are recreatable; even = false is a contract violation)"
  b6_ok=false
fi
if ! has_prevent_destroy "${PRECIOUS_VM}"; then
  test_fail "proxmox-vm-precious must set prevent_destroy = true"
  b6_ok=false
fi
if ! has_prevent_destroy "${FIELD_VM}"; then
  test_fail "proxmox-vm-field-updatable must set prevent_destroy = true"
  b6_ok=false
fi
if [[ "${b6_ok}" == "true" ]]; then
  test_pass "prevent_destroy present only where intended"
fi

# B7 closes a coverage gap: A-class checks strip the whole lifecycle block and
# B1-B6 inspect only the three known attributes, so a NEW lifecycle attribute
# (e.g. create_before_destroy, a postcondition) landing in one variant but not
# the others would otherwise pass silently. Pin the lifecycle attribute-key SET
# per module as documented relationships (derived from base), naming only the
# intended differences: precious = base + prevent_destroy; field = base, minus
# replace_triggered_by, plus prevent_destroy and precondition.
BASE_KEYS="$(lifecycle_keys "${BASE_VM}")"
PRECIOUS_KEYS="$(lifecycle_keys "${PRECIOUS_VM}")"
FIELD_KEYS="$(lifecycle_keys "${FIELD_VM}")"

test_start "B7" "lifecycle attribute-key sets match the documented per-variant contract"
expected_precious_keys="$( { printf '%s\n' "${BASE_KEYS}"; printf '%s\n' 'prevent_destroy'; } | sort -u )"
expected_field_keys="$( { printf '%s\n' "${BASE_KEYS}" | grep -vFx 'replace_triggered_by'; printf '%s\n' 'prevent_destroy' 'precondition'; } | sort -u )"
b7_ok=true
if [[ "${PRECIOUS_KEYS}" != "${expected_precious_keys}" ]]; then
  test_fail "precious lifecycle keys != base keys + prevent_destroy"
  diff <(printf '%s\n' "${expected_precious_keys}") <(printf '%s\n' "${PRECIOUS_KEYS}") | sed 's/^/    /' >&2 || true
  b7_ok=false
fi
if [[ "${FIELD_KEYS}" != "${expected_field_keys}" ]]; then
  test_fail "field-updatable lifecycle keys != base keys - replace_triggered_by + {prevent_destroy, precondition}"
  diff <(printf '%s\n' "${expected_field_keys}") <(printf '%s\n' "${FIELD_KEYS}") | sed 's/^/    /' >&2 || true
  b7_ok=false
fi
if [[ "${b7_ok}" == "true" ]]; then
  test_pass "no unmirrored lifecycle attribute — a new key in one variant would be caught"
fi

# --- Mutation self-check ---------------------------------------------------
#
# Prove the comparisons above would actually catch drift: copy the modules to
# a scratch tree, inject (a) a body attribute into one variant and (b) a
# lifecycle-attribute change into another, and assert the relevant primitives
# now report a MISMATCH. If a mutated tree still "matches", the test is inert
# and this section fails loudly.

test_start "SELF" "mutation self-check — comparisons detect injected drift"
SELF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vm-parity-selfcheck.XXXXXX")"
trap 'rm -rf "${SELF_TMP}"' EXIT

cp "${BASE_VM}" "${SELF_TMP}/base.tf"
cp "${PRECIOUS_VM}" "${SELF_TMP}/precious.tf"
cp "${FIELD_VM}" "${SELF_TMP}/field.tf"

self_ok=true

# Sanity: unmutated copies still match. If they do NOT, the REAL modules have
# already drifted — the A/B checks above own that signal — so this is not a
# harness failure. Skip (do not falsely claim "the machinery is broken"); the
# mutation experiments below still exercise the comparisons' teeth regardless.
if bodies_match "${SELF_TMP}/base.tf" "${SELF_TMP}/precious.tf" \
   && bodies_match "${SELF_TMP}/base.tf" "${SELF_TMP}/field.tf" "nomem"; then
  test_pass "self-check baseline: pristine copies match"
else
  test_skip "real modules already drifted (see A/B failures above); baseline not meaningful, mutation teeth still checked below"
fi

# Inject a bogus resource-body attribute right after the (invariant) resource
# declaration line — a formatting-independent anchor at the resource top level,
# outside both the lifecycle and memory blocks. Verifies the edit landed.
inject_body_attr() {
  local file="$1" marker="$2"
  awk -v ins="  ${marker} = true" '
    { print }
    /^resource "proxmox_virtual_environment_vm" "vm" \{/ { print ins }
  ' "${file}" > "${file}.mut" && mv "${file}.mut" "${file}"
  grep -Fq "${marker}" "${file}"
}

# (a) Body drift into precious → A1 (base vs precious full body) must MISMATCH.
if ! inject_body_attr "${SELF_TMP}/precious.tf" "bogus_precious_drift"; then
  test_fail "self-check: could not inject body drift into precious (mutation harness broken)"
  self_ok=false
elif bodies_match "${SELF_TMP}/base.tf" "${SELF_TMP}/precious.tf"; then
  test_fail "self-check: injected body drift into precious was NOT detected (A1 check is inert)"
  self_ok=false
else
  test_pass "self-check: body drift in precious detected (A1)"
fi

# (b) Body drift into field OUTSIDE the memory block → A2 nomem (base vs field)
#     must MISMATCH, proving the memory-stripped comparison is not inert.
if ! inject_body_attr "${SELF_TMP}/field.tf" "bogus_field_drift"; then
  test_fail "self-check: could not inject body drift into field-updatable (mutation harness broken)"
  self_ok=false
elif bodies_match "${SELF_TMP}/base.tf" "${SELF_TMP}/field.tf" "nomem"; then
  test_fail "self-check: injected non-memory body drift into field was NOT detected (A2 nomem check is inert)"
  self_ok=false
else
  test_pass "self-check: non-memory body drift in field detected (A2 nomem)"
fi

# (c) Lifecycle ignore_changes drift: drop node_name from field-updatable's
#     ignore list. B2 (field == base + file_id) must now MISMATCH. The element
#     line is `node_name,` possibly with a trailing comment; the `node_name =`
#     resource attribute (no comma) is intentionally left untouched.
grep -Ev '^[[:space:]]*node_name[[:space:]]*,' "${SELF_TMP}/field.tf" > "${SELF_TMP}/field.mut" && mv "${SELF_TMP}/field.mut" "${SELF_TMP}/field.tf"
if ignore_is_base_plus "${SELF_TMP}/base.tf" "${SELF_TMP}/field.tf" "disk[0].file_id"; then
  test_fail "self-check: injected ignore_changes drift into field was NOT detected (B2 check is inert)"
  self_ok=false
else
  test_pass "self-check: ignore_changes drift in field detected (B2)"
fi

# (d) New lifecycle attribute in one variant → B7 key-set check must MISMATCH.
awk '
  { print }
  /^[[:space:]]*lifecycle[[:space:]]*\{/ { print "    create_before_destroy = true" }
' "${SELF_TMP}/precious.tf" > "${SELF_TMP}/precious.mut" && mv "${SELF_TMP}/precious.mut" "${SELF_TMP}/precious.tf"
self_expected_precious_keys="$( { lifecycle_keys "${SELF_TMP}/base.tf"; printf '%s\n' 'prevent_destroy'; } | sort -u )"
if [[ "$(lifecycle_keys "${SELF_TMP}/precious.tf")" == "${self_expected_precious_keys}" ]]; then
  test_fail "self-check: injected new lifecycle attribute was NOT detected (B7 key-set check is inert)"
  self_ok=false
else
  test_pass "self-check: unmirrored lifecycle attribute detected (B7)"
fi

# (e) prevent_destroy leak into base → B6's declares_prevent_destroy must fire.
#     (Injecting = false proves B6 rejects any declaration, not merely = true.)
awk '
  { print }
  /^[[:space:]]*lifecycle[[:space:]]*\{/ { print "    prevent_destroy = false" }
' "${SELF_TMP}/base.tf" > "${SELF_TMP}/base.mut" && mv "${SELF_TMP}/base.mut" "${SELF_TMP}/base.tf"
if declares_prevent_destroy "${SELF_TMP}/base.tf"; then
  test_pass "self-check: prevent_destroy declaration in base detected (B6)"
else
  test_fail "self-check: prevent_destroy declaration in base was NOT detected (B6 check is inert)"
  self_ok=false
fi

# (f) replace_triggered_by content change → lifecycle_array must reflect it
#     (B4/B5 parsing is not inert). Removing the only element empties the array.
grep -Ev 'terraform_data\.cidata_hash' "${SELF_TMP}/base.tf" > "${SELF_TMP}/base.mut" && mv "${SELF_TMP}/base.mut" "${SELF_TMP}/base.tf"
if [[ -z "$(lifecycle_array "${SELF_TMP}/base.tf" replace_triggered_by)" ]]; then
  test_pass "self-check: replace_triggered_by content change observed (B4/B5)"
else
  test_fail "self-check: replace_triggered_by parsing did not reflect element removal (B4/B5 check is inert)"
  self_ok=false
fi

if [[ "${self_ok}" != "true" ]]; then
  test_fail "mutation self-check failed — the parity comparisons cannot be trusted"
fi

runner_summary
