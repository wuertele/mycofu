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
#   /run/secrets/sops/age-key                      — SOPS age private key
#   /run/secrets/gitlab-runner/ssh-privkey          — SSH private key for node access
#
# The runner is Category 1 (fully rebuildable). No vdb, no precious state.
# Registration config is stored on the root disk but can be regenerated.

{ config, pkgs, lib, ... }:

let
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
in
{
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

  # Runner registration service — runs on boot, registers if token is available
  systemd.services.gitlab-runner-register = {
    description = "Register GitLab Runner";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" ];
    before = [ "gitlab-runner.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = registerScript;
    };
  };

  # GitLab Runner service
  systemd.services.gitlab-runner = {
    description = "GitLab Runner";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "gitlab-runner-register.service" ];
    wants = [ "network-online.target" ];
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
}
