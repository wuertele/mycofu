# Lenovo ThinkCentre M920q BIOS + MEBx setup checklist

Sequential setup procedure for inducting an M920q unit into a Mycofu
cluster. Each unit is set up once, by hand, with a keyboard and monitor
attached. After this procedure, the unit can be racked and managed
lights-out via Intel AMT.

This checklist assumes the BIOS revision is approximately `M1UCT18A`
(2022-10-06) or compatible. The Lenovo BIOS UI on the M920q is stable
across revisions in this range; menu labels may vary slightly.

## Applicability

- **Hardware:** Lenovo ThinkCentre M920q with Intel vPro / AMT 12.
  Verified on the i7-9700T variant; expected to apply to the i5/i7 9th-gen
  range with the same BIOS family.
- **Use case:** Mycofu cluster node, managed via AMT WSMAN by the
  regreener and HIL pipeline. NOT for general desktop deployments.
- **Delivered state:** the checklist covers units delivered fresh AND
  units that have been previously deployed (refurb, prior tenant, partial
  regreen attempt). Where the delivered state could differ, the
  checklist tells you to verify before changing — do not assume any
  field is at the factory default.

## Required artifacts before starting

- The unit, with keyboard and monitor attached, on AC power.
- Ethernet cable connected to the management network. The unit's onboard
  Intel I219-LM is the management NIC; AMT and the host OS share this
  MAC and IP.
- The unit's onboard NIC MAC address (visible in the BIOS Main page or
  the case sticker).
- A DHCP reservation in the site's DHCP server (UniFi UDM-Pro for the
  bfnet site) mapping the MAC to the intended management IP. Verify the
  reservation exists BEFORE running MEBx Activate Network Access.
- The shared AMT/ME password stored in the site's SOPS file as
  `amt_password_<site>` (e.g., `amt_password_bfnet`). The same password
  is used for every unit at the same site. The password must satisfy
  AMT 12 rules:
  - 8 to 32 characters
  - At least one uppercase letter
  - At least one lowercase letter
  - At least one digit
  - At least one special from `! @ # $ % ^ & * - _ + =`
  - No two consecutive identical characters
  - No username embedded in the password

## Stage A: BIOS Setup (F1 at POST)

Walk through the BIOS tabs in order. For each setting, verify the
current value against the target. Only change settings whose current
value differs from the target.

### A.1 Main tab

Read-only. Confirm:

- `Machine Type and Model` shows `10RRS3UP00` (or your M920q-equivalent
  type number).
- `System Brand ID` shows `ThinkCentre M920q`.
- `Ethernet MAC Address` matches the MAC the operator has on file for
  this slot in the cluster.
- Note the `BIOS Revision Level` and `BIOS Date` for the bringup log.

### A.2 Devices → USB Setup

| Setting | Target | Notes |
|---|---|---|
| USB Support | Enabled | Default; required for keyboard during setup |
| USB Legacy Support | Enabled | Default |
| All USB Ports | Enabled | Default |
| Bluetooth | Enabled | Default; harmless on a server |

No changes typically needed.

### A.3 Devices → ATA Drive Setup

| Setting | Target | Notes |
|---|---|---|
| SATA Controller | Enabled | Default |
| Configure SATA as | AHCI | Default; required for ZFS / Proxmox |
| Hard Disk Pre-delay | Disabled | Default |

No changes typically needed.

### A.4 Devices → Network Setup

| Setting | Target | Notes |
|---|---|---|
| Onboard Ethernet Controller | Enabled | Required |
| PXE Option ROM | **Enabled** | Required for PXE-based regreen |
| PXE IPV4 Network Stack | Enabled | Required |
| PXE IPV6 Network Stack | Enabled | Default; harmless |
| Wireless LAN | Disabled | Server should not use Wi-Fi |

### A.5 Advanced → CPU Setup

| Setting | Target | Notes |
|---|---|---|
| EIST Support | Enabled | Default; allows power management |
| Core Multi-Processing | Enabled | Required (all cores online) |
| Intel(R) Virtualization Technology | **Enabled** | Required for Proxmox |
| VT-d | **Enabled** | Required for PCI passthrough |
| TxT | Disabled | Default; not used |
| C1E Support | Enabled | Default |
| C State Support | Default value | Power management; harmless |
| Turbo Mode | Enabled | Default |

### A.6 Advanced → Intel(R) Manageability

| Setting | Target | Notes |
|---|---|---|
| Intel(R) Manageability Control | **Enabled** | Required for AMT |
| Intel(R) Manageability Reset | Disabled | Only flip to Enabled if rescuing a unit with an unknown ME password (see Stage B) |
| Press `<Ctrl-P>` to Enter MEBx | **Enabled** | Required to provision AMT |
| USB Provisioning | Disabled | Default; not used |

Note the `ME Firmware Version` and `Manageability Type` for the bringup
log. Expected: `ME Firmware Version 12.0.x.xxxx`, `Manageability Type
Intel(R) AMT`.

Do NOT enter the SOL Configuration submenu — defaults are correct.

### A.7 Power tab (top-level)

| Setting | Target | Notes |
|---|---|---|
| After Power Loss | **Power On** | Required — lights-out story depends on the box returning automatically after a power loss event |
| Enhanced Power Saving Mode | Disabled | Aggressive power-saving states can interfere with AMT WoL |
| Smart Power On | Enabled (default) | Lenovo keyboard-wake feature; irrelevant to AMT but no reason to disable |

### A.8 Power → Automatic Power On

| Setting | Target | Notes |
|---|---|---|
| Wake on LAN | **Automatic** | Required — secondary lights-out wake path |
| Wake from Serial Port Ring | Disabled | Default |
| Wake Up on Alarm | Disabled | Default |

The Startup Sequence / Alarm Time / Alarm Date / Alarm Day-of-Week
fields are inactive when Wake Up on Alarm is Disabled. Skip.

### A.9 Security → Secure Boot

| Setting | Target | Notes |
|---|---|---|
| Secure Boot | **Disabled** | Required — PXE-boots an unsigned Proxmox installer kernel |

If the delivered state has Secure Boot = Enabled, change it to Disabled
here. The `System Mode` field may show `Deployed Mode` or `Setup Mode`
— either is acceptable as long as Secure Boot itself is Disabled.

Do NOT use `Reset Platform to Setup Mode` or `Restore Factory Keys`
unless an Intel ME support engineer has specifically asked you to.

### A.10 Security → TCG Feature Setup

| Setting | Target | Notes |
|---|---|---|
| TCG Security Device | Firmware TPM | Default |
| Security Chip 2.0 | Enabled | Default |
| Clear TCG Security Feature | No | DO NOT change to Yes — clears TPM state |

### A.11 Other Security tab top-level items

| Setting | Target | Notes |
|---|---|---|
| Administrator Password | Not Installed | Optional. Leaving unset is fine for the cluster use case. If your site policy requires a BIOS admin password, set it here and record in SOPS. |
| Power-On Password | Not Installed | Do not set — would block lights-out boot |
| Allow Flashing BIOS to a Previous Version | Yes (default) | No change |
| Smart USB Protection | Disabled | Default |
| Device Guard | Disabled | Default |
| Chassis Intrusion Detection | Disabled | Default |
| Configuration Change Detection | Disabled | Default |

### A.12 Startup tab

| Setting | Target | Notes |
|---|---|---|
| CSM | **Disabled** | Switch from default — required for UEFI-only boot mode |
| Boot Mode | **UEFI Only** | Switch from default Legacy Only |
| Boot Up Num-Lock Status | On (default) | Cosmetic |

**Boot Mode change:** Lenovo's factory default on the M920q is often
`Legacy Only` (CSM Enabled). For Proxmox VE 9.x and modern PXE
bootloaders (iPXE EFI), switch to `UEFI Only` (CSM Disabled). If the
delivered state is already `UEFI Only`, no change needed.

### A.13 Startup → Primary Boot Sequence

Order entries from top to bottom — top entry is tried first.

| Order | Entry | Notes |
|---|---|---|
| 1 | M.2 Drive 1 (NVMe) | Boot from disk after regreen |
| 2 | Network 1 (`IBA CL Slot ... v....`) | PXE — fallback when disk has no bootloader, also the path the regreener uses |
| (excluded or below) | USB CDROM, SATA 1, USB HDD, Other Device, Network 2/3/4 | Not used |

### A.14 Save and exit

F10 → confirm Save and Exit. Box will reboot.

If you are about to enter MEBx (Stage B or C), let the box continue to
POST and press Ctrl-P at the prompt.

## Stage B: AMT password rescue (skip if MEBx login with `admin` works)

Use this stage ONLY when the unit was delivered with AMT already
provisioned by a previous owner, and the ME password is unknown. Symptoms:

- Ctrl-P at POST shows a MEBx login prompt that does not accept `admin`
- AMT WebUI at `http://<ip>:16992` either does not respond or rejects
  `admin` + every password you have

This procedure unprovisions AMT and resets the ME password to default.
It does NOT clear BIOS settings or wipe the disk.

1. Enter BIOS Setup (F1 at POST).
2. Navigate to `Advanced` → `Intel(R) Manageability`.
3. Change `Intel(R) Manageability Reset` from `Disabled` to **Enabled**.
4. F10 → confirm Save and Exit.
5. **Watch the POST carefully.** The ME firmware will display a prompt
   resembling `Found unconfigure of Intel(R) ME, continue (Y/N)?` (the
   wording varies). **Press Y.** If you miss the prompt and the box
   boots through, re-enter BIOS, the Manageability Reset toggle will
   have auto-flipped back to Disabled — re-enable it and try again.
6. After the unconfigure completes, the box reboots normally. You can
   now proceed to Stage C with the default MEBx password.
7. The `Intel(R) Manageability Reset` toggle is one-shot — after firing,
   it returns to Disabled automatically. This is expected.

## Stage C: MEBx (Ctrl-P at POST)

Settings in MEBx commit immediately as you change them — there is no
explicit "save" action. The "MEBx Exit" prompt only asks whether you
want to leave, not whether you want to save.

The exception is `Activate Network Access` — that is the explicit commit
that transitions the ME from "Pre-Provisioning" to "Provisioned" state.
DO that last.

### C.1 MEBx login

1. At POST, press Ctrl-P.
2. At the MEBx Login prompt, enter the current ME password.
   - On a freshly unconfigured unit (Stage B done, or unit out of the
     box with default credentials): username is implicit, password is
     `admin`.
   - On a unit you previously provisioned: the password is the
     `amt_password_<site>` value in SOPS.
3. If you used `admin`, MEBx will force you to set a new password
   immediately. Set the value from SOPS (see "Required artifacts"
   above). Type carefully — a typo here is recoverable but expensive.

### C.2 Intel(R) ME General Settings → Change ME Password

Skip unless you need to rotate the ME password. Note: changing the
password here updates ONLY the MEBx login. It does NOT update the AMT
admin user password — see "AMT 12 password-store quirk" below.

### C.3 Intel(R) AMT Configuration → Manageability Feature Selection

Target: `Enabled` (default).

### C.4 Intel(R) AMT Configuration → SOL/Storage Redirection/KVM

| Setting | Target | Notes |
|---|---|---|
| SOL | **Enabled** | Default; required for HIL console capture |
| Storage Redirection | **Enabled** | Default; vestigial — this hardware's BIOS does not expose IDER as a boot source, but enabling it is harmless |
| KVM Feature Selection | **Enabled** | Default; required for KVM remote console debugging |

### C.5 Intel(R) AMT Configuration → User Consent

| Setting | Target | Default? |
|---|---|---|
| User Opt-in | **NONE** | NO — default is `KVM`. **CHANGE TO NONE.** |
| Opt-in Configurable from Remote IT | Enabled | Default |

`User Opt-in = NONE` makes KVM remote console accessible without a
local-screen consent code. Required for unattended HIL operation. SOL
and storage redirection are not gated by this setting.

### C.6 Intel(R) AMT Configuration → Password Policy

Target: `Anytime` (default). Allows MEBx entry without time-window
restrictions.

### C.7 Intel(R) AMT Configuration → Network Setup → Intel(R) ME Network Name Settings

| Setting | Target | Notes |
|---|---|---|
| Host Name | **`<bpveNN>`** (per-unit) | e.g., `bpve01`, `bpve02`, ... |
| Domain Name | **`<site-domain>`** | e.g., `bfnet.com`, `wuertele.com` |
| Shared/Dedicated FQDN | `Shared` | Default; correct for I219-LM single-NIC |
| Dynamic DNS Update | `Disabled` | Default; DHCP reservation handles DNS |

### C.8 Intel(R) AMT Configuration → Network Setup → TCP/IP Settings → Wired LAN IPv4 Configuration

| Setting | Target | Notes |
|---|---|---|
| DHCP Mode | `Enabled` | Default; UDM-Pro reservation supplies the IP |

### C.9 Intel(R) AMT Configuration → Power Control

The Power Control submenu offers only two choices on the M920q desktop
SKU:

- `Desktop: ON in S0`
- `Desktop: ON in S0, ME Wake in S3, S4-5`

Target: **`Desktop: ON in S0, ME Wake in S3, S4-5`** (default).

The "always-on in all sleep states" mode that some AMT-capable platforms
offer is not available on this hardware. The wake-on-demand variant is
sufficient: AMT clients (meshcmd, MeshCommander) handle the ~200 ms
wake latency on the first packet via internal retry.

The `Idle Timeout` field is fine at default (65535).

### C.10 Intel(R) AMT Configuration → Remote Setup And Configuration

Skip. We are doing manual MEBx-driven provisioning, not SCS-driven
remote configuration.

### C.11 Pre-activation prerequisites

Before pressing Activate Network Access, confirm:

- [ ] Ethernet cable is connected at the unit and link light is visible.
- [ ] UniFi DHCP reservation maps the unit's MAC to the intended
      management IP.
- [ ] The MEBx ME password set in C.1 matches the value being entered
      into SOPS as `amt_password_<site>` (or already in SOPS, if reusing
      the site's existing shared password).

### C.12 Intel(R) AMT Configuration → Activate Network Access

Select. Confirm with `Y`. This is the irreversible commit:

- AMT transitions from `Pre-Provisioning` to `Provisioned`.
- The AMT admin user password is SYNCHRONIZED with the current MEBx ME
  password. This is the only point in the lifecycle at which they sync.
- AMT begins listening on TCP/16992 (HTTP digest). On this hardware,
  TCP/16993 (TLS) remains closed — AMT is HTTP-only here.

### C.13 MEBx Exit

`Esc` back to the main menu, select `MEBx Exit`, confirm. Box reboots.

## Stage D: Post-provisioning smoke test and required AMT-listener enablement

Run these from hil-boot (or any host that has meshcmd installed). In the Sprint
037 regreener flow, cicd reaches meshcmd by SSHing to hil-boot.

### D.0 Enable AMT redirection and KVM listeners (REQUIRED — MEBx is not enough)

AMT separates "feature enabled" (in MEBx, Stage C.4) from "listener
active" (a runtime AMT setting that MEBx does NOT control). Without this
step, the redirection port (TCP/16994) and the KVM service stay offline
even though MEBx shows them as Enabled. SOL console capture during
regreen will not work.

```bash
PW_FILE=$(mktemp); umask 077
SOPS_AGE_KEY_FILE=/run/secrets/sops/age-key sops -d --extract \
  '["amt_password_<site>"]' <path-to-site-sops>/secrets.yaml > "$PW_FILE"
PW="$(< "$PW_FILE")"; rm -f "$PW_FILE"

meshcmd amtfeatures --redir 1 --kvm 1 \
  --host <unit-ip> --user admin --pass "$PW"
```

Expected output: AMT replies with the current feature state showing
`Redirection Port: Enabled` and `Remote desktop (KVM): Enabled`.
Re-verify:

```bash
meshcmd amtfeatures --host <unit-ip> --user admin --pass "$PW"
```

Expected: all four (User Consent=None, Redirection Port=Enabled,
Serial-over-LAN=Enabled, IDE Redirection=Enabled, Remote desktop
(KVM)=Enabled).

Confirm the port came up:

```bash
timeout 2 bash -c "</dev/tcp/<unit-ip>/16994" && echo "16994 OPEN"
```

Note: TCP/5900 (legacy VNC-compatible KVM endpoint) will remain
**closed**. That is by design — KVM on this hardware multiplexes
through the redirection port (16994) using AMT's native protocol, and
AMT-aware clients (MeshCommander, RealVNC's "Intel AMT KVM" connection
type) connect there. The 5900 endpoint is an optional legacy bypass
controlled by `IPS_KVMRedirectionSettingData.Is5900PortEnabled` and is
NOT enabled by `meshcmd amtfeatures --kvm 1`. Leave it disabled for our
use case.

### D.1 HTTP probe (anonymous)

```bash
curl -sI --max-time 5 http://<unit-ip>:16992/index.htm
```

Expected: HTTP 200, server header containing
`Intel(R) Active Management Technology 12.0.x.xxxx`. AMT is alive on the
network.

### D.2 Authenticated read-only call

```bash
# Decrypt password on the runner and pass to meshcmd via a temp file
# (avoids shell-quoting issues with special characters in the password):
PW_FILE=$(mktemp); umask 077
SOPS_AGE_KEY_FILE=/run/secrets/sops/age-key sops -d --extract \
  '["amt_password_<site>"]' <path-to-site-sops>/secrets.yaml > "$PW_FILE"
PW="$(< "$PW_FILE")"; rm -f "$PW_FILE"

meshcmd amtpower --get \
  --host <unit-ip> --user admin --pass "$PW"
```

Expected: `Current power state: Power on` (or `Power off`, depending on
unit state). Any other response — especially `Error, status 600` —
indicates an auth or provisioning failure. STOP and diagnose; do not
retry blindly. Five failed authentications will trigger an AMT
"under attack" event-log entry.

### D.3 Confirm boot-source enum (regression check)

```bash
meshcmd amtsavestate --output /tmp/amtstate.json \
  --host <unit-ip> --user admin --pass "$PW"
jq '.wsmanenums.CIM_BootSourceSetting' /tmp/amtstate.json
```

Expected: three entries listing `Force Hard-drive Boot`,
`Force PXE Boot`, `Force CD/DVD Boot`. The regreener depends on
`Force PXE Boot` being present. If the enum changes shape, the regreener
design assumption is broken — STOP and revisit.

### D.4 Power-cycle round-trip (optional, lightly destructive — reboots the box)

```bash
meshcmd amtpower --reset --host <unit-ip> --user admin --pass "$PW"
```

Watch `amtauditlog` after the reset; expect a `Performed Reset` entry
with the current timestamp. The host CPU side will reboot through POST.

### D.5 KVM remote console (optional, for debugging)

KVM uses VNC protocol on TCP/5900 with AMT-specific authentication
extensions. macOS Screen Sharing / Apple's built-in VNC client does NOT
support the AMT handshake. Use one of:

- MeshCommander (GUI tool, available for macOS / Windows / Linux)
- A VNC client with AMT support (RealVNC Viewer with the "Intel AMT
  KVM" connection type)

Connect to `<unit-ip>:5900` with username `admin` and the same
`amt_password_<site>` password. Expected: you see the unit's framebuffer
exactly as if a monitor were attached. With User Opt-in = NONE (Stage
C.5), no on-screen consent code is required.

## Common gotchas

### AMT 12 password-store quirk

On AMT 12 (this hardware), the MEBx login password and the AMT admin
user password are stored separately after provisioning. They are
synchronized **only at the moment of `Activate Network Access`**. After
that:

- Changing the MEBx password via Ctrl-P → "Change ME Password" updates
  only the MEBx login.
- Changing the AMT admin password via WebUI "Change Admin..." (or WSMAN
  PUT to the digest user) updates only the AMT admin.

To rotate the credential cleanly, either:

- Use the AMT WebUI's "Change Admin..." form (and update SOPS to match),
  then update MEBx via Ctrl-P → "Change ME Password" if you also want
  MEBx to use the same value. Verify both work before proceeding.
- OR un-provision AMT (Stage B) and re-provision (Stage C). At Activate,
  both stores are written from MEBx.

The regreener uses the AMT admin (WSMAN) credential, not the MEBx one,
for all its operations. The MEBx credential only matters when you need
physical-console access to MEBx for setup or rescue.

### Authentication-failure cost

AMT records every 401 in `amtauditlog`. After 5 failures, AMT writes an
`Authentication failed 5 times. The system may be under attack.` entry
to `amteventlog`. The regreener and any test code must:

- Fail fast on auth errors (do NOT retry with the same bad credential).
- Treat `amteventlog` "under attack" entries as a signal to investigate,
  not a routine event.

### Shell quoting and the AMT password

The AMT password may contain shell-special characters (`$`, `!`, `&`,
etc.). When passing it to meshcmd or curl over SSH, write it to a temp
file with `umask 077`, read with `PW="$(< "$file")"`, then quote as
`"$PW"` in the consuming command. Avoid pipelines that pass the password
through intermediate shells (e.g., `<<<"$PW"` over ssh) — each shell
hop is a chance for re-expansion.

### Boot Mode change requires UEFI-compatible installer media

After switching `Boot Mode` to `UEFI Only` (A.12), the unit will only
boot UEFI-signed bootloaders. The PXE boot path used by the regreener
must serve an iPXE EFI binary (`ipxe.efi`) and a UEFI-bootable Proxmox
installer. Legacy PXE bootloaders will silently fail to load.

### `Manageability Reset` is one-shot, not a sticky setting

The BIOS toggle `Advanced` → `Intel(R) Manageability` → `Intel(R)
Manageability Reset` auto-reverts to `Disabled` after the unconfigure
fires on the next POST. This is expected behavior, not a sign that the
reset did not happen. The proof of successful reset is that Ctrl-P
accepts `admin` as the MEBx password on the next boot.

## Per-unit bringup log template

After running the checklist on a unit, record the following in the
site's bringup log (one entry per unit):

```
- name: bpveNN
  serial_number: <S/N from Main page>
  mac: <MAC from Main page>
  bios_revision: <e.g., M1UCT18A>
  me_firmware: <e.g., 12.0.35.1427>
  bios_setup_done: <date>
  mebx_provisioned: <date>
  amt_smoke_test_passed: <date>
  notes: |
    <anything noteworthy, e.g., "delivered with prior Windows install on
    M.2, will be wiped during regreen">
```

## References

- `docs/reports/m920q-amt-investigation-2026-05-16.md` — the investigation
  this checklist was derived from. Contains the audit-log evidence and
  the architectural conclusions.
- `docs/reports/sprint-034-untested-amt-retrospective.md` — why the
  original IDER-based regreener design failed.
- `docs/reports/sprint-034-trial-and-error-retrospective.md` — the
  authoritative source for the `CIM_BootSourceSetting` finding.
- GitLab issues #311, #312 — predecessor tickets for the BIOS and
  MEBx checklists, addressed by this file.
