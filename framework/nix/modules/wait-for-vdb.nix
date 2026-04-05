# wait-for-vdb.nix — Prevent application services from starting before vdb is ready.
#
# During an atomic rebuild (destroy → apply → restore), the VM boots twice:
#   1. First boot: fresh vda, empty vdb. Application services must NOT start.
#   2. Second boot: fresh vda, restored vdb. Services start normally.
#
# The mechanism:
#   - CIDATA delivers /run/secrets/vdb-restore-expected for VMs with precious
#     state (backup: true in config.yaml). This file is a stable flag — it
#     doesn't change between deploys.
#   - wait-for-vdb.service checks: if the flag is present AND vdb is empty
#     (only lost+found), exit 1. systemd marks vdb-ready.target as failed.
#     All services that Require vdb-ready.target stay down.
#   - On the post-restore second boot, vdb has real content. The check passes.
#   - On warm reboots (vdb already populated), the check passes immediately.
#   - VMs without the flag (non-precious, no vdb) have no service/target at all.
#
# Role modules set mycofu.vdbMountPoint to their vdb path (e.g., /var/lib/gitlab).
# This communicates the mount path to wait-for-vdb without hardcoding.
#
# This module is imported in base.nix and applies to all VMs automatically.

{ config, pkgs, lib, ... }:

let
  cfg = config.mycofu;
  hasVdbMount = cfg.vdbMountPoint != "";
in
{
  options.mycofu.vdbMountPoint = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = ''
      The mount path for vdb (the data disk). Set by role modules that
      mount vdb at a role-specific path (e.g., /var/lib/gitlab).
      When non-empty, wait-for-vdb.service and vdb-ready.target are
      created. When empty (default), no service or target exists.
    '';
  };

  config = lib.mkIf hasVdbMount {
    # The target that application services depend on.
    # Active only when wait-for-vdb.service succeeds (exit 0).
    systemd.targets.vdb-ready = {
      description = "vdb contains real state (or no restore expected)";
      requires = [ "wait-for-vdb.service" ];
      after = [ "wait-for-vdb.service" ];
    };

    systemd.services.wait-for-vdb = {
      description = "Check whether vdb contains real state";
      wantedBy = [ "vdb-ready.target" ];
      after = [ "local-fs.target" "nocloud-init.service" ];
      requires = [ "nocloud-init.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = [ pkgs.coreutils pkgs.util-linux ];

      script = ''
        VDB_MOUNT="${cfg.vdbMountPoint}"

        # --- No CIDATA flag means not a precious VM — pass through ---
        if [ ! -f /run/secrets/vdb-restore-expected ]; then
          echo "No vdb-restore-expected flag — services may start"
          exit 0
        fi

        # --- Check if vdb is actually mounted ---
        if ! mountpoint -q "$VDB_MOUNT"; then
          echo "ERROR: vdb-restore-expected flag present but $VDB_MOUNT is not mounted"
          echo "Check that vdb is attached and formatted. Blocking services."
          exit 1
        fi

        # --- Check if vdb has real content ---
        # A freshly-formatted ext4 has only lost+found/.
        # Any real application data adds at least one more entry.
        ENTRY_COUNT=$(ls -A1 "$VDB_MOUNT" 2>/dev/null | grep -cv '^lost+found$' || echo "0")

        if [ "$ENTRY_COUNT" -gt 0 ]; then
          echo "vdb at $VDB_MOUNT has real state ($ENTRY_COUNT entries) — services may start"
          exit 0
        fi

        echo "vdb at $VDB_MOUNT is empty (restore expected but not yet run) — blocking services"
        exit 1
      '';
    };

    # --- Services gated on vdb-ready.target ---
    # These must not start on the pre-restore first boot. The gate is a
    # hard Requires — if vdb-ready fails (empty vdb), these services
    # do not start. On non-precious VMs (no vdb mount → no target),
    # these overrides have no effect (vdb-ready.target doesn't exist).
    #
    # certbot-initial: creates ACME account data on vda. On pre-restore
    # first boot, the registration fails and leaves a 0-byte regr.json
    # that breaks all subsequent boots. (#151)
    systemd.services.certbot-initial = {
      after = [ "vdb-ready.target" ];
      requires = [ "vdb-ready.target" ];
    };

    # vault.service: if vault starts on empty vdb it self-initializes,
    # writing new Raft state that conflicts with PBS-restored data.
    systemd.services.vault = {
      after = [ "vdb-ready.target" ];
      requires = [ "vdb-ready.target" ];
    };

    # vault-cert-link: polls for cert for 900s. Gate prevents wasted timeout.
    systemd.services.vault-cert-link = {
      after = [ "vdb-ready.target" ];
      requires = [ "vdb-ready.target" ];
    };

    # gitlab-gen-secrets: writes fresh secrets (root password, OTP keys)
    # to vdb on first boot. These conflict with PBS-restored secrets.
    systemd.services.gitlab-gen-secrets = {
      after = [ "vdb-ready.target" ];
      requires = [ "vdb-ready.target" ];
    };

    # gitlab-cert-link: polls for cert for 900s. Gate prevents wasted timeout.
    systemd.services.gitlab-cert-link = {
      after = [ "vdb-ready.target" ];
      requires = [ "vdb-ready.target" ];
    };

    # postgresql: runs initdb on empty vdb during pre-restore first boot,
    # creating a fresh cluster that conflicts with PBS-restored data.
    systemd.services.postgresql = {
      after = [ "vdb-ready.target" ];
      requires = [ "vdb-ready.target" ];
    };
  };
}
