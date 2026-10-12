# Mycofu HAOS Transition Report

> **Status:** Historical planning snapshot, originally drafted in
> `homeassistant-config` and imported here on 2026-08-30. Documents under
> `docs/proposals/` are non-authoritative. Revalidate all inventory, version,
> network, restore, and Mycofu-mechanism claims before using this as an
> implementation plan.

## Purpose

This report captures the plan for migrating the current standalone Home
Assistant OS installation to a Mycofu-managed Home Assistant OS VM using a
versioned, workstation-run transition program.

The desired transition is not an immediate takeover. The first result of
running the transition program should be:

- a new HAOS VM exists on Mycofu
- the VM has been restored from a real backup of the old standalone HAOS host
- the VM can be inspected and verified
- the old standalone HAOS host remains authoritative
- the new VM is not allowed to control devices, use the production IP, or
  collide with restored network identities

Activation should be a separate, explicit, gated operation.

## Current Production Shape

The current Home Assistant installation is not just a YAML deployment. It has
substantial runtime state that must be preserved.

Known current production facts:

- Home Assistant OS on `generic-x86-64`
- Home Assistant Core `2026.5.4`
- Supervisor `2026.05.1`
- current LAN IP `172.17.77.121`
- current maintenance SSH target `root@100.122.26.122`
- canonical config repo
  `gitlab@gitlab.prod.wuertele.com:root/homeassistant-config.git`
- workstation clone `/Users/dave/homeassistant-config`
- HA config checkout on the current HA host `/homeassistant`

Important runtime state:

- `.storage/` contains config entries, registries, UI-managed state, tokens,
  and integration metadata
- `home-assistant_v2.db` is approximately 1.6 GiB
- add-on state is required for Matter Server, ESPHome, Tailscale, HACS, and
  other add-ons
- Lutron Caseta certificate/key material exists in the config tree
- ESPHome config and integration state are both important
- Matter fabric/add-on state should be preserved by backup restore
- Tailscale identity must not be duplicated while old and new HA are both
  online

Observed integration shape:

- 47 ESPHome config entries
- 3 ComfoConnect config entries
- Matter Server add-on integration
- Lutron Caseta
- UniFi Network
- Synology DSM
- Roon/media integrations
- Roborock
- Tesla Fleet
- ThermoWorks Cloud
- Tractive
- mobile apps
- Bluetooth
- iBeacon tracker

Observed hardware shape:

- active Intel Bluetooth device used by the Bluetooth/iBeacon integrations
- Silicon Labs CP2102N USB-to-UART device at `/dev/ttyUSB0`
- no obvious config reference to `ttyUSB`, `CP210`, ZHA, Z-Wave, or Zigbee was
  found in the repo or `/config`, but the CP2102N device remains an open
  migration question until its purpose is confirmed

## Target Architecture

The target should be a Mycofu-managed HAOS vendor appliance VM, not Home
Assistant Core on NixOS and not Home Assistant Container.

Rationale:

- HAOS backup restore is the most faithful migration path for `.storage`,
  add-ons, Matter state, Tailscale state, dashboards, registries, and database
  history
- Home Assistant has no application-level HA, so Mycofu should provide
  availability through Proxmox HA, ZFS replication, and PBS backups
- changing deployment model and moving the workload at the same time increases
  migration risk

Recommended VM posture:

- official HAOS qcow2 image
- no cloud-init dependency
- stable VM MAC address
- production LAN IP preserved as `172.17.77.121` at activation
- temporary/quarantine IP during practice runs
- Proxmox HA enabled with high priority
- ZFS replication enabled
- PBS whole-VM backups enabled
- `prevent_destroy` or equivalent protection in infrastructure code
- health monitoring for HA port `8123`
- disk size at least 128 GiB; 256 GiB is reasonable if matching current host
  headroom is preferred
- 4 vCPU and 8 GiB RAM as a conservative starting point

The Mycofu side should model HAOS as a Category C vendor appliance, similar in
spirit to other vendor appliances that are not generated through the Nix image
pipeline.

## Transition Program Model

The transition should be a workstation-run program committed to git. The
program should be safe to run repeatedly and should produce evidence artifacts
for each run.

Proposed subcommands:

```text
ha-transition capture-old
ha-transition build-new
ha-transition restore-new
ha-transition verify-unactivated
ha-transition activate
ha-transition rollback
```

The first four commands should be practice-safe. `activate` and `rollback`
should require explicit confirmation gates.

Versioned inputs:

- target Proxmox node
- target storage
- VMID
- VM name
- HAOS image URL or local path
- HAOS image checksum
- vCPU count
- memory size
- disk size
- temporary IP
- production IP
- stable VM MAC address
- quarantine/firewall mode
- expected add-ons
- expected critical integrations
- expected critical entities
- expected critical automations
- expected allowed differences while unactivated

Per-run artifacts:

- timestamped run directory
- old HA inventory snapshot
- old HA network snapshot
- old HA hardware snapshot
- add-on inventory
- config entry inventory
- entity registry inventory
- device registry inventory
- backup slug/name/date
- backup checksum
- VM definition used
- restore log
- quarantine proof
- verification report
- expected differences
- unexpected differences
- activation readiness summary

## Activation Barrier

The unactivated VM must be prevented from acting like the real Home Assistant.
This is the most important safety property of the system.

The unactivated VM should not:

- use `172.17.77.121`
- advertise itself as the production HA instance
- run the restored Tailscale identity while old HA is online
- reach production device networks unless a test explicitly allows it
- control Lutron, ComfoAir, Matter, ESPHome, media, or other real devices
- receive production webhooks or mobile app traffic
- use Bluetooth/iBeacon hardware as the live production source unless old HA is
  offline

The unactivated VM may:

- boot HAOS
- restore a full backup
- run local config validation
- expose its UI on a temporary management IP
- allow read-only inspection of restored files and registries
- run carefully selected checks that do not reach or control production devices

The transition program should be able to prove that the barrier is in place.
Examples:

- old HA still answers on `172.17.77.121`
- new HA does not own `172.17.77.121`
- new HA has only the temporary/quarantine IP
- firewall or network policy blocks egress from new HA to production device
  networks
- Tailscale add-on is stopped, disabled, blocked, or otherwise prevented from
  colliding with the old restored identity
- production VLANs are not reachable from the new VM during unactivated
  verification

## Practice Transition Flow

### 1. Capture Old

Collect a read-only inventory from the current HA host.

Suggested captured data:

- Home Assistant Core version
- Supervisor version
- HAOS machine/architecture
- network interfaces and IPs
- hardware devices
- add-on list and add-on versions
- config entry list
- entity registry
- device registry
- area registry
- automation/script/scene counts
- unavailable entities
- critical entity states
- `/config` file manifest, excluding volatile files where appropriate
- recorder database size
- latest backup metadata

This phase should not mutate production HA.

### 2. Build New

Create or converge the Mycofu HAOS VM while it is still unactivated.

The VM should be created with:

- temporary IP or isolated network path
- stable MAC address
- production-sized disk
- HAOS image
- HA disabled or enabled according to the practice policy
- PBS backup policy configured but not relied on as the only rollback path yet
- no production IP claim

### 3. Restore New

Create or use a fresh full HA backup from old HA and restore it onto the new
HAOS VM.

The backup should include:

- Home Assistant config
- `.storage`
- recorder database, unless intentionally excluded for a fast rehearsal mode
- add-on data
- SSL data
- Matter Server data
- ESPHome add-on data
- Tailscale add-on data

The restore may require either Supervisor API automation, HA CLI automation, or
browser/console automation depending on what HAOS exposes reliably. That is an
open implementation question.

### 4. Verify Unactivated

Run checks that establish state/config equivalence without making the new HA
authoritative.

This phase should produce a pass/fail report with explicit expected
differences.

## Unactivated Verification

Unactivated verification can give high confidence that the new VM is equivalent
in stored state and configuration. It cannot fully prove live behavior because
many live checks would require allowing the new instance to control or connect
to production devices.

### Backup Integrity

Checks:

- backup file exists
- backup checksum recorded
- backup metadata matches the captured production host
- backup includes Home Assistant and expected add-ons
- backup date is within the expected transition window
- backup can be read/decrypted by the restore path

### HAOS Platform Health

Checks:

- VM boots
- Supervisor API responds
- Core API responds
- Core version matches old HA or the planned version
- Supervisor version is acceptable
- disk size matches plan
- CPU/memory match plan
- network identity is the temporary/quarantine identity
- Proxmox VM metadata matches versioned inputs

### Restored File Equivalence

Checks:

- `/config/configuration.yaml` exists
- packages, automations, dashboards, blueprints, ESPHome configs, `www/`, and
  HACS assets exist
- `secrets.yaml` exists without printing contents
- Lutron PEM/key/cert files exist
- restored config file manifest matches old HA or the repo, with expected
  exclusions
- no unexpected missing top-level config directories

### Home Assistant Config Validation

Checks:

- `ha core check` passes on the new VM
- Home Assistant can start from restored config
- logs have no migration or config-load failures that block startup

### Storage And Registry Equivalence

Checks:

- selected `.storage` files parse as JSON
- config entry count matches old HA
- config entries match by domain/title/source where appropriate
- entity registry count matches old HA within expected differences
- device registry count matches old HA within expected differences
- area registry matches
- labels/floors/helpers match if present
- dashboard storage exists
- no unexpected entity ID churn such as mass `_2` suffixes

### Add-On Equivalence

Checks:

- expected add-ons are installed
- add-on versions match or differences are explained
- add-on options exist
- add-on data directories exist
- Matter Server add-on data exists
- ESPHome add-on data and config exist
- Tailscale add-on state exists but is not allowed to collide with old HA

Expected add-ons from current inventory:

- ESPHome Device Builder
- ESPHome Device Builder dev
- Tailscale
- Matter Server
- File editor
- Terminal/SSH add-ons
- Get HACS helper

### Recorder Database Health

Checks if recorder DB is restored:

- database file exists
- SQLite integrity check passes
- key recorder/statistics tables exist
- high-level table counts are plausible compared with old HA

This check is optional for fast practice runs, but the final rehearsal should
restore and verify the database.

### Integration Inventory Equivalence

Checks:

- same set of integration domains appears in config entries
- counts by domain match old HA
- critical integration titles match old HA

Important domains to compare:

- `esphome`
- `comfoconnect`
- `matter`
- `lutron_caseta`
- `unifi`
- `synology_dsm`
- `mobile_app`
- `bluetooth`
- `ibeacon`
- `hacs`
- `hassio`
- `roon`
- `roborock`
- `tesla_fleet`

### Critical Entity Equivalence

The report should include a curated list of critical entities and compare:

- entity exists
- entity ID matches
- device association exists
- integration/platform matches
- enabled/disabled state matches

The unactivated VM may legitimately show many entities unavailable. The goal is
to prove identity preservation, not live availability.

### Quarantine Proof

Checks:

- old HA still answers at `172.17.77.121`
- new HA does not answer at `172.17.77.121`
- new HA answers only at its temporary/quarantine address
- production device networks are not reachable from the new VM
- Tailscale identity is not live in a conflicting way
- firewall/quarantine counters show traffic was blocked if probes were run

## What Cannot Be Fully Proven Before Activation

Some checks are inherently activation-time checks because they require the new
HA to become the single live controller.

Examples:

- Matter devices fully reconnect to the restored Matter Server
- ESPHome devices all choose the new HA API client
- Lutron commands execute through the new HA instance
- ComfoAirQ devices accept commands from the new HA instance
- mobile app callbacks and notifications use the new instance
- webhooks and cloud callbacks target the new instance
- Bluetooth/iBeacon behavior works with the final hardware/proxy design
- automations do the right thing in response to real device events
- Tailscale restored identity behaves correctly after old HA is offline

The practice transition should therefore distinguish:

- state/config equivalence: high confidence before activation
- live-control equivalence: only fully testable after activation

## Activation Flow

Activation should be a separate operation with explicit confirmation gates. It
should be short, logged, and reversible.

Recommended activation sequence:

1. Confirm latest unactivated verification report is acceptable.
2. Confirm operator intends to begin maintenance window.
3. Create final full backup from old HA.
4. Download/export final backup and record checksum.
5. Stop old HA or network-fence it.
6. Prove old HA no longer answers on LAN or Tailscale.
7. Restore final backup to new HA if the practice restore is not fresh enough.
8. Assign `172.17.77.121` to the new HAOS VM.
9. Remove quarantine/firewall restrictions.
10. Enable or unblock Tailscale only after old HA is offline.
11. Attach Bluetooth/USB passthrough or enable replacement Bluetooth proxy path
    if required.
12. Start or restart HA Core and expected add-ons.
13. Verify ARP/UniFi/DHCP show `172.17.77.121` belongs to the new VM MAC.
14. Run live smoke tests.
15. Trigger a Mycofu/PBS backup after validation.
16. Leave old HA powered off but intact for rollback.

Activation must enforce the invariant that old and new HA are never both live
on production networks at the same time.

## Activation Smoke Tests

Live smoke tests should be curated and short.

Suggested smoke test categories:

- HA UI loads at the production IP
- Home Assistant Core logs have no blocking errors
- Supervisor healthy
- add-ons running
- ESPHome device state updates
- one ESPHome command path works if safe
- one Lutron read and one harmless command path works
- each ComfoAir unit reports current state
- Matter device state updates
- mobile app notification works
- dashboard loads
- critical automations are loaded and enabled
- no mass entity ID churn
- unavailable entity count is within expected range
- Tailscale route/SSH behavior works

The exact entities and automations should be versioned as part of the transition
program inputs.

## Rollback Flow

Rollback should prefer returning to the old HA unchanged rather than attempting
to merge state back from the new HA.

Recommended rollback sequence:

1. Stop or network-fence the new HAOS VM.
2. Prove new HA no longer answers at `172.17.77.121`.
3. Restore old HA networking.
4. Start old HA.
5. Confirm old HA answers at `172.17.77.121`.
6. Confirm Tailscale target is reachable.
7. Run the production smoke tests against old HA.

Do not run both live during rollback.

If new HA was active long enough to create meaningful state changes, decide
manually whether to keep those changes, discard them, or perform a carefully
scoped state capture. Automated reverse synchronization is not recommended as
the default rollback path.

## Open Questions

### Quarantine Model

Question: How should the unactivated VM be isolated?

Options:

- isolated VLAN
- temporary management-only VLAN
- Proxmox firewall egress block
- router/UniFi firewall rules
- no routed gateway
- application-level disablement of risky add-ons

Impact:

- determines how safe practice runs are
- determines how much live verification is possible
- affects whether the program needs UniFi/Proxmox firewall automation

Recommendation:

- prefer a network-level quarantine that blocks production device networks by
  default
- keep add-on disablement as a secondary safety layer, not the primary barrier

### Restore Automation

Question: Can HAOS backup restore be automated cleanly from the workstation?

Impact:

- determines whether `restore-new` can be fully non-interactive
- may require Supervisor API, HA CLI, browser automation, console automation, or
  a restore-staging workaround

Required investigation:

- identify the most reliable restore API/CLI path for a fresh HAOS VM
- determine whether backup upload and restore can be driven before onboarding
- determine how to detect restore completion safely

### Production IP Strategy

Question: Should the new VM preserve `172.17.77.121` exactly at activation?

Impact:

- preserving the IP reduces mobile app, webhook, mDNS, integration, and human
  workflow changes
- changing the IP requires updating documentation, clients, callbacks, and
  possibly integration config

Recommendation:

- preserve `172.17.77.121` at activation
- use a temporary/quarantine IP only for practice verification

### Tailscale Identity

Question: Should the restored new VM preserve the old HA Tailscale identity or
join as a new Tailscale node?

Impact:

- preserving identity may preserve `100.122.26.122` and existing maintenance
  paths
- duplicate restored Tailscale identity must never run while old HA is online
- new identity is safer for practice but requires updating docs/tools

Recommendation:

- block or stop Tailscale during unactivated practice
- during activation, restore/preserve the old identity only after old HA is
  offline
- if a new identity is chosen instead, make that a deliberate documentation and
  tooling change

### Bluetooth And iBeacon

Question: What is the desired Bluetooth/iBeacon architecture after migration?

Options:

- USB Bluetooth passthrough to the HAOS VM
- host Bluetooth passthrough
- ESPHome Bluetooth proxies
- retire Bluetooth/iBeacon tracking

Impact:

- affects Mycofu failover
- affects Proxmox node placement
- affects whether HA can migrate cleanly between nodes
- affects iBeacon continuity

Recommendation:

- prefer ESPHome Bluetooth proxies for long-term HA failover friendliness
- use USB passthrough only if required for short-term parity

### CP2102N USB-to-UART Device

Question: What is connected to the Silicon Labs CP2102N USB-to-UART device at
`/dev/ttyUSB0`?

Impact:

- if unused, no migration work is needed
- if used outside obvious config references, the VM may need USB passthrough or
  a replacement network-attached device path
- USB passthrough can constrain Proxmox HA failover

Required investigation:

- identify the physical device
- check HA logs for historical references
- check add-on configurations and any non-YAML runtime state
- decide whether the device is required for production

### Equivalence Threshold

Question: What level of unactivated equivalence is enough to permit activation?

Potential threshold:

- backup verified
- HAOS restored and healthy
- `ha core check` passes
- config entries match
- entity/device registries match within expected differences
- expected add-ons installed with data present
- critical entity IDs exist
- recorder DB integrity passes if DB is included
- quarantine proof passes

Impact:

- determines the activation gate
- determines how much report drift is acceptable

### Critical Smoke Test List

Question: Which entities, devices, automations, and dashboards are critical
enough to gate activation?

Candidates:

- ComfoAirQ units and bypass/boost controls
- Lutron Caseta bridge and selected lights/shades
- ESPHome sensor packs and relay boards
- Matter devices
- mobile app notifications
- key blind automations
- lighting automations
- UniFi-related automations
- dashboards used daily

Impact:

- makes verification meaningful instead of relying only on counts
- gives activation and rollback objective pass/fail criteria

### Recorder Database Policy

Question: Should practice runs always restore the recorder DB?

Options:

- always restore DB
- skip DB for fast practice
- support both fast and full modes

Impact:

- DB restore increases realism
- DB restore increases runtime and storage churn
- final rehearsal should include the DB if production activation will preserve
  history

Recommendation:

- support fast practice without DB only if clearly labeled
- require full DB restore for the final pre-activation rehearsal

### Add-On Startup Policy During Practice

Question: Should restored add-ons start during unactivated verification?

Impact:

- starting add-ons verifies more restored state
- Matter, Tailscale, ESPHome, and cloud-connected add-ons may attempt to become
  live

Recommendation:

- define an explicit add-on allowlist for practice mode
- block risky add-ons by network quarantine even if they start
- treat Tailscale specially to avoid identity collision

### Old HA Deactivation Mechanism

Question: What exactly deactivates old HA during activation?

Options:

- graceful HAOS shutdown
- stop Home Assistant Core
- disconnect old host network
- UniFi firewall block
- power off old host

Impact:

- activation program needs a reliable proof that old HA is no longer live
- rollback time depends on deactivation method

Recommendation:

- use a clear network-level or power-level deactivation, not only stopping Core
- require probes proving old HA is unreachable before new HA gets production
  network access

### Rollback State Policy

Question: If the new HA has been active and produced new state, should rollback
attempt to preserve that state?

Impact:

- preserving state requires careful reverse migration
- discarding state is simpler and safer but may lose events/history/changes from
  the active interval

Recommendation:

- default rollback should discard new-state changes and return to old HA
  unchanged
- any reverse state capture should be manual and exceptional

### Mycofu Module Boundary

Question: Should HAOS become a first-class Mycofu vendor appliance module before
the first practice transition?

Impact:

- if yes, VM lifecycle, HA, backups, replication, and monitoring are versioned
- if no, the transition program must directly manage more Proxmox details

Recommendation:

- model HAOS as a first-class Mycofu vendor appliance before serious practice
  runs

### Proxmox Node And Storage Placement

Question: Which node and storage should host the primary HAOS VM?

Impact:

- affects resource headroom
- affects USB/Bluetooth feasibility
- affects failover behavior
- affects replication paths

Required investigation:

- check current node load
- check storage capacity
- check whether any short-term USB passthrough requirement constrains placement

### DHCP, DNS, And UniFi Automation

Question: Should the transition program update DHCP reservations, DNS records,
or UniFi client aliases?

Impact:

- final production IP activation can be made cleaner
- adds UniFi as another dependency in activation
- requires rollback-safe handling of MAC/IP reservations

Recommendation:

- version the desired MAC/IP mapping
- automate only if the UniFi API path is reliable and rollback-safe
- otherwise keep the DHCP/IP switch as an explicit manual gate

### Config Management Timing

Question: Should the migration also move Home Assistant config management into
the Mycofu monorepo rsync/SOPS model?

Impact:

- doing it during migration increases risk
- deferring it keeps the service migration focused

Recommendation:

- keep the current `homeassistant-config` repo and deploy workflow for the
  migration
- move to Mycofu rsync/SOPS after the HAOS VM is stable

### Secrets Handling

Question: How should `secrets.yaml` and certificate/key material be handled
long term?

Impact:

- backup restore handles the initial migration
- future rebuilds need a controlled secrets path

Recommendation:

- do not change secrets handling during the migration
- after migration, move toward SOPS-managed `secrets.yaml` and a documented
  policy for sensitive certificate/key files

### `.storage` Snapshot Policy

Question: Should `.storage` be captured into transition artifacts?

Impact:

- `.storage` snapshots are valuable for equivalence comparison
- `.storage` may contain sensitive data and tokens
- `.storage` should not become authored deployable config by accident

Recommendation:

- allow read-only, timestamped `.storage` snapshots as sensitive artifacts
- do not commit raw `.storage` snapshots to git
- commit only summarized comparison reports

## Recommended Next Steps

1. Decide the quarantine model.
2. Investigate HAOS restore automation from a workstation.
3. Identify the CP2102N USB-to-UART device.
4. Decide Bluetooth/iBeacon target architecture.
5. Define the critical entity and automation smoke test list.
6. Add HAOS as a first-class Mycofu vendor appliance.
7. Implement `capture-old`, `build-new`, `restore-new`, and
   `verify-unactivated`.
8. Run repeated practice transitions until reports are boring.
9. Implement `activate` and `rollback` only after practice transition behavior
   is reliable.
