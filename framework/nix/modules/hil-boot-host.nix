{ lib
, pkgs
, meshcmdPackage ? null
, paiaPackage ? null
, hilBootArtifacts ? null
, ...
}:

let
  artifactRoot = "/var/lib/pxe-boot";
  nodeNames = hilBootArtifacts.nodeNames or [];
  linkNodeArtifacts = lib.concatMapStringsSep "\n" (nodeName: ''
    mkdir -p ${artifactRoot}/nodes/${nodeName}
    ln -sfn ${hilBootArtifacts.bootIpxe.${nodeName}} ${artifactRoot}/nodes/${nodeName}/boot.ipxe
    ln -sfn ${hilBootArtifacts.perNodeIsos.${nodeName}} ${artifactRoot}/nodes/${nodeName}/proxmox.iso
  '') nodeNames;

  hilBootStatus = pkgs.writeShellScriptBin "hil-boot-status" ''
    set -eu
    echo "hil-boot artifact root: ${artifactRoot}"
    echo "linux26: ${artifactRoot}/linux26"
    echo "initrd.img: ${artifactRoot}/initrd.img"
    echo "ipxe.efi: ${artifactRoot}/ipxe.efi"
    for node in ${lib.escapeShellArgs nodeNames}; do
      echo "node $node boot.ipxe: ${artifactRoot}/nodes/$node/boot.ipxe"
      echo "node $node proxmox.iso: ${artifactRoot}/nodes/$node/proxmox.iso"
    done
    systemctl --no-pager --plain is-active hil-boot-artifacts.service || true
    systemctl --no-pager --plain is-active hil-boot-dnsmasq.service || true
    systemctl --no-pager --plain is-active nginx.service || true
  '';
in
{
  assertions = [
    {
      assertion = meshcmdPackage != null;
      message = "hil-boot-host.nix requires the flake-provided meshcmdPackage special argument";
    }
    {
      assertion = paiaPackage != null;
      message = "hil-boot-host.nix requires the flake-provided paiaPackage special argument";
    }
    {
      assertion = hilBootArtifacts != null && nodeNames != [];
      message = "hil-boot-host.nix requires hilBootArtifacts with at least one node";
    }
  ];

  environment.systemPackages = [
    meshcmdPackage
    paiaPackage
    pkgs.curl
    pkgs.dnsmasq
    pkgs.ipxe
    pkgs.jq
    pkgs.openssh
    pkgs.yq-go
    hilBootStatus
  ];

  systemd.tmpfiles.rules = [
    "d /run/hil-boot 0755 root root - -"
    "d ${artifactRoot} 0755 root root - -"
  ];

  systemd.services.hil-boot-artifacts = {
    description = "Populate static hil-boot PXE artifact links";
    wantedBy = [ "multi-user.target" ];
    before = [ "hil-boot-dnsmasq.service" "nginx.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -eu
      rm -rf ${artifactRoot}
      mkdir -p ${artifactRoot}
      ln -sfn ${hilBootArtifacts.linux26} ${artifactRoot}/linux26
      ln -sfn ${hilBootArtifacts.initrd} ${artifactRoot}/initrd.img
      ln -sfn ${hilBootArtifacts.ipxeEfi} ${artifactRoot}/ipxe.efi
      ${linkNodeArtifacts}
    '';
  };

  systemd.services.hil-boot-dnsmasq = {
    description = "hil-boot static PXE dnsmasq";
    after = [ "network-online.target" "hil-boot-artifacts.service" ];
    requires = [ "hil-boot-artifacts.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=${hilBootArtifacts.dnsmasqConf}";
      Restart = "on-failure";
      RuntimeDirectory = "hil-boot";
    };
  };

  services.nginx = {
    enable = true;
    virtualHosts."hil-boot" = {
      listen = [
        { addr = "0.0.0.0"; port = 80; }
      ];
      root = artifactRoot;
      locations."/" = {
        extraConfig = ''
          limit_except GET HEAD { deny all; }
          try_files $uri =404;
        '';
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
  networking.firewall.allowedUDPPorts = [ 67 69 ];

  system.stateVersion = "24.11";
}
