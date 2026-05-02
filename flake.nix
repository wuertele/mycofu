{
  description = "Home infrastructure — NixOS VM images and development tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable }:
    let
      # Image builds are linux-only; devShell works on both
      imageSystem = "x86_64-linux";
      pkgsUnstable = import nixpkgs-unstable {
        system = imageSystem;
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "vault" ];
      };
      extraSpecialArgs = {
        vaultPackage = pkgsUnstable.vault;
      };
      # Overlay: pull opentofu from nixpkgs-unstable while keeping everything
      # else from nixos-24.11. Required for -exclude flag support in
      # safe-apply.sh (OpenTofu >= 1.9). The nixos-24.11 channel has 1.8.7.
      opentofuOverlay = { nixpkgs.overlays = [
        (final: prev: { opentofu = pkgsUnstable.opentofu; })
      ]; };

      # Systems for devShell
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Filtered source: only nix-related files affect image derivation hashes.
      # Without this filter, ANY tracked file change (CLAUDE.md, .gitlab-ci.yml,
      # etc.) changes the flake source hash, changing all derivation hashes and
      # image filenames, triggering VM recreation on every commit.
      nixSrc = builtins.path {
        name = "nix-source";
        path = self;
        filter = path: type:
          let
            relPath = nixpkgs.lib.removePrefix (toString self + "/") (toString path);
          in
            type == "directory" ||
            nixpkgs.lib.hasPrefix "framework/nix/" relPath ||
            nixpkgs.lib.hasPrefix "framework/catalog/" relPath || # catalog modules and static dashboard assets
            nixpkgs.lib.hasPrefix "framework/step-ca/" relPath ||
            nixpkgs.lib.hasPrefix "framework/scripts/certbot-" relPath ||
            relPath == "framework/scripts/cert-sync.sh" ||
            relPath == "framework/scripts/certbot-initial-wrapper.sh" ||
            relPath == "framework/scripts/vdb-state-lib.sh" ||
            nixpkgs.lib.hasPrefix "site/nix/" relPath ||
            nixpkgs.lib.hasPrefix "site/apps/" relPath ||
            nixpkgs.lib.hasPrefix "benchmarks/grafana/" relPath ||
            relPath == "flake.nix" ||
            relPath == "flake.lock";
      };

      roleModules = {
        base = [ "${nixSrc}/framework/nix/modules/base.nix" ];
        dns = [ "${nixSrc}/site/nix/hosts/dns.nix" ];
        acme-dev = [ "${nixSrc}/site/nix/hosts/acme-dev.nix" ];
        vault = [ "${nixSrc}/site/nix/hosts/vault.nix" ];
        gitlab = [ "${nixSrc}/site/nix/hosts/gitlab.nix" ];
        cicd = [ "${nixSrc}/site/nix/hosts/cicd.nix" ];
        gatus = [ "${nixSrc}/site/nix/hosts/gatus.nix" ];
        testapp = [ "${nixSrc}/site/nix/hosts/testapp.nix" ];
        influxdb = [ "${nixSrc}/site/nix/hosts/influxdb.nix" ];
        grafana = [ "${nixSrc}/site/nix/hosts/grafana.nix" ];
        roon = [ "${nixSrc}/site/nix/hosts/roon.nix" ];
        workstation = [ "${nixSrc}/site/nix/hosts/workstation.nix" ];
      };

      configurationRoles = {
        base = "base";
        acme_dev = "acme-dev";
        cicd = "cicd";
        dns_dev = "dns";
        dns_prod = "dns";
        gatus = "gatus";
        gitlab = "gitlab";
        grafana_dev = "grafana";
        grafana_prod = "grafana";
        influxdb_dev = "influxdb";
        influxdb_prod = "influxdb";
        roon_dev = "roon";
        roon_prod = "roon";
        testapp_dev = "testapp";
        testapp_prod = "testapp";
        vault_dev = "vault";
        vault_prod = "vault";
        workstation_dev = "workstation";
        workstation_prod = "workstation";
      };

      imageRoles = {
        base-image = "base";
        dns-image = "dns";
        acme-dev-image = "acme-dev";
        vault-image = "vault";
        gitlab-image = "gitlab";
        cicd-image = "cicd";
        gatus-image = "gatus";
        testapp-image = "testapp";
        influxdb-image = "influxdb";
        grafana-image = "grafana";
        roon-image = "roon";
        workstation-image = "workstation";
      };

      mkVmModules = role: [
        opentofuOverlay
        "${nixSrc}/framework/nix/lib/vm-runtime.nix"
      ] ++ roleModules.${role};

      mkVmSystem = role: nixpkgs.lib.nixosSystem {
        system = imageSystem;
        specialArgs = extraSpecialArgs;
        modules = mkVmModules role;
      };

      mkImage = role: import "${nixSrc}/framework/nix/lib/make-image.nix" {
        inherit nixpkgs extraSpecialArgs;
        system = imageSystem;
        modules = mkVmModules role;
      };
    in
    {
      # NixOS system configurations (for closure builds and nix eval / repl).
      nixosConfigurations =
        nixpkgs.lib.mapAttrs (_: role: mkVmSystem role) configurationRoles;

      # VM image builds (linux-only)
      packages.${imageSystem} =
        nixpkgs.lib.mapAttrs (_: role: mkImage role) imageRoles;

      # Build-time checks
      checks.${imageSystem} = {
        source-filter = import "${nixSrc}/framework/nix/checks/source-filter-check.nix" {
          inherit nixSrc;
          pkgs = nixpkgs.legacyPackages.${imageSystem};
        };
      };

      # Development shell with all required tooling
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.opentofu
              pkgs.sops
              pkgs.age
              pkgs.yq-go
              pkgs.jq
              pkgs.qemu
              pkgs.openssh
              pkgs.postgresql
            ];

            shellHook = ''
              # Set SOPS_AGE_KEY_FILE if the operator key exists at repo root
              if [ -f "./operator.age.key" ] && [ -z "''${SOPS_AGE_KEY_FILE:-}" ]; then
                export SOPS_AGE_KEY_FILE="$(pwd)/operator.age.key"
              fi
            '';
          };
        }
      );
    };
}
