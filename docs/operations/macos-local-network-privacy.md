# macOS Local Network Privacy And Mycofu Tools

macOS can block local-network connections before they reach the normal routing
path. In this failure mode the user-space error is often `No route to host`,
while kernel logs show `reason: NECP`.

Mycofu's workstation path is a direct network client. `tofu` must open a socket
to the NAS PostgreSQL backend, `glab` must reach self-hosted GitLab, and helper
tools such as Homebrew Python may be used for diagnostics. These clients must
not depend on a per-app macOS Local Network allow prompt.

This can fail suddenly even after months of successful operation. On
2026-06-27 the affected tools had not changed; macOS appears to have rebuilt or
reactivated an existing NetworkExtension Local Network policy after an app
inventory change.

## Symptom

The affected workstation showed this split:

```text
nc -> 172.17.77.12:5432 succeeded
/usr/bin/python3 -> 172.17.77.12:5432 succeeded
/usr/local/bin/python3 -> Errno 65 No route to host

glab api /version -> dial tcp 172.17.77.62:443: connect: no route to host
framework/scripts/tofu-wrapper.sh init -> dial tcp 172.17.77.12:5432: connect: no route to host
```

The route and firewall were valid. Kernel logs identified the real block:

```text
tcp drop outgoing ... process: tofu ... reason: NECP
tcp drop outgoing ... process: glab ... reason: NECP
tcp drop outgoing ... process: Python ... reason: NECP
```

## Diagnosis

Check the current NetworkExtension privacy state:

```bash
framework/scripts/bootstrap-macos-local-network-tools.sh status
```

The blocking state looks like:

```text
PathController 116 Enabled= True
DefaultRule 118 DenyMulticast= True MulticastPreferenceSet= False
```

Use the kernel log to confirm NECP policy drops:

```bash
log show --style compact --last 20m \
  --predicate 'eventMessage CONTAINS[c] "tcp drop outgoing" || eventMessage CONTAINS[c] "NECP"'
```

Also verify that system tools can reach the same management services:

```bash
nc -vz -w 3 172.17.77.12 5432
nc -vz -w 3 172.17.77.62 443
```

## Disable The Blocker

This is a workstation-wide NetworkExtension Local Network privacy policy
change. It is not scoped to Mycofu, `tofu`, `glab`, or the current terminal
session. The helper creates a backup first so the previous policy can be
restored.

Run the helper as root:

```bash
sudo framework/scripts/bootstrap-macos-local-network-tools.sh apply
```

The helper:

1. Backs up `/Library/Preferences/com.apple.networkextension.plist`.
2. Disables the Network Privacy PathController.
3. Allows the default non-system path rule and existing local-network rules.
4. Restarts `nehelper` and `nesessionmanager`.
5. Prints the resulting policy state.

Expected post-change state:

```text
PathController 116 Enabled= False
DefaultRule 118 DenyMulticast= False MulticastPreferenceSet= True
```

The observed fix was applied as one combined plist change. The PathController
disable is the likely unicast-TCP unblock, while the local-network rule changes
are retained because that was the empirically verified working state.

Then verify clients:

```bash
framework/scripts/bootstrap-macos-local-network-tools.sh verify
```

If `verify` reports that `nix` is not on `PATH`, run from the Mycofu dev shell
or add the system Nix path first:

```bash
export PATH=/nix/var/nix/profiles/default/bin:$PATH
framework/scripts/bootstrap-macos-local-network-tools.sh verify
```

Successful verification should include:

```text
172.17.77.12:5432 ok
172.17.77.62:443 ok
OpenTofu has been successfully initialized!
```

## Rollback

The `apply` command prints the exact backup path, for example:

```text
backup=/Library/Preferences/com.apple.networkextension.plist.mycofu-backup-20260627164556
```

To restore that policy file:

```bash
sudo framework/scripts/bootstrap-macos-local-network-tools.sh restore \
  /Library/Preferences/com.apple.networkextension.plist.mycofu-backup-20260627164556
```

## Notes

- This is a host policy change on the operator workstation.
- It is intentionally not a tunnel, proxy, or workaround through another host.
- It is not a Mycofu routing change.
- It is not an Application Firewall change.
- It may need to be re-applied after macOS rewrites NetworkExtension policy.
- Do not hand-edit `/Library/Preferences/com.apple.networkextension.plist`;
  use the helper so a backup is created and the NetworkExtension daemons are
  restarted consistently.
