#!/usr/bin/env bash
# test_operations_md_runbooks.sh — Verify required runbook sections in OPERATIONS.md.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

OPS_MD="${REPO_ROOT}/OPERATIONS.md"
SPRINT_033_MD="${REPO_ROOT}/docs/sprints/SPRINT-033.md"

test_start "1" "OPERATIONS.md exists"
if [[ -s "$OPS_MD" ]]; then
  test_pass "file exists and is non-empty"
else
  test_fail "OPERATIONS.md missing or empty"
fi

required_sections=(
  "Field Update Workflow"
  "Recovery from Broken Control-Plane Closure"
  "gitlab Down After Closure Push"
  "Runner Down After Self-Update"
  "Recovery Decision Table"
  "Break-Glass"
  "known_hosts Management"
  "Publishing to GitHub"
  "Accepting a GitHub Contribution"
  "Pre-Promotion Dashboard Check"
  "Onboarding New Catalog Apps"
)

idx=2
for section in "${required_sections[@]}"; do
  test_start "$idx" "Section: ${section}"
  if grep -qi "$section" "$OPS_MD"; then
    test_pass "section present"
  else
    test_fail "MISSING: ${section}"
  fi
  idx=$((idx + 1))
done

test_start "${idx}" "OPERATIONS.md manual applications.yaml example includes pool fields"
if grep -q 'pool: prod' "$OPS_MD" && grep -q 'pool: dev' "$OPS_MD"; then
  test_pass "applications.yaml example documents required pool values"
else
  test_fail "applications.yaml example is missing required pool values"
fi
idx=$((idx + 1))

test_start "${idx}" "OPERATIONS.md proxmox-vm examples include tags wiring"
if grep -q 'tags   = \["pool-\${local.app_myapp.environments.prod.pool}"\]' "$OPS_MD" && \
   grep -q 'tags   = \["pool-\${local.app_myapp.environments.dev.pool}"\]' "$OPS_MD"; then
  test_pass "proxmox-vm examples document required tags wiring"
else
  test_fail "proxmox-vm examples are missing required tags wiring"
fi
idx=$((idx + 1))

test_start "${idx}" "OPERATIONS.md dashboard checklist includes required dev gate steps"
if grep -q 'Open `https://influxdb.dev.<domain>/`' "$OPS_MD" && \
   grep -q 'Confirm all VMs are visible and each card has a chart' "$OPS_MD" && \
   grep -q 'Confirm VM and node label click-through opens the correct Grafana detail dashboard' "$OPS_MD" && \
   grep -q 'Confirm `Swap Axes` works, switch to `Flat`, reload, and verify the layout preference persists' "$OPS_MD"; then
  test_pass "dashboard pre-promotion checklist documents the required checks"
else
  test_fail "dashboard pre-promotion checklist is missing required validation steps"
fi
idx=$((idx + 1))

test_start "${idx}" "OPERATIONS.md onboarding runbook includes the rebuild-cluster remediation command"
if grep -q 'rebuild-cluster.sh --scope onboard-app=<app>' "$OPS_MD" && \
   grep -q 'git log --oneline -2 -- site/sops/secrets.yaml' "$OPS_MD" && \
   grep -q 'git push' "$OPS_MD"; then
  test_pass "onboarding runbook documents the command, commit inspection, and manual push"
else
  test_fail "onboarding runbook is missing the documented remediation flow"
fi
idx=$((idx + 1))

test_start "${idx}" "OPERATIONS.md documents workstation access, monitoring, and reboot behavior"
if grep -q '### Workstation Access and Operations' "$OPS_MD" && \
   grep -q 'ssh kentaro@workstation.prod.<domain>' "$OPS_MD" && \
   grep -q 'https://workstation.<env>.<domain>:8443/status' "$OPS_MD" && \
   grep -q 'tmux sessions do \*\*not\*\* survive that reboot' "$OPS_MD"; then
  test_pass "workstation runbook covers access, health checks, and reboot semantics"
else
  test_fail "workstation runbook is missing required operator guidance"
fi
idx=$((idx + 1))

test_start "${idx}" "OPERATIONS.md GitHub publishing runbook covers Sprint 033 flow"
if grep -q 'seed-github-deploy-key.sh' "$OPS_MD" && \
   grep -q 'verify-github-publish.sh' "$OPS_MD" && \
   grep -q 'GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE' "$OPS_MD" && \
   grep -q 'github-mirror-main' "$OPS_MD" && \
   grep -q 'Missing deploy key material.*is now an error' "$OPS_MD" && \
   grep -q "pipeline uses a Vault-delivered deploy key" "$OPS_MD" && \
   grep -q 'sync-to-main.sh' "$OPS_MD" && \
   grep -q "operator's local SSH credentials" "$OPS_MD"; then
  test_pass "GitHub publishing runbook documents seeding, verification, rewrite ack, telemetry, fail-loud behavior, and credential seam"
else
  test_fail "GitHub publishing runbook is missing Sprint 033 guidance"
fi
idx=$((idx + 1))

test_start "${idx}" "GitHub publish runbooks require cicd CIDATA convergence before first prod publish"
if ! grep -q 'safe-apply.sh control-plane' "$OPS_MD" && \
   ! grep -q 'safe-apply.sh control-plane' "$SPRINT_033_MD" && \
   grep -q 'rebuild-cluster.sh --scope control-plane' "$OPS_MD" && \
   grep -q '\[PASS\] runner remote-url materialized' "$OPS_MD" && \
   grep -q 'rebuild-cluster.sh --scope control-plane' "$SPRINT_033_MD" && \
   grep -q '\[PASS\] runner remote-url materialized' "$SPRINT_033_MD"; then
  test_pass "runbooks gate first publish on supported workstation control-plane convergence and runner remote-url verification"
else
  test_fail "runbooks must require rebuild-cluster control-plane convergence, reject safe-apply control-plane, and verify runner remote-url before first publish"
fi
idx=$((idx + 1))

test_start "${idx}" "GitHub publish runbooks document first-publish disciplines (per-run override, smoke-branch soak, revert-not-patch)"
if grep -q 'per-run' "$OPS_MD" && \
   grep -q 'per-run' "$SPRINT_033_MD" && \
   grep -q 'smoke-branch' "$OPS_MD" && \
   grep -q 'smoke-branch' "$SPRINT_033_MD" && \
   grep -qi 'revert' "$OPS_MD" && \
   grep -qi 'revert' "$SPRINT_033_MD" && \
   grep -q 'Sprint-027' "$OPS_MD" && \
   grep -q 'Sprint-027' "$SPRINT_033_MD"; then
  test_pass "runbooks document the three first-publish disciplines"
else
  test_fail "runbooks must document the per-run override, smoke-branch soak, and revert-not-patch disciplines for the first prod publish"
fi

runner_summary
