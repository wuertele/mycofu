# Adversarial Review: `new-site.sh --fill-ssh-keys`

**Verdict: ISSUES_FOUND**

---

## BUG 1 (Critical): `sops --set` breaks on multi-line SSH private keys

**File:** `framework/scripts/new-site.sh`, line 69

```bash
sops --set "[\"ssh_host_keys\"][\"${vm_key}\"][\"private\"] \"$(cat "${TMPDIR_KEYS}/${vm_key}")\"" "$SECRETS"
```

The `sops --set` command requires the value to be a **JSON encoded string**.
The `$(cat ...)` command substitution embeds literal newlines from the SSH
private key (which is 7 lines for ed25519) directly into the shell argument.
Literal newlines are not valid inside a JSON string — JSON requires `\n`
escape sequences.

An ed25519 private key looks like:
```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAA...
...
-----END OPENSSH PRIVATE KEY-----
```

When this is interpolated via `$(cat ...)`, the `sops --set` argument
becomes a multi-line shell string. SOPS attempts to parse the value as JSON
and will fail because the unescaped newlines break JSON string parsing.

**Fix:** The newlines must be escaped before passing to `sops --set`.
For example:
```bash
PRIVATE_KEY=$(cat "${TMPDIR_KEYS}/${vm_key}" | jq -Rs .)
sops --set "[\"ssh_host_keys\"][\"${vm_key}\"][\"private\"] ${PRIVATE_KEY}" "$SECRETS"
```
Using `jq -Rs .` reads the entire input as a single raw string and outputs
it as a properly JSON-escaped string (with `\n` for newlines and surrounding
quotes). This produces valid JSON for `sops --set`.

The same issue applies to line 70 (the public key), though public keys are
single-line so it is less likely to manifest there in practice.

**Severity:** The script will fail on every invocation. No SSH host keys
will be stored in SOPS. This is a blocking bug.

---

## BUG 2 (Medium): No tmpdir cleanup trap

**File:** `framework/scripts/new-site.sh`, line 52

```bash
TMPDIR_KEYS=$(mktemp -d)
```

The temporary directory containing generated SSH private keys is only
cleaned up on the happy path (line 89: `rm -rf "$TMPDIR_KEYS"`). If the
script is interrupted (Ctrl-C, `kill`, or an error exit from `set -e`),
the private key material remains on disk in a world-readable temp directory.

**Fix:** Add a trap immediately after creating the tmpdir:
```bash
TMPDIR_KEYS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_KEYS"' EXIT
```

**Severity:** Medium. Sensitive key material leaks to the filesystem on
abnormal exit. The keys are ephemeral (they will be stored in SOPS), but
leaving unencrypted private keys in `/tmp` is a security hygiene issue.

---

## BUG 3 (Low): Generates keys for PBS (vendor appliance, no consumer)

**File:** `framework/scripts/new-site.sh`, line 76

The script iterates all keys from `config.yaml` `.vms`, which includes
`pbs`. However, the PBS module (`framework/tofu/modules/pbs/`) does not
accept `ssh_host_key_private` or `ssh_host_key_public` variables, and
`main.tf` does not pass SSH host keys to the `pbs` module (lines 369-380).

PBS is a vendor appliance (Category C) running Proxmox Backup Server, not
a NixOS VM. It does not use nocloud-init CIDATA for SSH key delivery. The
generated `pbs` key in SOPS will never be consumed.

**Impact:** Harmless dead data in SOPS. No functional impact, but adds
confusion. Could be fixed by skipping vendor appliance VMs, or simply
documented as intentional (pre-generating keys for future use).

---

## BUG 4 (Low): `enable-app.sh` step numbering is inconsistent

**File:** `framework/scripts/enable-app.sh`, lines 395-420

When `$DEFAULT_BACKUP` is false, the step numbering shown to the user is:
```
1. Review...
2. Edit config files...   (conditional on CREATED_FILES)
3. Generate SSH host keys...
4. Add secrets to SOPS
5. Add the flake output...
6. Add the OpenTofu module...
8. Build the image...     <-- jumps from 6 to 8
```

Step 7 is conditional on `$DEFAULT_BACKUP == "true"`, but step 8 is always
printed with a hardcoded "8" regardless of whether step 7 was shown.
Similarly, step 2 is conditional, but steps 3-8 are unconditional and
always use hardcoded numbers, so when no config files are created, the
user sees steps 1, 3, 4, 5, 6, 8 (missing 2 and 7).

**Impact:** Cosmetic. The instructions are still understandable. A counter
variable would fix the numbering.

---

## ISSUE 5 (Medium): Write-once guard may not work for partially created keys

**File:** `framework/scripts/new-site.sh`, lines 59-65

The write-once guard checks only the `private` subkey:
```bash
existing=$(sops -d --extract "[\"ssh_host_keys\"][\"${vm_key}\"][\"private\"]" "$SECRETS" 2>/dev/null || true)
```

If the script is killed between writing the private key (line 69) and
writing the public key (line 70), the next run will see the private key
exists and skip the VM entirely. The public key will be missing from SOPS
forever.

Additionally, when `--extract` is given a path that does not exist in the
SOPS document, SOPS exits with a non-zero status and prints an error to
stderr. The `2>/dev/null || true` correctly suppresses this, leaving
`$existing` as an empty string. So the guard itself works correctly for the
"key does not exist" case.

However, the guard checks `"$existing" != "null"`. When the `ssh_host_keys`
parent key does not exist at all, `--extract` returns an error (caught by
`|| true`), and `$existing` is empty — this is handled. But if someone
manually set the value to the literal string `"null"` in SOPS, the guard
would treat it as missing and overwrite. This is unlikely but worth noting.

**Fix for partial-write:** Write both keys atomically, or check for the
public key as well. Alternatively, write both keys in a single `sops --set`
call using a JSON object value.

---

## ISSUE 6 (Medium): Tests are source-grep-only, no functional coverage

**File:** `tests/test_new_site_ssh_key_generation.sh`

All six tests only grep the script source code for pattern strings:
- `fill-ssh-keys` exists in the file
- `config.yaml.*not found` exists
- `exists.*skipping.*write-once` exists
- `ssh-keygen -t ed25519` exists
- `vms.*keys` and `applications` exist
- `enable-app.sh` references `fill-ssh-keys`

None of these tests would catch BUG 1 (the `sops --set` multi-line failure).
A source grep for `sops --set` would pass even though the command is
syntactically broken at runtime.

The test file acknowledges this limitation in its header comment ("Cannot
test actual key generation without a real SOPS setup"), but the tests
provide false confidence. They verify that certain strings appear in the
source file, which is tautologically true if the feature was implemented
at all.

**Recommendation:** At minimum, add a test that verifies the `jq -Rs .`
(or equivalent) JSON escaping is present in the `sops --set` line. Better:
create a mock SOPS file in a temp directory, generate a key, run the actual
`sops --set` command, and verify the round-trip (decrypt and compare).

---

## Summary

| # | Severity | Description |
|---|----------|-------------|
| 1 | Critical | `sops --set` fails on multi-line SSH private keys (newlines not JSON-escaped) |
| 2 | Medium   | No cleanup trap for tmpdir containing private key material |
| 3 | Low      | Generates unused key for PBS vendor appliance |
| 4 | Low      | `enable-app.sh` step numbering jumps when conditional steps are absent |
| 5 | Medium   | Partial write (private saved, public not) leaves unrecoverable state |
| 6 | Medium   | Tests are source-pattern-only, cannot detect runtime failures |

Bug 1 is a blocking defect. The feature cannot work as written.
