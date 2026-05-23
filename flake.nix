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

      # Overlay: bump the libburnia stack (libburn, libisofs, libisoburn)
      # from nixpkgs-24.11's 1.5.6 to upstream 1.5.8. libisoburn 1.5.6
      # has a non-deterministic SOURCE_DATE_EPOCH handling bug: the GMT
      # offset byte (offset 24) in every ISO9660 directory record's
      # recording-date field flips between 15 and 16 across xorriso
      # processes instead of being 0 (UTC). Surfaced in the paia
      # determinism test (tests/test_paia_packaging.sh s037.0.4) at
      # ~20% failure rate. 1.5.8 honors SDE=0 correctly. All three
      # libraries must be bumped together — libisoburn 1.5.8 has a
      # compile-time guard that aborts if libisofs.h or libburn.h are
      # older. Tarballs are mirrored on dev.lovelyhq.com (the libburnia
      # project's Gitea). Track #383 will move these to an internal
      # mirror as part of broader sovereignty work.
      libburniaOverlay = final: prev:
        let bump = pkg: hash:
          pkg.overrideAttrs (old: rec {
            version = "1.5.8";
            src = prev.fetchurl {
              url = "https://dev.lovelyhq.com/libburnia/${pkg.pname}/archive/release-${version}.tar.gz";
              inherit hash;
            };
          });
        in {
          libburn = bump prev.libburn "sha256-iy9PALNRG9a1JAtV3IYMCz+9ru3yhqH8p3hkEsg0ocE=";
          libisofs = bump prev.libisofs "sha256-mvriDB2ugskXkBqkZcv7bpFfJYYH+uBPMRfiOz0x0ZE=";
          libisoburn = bump prev.libisoburn "sha256-aumPSRTzbo+h//7kTx6TMe74ym9nY2iakPsN+JMHTG8=";
        };

      pkgsHostTools = import nixpkgs {
        system = imageSystem;
        overlays = [ libburniaOverlay ];
      };
      pkgsUnstable = import nixpkgs-unstable {
        system = imageSystem;
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [ "vault" ];
      };
      hostToolPackages = import "${self}/framework/nix/pkgs" {
        pkgs = pkgsHostTools;
      };
      hilBootRootPassword = builtins.getEnv "MYCOFU_HIL_BOOT_ROOT_PASSWORD";
      extraSpecialArgsBase = {
        vaultPackage = pkgsUnstable.vault;
        meshcmdPackage = hostToolPackages.meshcmd;
        paiaPackage = hostToolPackages.paia;
      };
      # Overlay: pull opentofu from nixpkgs-unstable, plus the shared
      # libburnia 1.5.8 bump so VM image evaluations see the same
      # xorriso version as host-side paia/per-node-ISO builds. The
      # vendored bpg/proxmox provider is delivered separately (as a
      # derivation in systemPackages, via TF_CLI_CONFIG_FILE) rather
      # than through opentofu.withPlugins, because withPlugins wraps
      # each provider binary in a bash shim and OpenTofu would hash
      # the shim — never matching the upstream package hash recorded
      # in .terraform.lock.hcl. See
      # framework/nix/lib/bpg-proxmox-provider.nix for the mechanism.
      opentofuOverlay = { nixpkgs.overlays = [
        (final: prev: { opentofu = pkgsUnstable.opentofu; })
        libburniaOverlay
      ]; };

      # Exposed as a flake package so the cicd runner module and the
      # devShell can both consume the same vendored provider derivation
      # via their respective `pkgs` views.
      bpgProxmoxProviderFor = pkgs:
        pkgs.callPackage "${nixSrc}/framework/nix/lib/bpg-proxmox-provider.nix" { };

      # Systems for devShell. Includes aarch64-darwin for Apple Silicon
      # workstations — the bpg/proxmox provider derivation has a
      # darwin_arm64 release pinned, and the .terraform.lock.hcl
      # includes its h1: hash.
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Filtered source: only nix-related files affect image derivation hashes.
      # Without this filter, ANY tracked file change (CLAUDE.md, .gitlab-ci.yml,
      # etc.) changes the flake source hash, changing all derivation hashes and
      # image filenames, triggering VM recreation on every commit.
      mkNixSrc = includeHil: builtins.path {
        name = "nix-source";
        path = self;
        filter = path: type:
          let
            relPath = nixpkgs.lib.removePrefix (toString self + "/") (toString path);
            isHostToolPackage =
              relPath == "framework/nix/pkgs" ||
              nixpkgs.lib.hasPrefix "framework/nix/pkgs/" relPath;
          in
            !isHostToolPackage && (
              type == "directory" ||
              nixpkgs.lib.hasPrefix "framework/nix/" relPath ||
              nixpkgs.lib.hasPrefix "framework/catalog/" relPath || # catalog modules and static dashboard assets
              nixpkgs.lib.hasPrefix "framework/step-ca/" relPath ||
              nixpkgs.lib.hasPrefix "framework/scripts/certbot-" relPath ||
              relPath == "framework/scripts/cert-sync.sh" ||
              relPath == "framework/scripts/certbot-initial-wrapper.sh" ||
              relPath == "framework/scripts/vdb-state-lib.sh" ||
              (includeHil && nixpkgs.lib.hasPrefix "tests/hil/" relPath) ||
              nixpkgs.lib.hasPrefix "site/nix/" relPath ||
              nixpkgs.lib.hasPrefix "site/apps/" relPath ||
              (includeHil && relPath == "site/config.yaml") ||
              nixpkgs.lib.hasPrefix "benchmarks/grafana/" relPath ||
              relPath == "flake.nix" ||
              relPath == "flake.lock"
            );
      };

      # Keep HIL fixtures out of ordinary image inputs so bfnet config changes
      # only perturb hil-boot derivations.
      nixSrc = mkNixSrc false;
      hilNixSrc = mkNixSrc true;
      hilBootConfigured =
        builtins.pathExists "${hilNixSrc}/tests/hil/bfnet/config.yaml" &&
        builtins.pathExists "${hilNixSrc}/site/nix/hosts/hil-boot.nix";

      sourceForRole = role: if role == "hil-boot" then hilNixSrc else nixSrc;

      roleModulesFor = src: {
        base = [ "${src}/framework/nix/modules/base.nix" ];
        dns = [ "${src}/site/nix/hosts/dns.nix" ];
        acme-dev = [ "${src}/site/nix/hosts/acme-dev.nix" ];
        vault = [ "${src}/site/nix/hosts/vault.nix" ];
        gitlab = [ "${src}/site/nix/hosts/gitlab.nix" ];
        cicd = [ "${src}/site/nix/hosts/cicd.nix" ];
        hil-boot = [ "${src}/site/nix/hosts/hil-boot.nix" ];
        gatus = [ "${src}/site/nix/hosts/gatus.nix" ];
        testapp = [ "${src}/site/nix/hosts/testapp.nix" ];
        influxdb = [ "${src}/site/nix/hosts/influxdb.nix" ];
        grafana = [ "${src}/site/nix/hosts/grafana.nix" ];
        roon = [ "${src}/site/nix/hosts/roon.nix" ];
        workstation = [ "${src}/site/nix/hosts/workstation.nix" ];
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
      } // nixpkgs.lib.optionalAttrs hilBootConfigured {
        hil_boot = "hil-boot";
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
      } // nixpkgs.lib.optionalAttrs hilBootConfigured {
        hil-boot-image = "hil-boot";
      };

      hilBootArtifacts = if hilBootConfigured then import "${nixSrc}/site/nix/lib/hil-boot-artifacts.nix" {
        pkgs = pkgsHostTools;
        lib = nixpkgs.lib;
        nixSrc = hilNixSrc;
        rootPassword = hilBootRootPassword;
        paiaPackage = hostToolPackages.paia;
      } else null;

      hilBootIsoPackages = if hilBootConfigured then
        nixpkgs.lib.listToAttrs (map (nodeName: {
          name = "hil-boot-${nodeName}-iso";
          value = hilBootArtifacts.perNodeIsos.${nodeName};
        }) hilBootArtifacts.nodeNames)
      else {};

      hilBootBootIpxePackages = if hilBootConfigured then
        nixpkgs.lib.listToAttrs (map (nodeName: {
          name = "hil-boot-${nodeName}-boot-ipxe";
          value = hilBootArtifacts.bootIpxe.${nodeName};
        }) hilBootArtifacts.nodeNames)
      else {};

      hilBootServiceArtifactPackages = if hilBootConfigured then {
        hil-boot-dnsmasq-conf = hilBootArtifacts.dnsmasqConf;
        hil-boot-linux26 = hilBootArtifacts.linux26;
        hil-boot-initrd-img = hilBootArtifacts.initrd;
      } else {};

      extraSpecialArgsFor = role:
        extraSpecialArgsBase
        // nixpkgs.lib.optionalAttrs (role == "hil-boot") {
          hilBootArtifacts = hilBootArtifacts;
        };

      mkVmModules = role:
      let
        src = sourceForRole role;
        roleModules = roleModulesFor src;
      in [
        opentofuOverlay
        "${src}/framework/nix/lib/vm-runtime.nix"
      ] ++ roleModules.${role};

      mkVmSystem = role: nixpkgs.lib.nixosSystem {
        system = imageSystem;
        specialArgs = extraSpecialArgsFor role;
        modules = mkVmModules role;
      };

      mkImage = role: import "${sourceForRole role}/framework/nix/lib/make-image.nix" {
        inherit nixpkgs;
        extraSpecialArgs = extraSpecialArgsFor role;
        system = imageSystem;
        modules = mkVmModules role;
      };
    in
    {
      # NixOS system configurations (for closure builds and nix eval / repl).
      nixosConfigurations =
        nixpkgs.lib.mapAttrs (_: role: mkVmSystem role) configurationRoles;

      # VM image builds (linux-only) + the bpg/proxmox provider
      # derivation, exposed per-system so tests/test_sovereign_tofu_init.sh
      # can `nix build` it directly. The test must work on a fresh
      # runner whose cicd image hasn't yet been rebuilt with the new
      # TF_CLI_CONFIG_FILE wiring — building the provider explicitly
      # decouples the test from the deploy order.
      packages = forAllSystems (system:
        {
          bpg-proxmox-provider =
            bpgProxmoxProviderFor nixpkgs.legacyPackages.${system};
        }
        // (if system == imageSystem then
              (nixpkgs.lib.mapAttrs (_: role: mkImage role) imageRoles)
              // hilBootIsoPackages
              // hilBootBootIpxePackages
              // hilBootServiceArtifactPackages
              // hostToolPackages
            else { })
      );

      # Build-time checks
      checks.${imageSystem} = {
        source-filter = import "${nixSrc}/framework/nix/checks/source-filter-check.nix" {
          inherit nixSrc;
          pkgs = nixpkgs.legacyPackages.${imageSystem};
        };
      };

      # Development shell with all required tooling. opentofu comes from
      # nixpkgs-unstable, and the bpg/proxmox provider is delivered via
      # TF_CLI_CONFIG_FILE pointing at a Nix-built terraformrc that
      # configures a filesystem mirror at the provider derivation's
      # output. `tofu init` on the workstation reads the provider from
      # the local nix-store and does not contact registry.opentofu.org
      # or github.com — same sovereignty regime as the cicd runner.
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pkgsUnstableForShell = import nixpkgs-unstable { inherit system; };
          bpgProxmoxProvider = bpgProxmoxProviderFor pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgsUnstableForShell.opentofu
              bpgProxmoxProvider
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
              # Sovereignty: point tofu at the vendored bpg/proxmox
              # provider's filesystem mirror so `tofu init` never reaches
              # the OpenTofu registry or github.com.
              export TF_CLI_CONFIG_FILE="${bpgProxmoxProvider}/etc/terraformrc"
            '';
          };
        }
      );
    };
}
