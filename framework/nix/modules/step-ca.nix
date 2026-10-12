# step-ca.nix — Dev ACME server module.
#
# Runs Smallstep step-ca on the dev VLAN as the shared development ACME
# endpoint. The root CA is static and shipped in the repo; the intermediate
# is generated on first boot and recreated whenever the VM is recreated.
#
# The packaged step-ca build does not expose an authoritative DNS resolver
# override in the version targeted by this repo, so this module runs a tiny
# local dnsmasq forwarder on 127.0.0.1:53 that sends all lookups to the
# PowerDNS authoritative servers on port 8053. step-ca then uses the normal
# system resolver path without seeing recursor negative-cache behavior.

{ config, pkgs, lib, ... }:

let
  stateDir = "/var/lib/step-ca";
  rootCaCert = ../../../framework/step-ca/root-ca.crt;
  rootCaKey = ../../../framework/step-ca/root-ca.key;

  stepCaInit = pkgs.writeShellScript "step-ca-init" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.step-cli ]}:$PATH

    STATE_DIR="${stateDir}"
    CONFIG_FILE="$STATE_DIR/config/ca.json"
    INTERMEDIATE_PASSWORD_FILE="$STATE_DIR/secrets/intermediate-password.txt"
    PROVISIONER_PASSWORD_FILE="$STATE_DIR/secrets/provisioner-password.txt"

    if [ -s "$CONFIG_FILE" ] \
      && [ -s "$STATE_DIR/certs/intermediate_ca.crt" ] \
      && [ -s "$STATE_DIR/secrets/intermediate_ca_key" ]; then
      echo "step-ca already initialized"
      exit 0
    fi

    rm -rf \
      "$STATE_DIR/config" \
      "$STATE_DIR/certs" \
      "$STATE_DIR/db" \
      "$STATE_DIR/secrets" \
      "$STATE_DIR/templates"
    mkdir -p \
      "$STATE_DIR/config" \
      "$STATE_DIR/certs" \
      "$STATE_DIR/db" \
      "$STATE_DIR/secrets" \
      "$STATE_DIR/templates"

    printf '%s\n' 'mycofu-step-ca-intermediate' > "$INTERMEDIATE_PASSWORD_FILE"
    printf '%s\n' 'mycofu-step-ca-provisioner' > "$PROVISIONER_PASSWORD_FILE"
    chmod 0600 "$INTERMEDIATE_PASSWORD_FILE" "$PROVISIONER_PASSWORD_FILE"

    SEARCH_DOMAIN=$(tr -d '[:space:]' < /run/secrets/network/search-domain 2>/dev/null || true)
    DNS_ARGS=(--dns acme --dns localhost)
    if [ -n "$SEARCH_DOMAIN" ]; then
      DNS_ARGS+=(--dns "acme.$SEARCH_DOMAIN")
    fi

    export STEPPATH="$STATE_DIR"

    step ca init \
      --name "Mycofu Dev ACME" \
      --deployment-type standalone \
      --address ":14000" \
      --root ${rootCaCert} \
      --key ${rootCaKey} \
      --provisioner "mycofu-admin" \
      --password-file "$INTERMEDIATE_PASSWORD_FILE" \
      --provisioner-password-file "$PROVISIONER_PASSWORD_FILE" \
      "''${DNS_ARGS[@]}"

    step ca provisioner add acme \
      --type ACME \
      --ca-config "$CONFIG_FILE" \
      --x509-default-dur 2160h \
      --x509-max-dur 2160h

    chown -R step-ca:step-ca "$STATE_DIR"
    chmod 0700 "$STATE_DIR/secrets"
    chmod 0600 "$STATE_DIR/secrets/"*
    chmod 0644 "$STATE_DIR/certs/"*

    echo "step-ca initialized in $STATE_DIR"
  '';

  stepCaDnsForwarder = pkgs.writeShellScript "step-ca-dns-forwarder" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.dnsmasq ]}:$PATH

    DNS_FILE="/run/secrets/network/dns"
    if [ ! -s "$DNS_FILE" ]; then
      echo "ERROR: $DNS_FILE is missing or empty" >&2
      exit 1
    fi

    DNS_ARGS=()
    while IFS= read -r server; do
      server=$(echo "$server" | tr -d '[:space:]')
      [ -n "$server" ] && DNS_ARGS+=(--server="$server#8053")
    done < "$DNS_FILE"

    if [ "''${#DNS_ARGS[@]}" -eq 0 ]; then
      echo "ERROR: no DNS forwarders discovered for step-ca" >&2
      exit 1
    fi

    exec ${pkgs.dnsmasq}/bin/dnsmasq \
      --keep-in-foreground \
      --no-daemon \
      --no-resolv \
      --listen-address=127.0.0.1 \
      --bind-interfaces \
      --port=53 \
      --cache-size=0 \
      "''${DNS_ARGS[@]}"
  '';
in
{
  services.resolved.enable = lib.mkForce false;
  networking.nameservers = lib.mkForce [];

  users.groups.step-ca = {};
  users.users.step-ca = {
    isSystemUser = true;
    group = "step-ca";
    home = stateDir;
  };

  systemd.services.write-step-ca-resolv-conf = {
    description = "Write /etc/resolv.conf for step-ca";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" ];
    before = [ "step-ca-dns-forwarder.service" "step-ca-init.service" "step-ca.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "write-step-ca-resolv-conf" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

        SEARCH_DOMAIN=""
        if [ -s /run/secrets/network/search-domain ]; then
          SEARCH_DOMAIN=$(tr -d '[:space:]' < /run/secrets/network/search-domain)
        fi

        {
          echo "nameserver 127.0.0.1"
          [ -n "$SEARCH_DOMAIN" ] && echo "search $SEARCH_DOMAIN"
          echo "options edns0"
        } > /etc/resolv.conf

        echo "step-ca resolv.conf written (search=''${SEARCH_DOMAIN:-none})"
      '';
    };
  };

  systemd.services.step-ca-dns-forwarder = {
    description = "Local DNS forwarder for step-ca ACME validation";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" "write-step-ca-resolv-conf.service" ];
    wants = [ "network-online.target" ];
    requires = [ "write-step-ca-resolv-conf.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = stepCaDnsForwarder;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services.step-ca-init = {
    description = "Initialize step-ca state from the static root CA";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" "write-step-ca-resolv-conf.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" ];
    before = [ "step-ca.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = stepCaInit;
      UMask = "0077";
    };
  };

  systemd.services.step-ca = {
    description = "Smallstep ACME server";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "nocloud-init.service"
      "write-step-ca-resolv-conf.service"
      "step-ca-dns-forwarder.service"
      "step-ca-init.service"
    ];
    wants = [
      "network-online.target"
      "step-ca-dns-forwarder.service"
      "step-ca-init.service"
    ];
    requires = [ "step-ca-dns-forwarder.service" "step-ca-init.service" ];
    serviceConfig = {
      Type = "simple";
      User = "step-ca";
      Group = "step-ca";
      WorkingDirectory = stateDir;
      StateDirectory = "step-ca";
      ExecStart = "${pkgs.step-ca}/bin/step-ca ${stateDir}/config/ca.json --password-file ${stateDir}/secrets/intermediate-password.txt";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [ 14000 ];

  environment.systemPackages = [ pkgs.dnsmasq pkgs.step-ca pkgs.step-cli ];
}
