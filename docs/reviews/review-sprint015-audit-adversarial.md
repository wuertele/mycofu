# Adversarial Review: Design Goal 4 Compliance Audit Report

**Reviewer:** Claude (adversarial)
**Date:** 2026-04-12
**Files reviewed:**
- `docs/reports/design-goal-4-audit.md` (synthesized report)
- `docs/sprints/drafts/SPRINT-015-CLAUDE-FINDINGS.md`
- `docs/sprints/drafts/SPRINT-015-CODEX-FINDINGS.md`
- `docs/sprints/drafts/SPRINT-015-GEMINI-FINDINGS.md`
- `docs/sprints/drafts/SPRINT-015-MERGE-NOTES-SYNTHESIS.md`

---

## 1. Dropped Findings

**No findings were dropped.** Every raw finding from all three agents
appears in the final report, either as a numbered finding (F-001 through
F-016), a known boundary (KB-1 through KB-7), or in the "Already Fixed"
section. The mapping is complete.

---

## 2. Severity Misclassifications

### ISSUE: F-014 (PBS ISO) severity disagreement not fully justified

Gemini classified the PBS ISO finding as S2 (visible failure). Claude
and Codex classified it as S1. The synthesis notes record the override
("Chose S1 -- a mutated ISO is silent") and the report uses S1. This is
defensible: a supply-chain substitution at the same URL IS silent (the
script succeeds, no error is displayed, and a different PBS binary is
installed). However, the more likely real-world scenario is URL removal
(S2, visible `curl` failure), not content substitution. The S1
classification is the correct conservative choice for a security-relevant
finding but should acknowledge that the S2 scenario (unavailability) is
more probable than the S1 scenario (silent substitution).

**Verdict:** Classification is defensible. Minor wording improvement possible.

### ISSUE: F-005 (OpenTofu required_version) classified as S1 -- questionable

The report classifies `required_version = ">= 1.6.0"` as S1 (silent
behavioral change). But different tofu versions producing different
`tofu plan` output is visible to the operator -- the plan is reviewed
before apply. The silent part is that two operators may get different
plans without realizing it, but each individual operator sees their plan
output. This is closer to S2 (visible divergence between environments)
than S1 (truly silent). Claude's raw finding also classified this as S1,
but the reasoning ("different plan output") describes divergence, not
silence. Consider S2.

**Verdict:** Borderline. S2 would be more accurate.

### ISSUE: F-008 (Tofu state on NAS) classified as S2 -- should be Known Boundary

The synthesis notes explicitly say: "Tofu state on NAS (Gemini F-004) --
Known boundary -- state is derived, not config." Yet the final report
includes it as F-008 with severity S2. The merge notes and the report
contradict each other. Either the merge notes are wrong (and it should
be a finding), or the report failed to follow the merge notes (and it
should be KB-8). Given that OpenTofu state is inherently external in
every OpenTofu deployment, and the report itself says in the fix
recommendation "Consider documenting as a known boundary since tofu
state is inherently external by design," this should be a Known
Boundary, not a finding.

**Verdict:** Misclassified. Should be KB-8, not F-008. This is the most
significant synthesis error in the report.

---

## 3. Known Boundaries vs. Findings

### F-008 should be a Known Boundary (see above)

### F-010 (PostgreSQL :16 tag) -- could be Known Boundary

The report notes this is on a dormant code path (`postgres_method:
native`). A finding on dead code is debatable. The S3 classification
acknowledges the low probability, but "Known Boundary (dormant code)"
or removal of the dead code would be cleaner than tracking it as a
finding. The current classification is acceptable but the fix
recommendation should prioritize removing the dormant code path over
pinning a tag that is never used.

### KB-2 (Proxmox API behavior) vs. F-015 (Proxmox node apt/tools)

These are closely related. KB-2 says "Proxmox is outside commit scope by
design." F-015 says "Proxmox apt sources and tool versions are a
finding." The distinction is that KB-2 is about the API behavior of an
already-installed PVE, while F-015 is about the installation of packages
on PVE nodes by framework scripts. This distinction is valid -- the
framework chooses to run `apt-get install -y socat` without version pins,
which is an active choice, not a passive dependency on the hypervisor.

**Verdict:** The boundary between KB-2 and F-015 is correctly drawn.

---

## 4. Deduplication Correctness

### ISSUE: F-005 and F-006 overlap significantly

F-005 (OpenTofu required_version too broad) and F-006 (devShell/runner
version mismatch) are two facets of the same root cause: the repo does
not enforce a single OpenTofu version. The report acknowledges this
("May be resolved as part of F-005" in the priority section), but
counting them as separate S1 and S2 findings inflates the count. A
single finding with two manifestations would be more accurate.

**Verdict:** Not wrong, but the overlap should be more explicitly called
out. The priority section partially does this.

### PostgreSQL container tag merged correctly

Codex F-003 covered both Gatus and PostgreSQL in a single finding. The
synthesis correctly split these into F-009 (Gatus) and F-010
(PostgreSQL) because they have different severities (S1 vs S3) and
different remediation paths. This is correct deduplication.

### Merge notes ID renumbering

The merge notes assign intermediate IDs (F-001 through F-015) that do
not match the final report IDs (F-001 through F-016). For example, in
the merge notes, "Gatus :latest" is F-001 and "PBS ISO" is F-002, but
in the final report Gatus is F-009 and PBS ISO is F-014. The final
report reorganized findings by category (Build, Deploy, Runtime,
Environment, External, Secrets) rather than by confidence level. This
is a valid editorial choice, but the merge notes and the report are
not cross-referenceable by ID. Anyone trying to trace a finding from
the merge notes to the report will be confused.

**Verdict:** Not an error, but a documentation gap. The merge notes
should either be updated with final IDs or the report should include
the merge-note IDs as aliases.

---

## 5. Coverage Gaps

### No findings about the Tailscale package

Claude's raw findings mention Tailscale: "Tailscale uses committed
package; no auto-update found. Compliant." None of the agents examined
whether Tailscale's control plane (login server, coordination server)
constitutes an external input that escapes the commit. The Tailscale
binary is pinned via nixpkgs, but Tailscale phones home to
`controlplane.tailscale.com` and the coordination server can push ACL
changes, key rotations, and node expiry. This is arguably a known
boundary (similar to ACME CA behavior), but none of the three agents
even raised it for consideration. Given that Tailscale has root-level
network access on every VM, the absence of any finding or known-boundary
entry is a gap.

**Verdict:** Minor gap. Should be documented as a Known Boundary (KB-8
or KB-9) alongside ACME and NTP.

### No findings about the HAOS appliance

The project includes a Home Assistant OS VM (Category C vendor
appliance). HAOS auto-updates by default. None of the agents examined
whether HAOS's update channel is committed or ambient. This is likely a
known boundary (vendor appliance, managed via PBS backup), but it was
not examined by any agent.

**Verdict:** Minor gap. HAOS is a Category C appliance and the update
channel is outside the framework's scope, but it should be explicitly
listed as a known boundary for completeness.

### No findings about DNS resolver during nix builds

Claude noted "DNS resolution during nix builds uses the runner's
`/etc/resolv.conf` (NixOS-configured)" but did not flag that the DNS
resolver itself is an external input. If the runner's DNS resolver
returns different results for `cache.nixos.org` (e.g., CDN steering),
the nix binary cache endpoint changes. This is a stretch (CDN steering
does not change content, only routing), and falls under the same trust
model as KB-6 (nix binary cache). The absence of a finding here is
plausible.

**Verdict:** Not a gap. Covered implicitly by KB-6.

---

## 6. "Already Fixed" Evidence

The "Already Fixed" section (provider lockfile) has strong evidence:

- Specific commit hash (1db5669) cited
- Six independent verification points listed
- Negative checks included (no `-upgrade` flag, `.gitignore` does not
  exclude the lockfile)
- Ratchet test cited by name and verified behaviors

**Verdict:** Evidence is sufficient and well-documented. No issues.

---

## 7. Priority Ordering

### ISSUE: F-013 (SSH host-key verification) ranked #3 in priority

F-013 is ranked above F-005 (OpenTofu version constraint) and F-011
(SOPS-to-Vault sync). From a security perspective this makes sense --
SSH MITM on the management network is a supply-chain risk. From a
probability perspective, F-005 and F-011 are far more likely to
manifest in normal operations. The report does not explain the priority
rationale beyond listing them in order. Adding a sentence about
prioritizing security findings over operational findings would help.

### F-009 (Gatus :latest) is correctly ranked #1

This is the most likely S1 to actually manifest -- a `docker pull` on
a different day silently changes the monitoring stack. The fix is
trivial (30 minutes). Correct prioritization.

### F-008 appears in the Near-term priority list as item #11

If F-008 should be a Known Boundary (as argued above), it should not
appear in the fix priority list at all.

**Verdict:** Priority ordering is reasonable except for the F-008
issue. Consider explaining the security-vs-probability tradeoff for
F-013's ranking.

---

## Summary of Issues Found

| # | Issue | Severity |
|---|-------|----------|
| 1 | F-008 contradicts merge notes -- classified as S2 finding but merge notes say "Known boundary" | Material error |
| 2 | F-005 classified as S1, better fits S2 (divergence is visible to each operator) | Minor |
| 3 | F-005 and F-006 overlap significantly, inflating finding count | Minor |
| 4 | Merge notes IDs do not match report IDs, no cross-reference provided | Documentation gap |
| 5 | Tailscale control plane not examined by any agent | Coverage gap |
| 6 | HAOS auto-update channel not examined by any agent | Coverage gap |
| 7 | F-013 priority ranking rationale not explained | Minor |

### Overall Assessment

The report is well-structured and the synthesis is largely faithful to
the raw findings. The most significant error is F-008's classification
as a finding when the merge notes explicitly marked it as a known
boundary. The F-005 severity is debatable. The coverage gaps
(Tailscale, HAOS) are minor -- both would likely be classified as known
boundaries rather than findings. The deduplication is generally correct
with the F-005/F-006 overlap being the only notable case. The "Already
Fixed" section has strong evidence. The priority ordering is reasonable.

The report is suitable for use as-is with the caveat that F-008 should
be reclassified as a Known Boundary.
