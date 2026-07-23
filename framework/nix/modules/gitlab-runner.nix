# gitlab-runner.nix — GitLab Runner with shell executor and CI/CD tooling.
#
# This module extends base.nix with:
#   - GitLab Runner (shell executor for pipeline job execution)
#   - All tools needed for infrastructure CI/CD pipelines
#   - Nix daemon re-enabled (base.nix disables it for immutable VMs)
#   - SOPS age key environment for secret decryption
#
# Runtime configuration (injected via write_files):
#   /run/secrets/gitlab-runner/registration-token — Runner auth token (from GitLab)
#   /run/secrets/gitlab-runner/gitlab-url          — GitLab instance URL
#   /run/secrets/github/remote-url                 — GitHub remote URL
#   /run/secrets/sops/age-key                      — SOPS age private key
#   /run/secrets/gitlab-runner/ssh-privkey          — SSH private key for node access
#   /run/secrets/vault-agent/github-deploy-key     — GitHub deploy key (from Vault)
#
# The runner is Category 1 (fully rebuildable). No vdb, no precious state.
# Registration config is stored on the root disk but can be regenerated.

{ config, pkgs, lib, ... }:

let
  cfg = config.mycofu;
  persistConfigDir = "/nix/persist/gitlab-runner";

  # #537 — single source of truth for scratch/build location.
  # Derived by:
  #   - nix.settings.build-dir              (nix build sandbox scratch)
  #   - systemd.tmpfiles.rules              (owner/permissions + age sweep)
  #   - systemd.services.gitlab-runner.env  (TMPDIR for CI jobs)
  #   - environment.variables               (TMPDIR for interactive shells)
  # Deriving all four from `scratchDir` closes G1 finding C1 —
  # relationship-is-configuration: a future move (e.g., to a dedicated
  # data partition) is one edit instead of four, and the test rachet
  # (test_runner_tmpdir_class_fix.sh assertion 2 vs 4) catches drift
  # if the sweep-rule path ever diverges from the runner TMPDIR.
  scratchDir = "/nix/tmp";
  # Age for the mktemp-shape sweep on scratchDir. Kept short enough
  # that job-abort corpses reclaim promptly, well past any legitimate
  # job runtime (HIL boot ISO builds ~30 min; bench soaks ~2h; the
  # nix build sandbox writes under nix-build-* prefixes that don't
  # match the `tmp.*` sweep glob).
  scratchSweepAge = "6h";

  # Vendored OpenTofu provider — runner reaches no registry / no github.com
  # at `tofu init` time. See framework/nix/lib/bpg-proxmox-provider.nix
  # for the version pin and rationale.
  bpgProxmoxProvider = pkgs.callPackage ../lib/bpg-proxmox-provider.nix { };

  # Script to register the runner on first boot if token is available
  registerScript = pkgs.writeShellScript "gitlab-runner-register" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.gitlab-runner pkgs.coreutils pkgs.gnugrep
    ]}:$PATH

    TOKEN_FILE="/run/secrets/gitlab-runner/registration-token"
    URL_FILE="/run/secrets/gitlab-runner/gitlab-url"
    CONFIG_FILE="/etc/gitlab-runner/config.toml"

    # Skip if no token available (first deploy before GitLab is configured)
    if [ ! -f "$TOKEN_FILE" ] || [ ! -s "$TOKEN_FILE" ]; then
      echo "No registration token — runner will not register (deploy token later)"
      exit 0
    fi

    # Skip if already registered
    if [ -f "$CONFIG_FILE" ] && grep -q 'token' "$CONFIG_FILE"; then
      echo "Runner already registered"
      exit 0
    fi

    if [ ! -f "$URL_FILE" ] || [ ! -s "$URL_FILE" ]; then
      echo "ERROR: No GitLab URL file at $URL_FILE" >&2
      exit 1
    fi

    TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
    GITLAB_URL=$(tr -d '[:space:]' < "$URL_FILE")

    mkdir -p /etc/gitlab-runner

    gitlab-runner register \
      --non-interactive \
      --url "$GITLAB_URL" \
      --token "$TOKEN" \
      --executor shell \
      --tag-list "infra,deploy"

    echo "Runner registered with $GITLAB_URL"
  '';

  restoreConfigScript = pkgs.writeShellScript "gitlab-runner-restore-config" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

    CONFIG_FILE="/etc/gitlab-runner/config.toml"
    PERSISTED_CONFIG="${persistConfigDir}/config.toml"

    mkdir -p "${persistConfigDir}" /etc/gitlab-runner

    if [ -s "$PERSISTED_CONFIG" ]; then
      cp "$PERSISTED_CONFIG" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
      echo "Restored GitLab Runner config from ${persistConfigDir}"
    else
      echo "No persisted GitLab Runner config found"
    fi
  '';

  persistConfigScript = pkgs.writeShellScript "gitlab-runner-persist-config" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

    CONFIG_FILE="/etc/gitlab-runner/config.toml"
    PERSISTED_CONFIG="${persistConfigDir}/config.toml"

    mkdir -p "${persistConfigDir}"

    if [ -s "$CONFIG_FILE" ]; then
      cp "$CONFIG_FILE" "$PERSISTED_CONFIG"
      chmod 600 "$PERSISTED_CONFIG"
      echo "Persisted GitLab Runner config to ${persistConfigDir}"
    else
      echo "Runner config not present yet — nothing to persist"
    fi
  '';

  runnerBudgetScript = pkgs.writeShellScript "mycofu-runner-budget" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.diffutils
      pkgs.procps
      config.systemd.package
    ]}:$PATH
    export RUNNER_BUDGET_MAX_CONCURRENT=${toString cfg.runnerBudget.maxConcurrent}
    export RUNNER_BUDGET_LIGHT_JOB_MB=${toString cfg.runnerBudget.lightJobMb}
    export RUNNER_BUDGET_HEAVY_RESERVE_MB=${toString cfg.runnerBudget.heavyReserveMb}
    export RUNNER_BUDGET_OS_RESERVE_MB=${toString cfg.runnerBudget.osReserveMb}
    export RUNNER_BUDGET_FLOOR_MB=${toString cfg.runnerBudget.floorMb}
    export RUNNER_BUDGET_MAX_NIX_JOBS=${toString cfg.runnerBudget.maxNixJobs}
    export RUNNER_BUDGET_FLOOR_CORES=${toString cfg.runnerBudget.floorCores}
    exec ${pkgs.bash}/bin/bash ${./gitlab-runner-budget.sh}
  '';

  runnerBudgetColdMaxMb = cfg.runnerBudget.floorMb - cfg.runnerBudget.osReserveMb;
  runnerBudgetColdHighMb = builtins.div (runnerBudgetColdMaxMb * 9) 10;

  # Busy-aware GC wrapper. `--delete-older-than 7d` only protects
  # profile generations, NOT individual store paths. A GC run that
  # brackets an in-flight `nix build` can delete a derivation the
  # build job currently references, racing it to failure. With
  # concurrent=8 the window widens. TasksCurrent (cgroup-based)
  # catches grandchildren and reparented PIDs that `pgrep -P MainPID`
  # would miss; it returns "[not set]" when the runner is inactive,
  # which the regex check filters out (treats as "not busy → run GC").
  # The wrapper is shared by nix-gc.service and mycofu-generation-
  # cleanup.service so both GC paths on cicd are gated by the same
  # invariant.
  nixGcBusyAwareScript = name: gcCommands: pkgs.writeShellScript name ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils config.systemd.package pkgs.nix ]}:$PATH
    TASKS=$(systemctl show -p TasksCurrent --value gitlab-runner.service 2>/dev/null || echo 0)
    if [[ "$TASKS" =~ ^[0-9]+$ ]] && [ "$TASKS" -gt 1 ]; then
      echo "gitlab-runner cgroup has $TASKS tasks (>1, indicating active builds); skipping GC this cycle"
      exit 0
    fi
    ${gcCommands}
  '';
in
{
  options.mycofu.runnerBudget.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable the adaptive GitLab Runner memory-budget service and timer.";
  };

  options.mycofu.runnerBudget.maxConcurrent = lib.mkOption {
    type = lib.types.ints.positive;
    default = 8;
    description = "Maximum value the adaptive budget may write to GitLab Runner's top-level concurrent key.";
  };

  options.mycofu.runnerBudget.lightJobMb = lib.mkOption {
    type = lib.types.ints.positive;
    default = 2048;
    description = "Coarse memory cost, in MiB, for one light CI job admitted by the runner budget.";
  };

  options.mycofu.runnerBudget.heavyReserveMb = lib.mkOption {
    type = lib.types.ints.positive;
    default = 8192;
    description = "Memory reserve, in MiB, kept for the single heavy CI job class before additional light slots are admitted.";
  };

  options.mycofu.runnerBudget.osReserveMb = lib.mkOption {
    type = lib.types.ints.positive;
    default = 1024;
    description = "Memory reserve, in MiB, left for the operating system outside CI workload admission.";
  };

  options.mycofu.runnerBudget.floorMb = lib.mkOption {
    type = lib.types.ints.positive;
    default = 8192;
    description = "Runner balloon floor in MiB; mirrors site/config.yaml cicd.runner_ram_floor_mb (8192, set by MR-3) and sizes the cold-start backstop.";
  };

  options.mycofu.runnerBudget.maxNixJobs = lib.mkOption {
    type = lib.types.ints.positive;
    default = 4;
    description = "Maximum nix max-jobs value the budget may expose through the runtime nix-budget include.";
  };

  options.mycofu.runnerBudget.floorCores = lib.mkOption {
    type = lib.types.ints.positive;
    default = 4;
    description = "Nix cores value used when the budget serializes runner admission to one job.";
  };

  imports = [ ./vault-agent.nix ];

  config = {

  vaultAgent = {
    enable = true;
    extraConfig = ''
      template {
        contents = <<EOF
{{ with secret "secret/data/github/deploy-key" }}{{ .Data.data.value }}{{ end }}
EOF
        destination = "/run/secrets/vault-agent/github-deploy-key"
        error_on_missing_key = false
        perms = 0400
      }
    '';
  };

  # Re-enable Nix daemon (base.nix disables it for immutable VMs,
  # but the runner needs nix for building NixOS images)
  nix.enable = lib.mkForce true;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    # Trust the gitlab-runner user for nix builds
    trusted-users = [ "root" "gitlab-runner" ];
  };

  # T4.6 runtime nix parallelism lever. /etc/nix/nix.conf is a read-only
  # store-managed symlink, so the mutable part is an optional include under
  # /run. The budget script writes max-jobs/cores there. The original plan's
  # reload mechanism does not exist: nix-daemon has CanReload=no, and CI nix
  # clients re-read nix.conf on every invocation.
  nix.extraOptions = "!include /run/mycofu/nix-budget.conf\n";

  # Automatic garbage collection — keep the nix store bounded.
  # Removes unreferenced paths older than 7 days. Safe on the runner
  # (normal ext4, no overlayfs). See .claude/rules/nix-builder.md.
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  # Override nix-gc.service ExecStart with the busy-aware wrapper so
  # the daily fire skips GC when gitlab-runner has active build
  # children. The next daily fire still runs; we just don't garbage-
  # collect on top of a live build. See nixGcBusyAwareScript above
  # for rationale.
  systemd.services.nix-gc.serviceConfig.ExecStart = lib.mkForce (
    nixGcBusyAwareScript "nix-gc-busy-aware" ''
      exec nix-collect-garbage --delete-older-than 7d
    ''
  );

  # mycofu-generation-cleanup (defined in base.nix, enabled here via
  # cfg.fieldUpdatable) runs nix-collect-garbage weekly. Apply the
  # same busy-aware guard so the weekly run can't race active builds
  # either. Preserve the original two commands (delete generations
  # older than 14d, then GC); only the busy-check preamble is added.
  systemd.services.mycofu-generation-cleanup.serviceConfig.ExecStart = lib.mkForce (
    nixGcBusyAwareScript "mycofu-generation-cleanup-busy-aware" ''
      nix-env --delete-generations --profile /nix/var/nix/profiles/system 14d
      exec nix-collect-garbage
    ''
  );

  # Reactive GC: when free disk drops below 8GB during a build, nix
  # triggers GC automatically before continuing. GCs until 32GB is free.
  # HIL boot image builds stage six remastered installer ISOs and a large
  # raw disk image under /nix/tmp, so the old 1GB/3GB thresholds left too
  # little scratch headroom after the ordinary image matrix.
  nix.settings.min-free = 8589934592;    # 8 GB
  nix.settings.max-free = 34359738368;   # 32 GB

  # Build sandbox on the real ext4 partition, not the overlay tmpfs.
  # With overlay root, / is a 256MB tmpfs. Nix builds (especially vault
  # with Go module downloads) need gigabytes of scratch space. Placing
  # the build directory under /nix uses the ext4 partition (189GB).
  nix.settings.build-dir = scratchDir;

  # Ensure the build and runner working directories exist on the real
  # ext4 partition. With overlay root, the default paths (/var/lib/
  # gitlab-runner/builds, /tmp) are on the 256MB tmpfs overlay and
  # exhaust during image builds.
  #
  # benchmarks/synthetic/fio.sh assumes /nix is the disk class hosting
  # builds_dir on overlay-root hosts and uses /nix/var/bench-tmp as its
  # disk workload candidate. If you change the path below to a non-/nix
  # location (e.g., a separate data partition), update the candidate
  # list in benchmarks/synthetic/fio.sh:disk_workdir() — otherwise the
  # benchmark will silently re-acquire the misalignment that #247 fixed.
  systemd.tmpfiles.rules = [
    "d /run/mycofu 0755 root root -"
    "d ${scratchDir} 1777 root root -"
    "d /nix/var/gitlab-runner 0755 gitlab-runner gitlab-runner -"
    "d /nix/var/gitlab-runner/builds 0755 gitlab-runner gitlab-runner -"
    # #537 — active cleanup for the relocated scratch location.
    #
    # With TMPDIR=/nix/tmp set at the gitlab-runner service level (see
    # below), every job's bare `mktemp` / `mktemp -d` lands under
    # /nix/tmp instead of the 256 MiB overlay /tmp. That fixes ENOSPC,
    # but /nix/tmp lives on the persistent 252 GiB disk — no reboot-
    # wipe. Without an active sweep, mktemp-shaped corpses (job
    # abort, kill -9, runner crash) accumulate on the persistent
    # store indefinitely. This is the trap the issue names: bare
    # relocation trades a small self-clearing overlay for a large
    # never-clearing store.
    #
    # The `e` age-sweep is structural: runs via systemd-tmpfiles-clean
    # regardless of whether individual jobs cooperate. 6h is well past
    # any legitimate job runtime (longest observed: HIL boot ISO
    # builds ~30 min; bench soaks ~2h), and any in-flight job that
    # continues writing to its scratch dir updates the mtime so the
    # sweep leaves it alone. Older orphans get reclaimed within one
    # clean.timer cycle after crossing the threshold.
    #
    # This supersedes the prior prefix-specific rule
    # (`e /tmp/publish-filter-test.* - - - 1d`, added for #510) and
    # closes #534 (which asked to broaden that rule's prefix list).
    "e ${scratchDir}/tmp.* - - - ${scratchSweepAge}"
  ];

  # GitLab Runner user
  users.users.gitlab-runner = {
    isSystemUser = true;
    group = "gitlab-runner";
    home = "/var/lib/gitlab-runner";
    createHome = true;
    shell = pkgs.bash;
    # Add to wheel for sudo if needed during pipeline runs
  };
  users.groups.gitlab-runner = {};

  systemd.services.gitlab-runner-restore-config = {
    description = "Restore GitLab Runner config from /nix/persist";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "gitlab-runner-register.service" ]
      ++ lib.optionals cfg.runnerBudget.enable [ "mycofu-runner-budget.service" ]
      ++ [ "gitlab-runner.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = restoreConfigScript;
    };
  };

  # Runner registration service — runs on boot, registers if token is available
  systemd.services.gitlab-runner-register = {
    description = "Register GitLab Runner";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" "gitlab-runner-restore-config.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" "gitlab-runner-restore-config.service" ];
    before = lib.optionals cfg.runnerBudget.enable [ "mycofu-runner-budget.service" ]
      ++ [ "gitlab-runner.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = registerScript;
      ExecStartPost = persistConfigScript;
    };
  };

  # The old config.toml .path watcher is intentionally gone. It was a second
  # writer for the same top-level `concurrent` key and had already tripped
  # deploy-time StartLimitBurst cascades in MR !211 and MR !213. The 30 s
  # timer below is now the single repair loop for runner self-writes.
  systemd.services.mycofu-runner-budget = lib.mkIf cfg.runnerBudget.enable {
    description = "Apply adaptive GitLab Runner memory budget";
    wantedBy = [ "multi-user.target" ];
    wants = [ "gitlab-runner-restore-config.service" "gitlab-runner-register.service" ];
    after = [ "gitlab-runner-restore-config.service" "gitlab-runner-register.service" ];
    before = [ "gitlab-runner.service" ];
    # During switch-to-configuration, /etc/gitlab-runner/config.toml is
    # rewritten in rapid succession by restoreConfigScript, registerScript,
    # and gitlab-runner.service startup. Each write fires the .path, which
    # queues a .service run. systemd's default StartLimitBurst=5 over
    # StartLimitIntervalSec=10s trips on this legitimate cascade (observed:
    # 5 starts in the same second during MR !211's deploy, causing the
    # .path to fail with unit-start-limit-hit and switch-to-configuration
    # to exit status 4). Raising the burst absorbs the cascade. The script
    # is idempotent (cmp check), so each run is a no-op when the file is
    # already normalized — the limit only exists to catch a true infinite
    # loop. 30/60s is wide enough for legitimate cascades and narrow
    # enough to surface a real bug.
    startLimitBurst = 30;
    startLimitIntervalSec = 60;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = runnerBudgetScript;
    };
  };

  systemd.timers.mycofu-runner-budget = lib.mkIf cfg.runnerBudget.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "30s";
      Unit = "mycofu-runner-budget.service";
    };
  };

  # GitLab Runner service
  systemd.services.gitlab-runner = {
    description = "GitLab Runner";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "gitlab-runner-register.service" ]
      ++ lib.optionals cfg.runnerBudget.enable [ "mycofu-runner-budget.service" ]
      ++ [ "vault-agent.service" ];
    # `wants` (ordering-only), NOT `requires`, on the budget service: if the
    # budget oneshot ever crashes, the runner must still come up — CI slow (or
    # even at a stale-wide `concurrent`) beats CI dead. The host stays protected
    # regardless because the static floor-sized MemoryHigh/MemoryMax below is
    # applied by THIS unit at cold start, independent of the budget script. The
    # budget script also fail-safes internally (serialize + exit 0) on unreadable
    # memory, so a true unit failure means an actual bug, not a small survivor.
    wants = [ "network-online.target" ]
      ++ lib.optionals cfg.runnerBudget.enable [ "mycofu-runner-budget.service" ]
      ++ [ "vault-agent.service" ];
    requires = [ "gitlab-runner-register.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.gitlab-runner}/bin/gitlab-runner run --working-directory /var/lib/gitlab-runner --config /etc/gitlab-runner/config.toml";
      Restart = "on-failure";
      RestartSec = "5s";
      # Corrected T4.5: the clamp belongs here, not on nix-daemon. The shell
      # executor runs as root and `nix build` uses the local store directly in
      # this cgroup; MR-4's measurement saw gitlab-runner peak at 16,011 MiB
      # while nix-daemon sat at 4 MiB, so the plan's D1 daemon target is void.
      #
      # MemoryHigh is the normal control: soft, reclaim-first, and suitable for
      # GitLab's mostly page-cache 16 GiB peak. At max-jobs=1 it builds within
      # the 8 GiB floor.
      #
      # MemoryMax is the host-protection kill switch. A breach OOM-kills the
      # fattest process in the runner slice: failed builds, not a dead host. It
      # may kill a build belonging to a different job than the one that caused
      # the pressure; that is the accepted trade.
      #
      # OOMPolicy=continue is pinned so the runner daemon survives and GitLab
      # reports a red job instead of the runner vanishing.
      MemoryAccounting = true;
      MemoryHigh = "${toString runnerBudgetColdHighMb}M";
      MemoryMax = "${toString runnerBudgetColdMaxMb}M";
      OOMPolicy = "continue";
    };
    # Set environment for SOPS decryption and tool access during pipeline runs
    environment = {
      SOPS_AGE_KEY_FILE = "/run/secrets/sops/age-key";
      HOME = "/var/lib/gitlab-runner";
      # Sovereignty: point tofu at the vendored bpg/proxmox provider so
      # `tofu init` never reaches registry.opentofu.org / github.com.
      TF_CLI_CONFIG_FILE = "${bpgProxmoxProvider}/etc/terraformrc";
      # #537 — class-level fix for job scratch ENOSPC.
      #
      # cicd's root is a 256 MiB overlay tmpfs (base.nix). Jobs that
      # scratch via bare `mktemp` / `mktemp -d` inherit TMPDIR from
      # the gitlab-runner service they're spawned under. Setting
      # TMPDIR=/nix/tmp here diverts every job's scratch onto the
      # persistent 252 GiB ext4 partition (same disk nix's build-dir
      # uses). This retires the per-job `variables: TMPDIR: /nix/tmp`
      # overrides #510 added to three publish-* validate jobs, and
      # makes the per-prefix tmpfiles GC rule #534 proposed unnecessary.
      #
      # See the /nix/tmp/tmp.* sweep rule under systemd.tmpfiles.rules
      # above for the required active-cleanup counterpart.
      TMPDIR = scratchDir;
    };
    path = with pkgs; [
      bash
      coreutils
      git
      opentofu
      sops
      age
      yq-go
      jq
      curl
      openssh
      gnused
      gnugrep
      findutils
      gnutar
      gzip
      nix
    ];
    # ExecCondition: only start if config.toml exists (runner is registered)
    unitConfig.ConditionPathExists = "/etc/gitlab-runner/config.toml";
  };

  # --- SSH setup for node access ---
  # Copy the SSH private key from write_files to the runner's .ssh directory
  systemd.services.gitlab-runner-ssh-setup = {
    description = "Set up SSH key for GitLab Runner";
    wantedBy = [ "multi-user.target" ];
    after = [ "nocloud-init.service" ];
    requires = [ "nocloud-init.service" ];
    before = [ "gitlab-runner.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "runner-ssh-setup" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.openssh ]}:$PATH

        SSH_KEY_FILE="/run/secrets/gitlab-runner/ssh-privkey"
        RUNNER_SSH_DIR="/var/lib/gitlab-runner/.ssh"

        mkdir -p "$RUNNER_SSH_DIR"

        if [ -f "$SSH_KEY_FILE" ] && [ -s "$SSH_KEY_FILE" ]; then
          # Set up for gitlab-runner user
          cp "$SSH_KEY_FILE" "$RUNNER_SSH_DIR/id_ed25519"
          chmod 600 "$RUNNER_SSH_DIR/id_ed25519"
          cat > "$RUNNER_SSH_DIR/config" <<EOF
        Host *
          StrictHostKeyChecking accept-new
          UserKnownHostsFile /var/lib/gitlab-runner/.ssh/known_hosts
        EOF
          chmod 700 "$RUNNER_SSH_DIR"
          chown -R gitlab-runner:gitlab-runner "$RUNNER_SSH_DIR"

          # Also set up for root — shell executor runs as root
          ROOT_SSH_DIR="/root/.ssh"
          mkdir -p "$ROOT_SSH_DIR"
          cp "$SSH_KEY_FILE" "$ROOT_SSH_DIR/id_ed25519"
          chmod 600 "$ROOT_SSH_DIR/id_ed25519"
          cat > "$ROOT_SSH_DIR/config" <<EOF
        Host *
          StrictHostKeyChecking accept-new
          UserKnownHostsFile /root/.ssh/known_hosts
        EOF
          chmod 700 "$ROOT_SSH_DIR"
          echo "SSH key configured for gitlab-runner and root"
        else
          echo "No SSH key at $SSH_KEY_FILE — skipping"
        fi
      '';
    };
  };

  # Sovereignty: set TF_CLI_CONFIG_FILE system-wide so an operator who
  # logs into the runner and runs tofu manually gets the same vendored
  # provider configuration the pipeline jobs see.
  environment.variables.TF_CLI_CONFIG_FILE = "${bpgProxmoxProvider}/etc/terraformrc";

  # #537 — TMPDIR relocation for interactive / non-gitlab-runner shells.
  # The systemd.services.gitlab-runner.environment setting above is what
  # actually diverts job scratch (jobs inherit from the runner service).
  # This system-wide setting is defense-in-depth: an operator SSHing in
  # and running `mktemp` interactively lands on /nix/tmp too, so nothing
  # on this VM scratches the 256 MiB overlay by default.
  environment.variables.TMPDIR = scratchDir;

  # --- CI/CD tooling ---
  # All tools that pipeline jobs need, available in the runner's shell.
  # The bpg/proxmox provider is included here so its store path is
  # registered in the system closure; it is referenced by
  # TF_CLI_CONFIG_FILE on the gitlab-runner service.
  environment.systemPackages = with pkgs; [
    # Build tools
    git
    opentofu
    bpgProxmoxProvider
    sops
    age

    # Utilities
    yq-go
    jq
    curl
    openssh
    python3
    gnumake
    bash
    coreutils
    gnused
    gawk
    gnugrep
    findutils
    gnutar
    gzip
    dig  # DNS validation in test stages
    openssl  # Certificate checks in test stages

    # HIL regreener tooling (sprint-037 completion). expect is required by
    # framework/scripts/pdu-cycle.sh to drive the APC PDU's interactive SSH
    # session (no API equivalent on the rack PDU). Regreen verification
    # itself uses the Proxmox HTTPS API (see pve_api_login in
    # install-pve-node.sh), not SSH — so sshpass is intentionally NOT in
    # this list. When a future sprint expands cicd to drive
    # rebuild-cluster.sh, that sprint will add sshpass for one-time SSH
    # key bootstrap via configure-node-network.sh.
    expect
    # xorriso is used by tests/test_hil_boot_iso_real_build.sh in the
    # build stage to verify that the freshly-built hil-boot per-node ISO
    # contains the expected answer.toml + auto-installer-mode.toml.
    # libisoburn provides the xorriso binary.
    libisoburn
  ];

  # Disable IPv6 — the management network has no IPv6 connectivity.
  # Without this, Go module downloads fail when the proxy resolves to
  # an IPv6 address (AAAA before A) and the connection is unreachable.
  boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
  boot.kernel.sysctl."net.ipv6.conf.default.disable_ipv6" = 1;

  # Firewall — runner is a client only, no inbound ports needed beyond SSH
  networking.firewall.allowedTCPPorts = [ 22 ];

  };
}
