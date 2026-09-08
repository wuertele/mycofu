# Adversarial Review: --fill-ssh-keys feature

**Status:** ISSUES_FOUND

## Summary
The `--fill-ssh-keys` feature in `new-site.sh` provides a necessary automation for bootstrapping SSH host keys, but the current implementation has several flaws ranging from minor UI bugs to significant performance and robustness issues.

## Findings

### 1. Missing Cleanup Trap (Security/Hygiene)
The script creates a temporary directory `TMPDIR_KEYS` using `mktemp -d` to store plaintext private keys. However, it only removes this directory at the very end of the script. If the script is interrupted (Ctrl+C) or fails during a `sops` call (due to `set -e`), the plaintext private keys remain on disk in `/tmp`.
**Recommendation:** Add `trap 'rm -rf "${TMPDIR_KEYS}"' EXIT` immediately after creating the directory.

### 2. Atomic State Inconsistency (Robustness)
The "write-once" guard only checks for the existence of the `private` key in SOPS:
```bash
existing=$(sops -d --extract "[\"ssh_host_keys\"][\"${vm_key}\"][\"private\"]" "$SECRETS" 2>/dev/null || true)
if [[ -n "$existing" && "$existing" != "null" ]]; then
  echo "  ${vm_key}: exists — skipping (write-once)"
  SKIPPED=$((SKIPPED + 1))
  return 0
fi
```
If the script is interrupted *after* the private key is set but *before* the public key is set (which are two separate `sops --set` calls), subsequent runs will skip this VM because the private key exists. This leaves the SOPS file in an inconsistent state with a missing public key, which will cause downstream Tofu/Nix failures.
**Recommendation:** The guard should check for the existence of both keys, or the script should use a more atomic update method.

### 3. Significant Performance Inefficiency (UX)
The script performs $2N$ `sops` re-encryption operations (where $N$ is the number of VMs), plus $N$ decryption operations for the guard check. For a typical site with 15-20 VMs, this results in ~40-60 SOPS calls. Each call involves decryption, process overhead, and re-encryption, making the script take several minutes to complete even for a small site.
**Recommendation:** Decrypt the secrets file once, perform all modifications using `yq` (e.g., to a temporary file), and then encrypt once.

### 4. Hardcoded Step Numbering in `enable-app.sh` (Minor)
In `enable-app.sh`, the "Next steps" output has hardcoded numbers. Step `2.` is conditional, but step `3.` (Generate SSH host keys) is fixed. If step `2.` is skipped, the output jumps from `1.` to `3.`.
**Recommendation:** Use a counter variable for step numbering.

### 5. Portability Issue: `sed -i` (Compatibility)
The script uses `sed -i ''`, which is the BSD/macOS syntax. This will fail on GNU/Linux (where it should be `sed -i`). Given the framework is Nix-based and likely intended for cross-platform operator use, this is a regression for Linux users.

### 6. PBS VM Redundancy (Clarification)
The script generates SSH host keys for the `pbs` VM. However, `install-pbs.sh` currently uses password-based authentication (`sshpass`) and the PBS installer (vendor ISO) does not automatically consume SSH host keys from CIDATA in the same way the NixOS-based VMs do. This isn't a bug, but it's redundant.

## Probe Answers
1. **Does sops --set work for nested keys?** Yes, it creates the parent structure if missing.
2. **Write-once guard missing vs empty?** The check `[[ -n "$existing" && "$existing" != "null" ]]` correctly handles missing keys (which return "null" or empty).
3. **Can sops --set handle multi-line SSH private keys?** Yes, shell expansion preserves newlines, and `sops --set` handles them as long as the first space correctly separates the path and the value (which it does here).
4. **Is there a tmpdir cleanup trap?** No. (See Finding #1).
5. **Does the script handle the PBS VM?** Yes, it generates keys for it, but they are not used by the current `install-pbs.sh`. (See Finding #6).
6. **Is the enable-app.sh step numbering correct?** No, it is hardcoded and can skip numbers. (See Finding #4).
