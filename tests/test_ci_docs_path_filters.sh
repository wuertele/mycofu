#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"
FLAKE_FILE="${REPO_ROOT}/flake.nix"
JSON_FILE=""

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  if [[ -n "${JSON_FILE}" && -f "${JSON_FILE}" ]]; then
    rm -f "${JSON_FILE}"
  fi
}
trap cleanup EXIT

# Fail-closed: malformed CI YAML is a test failure, not a skip.
yq '.' "${CI_FILE}" >/dev/null 2>&1 || fail ".gitlab-ci.yml failed yq parse"

PARSER="yaml"
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  command -v yq >/dev/null 2>&1 || fail "python yaml module missing and yq is unavailable"
  JSON_FILE="$(mktemp)"
  yq -o=json '.' "${CI_FILE}" > "${JSON_FILE}" \
    || fail ".gitlab-ci.yml failed yq-to-json conversion"
  PARSER="json"
fi

PARSER="${PARSER}" JSON_FILE="${JSON_FILE}" python3 - "${CI_FILE}" "${FLAKE_FILE}" <<'PY'
import json
import os
import re
import sys


class Failure(Exception):
    pass


def fail(message):
    raise Failure(message)


def ok(message):
    print(f"ok - {message}")


def load_ci():
    parser = os.environ["PARSER"]
    ci_file = sys.argv[1]
    if parser == "yaml":
        import yaml

        with open(ci_file, "r", encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    if parser == "json":
        with open(os.environ["JSON_FILE"], "r", encoding="utf-8") as fh:
            return json.load(fh)
    fail(f"unknown parser mode: {parser}")


def require_mapping(value, label):
    if not isinstance(value, dict):
        fail(f"{label} is not a mapping")
    return value


def require_rules(ci, job_name):
    job = require_mapping(ci.get(job_name), job_name)
    rules = job.get("rules")
    if not isinstance(rules, list):
        fail(f"{job_name} has no rules list")
    for idx, rule in enumerate(rules):
        if not isinstance(rule, dict):
            fail(f"{job_name}.rules[{idx}] is not a mapping")
    return rules


REGEX_CACHE = {}


def glob_to_regex(pattern):
    if not isinstance(pattern, str):
        fail(f"non-string changes glob: {pattern!r}")
    cached = REGEX_CACHE.get(pattern)
    if cached is not None:
        return cached
    out = []
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if pattern.startswith("**/", i):
            out.append(r"(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(r".*")
            i += 2
        elif ch == "*":
            out.append(r"[^/]*")
            i += 1
        elif ch == "?":
            out.append(r"[^/]")
            i += 1
        else:
            out.append(re.escape(ch))
            i += 1
    regex = re.compile(r"^" + "".join(out) + r"$")
    REGEX_CACHE[pattern] = regex
    return regex


def path_matches(pattern, path):
    return glob_to_regex(pattern).match(path) is not None


def any_change_matches(changes, changed_files):
    if not isinstance(changes, list):
        fail(f"changes clause is not a list: {changes!r}")
    if not changes:
        fail("changes clause is empty")
    return any(path_matches(pattern, path) for pattern in changes for path in changed_files)


def eval_if(expr, context):
    if not isinstance(expr, str):
        fail(f"if expression is not a string: {expr!r}")

    def eval_term(term):
        term = term.strip()
        cmp_match = re.fullmatch(r'\$([A-Za-z_][A-Za-z0-9_]*)\s*(==|!=)\s*"([^"]*)"', term)
        if cmp_match:
            name, op, want = cmp_match.groups()
            got = context.get(name, "")
            return got == want if op == "==" else got != want
        bare_match = re.fullmatch(r"\$([A-Za-z_][A-Za-z0-9_]*)", term)
        if bare_match:
            return bool(context.get(bare_match.group(1), ""))
        fail(f"unsupported if expression term: {term!r}")

    return all(eval_term(term) for term in expr.split("&&"))


def rule_matches(rule, context, changed_files):
    expr = rule.get("if")
    if expr is not None and not eval_if(expr, context):
        return False
    if "changes" in rule and not any_change_matches(rule["changes"], changed_files):
        return False
    return True


def job_runs(ci, job_name, context, changed_files):
    for rule in require_rules(ci, job_name):
        if rule_matches(rule, context, changed_files):
            return rule.get("when") != "never"
    return False


PIGS = ("validate:per-role-isolation", "validate:nix-checks")
EXPECTED_ENABLE_IFS = (
    '$CI_PIPELINE_SOURCE == "merge_request_event"',
    '$CI_PIPELINE_SOURCE != "web" && $CI_COMMIT_BRANCH == "dev"',
    '$CI_PIPELINE_SOURCE != "web" && $CI_COMMIT_BRANCH == "prod"',
)
REQUIRED_FILTER_ENTRIES = {".gitlab-ci.yml", "flake.nix", "flake.lock"}
FLAKE_SOURCE_PROBE_ROLES = ("dns", "testapp")
MR_CONTEXT = {
    "CI_PIPELINE_SOURCE": "merge_request_event",
    "CI_COMMIT_BRANCH": "",
    "RECLAIM_IMAGE_STORE": "",
    "BENCH_SCHEDULE_KEY": "",
}
DEV_CONTEXT = {
    "CI_PIPELINE_SOURCE": "push",
    "CI_COMMIT_BRANCH": "dev",
    "RECLAIM_IMAGE_STORE": "",
    "BENCH_SCHEDULE_KEY": "",
}


def enabling_changes_by_job(ci):
    result = {}
    for job_name in PIGS:
        rules = require_rules(ci, job_name)
        enabling = [rule for rule in rules if rule.get("when") != "never"]
        if len(enabling) != 3:
            fail(f"{job_name} has {len(enabling)} enabling rules, expected exactly 3")
        by_if = {}
        for rule in enabling:
            expr = rule.get("if")
            if expr not in EXPECTED_ENABLE_IFS:
                fail(f"{job_name} has unexpected enabling if: {expr!r}")
            if expr in by_if:
                fail(f"{job_name} has duplicate enabling if: {expr}")
            changes = rule.get("changes")
            if not isinstance(changes, list) or not changes:
                fail(f"{job_name} enabling rule {expr!r} lacks a non-empty changes list")
            missing = REQUIRED_FILTER_ENTRIES - set(changes)
            if missing:
                fail(f"{job_name} changes list for {expr!r} is missing {sorted(missing)}")
            by_if[expr] = changes

        for rule in rules:
            if rule.get("if") not in EXPECTED_ENABLE_IFS and "changes" in rule:
                fail(f"{job_name} has changes on non-enabling rule {rule.get('if')!r}")
        result[job_name] = by_if
    ok("both heavy validators have exactly three non-empty MR/dev/prod changes filters")
    return result


def rules_have_changes(rules):
    if not isinstance(rules, list):
        return False
    return any(isinstance(rule, dict) and "changes" in rule for rule in rules)


def require_script_contains(ci, job_name, expected_line):
    job = require_mapping(ci.get(job_name), job_name)
    script = job.get("script")
    if not isinstance(script, list):
        fail(f"{job_name} script is not a list")
    if expected_line not in script:
        fail(f"{job_name} script is missing required line: {expected_line}")


def assert_identical_heavy_changes(changes_by_job):
    reference = None
    for expr in EXPECTED_ENABLE_IFS:
        isolation = changes_by_job["validate:per-role-isolation"][expr]
        nix_checks = changes_by_job["validate:nix-checks"][expr]
        if isolation != nix_checks:
            fail(f"heavy-validator changes lists differ for {expr!r}")
        if reference is None:
            reference = isolation
        elif isolation != reference:
            fail(f"heavy-validator changes list for {expr!r} differs from the MR list")
    ok("validate:per-role-isolation and validate:nix-checks share identical MR/dev/prod changes filters")


def classify_path(path, forced_kind=None):
    if forced_kind is not None:
        return forced_kind
    if path.endswith("/"):
        return "directory"
    return "exact"


def source_input(origin, path, forced_kind=None):
    if not path:
        fail(f"{origin} produced an empty source input")
    return (origin, classify_path(path, forced_kind), path)


def read_flake(flake_file):
    with open(flake_file, "r", encoding="utf-8") as fh:
        return fh.read()


def parse_shared_file_inputs(text):
    match = re.search(r"^\s*sharedFile\s*=\s*relPath:\n(?P<block>.*?)^\s*ensureSlash\s*=", text, re.S | re.M)
    if not match:
        fail("could not locate sharedFile block in flake.nix")
    entries = []
    for raw_line in match.group("block").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        content = line.split("#", 1)[0].strip()
        parsed = []
        for prefix_match in re.finditer(r'hasPrefix\s+"([^"]+)"\s+relPath', content):
            path = prefix_match.group(1)
            kind = "directory" if path.endswith("/") else "prefix"
            entries.append(source_input("sharedFile", path, kind))
            parsed.append(path)
        for exact_match in re.finditer(r'relPath\s*==\s*"([^"]+)"', content):
            path = exact_match.group(1)
            entries.append(source_input("sharedFile", path, "exact"))
            parsed.append(path)

        # Fail closed if sharedFile grows a path-bearing form this parser does
        # not understand. If host-tool negation paths are ever inlined here, the
        # generic hasPrefix/relPath parsers above intentionally treat them as
        # inputs; CI over-triggering is fail-open for this ratchet.
        quoted_paths = [
            quoted
            for quoted in re.findall(r'"([^"]+)"', content)
            if "/" in quoted or quoted in {"flake.nix", "flake.lock"}
        ]
        unparsed = [quoted for quoted in quoted_paths if quoted not in parsed]
        if unparsed:
            fail(f"unparsed sharedFile path line in flake.nix: {raw_line}")
    if not entries:
        fail("flake.nix sharedFile block yielded no source inputs")
    return entries


def parse_extra_role_subtrees(text):
    match = re.search(r"^\s*extraRoleSubtrees\s*=\s*\{\n(?P<block>.*?)^\s*\};", text, re.S | re.M)
    if not match:
        fail("could not locate extraRoleSubtrees attrset in flake.nix")
    entries = []
    for raw_line in match.group("block").splitlines():
        content = raw_line.split("#", 1)[0]
        for quoted in re.findall(r'"([^"]+)"', content):
            if "/" not in quoted:
                continue
            entries.append(source_input("extraRoleSubtrees", quoted))
    if not entries:
        fail("extraRoleSubtrees parser yielded zero entries")
    return entries


def parse_role_wanted_templates(text):
    match = re.search(r"^\s*roleWantedPaths\s*=\s*role:\n(?P<block>.*?)^\s*sharedWantedPaths\s*=", text, re.S | re.M)
    if not match:
        fail("could not locate roleWantedPaths block in flake.nix")
    templates = re.findall(r'"([^"]*\$\{role\}[^"]*)"', match.group("block"))
    if not templates:
        fail("roleWantedPaths parser yielded zero role-derived templates")
    return templates


def flake_source_inputs(flake_file):
    text = read_flake(flake_file)
    repo_root = os.path.dirname(flake_file)
    inputs = []
    inputs.extend(parse_shared_file_inputs(text))
    inputs.extend(parse_extra_role_subtrees(text))

    templates = parse_role_wanted_templates(text)
    for role in FLAKE_SOURCE_PROBE_ROLES:
        host_path = os.path.join(repo_root, "site", "nix", "hosts", f"{role}.nix")
        if not os.path.exists(host_path):
            fail(f"probe role {role!r} is not a real repo role; missing {host_path}")
        for template in templates:
            inputs.append(source_input("roleWantedPaths", template.replace("${role}", role)))

    deduped = []
    seen = set()
    for origin, kind, path in inputs:
        key = (kind, path)
        if key in seen:
            continue
        seen.add(key)
        deduped.append((origin, kind, path))
    if not deduped:
        fail("flake source-surface derivation yielded zero inputs")
    return deduped


def probes_for_input(kind, path):
    if kind == "directory":
        base = path.rstrip("/")
        return [
            f"{base}/probe-file.nix",
            f"{base}/sub/dir/probe-file.nix",
        ]
    if kind == "prefix":
        if path == "framework/scripts/certbot-":
            return [
                "framework/scripts/certbot-probe.sh",
                "framework/scripts/certbot-probe/hook.sh",
            ]
        return [
            f"{path}probe-file.nix",
            f"{path}probe/hook.nix",
        ]
    if kind == "exact":
        return [path]
    fail(f"unknown source input kind: {kind}")


def assert_flake_source_inputs_trigger_isolation(ci, flake_file):
    inputs = flake_source_inputs(flake_file)
    probe_count = 0
    for origin, kind, path in inputs:
        for probe in probes_for_input(kind, path):
            probe_count += 1
            if not job_runs(ci, "validate:per-role-isolation", MR_CONTEXT, [probe]):
                fail(
                    "validate:per-role-isolation does not run for "
                    f"flake.nix {origin} input {path!r} probe {probe!r}"
                )
    if probe_count == 0:
        fail("flake source-surface ratchet produced zero probes")
    ok(f"flake.nix source-surface ratchet checked {len(inputs)} inputs and {probe_count} probes")


def main():
    ci_file = sys.argv[1]
    flake_file = sys.argv[2]
    ci = require_mapping(load_ci(), ".gitlab-ci.yml")

    changes_by_job = enabling_changes_by_job(ci)
    assert_identical_heavy_changes(changes_by_job)
    require_script_contains(
        ci,
        "validate:nix-checks",
        "nix build .#checks.x86_64-linux.per-role-isolation --no-link",
    )
    ok("validate:nix-checks still builds the per-role-isolation check")

    docs_only = [
        "docs/sprints/SPRINT-046.md",
        "README.md",
        ".claude/rules/testing.md",
        "docs/reports/x.md",
    ]
    for job_name in PIGS:
        if job_runs(ci, job_name, MR_CONTEXT, docs_only):
            fail(f"{job_name} runs for docs-only MR changes")
    if not job_runs(ci, "validate:plan", MR_CONTEXT, docs_only):
        fail("validate:plan does not run for docs-only MR changes")
    ok("docs-only MR changes skip both heavy validators while validate:plan still runs")

    shared_run_files = [
        "framework/nix/modules/base.nix",
        "flake.lock",
        "flake.nix",
        "framework/catalog/dns/default.nix",
        "site/nix/hosts/dns.nix",
        "site/apps/testapp/app.nix",
        "framework/images.yaml",
        "site/images.yaml",
        ".gitlab-ci.yml",
        "tests/test_per_role_source_isolation.sh",
        "site/config.yaml",
        "tests/hil/x.nix",
        "framework/scripts/certbot-hook.sh",
        "framework/scripts/certbot-probe/hook.sh",
    ]
    for context_name, context in (("MR", MR_CONTEXT), ("dev", DEV_CONTEXT)):
        for path in shared_run_files:
            for job_name in PIGS:
                if not job_runs(ci, job_name, context, [path]):
                    fail(f"{job_name} does not run for {context_name} change {path}")
    ok("MR and dev source-filter changes run both heavy validators")

    mixed = ["docs/x.md", "framework/nix/modules/base.nix"]
    for job_name in PIGS:
        if not job_runs(ci, job_name, MR_CONTEXT, mixed):
            fail(f"{job_name} does not run for mixed docs + nix-source change")
    ok("mixed docs plus source change runs both heavy validators")

    cheap_path = ["framework/scripts/safe-apply.sh"]
    for job_name in PIGS:
        if job_runs(ci, job_name, MR_CONTEXT, cheap_path):
            fail(f"{job_name} runs for cheap-path-only change framework/scripts/safe-apply.sh")
    ok("#482 cheap-path-only safe-apply.sh change skips both heavy validators")

    # R6 never skips a build or a deploy: assert it behaviorally (these jobs still
    # run on a docs-only dev push), not merely structurally.
    for job_name in ("build:image", "build:merge", "deploy:dev"):
        if not job_runs(ci, job_name, DEV_CONTEXT, docs_only):
            fail(f"{job_name} does not run for a docs-only dev push (R6 must never skip build/deploy)")
    ok("build:image, build:merge and deploy:dev still run on a docs-only dev push")

    workflow = require_mapping(ci.get("workflow"), "workflow")
    if rules_have_changes(workflow.get("rules")):
        fail("workflow.rules carries a changes clause")
    allowed_changes_jobs = set(PIGS)
    offenders = []
    for name, value in ci.items():
        if name in allowed_changes_jobs or name == "workflow":
            continue
        if isinstance(value, dict) and rules_have_changes(value.get("rules")):
            offenders.append(name)
    if offenders:
        fail(f"non-allowlisted jobs carry rules:changes: {', '.join(sorted(offenders))}")
    ok("no workflow or non-allowlisted job carries rules:changes")

    for job_name in PIGS:
        job = require_mapping(ci.get(job_name), job_name)
        if job.get("resource_group") != "ci-heavy-nix-eval":
            fail(f"{job_name} resource_group changed: {job.get('resource_group')!r}")
        for expr in EXPECTED_ENABLE_IFS:
            matching = [rule for rule in require_rules(ci, job_name) if rule.get("if") == expr]
            if len(matching) != 1:
                fail(f"{job_name} expected one rule for {expr!r}, found {len(matching)}")
            if matching[0].get("when") == "never":
                fail(f"{job_name} enabling rule {expr!r} is when: never")
    ok("R5 resource_group and enabled MR/dev/prod rules still coexist")

    assert_flake_source_inputs_trigger_isolation(ci, flake_file)


try:
    main()
except Failure as exc:
    print(f"FAIL: {exc}", file=sys.stderr)
    sys.exit(1)
except Exception as exc:
    print(f"FAIL: unexpected error: {exc}", file=sys.stderr)
    sys.exit(1)
PY
