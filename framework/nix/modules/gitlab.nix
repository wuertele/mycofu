# gitlab.nix — GitLab CE server with Let's Encrypt TLS.
#
# This module extends base.nix with:
#   - GitLab CE (Puma, Sidekiq, Gitaly, Workhorse, PostgreSQL, Redis)
#   - Let's Encrypt TLS via certbot (explicit FQDN from /run/secrets/certbot/fqdn)
#   - Nginx reverse proxy with certbot-issued certificate
#   - Data on vdb (/var/lib/gitlab) — repositories, uploads, CI/CD data, PostgreSQL
#
# Runtime configuration (injected via write_files):
#   /run/secrets/gitlab/external-url     — GitLab external URL (e.g., https://gitlab.prod.example.com)
#   /run/secrets/certbot/fqdn            — Explicit FQDN for certbot
#   /run/secrets/certbot/pdns-api-key    — PowerDNS API key for DNS-01
#   /run/secrets/certbot/acme-server-url — ACME directory URL
#   /run/secrets/certbot/pdns-api-servers — DNS server IPs for certbot hooks
#
# GitLab is Category 3 (precious state). The vdb data disk holds Git
# repositories and must be backed up via PBS.

{ config, pkgs, lib, ... }:

let
  gitlabStatePath = "/var/lib/gitlab/state";
  getRealRootDevice = import ../lib/get-real-root-device.nix { inherit pkgs; };

  # Script to patch gitlab.yml with runtime external URL
  patchExternalUrl = pkgs.writeShellScript "gitlab-patch-external-url" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused ]}:$PATH

    EXTERNAL_URL_FILE="/run/secrets/gitlab/external-url"
    if [ ! -f "$EXTERNAL_URL_FILE" ]; then
      echo "WARNING: No external URL file — using placeholder"
      exit 0
    fi

    EXTERNAL_URL=$(tr -d '[:space:]' < "$EXTERNAL_URL_FILE")
    HOST=$(echo "$EXTERNAL_URL" | sed 's|https\?://||;s|:.*||;s|/.*||')

    CONFIG="${gitlabStatePath}/config/gitlab.yml"
    if [ -f "$CONFIG" ]; then
      sed -i "s/localhost/$HOST/g" "$CONFIG"
      echo "Patched gitlab.yml: host=$HOST"
    fi
  '';
in
{
  imports = [ ./certbot.nix ];

  # DNS resolution handled by systemd-resolved (enabled in base.nix).
  # resolved reads DNS= and Domains= from the networkd .network file
  # written by configure-static-network and writes resolv.conf.

  # --- vdb mount at /var/lib/gitlab ---
  fileSystems."/var/lib/gitlab" = {
    device = "/dev/disk/by-label/gitlab-data";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=5s" ];
  };
  # Override default /var/lib/data mount from base.nix
  fileSystems."/var/lib/data" = lib.mkForce {
    device = "none";
    fsType = "none";
    options = [ "noauto" ];
  };

  # Format vdb on first boot
  systemd.services.gitlab-format-vdb = {
    description = "Format vdb for GitLab data";
    wantedBy = [ "var-lib-gitlab.mount" ];
    before = [ "var-lib-gitlab.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "gitlab-format-vdb" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.e2fsprogs pkgs.util-linux pkgs.coreutils ]}:$PATH

        # Already formatted — skip
        if [ -e /dev/disk/by-label/gitlab-data ]; then
          echo "gitlab-data disk already formatted"
          exit 0
        fi

        # Find the data disk: the non-boot whole disk (no partitions)
        BOOT_DISK=$(lsblk -ndo PKNAME "$("${getRealRootDevice}")" 2>/dev/null || true)
        for dev in /dev/sd?; do
          NAME=$(basename "$dev")
          [ "$NAME" = "$BOOT_DISK" ] && continue
          if [ -b "$dev" ] && ! blkid -o value -s TYPE "$dev" 2>/dev/null | grep -q .; then
            echo "Formatting $dev as ext4..."
            mkfs.ext4 -L gitlab-data "$dev"
            echo "vdb formatted"
            exit 0
          fi
        done

        echo "WARNING: No unformatted data disk found"
      '';
    };
  };

  # --- GitLab CE ---
  services.gitlab = {
    enable = true;
    host = "localhost";  # Patched at runtime from /run/secrets/gitlab/external-url
    port = 443;
    https = true;
    statePath = gitlabStatePath;

    # Minimal resources for single-user home lab.
    # workers=0 runs Puma in single-process mode (no forking), saving ~500MB.
    # Threads handle concurrency instead — sufficient for 1-2 users.
    puma = {
      workers = 0;
      threadsMin = 1;
      threadsMax = 4;
    };

    # Initial root password (generated on first boot)
    initialRootPasswordFile = "/var/lib/gitlab/initial_root_password";

    # Required secrets — generated on first boot and persisted on vdb
    secrets = {
      secretFile = "/var/lib/gitlab/secrets/secret";
      dbFile = "/var/lib/gitlab/secrets/db";
      otpFile = "/var/lib/gitlab/secrets/otp";
      jwsFile = "/var/lib/gitlab/secrets/jws";
    };

    # SMTP — configured via extraConfig from runtime values if needed
    # For initial deployment, email is not critical
  };

  # --- PostgreSQL data on vdb ---
  # The GitLab NixOS module creates PostgreSQL automatically.
  # By default PostgreSQL stores data on vda (/var/lib/postgresql),
  # which means the database is NOT backed up by PBS (only vdb is backed up).
  # Move it to vdb so it survives rebuild and gets backed up.
  # Place PostgreSQL data directly under /var/lib/gitlab (the vdb mount),
  # NOT under statePath (/var/lib/gitlab/state) which is owned by gitlab
  # with restricted permissions that prevent the postgres user from traversing.
  services.postgresql.dataDir = lib.mkForce "/var/lib/gitlab/postgresql";

  # Ensure PostgreSQL starts after vdb is mounted
  systemd.services.postgresql.after = [ "var-lib-gitlab.mount" ];
  systemd.services.postgresql.requires = [ "var-lib-gitlab.mount" ];

  # The NixOS GitLab pre-start script does chown gitlab:gitlab on state/*
  # which overrides the postgres ownership on the postgresql dir. Fix it
  # right before PostgreSQL starts. Uses + prefix to run as root since
  # the state directory is owned by gitlab.
  systemd.services.postgresql.serviceConfig.ExecStartPre = lib.mkBefore [
    "+${pkgs.writeShellScript "fix-pg-dir-ownership" ''
      install -d -m 700 -o postgres -g postgres "/var/lib/gitlab/postgresql"
    ''}"
  ];

  # Generate initial root password and required secrets on first boot.
  # These are persisted on vdb (/var/lib/gitlab) and survive reboots.
  systemd.services.gitlab-gen-secrets = {
    description = "Generate GitLab secrets and initial root password";
    wantedBy = [ "multi-user.target" ];
    after = [ "var-lib-gitlab.mount" ];
    before = [ "gitlab.service" "gitlab-config.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "gitlab-gen-secrets" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.openssl pkgs.findutils ]}:$PATH

        SECRETS_DIR="/var/lib/gitlab/secrets"
        mkdir -p "$SECRETS_DIR"

        # Create state directory structure expected by NixOS gitlab-config
        for d in config db log repositories shared uploads builds backup tmp/sockets tmp/pids shell/hooks home/.ssh; do
          mkdir -p "${gitlabStatePath}/$d"
        done

        # PostgreSQL data directory on vdb — directly under /var/lib/gitlab
        # (not under statePath, which has restricted gitlab-only permissions)
        mkdir -p "/var/lib/gitlab/postgresql"
        chown -R postgres:postgres "/var/lib/gitlab/postgresql"
        chmod 700 "/var/lib/gitlab/postgresql"

        chown -R gitlab:gitlab "${gitlabStatePath}"

        # Generate initial root password
        if [ ! -f /var/lib/gitlab/initial_root_password ]; then
          head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24 > /var/lib/gitlab/initial_root_password
          chmod 600 /var/lib/gitlab/initial_root_password
          echo "Generated initial root password"
        fi

        # Generate secret key (for encrypting variables in DB)
        if [ ! -f "$SECRETS_DIR/secret" ]; then
          head -c 64 /dev/urandom | base64 | tr -d '/+=' | head -c 64 > "$SECRETS_DIR/secret"
          chmod 600 "$SECRETS_DIR/secret"
          echo "Generated secret key"
        fi

        # Generate DB encryption key
        if [ ! -f "$SECRETS_DIR/db" ]; then
          head -c 64 /dev/urandom | base64 | tr -d '/+=' | head -c 64 > "$SECRETS_DIR/db"
          chmod 600 "$SECRETS_DIR/db"
          echo "Generated DB key"
        fi

        # Generate OTP key
        if [ ! -f "$SECRETS_DIR/otp" ]; then
          head -c 64 /dev/urandom | base64 | tr -d '/+=' | head -c 64 > "$SECRETS_DIR/otp"
          chmod 600 "$SECRETS_DIR/otp"
          echo "Generated OTP key"
        fi

        # Generate JWS key (RSA private key in PEM format)
        if [ ! -f "$SECRETS_DIR/jws" ]; then
          openssl genrsa 2048 > "$SECRETS_DIR/jws" 2>/dev/null
          chmod 600 "$SECRETS_DIR/jws"
          echo "Generated JWS key"
        fi

        # GitLab config service runs as gitlab user and needs to read these
        chown -R gitlab:gitlab "$SECRETS_DIR"
        chown gitlab:gitlab /var/lib/gitlab/initial_root_password

        echo "All GitLab secrets ready"
      '';
    };
  };

  # Patch external URL after gitlab-config generates config files but before
  # gitlab (Puma) starts reading them. The gitlab-config service generates
  # gitlab.yml from the Nix store; we patch the host placeholder afterward.
  systemd.services.gitlab-patch-url = {
    description = "Patch GitLab external URL from runtime config";
    wantedBy = [ "gitlab.target" ];
    after = [ "gitlab-config.service" ];
    requires = [ "gitlab-config.service" ];
    before = [ "gitlab.service" "gitlab-workhorse.service" "gitlab-sidekiq.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = patchExternalUrl;
    };
  };

  # GitLab and nginx depend on gitlab-cert-link (not certbot-initial directly).
  # gitlab-cert-link polls for the cert file, decoupling from certbot's lifecycle.
  systemd.services.gitlab.after = [ "gitlab-cert-link.service" "gitlab-patch-url.service" ];
  systemd.services.gitlab.requires = [ "gitlab-cert-link.service" "gitlab-patch-url.service" ];
  systemd.services.gitlab-workhorse.after = [ "gitlab-cert-link.service" "gitlab-patch-url.service" ];
  systemd.services.gitlab-sidekiq.after = [ "gitlab-patch-url.service" ];

  # Poll for the TLS certificate with retries, then create a fixed-path symlink.
  # This decouples nginx/gitlab startup from certbot-initial's lifecycle:
  # if certbot fails on the first attempt and succeeds on a retry, this service
  # will find the cert and trigger the rest of the chain.
  systemd.services.gitlab-cert-link = {
    description = "Create fixed-path symlink to GitLab TLS certificate";
    wantedBy = [ "multi-user.target" ];
    after = [ "nocloud-init.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" ];
    before = [ "nginx.service" "gitlab.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "gitlab-cert-link" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.inetutils pkgs.gawk ]}:$PATH

        FQDN_FILE="/run/secrets/certbot/fqdn"
        if [ -f "$FQDN_FILE" ] && [ -s "$FQDN_FILE" ]; then
          FQDN=$(tr -d '[:space:]' < "$FQDN_FILE")
        else
          FQDN=$(hostname).$(awk '/^search / { print $2; exit }' /etc/resolv.conf)
        fi

        # Wait for certbot to acquire the certificate (up to 15 minutes).
        # On a fresh VM, certbot runs DNS-01 challenges which depend on
        # DNS propagation. This blocks until the cert appears, preventing
        # dependent services (gitlab, nginx) from failing at boot.
        CERT_DIR="/etc/letsencrypt/live/$FQDN"
        TIMEOUT=900
        ELAPSED=0
        # Use test -s (non-empty), not test -f. Certbot can leave 0-byte
        # PEM files after a failed ACME challenge. See .claude/rules/platform.md.
        echo "Waiting for TLS certificate ($FQDN)..."
        while [ ! -s "$CERT_DIR/fullchain.pem" ] || [ ! -s "$CERT_DIR/privkey.pem" ]; do
          if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "ERROR: TLS certificate not available (or empty) after ''${TIMEOUT}s" >&2
            exit 1
          fi
          echo "  Certificate not yet available (''${ELAPSED}s elapsed, timeout ''${TIMEOUT}s)"
          sleep 5
          ELAPSED=$((ELAPSED + 5))
        done
        echo "Certificate found after ''${ELAPSED}s. Creating symlink."

        ln -sfn "$CERT_DIR" /etc/letsencrypt/live/gitlab

        # Certbot creates /etc/letsencrypt with mode 700; nginx needs to
        # traverse the parent to reach live/ and archive/. With overlay root,
        # permissions don't persist across reboots.
        chmod 755 /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive
        # Private key is 600/root — nginx runs as nginx user, needs group read
        chgrp nginx /etc/letsencrypt/archive/*/privkey*.pem
        chmod 640 /etc/letsencrypt/archive/*/privkey*.pem
        echo "Cert symlink: /etc/letsencrypt/live/gitlab -> $FQDN"
      '';
    };
  };

  # --- Nginx reverse proxy ---
  services.nginx = {
    enable = true;

    # Recommended settings
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."gitlab" = {
      listen = [
        { addr = "0.0.0.0"; port = 443; ssl = true; }
      ];
      onlySSL = true;
      sslCertificate = "/etc/letsencrypt/live/gitlab/fullchain.pem";
      sslCertificateKey = "/etc/letsencrypt/live/gitlab/privkey.pem";

      locations."/" = {
        proxyPass = "http://unix:/run/gitlab/gitlab-workhorse.socket";
        proxyWebsockets = true;
        extraConfig = ''
          client_max_body_size 250m;
          proxy_read_timeout 600;
          proxy_connect_timeout 300;
          proxy_redirect off;
        '';
      };
    };
  };

  # Nginx must start after cert is available (via cert-link, not certbot directly)
  systemd.services.nginx.after = [ "gitlab-cert-link.service" ];
  systemd.services.nginx.requires = [ "gitlab-cert-link.service" ];

  # --- SSH integration for git push via gitlab-shell ---
  # AuthorizedKeysCommand lets sshd look up SSH keys registered in GitLab's
  # database. Without this, git@<ip>:... push fails with "Permission denied"
  # because sshd only checks authorized_keys files, not gitlab-shell.
  services.openssh.extraConfig = ''
    Match User gitlab
      AuthorizedKeysCommand /etc/ssh/gitlab-shell-authorized-keys-check gitlab %u %k
      AuthorizedKeysCommandUser gitlab
  '';

  # Wrapper calls gitlab-shell-authorized-keys-check from the Nix store.
  # sshd requires AuthorizedKeysCommand to be owned by root and not
  # group/world-writable, so we use environment.etc (creates in /etc).
  environment.etc."ssh/gitlab-shell-authorized-keys-check" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      exec ${config.services.gitlab.packages.gitlab-shell}/bin/gitlab-shell-authorized-keys-check "$@"
    '';
  };

  # --- Firewall ---
  networking.firewall.allowedTCPPorts = [
    443  # HTTPS (GitLab web UI and API)
    22   # SSH (Git operations via gitlab-shell, plus operator SSH)
  ];

  # --- Operator tooling ---
  environment.systemPackages = with pkgs; [
    git
  ];
}
