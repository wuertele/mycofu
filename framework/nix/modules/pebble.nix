# pebble.nix — Pebble ACME test server module.
#
# Runs Pebble (Let's Encrypt's official ACME test server) on the dev VLAN.
# Dev VMs point certbot at Pebble for DNS-01 certificate issuance.
#
# Pebble validates challenges by querying the dev DNS servers (discovered
# from /etc/resolv.conf, set by DHCP).
#
# TLS: Pebble needs a TLS cert for its HTTPS endpoint. The nixpkgs pebble
# package only ships binaries, not the test certs. We generate a server
# cert at first boot using openssl, signed by the well-known Pebble test
# CA (whose cert and key are bundled in the repo at framework/pebble/).
# This CA cert is distributed to dev VMs via nocloud-init write_files so
# certbot trusts Pebble's HTTPS endpoint.
#
# Stateless: Category 1 — no precious state, fully rebuildable.

{ config, pkgs, lib, ... }:

let
  # The well-known Pebble test CA cert and key (public, from pebble source)
  pebbleCaCert = ../../../framework/pebble/pebble-ca.pem;
  pebbleCaKey = ../../../framework/pebble/pebble-ca.key.pem;

  pebbleConfig = pkgs.writeText "pebble-config.json" (builtins.toJSON {
    pebble = {
      listenAddress = "0.0.0.0:14000";
      managementListenAddress = "0.0.0.0:15000";
      certificate = "/var/lib/pebble/server-cert.pem";
      privateKey = "/var/lib/pebble/server-key.pem";
      httpPort = 5002;
      tlsPort = 5001;
      ocspResponderURL = "";
    };
  });

  # Script to generate a server TLS cert signed by the Pebble CA,
  # with SANs for the VM's current IP address and common hostnames
  generateCert = pkgs.writeShellScript "pebble-generate-cert" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.openssl pkgs.coreutils pkgs.gawk pkgs.iproute2 ]}:$PATH

    CERT_DIR=/var/lib/pebble
    mkdir -p "$CERT_DIR"

    # Skip if certs already exist and are non-empty
    if [ -s "$CERT_DIR/server-cert.pem" ] && [ -s "$CERT_DIR/server-key.pem" ]; then
      echo "Pebble server cert already exists, skipping generation"
      exit 0
    fi

    # Get VM's IP address from the first non-loopback interface
    MY_IP=$(ip -4 addr show scope global | awk '/inet / { split($2, a, "/"); print a[1]; exit }')
    if [ -z "$MY_IP" ]; then
      echo "ERROR: Could not determine VM IP address" >&2
      exit 1
    fi
    echo "Generating Pebble server cert for IP: $MY_IP"

    # Generate server key
    openssl genrsa -out "$CERT_DIR/server-key.pem" 2048

    # Create CSR config with SANs
    printf '%s\n' \
      "[req]" \
      "default_bits = 2048" \
      "prompt = no" \
      "distinguished_name = dn" \
      "req_extensions = v3_req" \
      "" \
      "[dn]" \
      "CN = pebble" \
      "" \
      "[v3_req]" \
      "subjectAltName = DNS:pebble,DNS:localhost,IP:$MY_IP,IP:127.0.0.1" \
      > "$CERT_DIR/server-csr.cnf"

    # Create extension config for signing
    printf '%s\n' \
      "[v3_ext]" \
      "subjectAltName = DNS:pebble,DNS:localhost,IP:$MY_IP,IP:127.0.0.1" \
      "keyUsage = digitalSignature, keyEncipherment" \
      "extendedKeyUsage = serverAuth" \
      > "$CERT_DIR/server-ext.cnf"

    # Generate CSR
    openssl req -new \
      -key "$CERT_DIR/server-key.pem" \
      -config "$CERT_DIR/server-csr.cnf" \
      -out "$CERT_DIR/server.csr"

    # Sign with the Pebble CA
    # Use -CAserial pointing to writable dir (CA cert is in read-only Nix store)
    openssl x509 -req \
      -in "$CERT_DIR/server.csr" \
      -CA ${pebbleCaCert} \
      -CAkey ${pebbleCaKey} \
      -CAserial "$CERT_DIR/ca.srl" -CAcreateserial \
      -out "$CERT_DIR/server-cert.pem" \
      -days 3650 \
      -extfile "$CERT_DIR/server-ext.cnf" \
      -extensions v3_ext

    # Clean up temp files
    rm -f "$CERT_DIR/server.csr" "$CERT_DIR/server-csr.cnf" "$CERT_DIR/server-ext.cnf"

    echo "Pebble server cert generated successfully"
  '';

  # Script to read DNS server from injected config for pebble -dnsserver flag
  pebbleStart = pkgs.writeShellScript "pebble-start" ''
    set -euo pipefail

    # Read authoritative DNS server from config (injected by nocloud-init)
    DNS_CONFIG="/run/pebble/dns-server"
    if [ -f "$DNS_CONFIG" ]; then
      DNS_SERVER=$(cat "$DNS_CONFIG" | tr -d '[:space:]')
    else
      echo "WARNING: $DNS_CONFIG not found, falling back to resolv.conf" >&2
      DNS_SERVER=$(${pkgs.gawk}/bin/awk '/^nameserver / { print $2; exit }' /etc/resolv.conf)
    fi

    if [ -z "$DNS_SERVER" ]; then
      echo "ERROR: No DNS server configured" >&2
      exit 1
    fi

    echo "Starting Pebble with DNS resolver: $DNS_SERVER:8053"
    exec ${pkgs.pebble}/bin/pebble \
      -config ${pebbleConfig} \
      -dnsserver "$DNS_SERVER:8053"
  '';
in
{
  # Pebble service
  systemd.services.pebble = {
    description = "Pebble ACME test server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" ];
    wants = [ "network-online.target" ];

    environment = {
      PEBBLE_VA_NOSLEEP = "1";
    };

    serviceConfig = {
      Type = "simple";
      StateDirectory = "pebble";
      ExecStartPre = [ "+${generateCert}" ];
      ExecStart = pebbleStart;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # Firewall: ACME directory (14000) and management (15000)
  networking.firewall.allowedTCPPorts = [ 14000 15000 ];

  environment.systemPackages = [ pkgs.pebble ];
}
