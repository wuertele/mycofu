# Disaster Recovery Test Framework

Structured test scripts that validate Mycofu's recovery behavior under
destructive conditions. Each test handles its own safety envelope —
running a DR test costs time, never precious state.

**Key distinction:** `validate.sh` checks a running cluster; DR tests
check recovery behavior under destructive conditions.

## Running a test

```bash
framework/dr-tests/run-dr-test.sh DRT-001
```

List all available tests:

```bash
framework/dr-tests/run-dr-test.sh
```

## Registry

`DR-REGISTRY.md` records when each scenario was last validated and at
what commit. After any significant change, scan the Invalidation Quick
Reference to determine which tests must be re-run.

A change is not safe until all tests it invalidates show a Last Run
commit equal to or after the change commit.

## Structure

```
framework/dr-tests/
  lib/common.sh           Shared library (drt_check, drt_assert, etc.)
  run-dr-test.sh          Master runner
  DR-REGISTRY.md          Test registry and invalidation reference
  tests/DRT-001-*.sh      Individual test scripts
```

## Design rationale

See `architecture.md` section 14.7.
