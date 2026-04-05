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
            nixpkgs.lib.hasPrefix "framework/catalog/" relPath ||
            nixpkgs.lib.hasPrefix "framework/step-ca/" relPath ||
            nixpkgs.lib.hasPrefix "framework/scripts/certbot-" relPath ||
            nixpkgs.lib.hasPrefix "site/nix/" relPath ||
            nixpkgs.lib.hasPrefix "site/apps/" relPath ||
            relPath == "flake.nix" ||
            relPath == "flake.lock";
      };
    in
    {
      # NixOS system configuration (for inspection via nix eval / nix repl)
      nixosConfigurations.base = nixpkgs.lib.nixosSystem {
        system = imageSystem;
        modules = [ "${nixSrc}/framework/nix/modules/base.nix" ];
      };

      # VM image builds (linux-only)
      packages.${imageSystem} = let
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
        mkImage = modules: import "${nixSrc}/framework/nix/lib/make-image.nix" {
          inherit nixpkgs system extraSpecialArgs;
          modules = [ opentofuOverlay ] ++ modules; # nixSrc: overlay is a pure value, not a file path
        };
        system = imageSystem;
      in {
        base-image    = mkImage [ "${nixSrc}/framework/nix/modules/base.nix" ];
        dns-image     = mkImage [ "${nixSrc}/site/nix/hosts/dns.nix" ];
        acme-dev-image = mkImage [ "${nixSrc}/site/nix/hosts/acme-dev.nix" ];
        vault-image   = mkImage [ "${nixSrc}/site/nix/hosts/vault.nix" ];
        gitlab-image  = mkImage [ "${nixSrc}/site/nix/hosts/gitlab.nix" ];
        cicd-image    = mkImage [ "${nixSrc}/site/nix/hosts/cicd.nix" ];
        gatus-image   = mkImage [ "${nixSrc}/site/nix/hosts/gatus.nix" ];
        testapp-image = mkImage [ "${nixSrc}/site/nix/hosts/testapp.nix" ];
        influxdb-image = mkImage [ "${nixSrc}/site/nix/hosts/influxdb.nix" ];
        grafana-image  = mkImage [ "${nixSrc}/site/nix/hosts/grafana.nix" ];
        roon-image     = mkImage [ "${nixSrc}/site/nix/hosts/roon.nix" ];
      };

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
