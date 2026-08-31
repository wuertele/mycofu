{ pkgs, lib, ... }:

let
  getRealRootDevice = import ../../nix/lib/get-real-root-device.nix { inherit pkgs; };

  workstationFormatHome = pkgs.writeShellScript "workstation-format-home" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.systemd
      pkgs.util-linux
    ]}:$PATH

    find_home_disk() {
      local root_device boot_disk
      local -a candidates=()
      local disk_name disk_type

      root_device="$("${getRealRootDevice}")"
      boot_disk="$(lsblk -ndo PKNAME "$root_device" 2>/dev/null || true)"
      if [[ -z "$boot_disk" ]]; then
        boot_disk="$(basename "$root_device")"
      fi

      while read -r disk_name disk_type; do
        [[ "$disk_type" == "disk" ]] || continue
        [[ "$disk_name" == "$boot_disk" ]] && continue
        candidates+=("/dev/$disk_name")
      done < <(lsblk -ndo NAME,TYPE)

      if [[ "''${#candidates[@]}" -eq 0 ]]; then
        echo "workstation-format-home: no non-boot whole-disk candidate found for /home" >&2
        return 1
      fi

      if [[ "''${#candidates[@]}" -ne 1 ]]; then
        echo "workstation-format-home: ambiguous /home disk candidates: ''${candidates[*]}" >&2
        return 1
      fi

      printf '%s\n' "''${candidates[0]}"
    }

    udevadm settle || true
    HOME_DISK="$(find_home_disk)"
    [[ -b "$HOME_DISK" ]] || {
      echo "workstation-format-home: candidate is not a block device: $HOME_DISK" >&2
      exit 1
    }

    BLKID_EXPORT=""
    TYPE=""
    LABEL=""
    set +e
    BLKID_EXPORT="$(blkid -o export "$HOME_DISK" 2>/dev/null)"
    BLKID_RC=$?
    set -e

    case "$BLKID_RC" in
      0)
        TYPE="$(awk -F= '$1 == "TYPE" { print $2 }' <<< "$BLKID_EXPORT")"
        LABEL="$(awk -F= '$1 == "LABEL" { print $2 }' <<< "$BLKID_EXPORT")"
        ;;
      2)
        ;;
      *)
        echo "workstation-format-home: blkid failed with exit code $BLKID_RC on $HOME_DISK; refusing to format" >&2
        exit 1
        ;;
    esac

    if [[ "$TYPE" == "ext4" && "$LABEL" == "home" ]]; then
      echo "workstation-format-home: found ext4 disk with label home; skipping format"
      exit 0
    fi

    if [[ -n "$TYPE" ]]; then
      echo "workstation-format-home: refusing to format $HOME_DISK (TYPE=$TYPE LABEL=$LABEL)" >&2
      exit 1
    fi

    if [[ -n "$LABEL" ]]; then
      echo "workstation-format-home: ambiguous blkid state on $HOME_DISK (blank TYPE, LABEL=$LABEL); refusing to format" >&2
      exit 1
    fi

    set +e
    WIPEFS_OUTPUT="$(wipefs -n "$HOME_DISK" 2>/dev/null)"
    WIPEFS_RC=$?
    set -e
    if [[ "$WIPEFS_RC" -ne 0 ]]; then
      echo "workstation-format-home: wipefs failed with exit code $WIPEFS_RC on $HOME_DISK; refusing to format" >&2
      exit 1
    fi

    if [[ -n "$WIPEFS_OUTPUT" ]]; then
      echo "workstation-format-home: ambiguous blank TYPE but signatures detected on $HOME_DISK; refusing to format" >&2
      echo "$WIPEFS_OUTPUT" >&2
      exit 1
    fi

    echo "workstation-format-home: formatting blank disk $HOME_DISK as ext4 label=home"
    mkfs.ext4 -F -L home "$HOME_DISK"

    TMP_DIR="$(mktemp -d)"
    cleanup() {
      mountpoint -q "$TMP_DIR" && umount "$TMP_DIR" || true
      rmdir "$TMP_DIR" 2>/dev/null || true
    }
    trap cleanup EXIT

    mount -o ro -t ext4 "$HOME_DISK" "$TMP_DIR"
    echo "workstation-format-home: verified read-only mount after format"
    umount "$TMP_DIR"
  '';

  workstationUserBootstrap = pkgs.writeShellScript "workstation-user-bootstrap" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.coreutils
      pkgs.glibc.getent
      pkgs.shadow
    ]}:$PATH

    USERNAME_FILE="/run/secrets/workstation/username"
    SHELL_FILE="/run/secrets/workstation/shell"
    SSH_KEY_FILE="/run/secrets/workstation/ssh-authorized-key"

    read_trimmed() {
      tr -d '\r\n' < "$1"
    }

    [[ -s "$USERNAME_FILE" ]] || {
      echo "workstation-user-bootstrap: missing $USERNAME_FILE" >&2
      exit 1
    }
    [[ -s "$SHELL_FILE" ]] || {
      echo "workstation-user-bootstrap: missing $SHELL_FILE" >&2
      exit 1
    }
    [[ -s "$SSH_KEY_FILE" ]] || {
      echo "workstation-user-bootstrap: missing $SSH_KEY_FILE" >&2
      exit 1
    }

    USERNAME="$(read_trimmed "$USERNAME_FILE")"
    SHELL_NAME="$(read_trimmed "$SHELL_FILE")"
    SSH_KEY_CONTENT="$(cat "$SSH_KEY_FILE")"

    case "$SHELL_NAME" in
      zsh) SHELL_PATH="${pkgs.zsh}/bin/zsh" ;;
      bash) SHELL_PATH="${pkgs.bashInteractive}/bin/bash" ;;
      *)
        echo "workstation-user-bootstrap: unsupported shell '$SHELL_NAME'" >&2
        exit 1
        ;;
    esac

    HOME_DIR="/home/$USERNAME"
    SSH_DIR="$HOME_DIR/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"

    if id "$USERNAME" >/dev/null 2>&1; then
      EXISTING_UID="$(id -u "$USERNAME")"
      if [[ "$EXISTING_UID" -ne 1000 ]]; then
        echo "workstation-user-bootstrap: $USERNAME already exists with UID $EXISTING_UID (expected 1000)" >&2
        exit 1
      fi
      usermod -s "$SHELL_PATH" -aG wheel "$USERNAME"
    else
      EXISTING_UID_1000="$(getent passwd 1000 | cut -d: -f1 || true)"
      if [[ -n "$EXISTING_UID_1000" ]]; then
        echo "workstation-user-bootstrap: UID 1000 already belongs to $EXISTING_UID_1000" >&2
        exit 1
      fi
      useradd -u 1000 -U -G wheel -d "$HOME_DIR" -M -s "$SHELL_PATH" "$USERNAME"
    fi

    if [[ ! -d "$HOME_DIR" ]]; then
      install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR"
    fi

    if [[ ! -d "$SSH_DIR" ]]; then
      install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "$SSH_DIR"
    fi

    if [[ ! -f "$AUTH_KEYS" ]]; then
      printf '%s\n' "$SSH_KEY_CONTENT" > "$AUTH_KEYS"
      chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
      chmod 0600 "$AUTH_KEYS"
    fi
  '';

  workstationHealthCheck = pkgs.writeShellScript "workstation-health-check" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.jq
      pkgs.util-linux
    ]}:$PATH

    USERNAME_FILE="/run/secrets/workstation/username"
    STATUS_DIR="/run/workstation-health"
    STATUS_FILE="$STATUS_DIR/status.json"
    HEALTHY_FLAG="$STATUS_DIR/healthy"
    MIN_FREE_PERCENT=5

    mkdir -p "$STATUS_DIR"

    USERNAME=""
    if [[ -s "$USERNAME_FILE" ]]; then
      USERNAME="$(tr -d '\r\n' < "$USERNAME_FILE")"
    fi

    HOME_MOUNTED=false
    HOME_FSTYPE=""
    HOME_SOURCE=""
    if mountpoint -q /home; then
      HOME_MOUNTED=true
      HOME_FSTYPE="$(findmnt -rn -o FSTYPE /home 2>/dev/null || true)"
      HOME_SOURCE="$(findmnt -rn -o SOURCE /home 2>/dev/null || true)"
    fi

    USER_HOME_EXISTS=false
    if [[ -n "$USERNAME" && -d "/home/$USERNAME" ]]; then
      USER_HOME_EXISTS=true
    fi

    DISK_FREE_PERCENT=-1
    DISK_OK=false
    if [[ "$HOME_MOUNTED" == true ]]; then
      USED_PERCENT="$(df -Pk /home 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }' || true)"
      if [[ "$USED_PERCENT" =~ ^[0-9]+$ ]]; then
        DISK_FREE_PERCENT=$((100 - USED_PERCENT))
        if [[ "$DISK_FREE_PERCENT" -ge "$MIN_FREE_PERCENT" ]]; then
          DISK_OK=true
        fi
      fi
    fi

    VAULT_AGENT_AUTHENTICATED=false
    if [[ -s /run/vault-agent/token ]]; then
      VAULT_AGENT_AUTHENTICATED=true
    fi

    NIX_SHELL_OK=false
    NIX_SHELL_OUTPUT=""
    set +e
    NIX_SHELL_OUTPUT="$(${pkgs.nix}/bin/nix-shell -p hello --run hello 2>&1)"
    NIX_SHELL_STATUS=$?
    set -e
    if [[ "$NIX_SHELL_STATUS" -eq 0 ]]; then
      NIX_SHELL_OK=true
    fi

    OVERALL=false
    if [[ "$HOME_MOUNTED" == true && "$USER_HOME_EXISTS" == true && "$DISK_OK" == true && "$NIX_SHELL_OK" == true && "$VAULT_AGENT_AUTHENTICATED" == true ]]; then
      OVERALL=true
    fi

    STATUS_TEXT="unhealthy"
    if [[ "$OVERALL" == true ]]; then
      STATUS_TEXT="healthy"
    fi

    TMP_FILE="$(mktemp)"
    jq -n \
      --arg checked_at "$(${pkgs.coreutils}/bin/date --iso-8601=seconds)" \
      --arg status "$STATUS_TEXT" \
      --arg username "$USERNAME" \
      --arg home_source "$HOME_SOURCE" \
      --arg home_fstype "$HOME_FSTYPE" \
      --arg nix_shell_output "$NIX_SHELL_OUTPUT" \
      --argjson home_mounted "$HOME_MOUNTED" \
      --argjson user_home_exists "$USER_HOME_EXISTS" \
      --argjson disk_ok "$DISK_OK" \
      --argjson disk_free_percent "$DISK_FREE_PERCENT" \
      --argjson nix_shell_ok "$NIX_SHELL_OK" \
      --argjson vault_agent_authenticated "$VAULT_AGENT_AUTHENTICATED" \
      '{
        status: $status,
        checked_at: $checked_at,
        username: $username,
        home: {
          mounted: $home_mounted,
          source: $home_source,
          fs_type: $home_fstype,
          user_home_exists: $user_home_exists,
          free_percent: $disk_free_percent,
          disk_ok: $disk_ok
        },
        nix: {
          shell_ok: $nix_shell_ok,
          output: $nix_shell_output
        },
        vault_agent_authenticated: $vault_agent_authenticated
      }' > "$TMP_FILE"
    mv "$TMP_FILE" "$STATUS_FILE"

    if [[ "$OVERALL" == true ]]; then
      touch "$HEALTHY_FLAG"
      exit 0
    fi

    rm -f "$HEALTHY_FLAG"
    exit 1
  '';

  workstationNginxCertLink = pkgs.writeShellScript "workstation-nginx-cert-link" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.inetutils
      pkgs.util-linux
    ]}:$PATH

    SEARCH_DOMAIN="$(cat /run/secrets/network/search-domain 2>/dev/null || true)"
    if [[ -z "$SEARCH_DOMAIN" ]]; then
      SEARCH_DOMAIN="$(awk '/^search / { print $2; exit }' /etc/resolv.conf)"
    fi
    if [[ -z "$SEARCH_DOMAIN" ]]; then
      echo "workstation-nginx-cert-link: no search domain found" >&2
      exit 1
    fi

    FQDN="$(hostname).$SEARCH_DOMAIN"
    CERT_DIR="/etc/letsencrypt/live/$FQDN"
    TIMEOUT=900
    ELAPSED=0

    while [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/privkey.pem" ]]; do
      if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
        echo "workstation-nginx-cert-link: certificate not available after ''${TIMEOUT}s" >&2
        exit 1
      fi
      sleep 5
      ELAPSED=$((ELAPSED + 5))
    done

    chmod 755 /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive
    mkdir -p /etc/letsencrypt/live
    ln -sfn "$CERT_DIR" /etc/letsencrypt/live/workstation
    find /etc/letsencrypt/archive -name 'privkey*.pem' -exec chgrp nginx {} + 2>/dev/null || true
    find /etc/letsencrypt/archive -name 'privkey*.pem' -exec chmod 640 {} + 2>/dev/null || true
  '';
in
{
  imports = [
    ../../nix/modules/certbot.nix
    ../../nix/modules/tailscale.nix
    ../../nix/modules/vault-agent.nix
  ];

  config = {
    vaultAgent.enable = true;

    programs.zsh.enable = true;

    environment.shells = [
      pkgs.bashInteractive
      pkgs.zsh
    ];

    environment.systemPackages = with pkgs; [
      curl
      emacs-nox
      git
      home-manager
      htop
      openssh
      tmux
      wget
      xorg.xauth
      zsh
    ];

    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "root" "@wheel" ];
    };

    services.openssh.settings.X11Forwarding = true;
    services.openssh.extraConfig = lib.mkAfter ''
      XAuthLocation /run/current-system/sw/bin/xauth
    '';

    fileSystems."/home" = {
      device = "/dev/disk/by-label/home";
      fsType = "ext4";
      options = [
        "nofail"
        "x-systemd.device-timeout=30s"
      ];
    };

    fileSystems."/var/lib/data" = lib.mkForce {
      device = "none";
      fsType = "none";
      options = [ "noauto" ];
    };

    systemd.services.workstation-format-home = {
      description = "Format and verify the workstation /home disk";
      wantedBy = [ "home.mount" ];
      before = [ "home.mount" ];
      wants = [ "systemd-udev-settle.service" ];
      after = [ "systemd-udev-settle.service" "local-fs-pre.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = workstationFormatHome;
      };
    };

    systemd.services.workstation-user-bootstrap = {
      description = "Create the workstation user and install the initial SSH key";
      wantedBy = [ "multi-user.target" ];
      before = [ "sshd.service" "workstation-health-check.service" ];
      after = [ "home.mount" "nocloud-init.service" ];
      requires = [ "home.mount" "nocloud-init.service" ];
      # Keep SSH bootstrap available on first deploy. Preboot restore now
      # populates /home before the workstation starts when backup state exists.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = workstationUserBootstrap;
      };
    };

    systemd.services.workstation-health-check = {
      description = "Run the workstation functional health check";
      wantedBy = [ "multi-user.target" ];
      after = [
        "home.mount"
        "network-online.target"
        "vault-agent.service"
        "workstation-user-bootstrap.service"
      ];
      wants = [ "network-online.target" "vault-agent.service" ];
      requires = [ "home.mount" "workstation-user-bootstrap.service" ];
      # The health check runs `nix-shell -p hello --run hello` to verify
      # the workstation is actually usable for dev work. nix-shell resolves
      # `-p hello` via `<nixpkgs>`, which needs NIX_PATH. Login shells get
      # NIX_PATH from /etc/profile; systemd units don't source profile, so
      # the variable must be set explicitly in the unit's Environment.
      # Without it, nix-shell fails with "file 'nixpkgs' was not found in
      # the Nix search path" and the whole health check reports unhealthy
      # even when every other sub-check passes.
      environment.NIX_PATH = "nixpkgs=flake:nixpkgs:/nix/var/nix/profiles/per-user/root/channels";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = workstationHealthCheck;
      };
    };

    systemd.timers.workstation-health-check = {
      description = "Refresh workstation health status";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "60s";
        AccuracySec = "1s";
      };
    };

    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      virtualHosts."workstation-health" = {
        listen = [
          { addr = "0.0.0.0"; port = 8443; ssl = true; }
        ];
        onlySSL = true;
        sslCertificate = "/etc/letsencrypt/live/workstation/fullchain.pem";
        sslCertificateKey = "/etc/letsencrypt/live/workstation/privkey.pem";

        locations."= /status" = {
          extraConfig = ''
            if (!-f /run/workstation-health/healthy) {
              return 503;
            }
            if (!-f /run/workstation-health/status.json) {
              return 503;
            }
            default_type application/json;
            add_header Cache-Control "no-store";
            alias /run/workstation-health/status.json;
          '';
        };
      };
    };

    systemd.services.workstation-nginx-cert-link = {
      description = "Wait for the workstation certificate and expose a stable nginx path";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      after = [ "nocloud-init.service" "network-online.target" "certbot-initial.service" ];
      wants = [ "network-online.target" ];
      requires = [ "nocloud-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = workstationNginxCertLink;
      };
    };

    systemd.services.nginx.after = [ "workstation-nginx-cert-link.service" ];
    systemd.services.nginx.requires = [ "workstation-nginx-cert-link.service" ];

    networking.firewall.allowedTCPPorts = [ 8443 ];
  };
}
