# M920q rack card — BIOS + MEBx settings for bfnet nodes

Print this. Bring to the keyboard+display desk. One sheet per node, or
read off all five from the same sheet. Every value below is the target
state for a bfnet cluster node. Only change a setting if its current
value differs from the target.

For the full procedure (rescue path, smoke test details, AMT 12 quirks),
see `docs/operations/m920q-bios-mebx-checklist.md`. This card is the
condensed reference.

---

## Per-unit info — fill in before starting

| Field | bpve02 | bpve03 | bpve04 | bpve05 | bpve06 |
|---|---|---|---|---|---|
| Lenovo S/N (case sticker)        | __________ | __________ | __________ | __________ | __________ |
| MAC (BIOS Main → Ethernet MAC)   | __________ | __________ | __________ | __________ | __________ |
| Mgmt IP (UDM-Pro reservation)    | 172.17.77.__ | 172.17.77.__ | 172.17.77.__ | 172.17.77.__ | 172.17.77.__ |
| PDU outlet #                     | __________ | __________ | __________ | __________ | __________ |
| BIOS rev (Main → BIOS Revision)  | __________ | __________ | __________ | __________ | __________ |
| ME FW (Mgmt → ME Firmware Ver.)  | __________ | __________ | __________ | __________ | __________ |
| BIOS done (date)                 | __________ | __________ | __________ | __________ | __________ |
| MEBx done + smoke pass (date)    | __________ | __________ | __________ | __________ | __________ |

**Before pressing Activate Network Access (MEBx), confirm:**
- [ ] DHCP reservation in UDM-Pro: MAC → mgmt IP
- [ ] AMT password in SOPS as `amt_password_bfnet` matches the value you'll type into MEBx
- [ ] Hostname for this unit is `bpveNN` (no environment suffix)
- [ ] Ethernet cable connected; link light visible

---

## Stage A: BIOS Setup (press F1 at POST)

Walk the tabs top to bottom. Tables show **target value**; bold = likely
needs change from factory default.

### Devices → Network Setup
| Setting | Target |
|---|---|
| Onboard Ethernet Controller | Enabled |
| **PXE Option ROM** | **Enabled** |
| PXE IPV4 Network Stack | Enabled |
| PXE IPV6 Network Stack | Enabled |
| Wireless LAN | Disabled |

### Advanced → CPU Setup
| Setting | Target |
|---|---|
| **Intel(R) Virtualization Technology** | **Enabled** |
| **VT-d** | **Enabled** |
| Core Multi-Processing | Enabled |
| EIST Support | Enabled |
| TxT | Disabled |
| C1E Support / C State Support / Turbo | Default (Enabled) |

### Advanced → Intel(R) Manageability
| Setting | Target |
|---|---|
| **Intel(R) Manageability Control** | **Enabled** |
| Intel(R) Manageability Reset | Disabled *(see Rescue on back if MEBx password is unknown)* |
| **Press `<Ctrl-P>` to Enter MEBx** | **Enabled** |
| USB Provisioning | Disabled |

Record ME Firmware Version and Manageability Type (should say `Intel(R) AMT`).

### Power (top-level)
| Setting | Target |
|---|---|
| **After Power Loss** | **Power On** |
| Enhanced Power Saving Mode | Disabled |
| Smart Power On | Default |

### Power → Automatic Power On
| Setting | Target |
|---|---|
| **Wake on LAN** | **Automatic** |
| Wake from Serial Port Ring | Disabled |
| Wake Up on Alarm | Disabled |

### Security → Secure Boot
| Setting | Target |
|---|---|
| **Secure Boot** | **Disabled** |

(System Mode may show Deployed or Setup — either is fine. Do NOT use "Reset Platform to Setup Mode".)

### Security → TCG Feature Setup
| Setting | Target |
|---|---|
| TCG Security Device | Firmware TPM |
| Security Chip 2.0 | Enabled |
| Clear TCG Security Feature | **No** (do not change to Yes) |

### Security → other top-level
| Setting | Target |
|---|---|
| Administrator Password | Not Installed (optional) |
| Power-On Password | Not Installed (must remain unset) |
| Smart USB Protection | Disabled |
| Device Guard | Disabled |
| Chassis Intrusion / Config Change Detection | Disabled |

### Startup
| Setting | Target |
|---|---|
| **CSM** | **Disabled** |
| **Boot Mode** | **UEFI Only** |
| Boot Up Num-Lock Status | On (default) |

### Startup → Primary Boot Sequence (top to bottom)
1. **M.2 Drive 1 (NVMe)** ← boot from disk after install
2. **Network 1** (IBA CL ... v....) ← PXE for regreener
3. (exclude or push below) USB CDROM, SATA 1, USB HDD, Other Device, Network 2/3/4

**F10 → Save and Exit. Box reboots. Press Ctrl-P at POST to enter MEBx.**

---

## Stage C: MEBx (Ctrl-P at POST)

Settings commit immediately as you change them. `Activate Network Access`
is the irreversible final step — do it last.

### C.1 Login
- Default (fresh / unconfigured): username implicit, password `admin`. MEBx forces a password change immediately — set the value from SOPS `amt_password_bfnet`.
- Previously provisioned (this site's password): use SOPS value.
- If `admin` rejected: see **Rescue** on back.

### C.3 Intel(R) AMT Configuration → Manageability Feature Selection
| Setting | Target |
|---|---|
| Manageability Feature Selection | Enabled |

### C.4 SOL / Storage Redirection / KVM
| Setting | Target |
|---|---|
| SOL | Enabled |
| Storage Redirection | Enabled |
| KVM Feature Selection | Enabled |

### C.5 User Consent
| Setting | Target |
|---|---|
| **User Opt-in** | **NONE** *(factory default is `KVM` — CHANGE)* |
| Opt-in Configurable from Remote IT | Enabled |

### C.6 Password Policy
| Setting | Target |
|---|---|
| Password Policy | Anytime |

### C.7 Network Setup → Intel(R) ME Network Name Settings
| Setting | Target (per unit) |
|---|---|
| **Host Name** | **`bpveNN`** (e.g., `bpve02`) |
| **Domain Name** | **`bfnet.com`** |
| Shared/Dedicated FQDN | Shared |
| Dynamic DNS Update | Disabled |

### C.8 Network Setup → TCP/IP → Wired LAN IPv4
| Setting | Target |
|---|---|
| DHCP Mode | Enabled |

### C.9 Power Control
| Setting | Target |
|---|---|
| Power Control | **Desktop: ON in S0, ME Wake in S3, S4-5** |
| Idle Timeout | 65535 (default) |

### C.10 Remote Setup And Configuration
Skip — we use manual MEBx provisioning.

### C.12 Activate Network Access
Last step. Select, confirm `Y`. AMT transitions Pre-Provisioning → Provisioned.
The MEBx ME password and the AMT admin password are SYNCHRONIZED at
this moment only.

### C.13 MEBx Exit
`Esc` → MEBx Exit → confirm. Box reboots.

---

## Post-rack smoke test (run from hil-boot)

Substitute `<IP>` and `<PW>` (= SOPS `amt_password_bfnet`).

```bash
# 1. HTTP 200 from AMT (anonymous)
curl -sI --max-time 5 http://<IP>:16992/index.htm | head -2

# 2. Authenticated power query — expect "Current power state: Power on"
meshcmd amtpower --get --host <IP> --user admin --pass '<PW>'

# 3. Enable redirection + KVM listeners (REQUIRED — MEBx alone doesn't enable them)
meshcmd amtfeatures --redir 1 --kvm 1 --host <IP> --user admin --pass '<PW>'

# 4. Confirm TCP/16994 open
timeout 2 bash -c "</dev/tcp/<IP>/16994" && echo 16994-OPEN
```

If `amtpower --get` returns "status 600" or auth fails: **STOP**. Do not
retry blindly. Five 401s triggers an AMT "under attack" event-log entry.
Diagnose first.

---

## Rescue: MEBx password is unknown (refurb / prior tenant)

Symptoms: Ctrl-P shows a MEBx login that doesn't accept `admin`, OR AMT
WebUI rejects every password you have.

1. F1 at POST → **Advanced → Intel(R) Manageability**.
2. Set `Intel(R) Manageability Reset` = **Enabled**.
3. F10 → Save and Exit.
4. **Watch POST carefully.** A prompt like `Found unconfigure of Intel(R) ME, continue (Y/N)?` appears.
   **Press Y.** If you miss it and the box boots through, re-enter BIOS — the toggle has auto-reverted to Disabled. Re-enable and try again.
5. Box reboots. MEBx password is now back to default `admin`. Go to Stage C.

The Manageability Reset toggle is one-shot — it auto-reverts to Disabled
after firing. That's expected, not a sign of failure.

---

## Gotchas (read once, remember)

- **AMT password store quirk.** MEBx ME password and AMT admin password are
  stored separately on AMT 12. Synced ONLY at Activate Network Access.
  After that, changing one does NOT change the other. Rotate via WebUI
  "Change Admin..." AND MEBx "Change ME Password" — verify both.
- **MEBx Storage Redirection = Enabled** does NOT make IDER work on this
  hardware. IDER is not in this BIOS's boot-source enum. Leave it Enabled
  anyway (harmless); the regreener uses PXE.
- **Boot Mode = UEFI Only** is critical. iPXE binary served by the regreener
  must be `ipxe.efi`, not `undionly.kpxe`. Legacy mode breaks the chain.
- **MEBx commits per-field as you tab away.** There is no "Save" button.
  The MEBx Exit prompt only asks whether to leave, not whether to save.
- **`Power Loss = Power On` and `Wake on LAN = Automatic`** are the
  lights-out story. Without these, a power blip leaves the unit off.
- **First five auth failures → "under attack" log entry.** Fail fast on
  401, never retry with the same bad credential.

---

## Per-unit sign-off (operator initials when stage complete)

| Unit | BIOS done | MEBx done | Smoke test pass | Racked |
|---|---|---|---|---|
| bpve02 | _____ | _____ | _____ | _____ |
| bpve03 | _____ | _____ | _____ | _____ |
| bpve04 | _____ | _____ | _____ | _____ |
| bpve05 | _____ | _____ | _____ | _____ |
| bpve06 | _____ | _____ | _____ | _____ |

After all five are signed off:
1. Add each node to `tests/hil/bfnet/config.yaml` with its mgmt_ip, mac, vmid, etc.
2. Generate per-node ISOs: `./image-master.sh bpveNN` for each (in `docs/reports/sprint-037-reproducer/`).
3. Update the PDU outlet map in `pdu-cycle.sh`.
4. Validate the lights-out chain on at least one new unit before declaring done.
