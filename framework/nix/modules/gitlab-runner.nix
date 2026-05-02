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

  setConcurrentScript = pkgs.writeShellScript "gitlab-runner-set-concurrent" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.diffutils ]}:$PATH

    CONFIG_FILE="''${GITLAB_RUNNER_CONFIG_FILE:-/etc/gitlab-runner/config.toml}"
    PERSISTED_CONFIG="''${GITLAB_RUNNER_PERSISTED_CONFIG:-/nix/persist/gitlab-runner/config.toml}"
    RUNNER_CONCURRENT=${toString cfg.runnerConcurrent}

    if [ ! -e "$CONFIG_FILE" ]; then
      echo "Runner config not present yet — nothing to normalize"
      exit 0
    fi

    TMP_FILE="$(mktemp)"
    trap 'rm -f "$TMP_FILE"' EXIT

    if sed '/^\[/q' "$CONFIG_FILE" | grep -qE '^concurrent[[:space:]]*='; then
      sed "1,/^\[/{s/^concurrent[[:space:]]*=.*/concurrent = $RUNNER_CONCURRENT/;}" "$CONFIG_FILE" > "$TMP_FILE"
    else
      {
        echo "concurrent = $RUNNER_CONCURRENT"
        cat "$CONFIG_FILE"
      } > "$TMP_FILE"
    fi

    if ! cmp -s "$TMP_FILE" "$CONFIG_FILE"; then
      cp "$TMP_FILE" "$CONFIG_FILE"
      chmod 600 "$CONFIG_FILE"
      echo "Normalized GitLab Runner concurrent = $RUNNER_CONCURRENT"
    else
      echo "GitLab Runner concurrent already normalized"
    fi

    mkdir -p "$(dirname "$PERSISTED_CONFIG")"
    cp "$CONFIG_FILE" "$PERSISTED_CONFIG"
    chmod 600 "$PERSISTED_CONFIG"
  '';

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
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.nix ]}:$PATH
    TASKS=$(systemctl show -p TasksCurrent --value gitlab-runner.service 2>/dev/null || echo 0)
    if [[ "$TASKS" =~ ^[0-9]+$ ]] && [ "$TASKS" -gt 1 ]; then
      echo "gitlab-runner cgroup has $TASKS tasks (>1, indicating active builds); skipping GC this cycle"
      exit 0
    fi
    ${gcCommands}
  '';
in
{
  options.mycofu.runnerConcurrent = lib.mkOption {
    type = lib.types.ints.positive;
    default = 8;
    description = "Top-level GitLab Runner concurrent job limit.";
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

  # Reactive GC: when free disk drops below 1GB during a build, nix
  # triggers GC automatically before continuing. GCs until 3GB is free.
  # This prevents disk exhaustion during burst build activity (e.g.,
  # multiple full image rebuilds in one day). The daily GC above handles
  # long-term retention; min-free handles same-day pressure.
  nix.settings.min-free = 1073741824;   # 1 GB
  nix.settings.max-free = 3221225472;   # 3 GB

  # Build sandbox on the real ext4 partition, not the overlay tmpfs.
  # With overlay root, / is a 256MB tmpfs. Nix builds (especially vault
  # with Go module downloads) need gigabytes of scratch space. Placing
  # the build directory under /nix uses the ext4 partition (189GB).
  nix.settings.build-dir = "/nix/tmp";

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
    "d /nix/tmp 1777 root root -"
    "d /nix/var/gitlab-runner 0755 gitlab-runner gitlab-runner -"
    "d /nix/var/gitlab-runner/builds 0755 gitlab-runner gitlab-runner -"
    # Defense-in-depth: garbage-collect stale publish-filter test temp
    # dirs from /tmp if a job is interrupted before EXIT cleanup runs.
    # Over days without reboot, leaked dirs can fill the 256M overlay
    # and break the runner.
    "e /tmp/publish-filter-test.* - - - 1d"
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
    before = [ "gitlab-runner-register.service" "gitlab-runner-set-concurrent.service" "gitlab-runner.service" ];
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
    before = [ "gitlab-runner-set-concurrent.service" "gitlab-runner.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = registerScript;
      ExecStartPost = persistConfigScript;
    };
  };

  systemd.services.gitlab-runner-set-concurrent = {
    description = "Normalize GitLab Runner top-level concurrency";
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
      ExecStart = setConcurrentScript;
    };
  };

  # PathChanged only — do NOT add PathExists. PathExists is a continuous
  # condition (re-evaluated after each .service deactivation), and the
  # .service is a oneshot without RemainAfterExit (we omit RemainAfterExit
  # because RemainAfterExit=true blocks the .path from re-firing on
  # subsequent legitimate writes — once .service is active(exited),
  # systemd suppresses redundant trigger requests). The combination
  # PathExists + oneshot-without-RemainAfterExit creates a tight loop:
  # .path fires .service → .service deactivates → .path re-evaluates
  # PathExists (still true) → fires .service again → ... until
  # StartLimitBurst trips. Observed during MR !213's deploy: 31 fires
  # in 1 second, switch-to-configuration exit status 4. PathChanged
  # alone suffices because (a) at boot, set-concurrent.service runs
  # directly via wantedBy=multi-user.target ordered after restore-config
  # and register and before gitlab-runner — no .path needed for boot;
  # (b) at runtime, any actual write to config.toml (gitlab-runner self-
  # update, manual edit) fires PathChanged, which fires .service.
  systemd.paths.gitlab-runner-set-concurrent = {
    description = "Watch GitLab Runner config for concurrency normalization";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/etc/gitlab-runner/config.toml";
      Unit = "gitlab-runner-set-concurrent.service";
    };
  };

  # GitLab Runner service
  systemd.services.gitlab-runner = {
    description = "GitLab Runner";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "gitlab-runner-register.service" "gitlab-runner-set-concurrent.service" "vault-agent.service" ];
    wants = [ "network-online.target" "gitlab-runner-set-concurrent.service" "vault-agent.service" ];
    requires = [ "gitlab-runner-register.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.gitlab-runner}/bin/gitlab-runner run --working-directory /var/lib/gitlab-runner --config /etc/gitlab-runner/config.toml";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    # Set environment for SOPS decryption and tool access during pipeline runs
    environment = {
      SOPS_AGE_KEY_FILE = "/run/secrets/sops/age-key";
      HOME = "/var/lib/gitlab-runner";
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

  # --- CI/CD tooling ---
  # All tools that pipeline jobs need, available in the runner's shell
  environment.systemPackages = with pkgs; [
    # Build tools
    git
    opentofu
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
