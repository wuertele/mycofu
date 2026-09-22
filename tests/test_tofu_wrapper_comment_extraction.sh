#!/usr/bin/env bash
# test_tofu_wrapper_comment_extraction.sh — issue #539.
#
# tofu-wrapper.sh at line 284 (as of pre-#539) extracted the set of roles
# main.tf references via:
#
#   grep -o 'var\.image_versions\["[^"]*"' main.tf | ...
#
# That grep matches occurrences INSIDE HCL comments (`#`, `//`, `/* ... */`).
# The pre-#539 main.tf has no commented references, so the defect is not
# exercised — but a future refactor that comments out a module block (a
# perfectly ordinary maintenance step for gate-flipping an experimental app)
# would immediately fabricate a `PLACEHOLDER_<role>` for the dead role.
# That placeholder is not merely noise: it trips the image gate with a
# confusing "invalid image value" message instead of the clear
# tofu key-not-found or missing-manifest signal that not-fabricating
# produces (G4: teeth over misleading pass). Origin: MR #520 adversarial
# review by a Claude fork sub-agent.
#
# The fix strips HCL comments (`#` / `//` line comments, `/* ... */` block
# comments including multi-line) before the grep. It is a strip-then-grep,
# not a comment-aware regex — the transform is explicit and structural so
# the extractor can only see uncommented HCL, by construction.
#
# This test drives the REAL tofu-wrapper.sh with stubbed sops/tofu (the
# fixture pattern from test_tofu_wrapper_disabled_role.sh):
#
#   1. Uncommented `var.image_versions["<role>"]` references produce
#      placeholders as before (regression).
#   2. References inside `#` line comments, `//` line comments, and
#      `/* ... */` block comments (including a block spanning multiple
#      lines) DO NOT produce placeholders.
#   3. A trailing `# ...` comment on a line that also contains a real,
#      uncommented reference: the real reference is extracted, the
#      commented-tail reference is not (proves the fix trims from the
#      first comment marker rather than dropping the whole line).
#   4. A multi-line block comment whose `*/` is on a different line than
#      its `/*` still suppresses every reference inside (proves the
#      in_block state carries across newlines).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
TOFU_LOG="${TMP_DIR}/tofu.log"
IMAGE_VERSIONS_FILE="${FIXTURE_REPO}/site/tofu/image-versions.auto.tfvars"

mkdir -p \
  "${FIXTURE_REPO}/framework/scripts" \
  "${FIXTURE_REPO}/framework/tofu/root" \
  "${FIXTURE_REPO}/site/sops" \
  "${FIXTURE_REPO}/site/tofu" \
  "${SHIM_DIR}"

# Every role potentially referenced in main.tf lives in the authoritative
# universe so that the fabrication code COULD emit a placeholder for it. The
# test is purely about EXTRACTION — i.e., which var.image_versions references
# the wrapper's awk-based extractor sees. Isolating universe membership from
# extractor behavior lets the test fail only for extractor defects.
cat > "${FIXTURE_REPO}/framework/images.yaml" <<'EOF'
roles:
  dns:
    category: nix
  influxdb:
    category: nix
  commented_hash:
    category: nix
  commented_slash:
    category: nix
  commented_block:
    category: nix
  inline_hash:
    category: nix
  real_before_hash:
    category: nix
  block_across_lines_a:
    category: nix
  block_across_lines_b:
    category: nix
  url_in_string:
    category: nix
  block_marker_in_string:
    category: nix
  hash_in_string:
    category: nix
  after_inline_block:
    category: nix
  after_multiline_block:
    category: nix
EOF

cp "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh" "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

printf 'fixture flake\n' > "${FIXTURE_REPO}/flake.nix"
printf 'dummy-age-key\n' > "${FIXTURE_REPO}/operator.age.key"
printf 'encrypted-placeholder\n' > "${FIXTURE_REPO}/site/sops/secrets.yaml"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nas:
  ip: 10.0.0.10
  postgres_port: 5432
nodes:
  - mgmt_ip: 10.0.0.11
vms: {}
EOF

# All apps enabled so applications.yaml never suppresses any candidate — the
# only reason a commented role should not appear is the extractor comment strip.
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"proxmox_api_user":"user","proxmox_api_password":"pass","tofu_db_password":"dbpass","ssh_pubkey":"ssh-ed25519 AAAA test","pdns_api_key":"pdns"}
JSON
EOF
chmod +x "${SHIM_DIR}/sops"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_TOFU_LOG}"
case "${1:-}" in
  state)
    case "${2:-}" in
      list|show|rm) exit 0 ;;
    esac
    ;;
  plan|apply|destroy|init|refresh) exit 0 ;;
esac
echo "unexpected tofu invocation: $*" >&2
exit 98
EOF
chmod +x "${SHIM_DIR}/tofu"

export PATH="${SHIM_DIR}:${PATH}"
export STUB_TOFU_LOG="${TOFU_LOG}"

OUTPUT=""
STATUS=0

run_wrapper() {
  : > "${TOFU_LOG}"
  set +e
  OUTPUT="$(cd "${FIXTURE_REPO}" && framework/scripts/tofu-wrapper.sh "$@" 2>&1)"
  STATUS=$?
  set -e
}

# ---------------------------------------------------------------------------
# 1. Comprehensive comment forms + real references on one page
#
#    Uncommented references (`dns`, `influxdb`, `real_before_hash`) must
#    become placeholders. Comment-hidden references (`commented_hash`,
#    `commented_slash`, `commented_block`, `inline_hash`) must NOT.
# ---------------------------------------------------------------------------
cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
module "dns" {
  source = "../modules/example"
  image  = "local:iso/${var.image_versions["dns"]}"
}

module "influxdb" {
  source = "../modules/example"
  image  = "local:iso/${var.image_versions["influxdb"]}"
}

# module "commented_hash" {
#   image = "local:iso/${var.image_versions["commented_hash"]}"
# }

// module "commented_slash" {
//   image = "local:iso/${var.image_versions["commented_slash"]}"
// }

/* module "commented_block" {
     image = "local:iso/${var.image_versions["commented_block"]}"
   } */

module "real_before_hash" {
  source = "../modules/example"
  image  = "local:iso/${var.image_versions["real_before_hash"]}"  # legacy: var.image_versions["inline_hash"]
}
EOF

test_start "extract.uncommented-refs-produce-placeholders" \
  "uncommented references become PLACEHOLDER_<role> entries in the fabricated tfvars"
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]]; then
  if grep -Fq '"dns" = "PLACEHOLDER_dns"' "${IMAGE_VERSIONS_FILE}" &&
     grep -Fq '"influxdb" = "PLACEHOLDER_influxdb"' "${IMAGE_VERSIONS_FILE}" &&
     grep -Fq '"real_before_hash" = "PLACEHOLDER_real_before_hash"' "${IMAGE_VERSIONS_FILE}"; then
    test_pass "dns, influxdb, and real_before_hash placeholders emitted for the uncommented references"
  else
    test_fail "expected placeholders missing from generated tfvars"; cat "${IMAGE_VERSIONS_FILE}" >&2
  fi
else
  test_fail "plan preflight failed (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "extract.comment-hidden-refs-suppressed" \
  "references inside #, //, and /* */ comments do NOT produce placeholders"
if ! grep -Fq 'commented_hash' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'commented_slash' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'commented_block' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'inline_hash' "${IMAGE_VERSIONS_FILE}"; then
  test_pass "none of the four commented references leaked a placeholder"
else
  test_fail "at least one commented reference produced a placeholder"; cat "${IMAGE_VERSIONS_FILE}" >&2
fi

# ---------------------------------------------------------------------------
# 2. Multi-line /* ... */ block whose */ is on a different line than /*
#
#    Proves the extractor's in_block state carries across newlines — the
#    single-line-strip approach that #520's review reference alluded to
#    ("comment-aware regex") would miss this shape.
# ---------------------------------------------------------------------------
cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
module "dns" {
  source = "../modules/example"
  image  = "local:iso/${var.image_versions["dns"]}"
}

/*
   module "block_across_lines_a" {
     image = "local:iso/${var.image_versions["block_across_lines_a"]}"
   }

   module "block_across_lines_b" {
     image = "local:iso/${var.image_versions["block_across_lines_b"]}"
   }
*/

module "influxdb" {
  source = "../modules/example"
  image  = "local:iso/${var.image_versions["influxdb"]}"
}
EOF

test_start "extract.multi-line-block-comment-suppressed" \
  "references inside a /* ... */ block spanning multiple lines are all suppressed"
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]]; then
  if grep -Fq '"dns" = "PLACEHOLDER_dns"' "${IMAGE_VERSIONS_FILE}" &&
     grep -Fq '"influxdb" = "PLACEHOLDER_influxdb"' "${IMAGE_VERSIONS_FILE}" &&
     ! grep -Fq 'block_across_lines_a' "${IMAGE_VERSIONS_FILE}" &&
     ! grep -Fq 'block_across_lines_b' "${IMAGE_VERSIONS_FILE}"; then
    test_pass "both refs inside the multi-line /* */ block are absent; dns + influxdb still present"
  else
    test_fail "multi-line block comment did not suppress every reference inside it"; cat "${IMAGE_VERSIONS_FILE}" >&2
  fi
else
  test_fail "plan preflight failed on the multi-line-block fixture (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

# ---------------------------------------------------------------------------
# 3. Comment markers inside real HCL string literals
#
#    The mirror bug (adversarial review of first-round fix by codex/gemini):
#    if the strip is not string-aware, a `//` inside a URL, a `/*` inside a
#    regex-shaped string, or a `#` in a color/id string on the same line
#    as a real reference would silently drop that reference. This is the
#    same "extractor lies to the gate" class as #539 itself.
#
#    Fix: the awk toggles `in_string` on `"` (with `\"` escape handling)
#    so comment markers inside strings are not treated as comment starts.
# ---------------------------------------------------------------------------
cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
module "url_in_string" {
  source  = "../modules/example"
  api_url = "https://example.com/api"
  image   = "https://registry/${var.image_versions["url_in_string"]}"
}

module "block_marker_in_string" {
  source  = "../modules/example"
  pattern = "/*/foo/bar/"
  image   = "local:iso/${var.image_versions["block_marker_in_string"]}"
}

module "hash_in_string" {
  source = "../modules/example"
  color  = "#FF0000"
  image  = "local:iso/${var.image_versions["hash_in_string"]}"
}
EOF

test_start "extract.string-literals-shield-comment-markers" \
  "comment markers inside HCL strings (URL //, block */, color #) do not truncate the line"
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]]; then
  if grep -Fq '"url_in_string" = "PLACEHOLDER_url_in_string"' "${IMAGE_VERSIONS_FILE}" &&
     grep -Fq '"block_marker_in_string" = "PLACEHOLDER_block_marker_in_string"' "${IMAGE_VERSIONS_FILE}" &&
     grep -Fq '"hash_in_string" = "PLACEHOLDER_hash_in_string"' "${IMAGE_VERSIONS_FILE}"; then
    test_pass "URL-with-//, string-with-/*, and string-with-# all extracted; extractor is string-aware"
  else
    test_fail "at least one string-with-comment-marker case dropped its real reference"; cat "${IMAGE_VERSIONS_FILE}" >&2
  fi
else
  test_fail "plan preflight failed on the string-literal fixture (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

# ---------------------------------------------------------------------------
# 4. In-block state exit and resume: a single-line /* ... */ block followed
#    on the same line by a real reference must yield the real ref (proves
#    in_block toggles back OFF at */ and normal scanning resumes); and a
#    multi-line block followed by a real ref on a later line must also
#    yield it (proves in_block resets before the next line is scanned).
# ---------------------------------------------------------------------------
cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
/* single-line block */ module "after_inline_block" {
  image = "local:iso/${var.image_versions["after_inline_block"]}"
}

/*
   multi
   line
*/
module "after_multiline_block" {
  image = "local:iso/${var.image_versions["after_multiline_block"]}"
}
EOF

test_start "extract.in-block-state-resumes-after-close" \
  "in_block toggles off at */ so a real ref on the same or later line is still extracted"
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]]; then
  if grep -Fq '"after_inline_block" = "PLACEHOLDER_after_inline_block"' "${IMAGE_VERSIONS_FILE}" &&
     grep -Fq '"after_multiline_block" = "PLACEHOLDER_after_multiline_block"' "${IMAGE_VERSIONS_FILE}"; then
    test_pass "extractor correctly resumes after single-line and multi-line block-comment closes"
  else
    test_fail "extractor dropped a real ref after a block comment closed"; cat "${IMAGE_VERSIONS_FILE}" >&2
  fi
else
  test_fail "plan preflight failed on the resume-after-block fixture (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

# ---------------------------------------------------------------------------
# 5. All-refs-commented main.tf
#
#    Adversarial finding: the pre-P1-fix `awk … | grep -o … | sed … | sort -u`
#    exited 1 under `set -euo pipefail` when the strip left zero references
#    for grep to match — crashing the wrapper on a main.tf that has every
#    var.image_versions[…] behind a comment. The fix moves the ref extraction
#    into the same awk pass (via match()), so the pipeline is `awk | sort -u`;
#    both exit 0 on empty input, so the wrapper produces an empty ROLES,
#    then falls through the "empty universe" fail-closed branch below.
#
#    Note: with EVERY authoritative source populated (framework/images.yaml
#    non-empty), the wrapper's G4 gate does NOT fail closed on empty ROLES —
#    ROLES ∩ AUTHORITATIVE = ∅, so no placeholders are fabricated but plan
#    is allowed to proceed. That is the intended behavior: a main.tf with
#    every ref commented out is a valid intermediate state during a
#    refactor.
# ---------------------------------------------------------------------------
cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
# every reference below is inside a comment; the extractor must
# survive and emit zero roles rather than tripping set -euo pipefail
# module "dns"      { image = "${var.image_versions["dns"]}" }
// module "influxdb" { image = "${var.image_versions["influxdb"]}" }
/* module "vault"    { image = "${var.image_versions["vault"]}" } */
EOF

test_start "extract.all-refs-commented-does-not-crash" \
  "main.tf whose only var.image_versions refs are all inside comments does not crash the wrapper"
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]]; then
  if [[ ! -s "${IMAGE_VERSIONS_FILE}" ]] || ! grep -Fq 'PLACEHOLDER_' "${IMAGE_VERSIONS_FILE}"; then
    test_pass "no fabricated placeholders; wrapper survived a fully-commented main.tf"
  else
    test_fail "fabricated a placeholder for a commented-out reference"; cat "${IMAGE_VERSIONS_FILE}" >&2
  fi
else
  test_fail "wrapper crashed on all-comments main.tf (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

runner_summary
