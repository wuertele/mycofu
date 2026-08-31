#!/usr/bin/env bash
# test_tofu_wrapper_disabled_role.sh — issue #505.
#
# Cold rebuild from a fresh clone (DRT-002) was blocked because tofu-wrapper.sh,
# when image-versions.auto.tfvars is absent, fabricated a PLACEHOLDER_<role>
# for EVERY role referenced in main.tf — including `workstation`, which is
# disabled in site/applications.yaml. build-all-images.sh / merge-image-versions.sh
# only build enabled==true apps, so workstation never gets a real image, and its
# VM modules are count=0 (OpenTofu does not index image_versions for a count=0
# module at plan time — verified separately). The fabricated placeholder then
# tripped the image gate and aborted the tofu preflight before any recovery
# could proceed.
#
# The fix: the fabrication path excludes disabled applications (same
# applications.yaml enabled flag the image producer uses). A disabled role needs
# NO image — different from a placeholder image. The gate stays strict for every
# role that DOES need an image (infra roles + enabled apps).
#
# This test drives the REAL tofu-wrapper.sh with stubbed sops/tofu (the harness
# pattern from test_tofu_image_validation.sh):
#   1. fresh clone (no tfvars) => fabrication omits the disabled role, keeps
#      infra + enabled-app placeholders; plan preflight passes
#   2. post-build state (enabled roles real, disabled role absent) => apply
#      preflight PASSES — the DRT-002 acceptance condition
#   3. an ENABLED role left as a placeholder still BLOCKS apply — guard intact
#   4. fresh-clone apply blocks on the enabled placeholders but never names the
#      disabled role — it is fully absent from the image contract

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

# Infra image manifest — `dns` is an infra role (never an app). Used to prove a
# disabled applications.yaml entry cannot suppress an infra role's placeholder.
cat > "${FIXTURE_REPO}/framework/images.yaml" <<'EOF'
roles:
  dns:
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

# workstation disabled (the #505 case); influxdb enabled (a normal app that must
# still get a placeholder so the gate keeps protecting it).
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications:
  workstation:
    enabled: false
  influxdb:
    enabled: true
EOF

# main.tf references an infra role (dns), an enabled app (influxdb), and the
# disabled app (workstation) — the last gated by count=0 exactly as in the real
# root module.
cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
module "dns" {
  source = "../modules/example"
  image  = "local:iso/${var.image_versions["dns"]}"
}

module "influxdb" {
  source = "../modules/example"
  image  = "local:iso/${var.image_versions["influxdb"]}"
}

module "grafana" {
  source = "../modules/example"
  count  = try(local.app_grafana.enabled, false) ? 1 : 0
  image  = "local:iso/${var.image_versions["grafana"]}"
}

module "workstation" {
  source = "../modules/example"
  count  = try(local.app_workstation.enabled, false) ? 1 : 0
  image  = "local:iso/${var.image_versions["workstation"]}"
}
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
# 1. Fresh clone (no tfvars): fabrication omits the disabled role
# ---------------------------------------------------------------------------
test_start "fabrication.disabled-omitted" "fresh clone: placeholder generation skips the disabled role"
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "plan preflight passes from a fresh clone with workstation disabled"
else
  test_fail "plan preflight did not pass (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "fabrication.file" "generated tfvars keeps infra + enabled app, omits disabled role"
if grep -Fq '"dns" = "PLACEHOLDER_dns"' "${IMAGE_VERSIONS_FILE}" &&
   grep -Fq '"influxdb" = "PLACEHOLDER_influxdb"' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'workstation' "${IMAGE_VERSIONS_FILE}"; then
  test_pass "dns + influxdb placeholders present; no workstation entry fabricated"
else
  test_fail "fabrication set is wrong"; cat "${IMAGE_VERSIONS_FILE}" >&2
fi

# ---------------------------------------------------------------------------
# 2. Post-build state: enabled roles real, disabled role absent => apply passes
#    (this is the DRT-002 acceptance condition)
# ---------------------------------------------------------------------------
test_start "apply.post-build-passes" "enabled roles built, disabled role absent => apply preflight passes"
cat > "${IMAGE_VERSIONS_FILE}" <<'EOF'
# built
image_versions = {
  "dns" = "dns-a1b2c3d4.img"
  "influxdb" = "influxdb-11223344.img"
}
EOF
run_wrapper apply
if [[ "${STATUS}" -eq 0 ]] && grep -Fq 'apply' "${TOFU_LOG}"; then
  test_pass "apply proceeds; the absent disabled role does not trip the gate"
else
  test_fail "apply blocked despite valid enabled images (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

# ---------------------------------------------------------------------------
# 3. Guard intact: an ENABLED role left as a placeholder still blocks apply
# ---------------------------------------------------------------------------
test_start "apply.enabled-placeholder-blocks" "an enabled role's placeholder still blocks apply (guard intact)"
cat > "${IMAGE_VERSIONS_FILE}" <<'EOF'
image_versions = {
  "dns" = "PLACEHOLDER_dns"
  "influxdb" = "influxdb-11223344.img"
}
EOF
run_wrapper apply
if [[ "${STATUS}" -ne 0 ]] &&
   grep -Fq 'dns: PLACEHOLDER_dns' <<< "${OUTPUT}" &&
   ! grep -Fq 'apply' "${TOFU_LOG}"; then
  test_pass "the placeholder gate still fails closed for a role that needs an image"
else
  test_fail "the gate was weakened for enabled roles (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

# ---------------------------------------------------------------------------
# 4. Fresh-clone apply blocks on enabled placeholders but never names the
#    disabled role — it is fully absent from the image contract
# ---------------------------------------------------------------------------
test_start "apply.fresh-clone-omits-disabled" "fresh-clone apply blocks on enabled placeholders, never on the disabled role"
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper apply
if [[ "${STATUS}" -ne 0 ]] &&
   grep -Fq 'dns: PLACEHOLDER_dns' <<< "${OUTPUT}" &&
   ! grep -Fq 'workstation' <<< "${OUTPUT}"; then
  test_pass "workstation is absent from the fabricated contract; only real placeholders block"
else
  test_fail "fresh-clone apply mishandled the disabled role (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

# ---------------------------------------------------------------------------
# 5. Symmetry: an app PRESENT but with no `enabled` field is treated as disabled
#    (the producers require enabled==true), so it gets no placeholder.
# ---------------------------------------------------------------------------
test_start "fabrication.absent-enabled-field" "app with no enabled field is excluded (producer symmetry)"
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications:
  workstation:
    enabled: false
  influxdb:
    enabled: true
  grafana:
    ram: 2048
EOF
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]] &&
   grep -Fq '"influxdb" = "PLACEHOLDER_influxdb"' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'grafana' "${IMAGE_VERSIONS_FILE}"; then
  test_pass "grafana (present, no enabled field) gets no placeholder — matches producer's enabled==true"
else
  test_fail "absent-enabled-field app mishandled (status=${STATUS})"; cat "${IMAGE_VERSIONS_FILE}" >&2
fi

# ---------------------------------------------------------------------------
# 6. Collision hardening: a disabled applications.yaml entry that shares an
#    INFRA role's name must NOT suppress the infra role's placeholder (the gate
#    must stay intact for a role that needs an image — destruction-safety).
# ---------------------------------------------------------------------------
test_start "fabrication.infra-collision" "disabled app colliding with an infra role does not drop the infra placeholder"
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications:
  workstation:
    enabled: false
  dns:
    enabled: false
  influxdb:
    enabled: true
EOF
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]] &&
   grep -Fq '"dns" = "PLACEHOLDER_dns"' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'workstation' "${IMAGE_VERSIONS_FILE}"; then
  test_pass "infra role dns keeps its placeholder despite a colliding disabled app; workstation still excluded"
else
  test_fail "infra-collision hardening failed (status=${STATUS})"; cat "${IMAGE_VERSIONS_FILE}" >&2
fi

# ---------------------------------------------------------------------------
# 7. Absent app (#520): a role referenced in main.tf but entirely absent
#    from applications.yaml is NOT fabricated. The residual edge from #505:
#    "disabled app" (enabled: false) was handled by the previous blacklist,
#    but an app entry entirely absent from applications.yaml still slipped
#    through and got a placeholder — tripping the image gate the same way
#    #505 did. The fix derives fabrication from the SAME authoritative
#    universe the image producers use, so absent AND disabled fall out by
#    one rule.
# ---------------------------------------------------------------------------
test_start "fabrication.absent-app-omitted" "app absent from applications.yaml gets no placeholder (issue #520)"
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications:
  influxdb:
    enabled: true
EOF
# `workstation` and `grafana` are now entirely absent from applications.yaml,
# though still referenced (count-gated) in main.tf. `dns` is a framework
# infra role and stays in the universe via framework/images.yaml.
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]] &&
   grep -Fq '"dns" = "PLACEHOLDER_dns"' "${IMAGE_VERSIONS_FILE}" &&
   grep -Fq '"influxdb" = "PLACEHOLDER_influxdb"' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'workstation' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'grafana' "${IMAGE_VERSIONS_FILE}"; then
  test_pass "absent apps (workstation, grafana) get no placeholder; infra + enabled app intact"
else
  test_fail "absent-app case mishandled (status=${STATUS})"; cat "${IMAGE_VERSIONS_FILE}" >&2
fi

# ---------------------------------------------------------------------------
# 8. From-scratch site (#520 core acceptance): applications.yaml has an
#    empty applications: map. Every app-shaped module in main.tf is
#    count=0. Only infra roles need placeholders. plan preflight must pass
#    from a genuinely empty applications.yaml — the from-scratch-site
#    entry condition #520 names.
# ---------------------------------------------------------------------------
test_start "fabrication.empty-applications-passes" "from-scratch site (empty applications: map) passes plan preflight"
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -eq 0 ]] &&
   grep -Fq '"dns" = "PLACEHOLDER_dns"' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'influxdb' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'grafana' "${IMAGE_VERSIONS_FILE}" &&
   ! grep -Fq 'workstation' "${IMAGE_VERSIONS_FILE}"; then
  test_pass "empty applications: map — only infra role dns fabricated; from-scratch clone plan passes"
else
  test_fail "from-scratch case mishandled (status=${STATUS})"; cat "${IMAGE_VERSIONS_FILE}" >&2
fi

# ---------------------------------------------------------------------------
# 9. G4 fail-closed: if main.tf references image_versions keys but the
#    authoritative role universe is empty (all three sources absent /
#    empty), the wrapper refuses to fabricate rather than silently emit
#    an empty `image_versions = {}` that would let apply through the
#    image gate. This is the safety envelope for the derivation-based
#    fabrication — a "cannot determine" state fails, does not skip.
# ---------------------------------------------------------------------------
test_start "fabrication.empty-universe-fails-closed" "empty role universe fails closed instead of silently disarming the gate"
# Wipe every authoritative source so the universe is genuinely empty.
rm -f "${FIXTURE_REPO}/framework/images.yaml" "${FIXTURE_REPO}/site/images.yaml"
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF
rm -f "${IMAGE_VERSIONS_FILE}"
run_wrapper plan
if [[ "${STATUS}" -ne 0 ]] &&
   grep -Fq 'cannot fabricate image-versions placeholders' <<< "${OUTPUT}" &&
   grep -Fq 'This looks like a broken framework/site checkout' <<< "${OUTPUT}"; then
  # The error message must identify the failure mode (empty universe) —
  # not just any exit 1 — and no placeholder tfvars should have been written.
  if [[ ! -s "${IMAGE_VERSIONS_FILE}" ]] || ! grep -Fq 'PLACEHOLDER_' "${IMAGE_VERSIONS_FILE}"; then
    test_pass "fabrication fails closed with a clear empty-universe error when manifests are absent"
  else
    test_fail "fabrication exited non-zero but still wrote a placeholder tfvars"; cat "${IMAGE_VERSIONS_FILE}" >&2
  fi
else
  test_fail "fabrication did not fail closed on empty universe (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi
# Restore framework/images.yaml for any downstream tests (defensive — this is
# currently the last test, but resetting keeps the fixture composable).
cat > "${FIXTURE_REPO}/framework/images.yaml" <<'EOF'
roles:
  dns:
    category: nix
EOF

runner_summary
