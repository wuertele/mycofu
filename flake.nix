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
      # older. Sources come from dev.lovelyhq.com (the libburnia
      # project's Gitea).
      #
      # We fetch via `fetchFromGitea { forceFetchGit = true; }` — i.e.
      # `fetchgit` under the hood — rather than `fetchurl` on the
      # `/archive/` endpoint. Gitea/Forgejo `/archive/` regenerates
      # the tarball at request time, so a server-side upgrade that
      # changes tar/gzip metadata (mtimes, uid/gid ordering,
      # compression parameters) changes the bytes for the same git
      # ref and breaks the pinned SHA256. See #461. `fetchgit`
      # hashes the canonicalized tree contents, not the tarball
      # bytes, so it is immune to that failure mode. Track #383 is
      # the longer-term sovereignty work to also remove the runtime
      # dependency on dev.lovelyhq.com entirely.
      libburniaOverlay = final: prev:
        let bump = pkg: hash:
          pkg.overrideAttrs (old: rec {
            version = "1.5.8";
            src = final.fetchFromGitea {
              domain = "dev.lovelyhq.com";
              owner = "libburnia";
              repo = pkg.pname;
              # `tag = ...` resolves to `refs/tags/<tag>` in fetchgit,
              # documenting intent (this is a release tag, not a raw
              # commit rev) and avoiding branch/tag ambiguity if a
              # same-named branch ever appears upstream.
              tag = "release-${version}";
              forceFetchGit = true;
              inherit hash;
            };
          });
        in {
          libburn = bump prev.libburn "sha256-W/9dUUQGB1V76G9YshNjJcrptAuVVcsXiM5ZQ9Q50Xs=";
          libisofs = bump prev.libisofs "sha256-tOkJfS/utUPn38rn0u5zAo1N4IIkvpejg89Oxw6Xqv4=";
          libisoburn = bump prev.libisoburn "sha256-imIi4I3ve46dunVz7tUnlpMV8wBVsH4sccNUjjQhpy8=";
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
      # systemd 256 leaks PID 1 BPF map/program FDs when
      # DefaultIPAccounting=yes and short-lived service units churn. NixOS
      # enables DefaultIPAccounting by default, and Mycofu relies on that
      # standard behavior being safe. Backport upstream
      # 5a8c2c95598f17fb79cca07365e70e54a7abcc88 onto the NixOS 24.11 systemd
      # package instead of swapping in an unstable-release systemd; the latter
      # crashed in NixOS stage 1 during post-merge dev deployment. See
      # root/mycofu#422.
      systemdBpfFdLeakPatch =
        "${sharedSrc}/framework/nix/patches/systemd-256-bpf-firewall-close-cgroup-runtime.patch";
      systemdNeedsBpfFdLeakBackport =
        !nixpkgs.lib.versionAtLeast pkgsHostTools.systemd.version "257";
      fixedSystemdPackage =
        if systemdNeedsBpfFdLeakBackport then
          pkgsHostTools.systemd.overrideAttrs (old: {
            patches = (old.patches or []) ++ [
              systemdBpfFdLeakPatch
            ];
            passthru = (old.passthru or {}) // {
              mycofuBpfFdLeakFix = true;
            };
          })
        else
          pkgsHostTools.systemd;
      extraSpecialArgsBase = {
        vaultPackage = pkgsUnstable.vault;
        meshcmdPackage = hostToolPackages.meshcmd;
        paiaPackage = hostToolPackages.paia;
        systemdPackage = fixedSystemdPackage;
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
        pkgs.callPackage "${hostToolSrc}/framework/nix/lib/bpg-proxmox-provider.nix" { };

      # Systems for devShell. Includes aarch64-darwin for Apple Silicon
      # workstations — the bpg/proxmox provider derivation has a
      # darwin_arm64 release pinned, and the .terraform.lock.hcl
      # includes its h1: hash.
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Filtered image sources: every role gets the shared base plus only
      # its own host/catalog/app paths. Directory inclusion is limited to
      # ancestors of wanted files so unrelated empty directories cannot
      # perturb image hashes. Required under-inclusion fails during Nix eval
      # or build; optional-content presence is asserted by flake checks.
      isHostToolPackage = relPath:
        relPath == "framework/nix/pkgs" ||
        nixpkgs.lib.hasPrefix "framework/nix/pkgs/" relPath;

      isHostToolOnlyNixFile = relPath:
        relPath == "framework/nix/lib/bpg-proxmox-provider.nix";

      sharedFile = relPath:
        (nixpkgs.lib.hasPrefix "framework/nix/" relPath &&
          !isHostToolPackage relPath &&
          !isHostToolOnlyNixFile relPath) ||
        nixpkgs.lib.hasPrefix "framework/step-ca/" relPath ||
        nixpkgs.lib.hasPrefix "framework/scripts/certbot-" relPath ||
        relPath == "framework/scripts/cert-sync.sh" ||
        relPath == "framework/scripts/certbot-initial-wrapper.sh" ||
        relPath == "framework/scripts/vdb-state-lib.sh" ||
        relPath == "flake.nix" ||
        relPath == "flake.lock";

      ensureSlash = s:
        if nixpkgs.lib.hasSuffix "/" s then s else "${s}/";

      dirOnPathToWanted = relPath: wanted:
        nixpkgs.lib.any (w:
             nixpkgs.lib.hasPrefix (ensureSlash w) (ensureSlash relPath)
          || nixpkgs.lib.hasPrefix (ensureSlash relPath) (ensureSlash w)
        ) wanted;

      fileMatchesWanted = relPath: wanted:
        nixpkgs.lib.any (w:
             relPath == w
          || nixpkgs.lib.hasPrefix (ensureSlash w) (ensureSlash relPath)
        ) wanted;

      extraRoleSubtrees = {
        cicd = [ "framework/nix/lib/bpg-proxmox-provider.nix" ];
        influxdb = [ "framework/catalog/cluster-dashboard/" ];
        grafana = [ "benchmarks/grafana/" ];
        "hil-boot" = [
          "tests/hil/"
          "site/config.yaml"
          "site/nix/lib/hil-boot-artifacts.nix"
        ];
      };

      roleWantedPaths = role:
        (nixpkgs.lib.filter
          (p: builtins.pathExists "${toString self}/${p}")
          [
            "site/nix/hosts/${role}.nix"
            "framework/catalog/${role}/"
            "site/apps/${role}/"
          ])
        ++ (nixpkgs.lib.filter
          (p: builtins.pathExists "${toString self}/${p}")
          (extraRoleSubtrees.${role} or []));

      sharedWantedPaths = [
        "framework/nix/"
        "framework/step-ca/"
        "framework/scripts/certbot-"
        "framework/scripts/cert-sync.sh"
        "framework/scripts/certbot-initial-wrapper.sh"
        "framework/scripts/vdb-state-lib.sh"
        "flake.nix"
        "flake.lock"
      ];

      mkFilteredSrc = name: extraWanted: extraFilePredicate: builtins.path {
        inherit name;
        path = self;
        filter = path: type:
          let
            pathString = toString path;
            relPath =
              if pathString == toString self then ""
              else nixpkgs.lib.removePrefix (toString self + "/") pathString;
            wanted = sharedWantedPaths ++ extraWanted;
          in
            if isHostToolPackage relPath then false
            else if type == "directory" then relPath == "" || dirOnPathToWanted relPath wanted
            else sharedFile relPath || extraFilePredicate relPath;
      };

      sharedSrc = mkFilteredSrc "nix-source-shared" [] (_: false);
      mkRoleSrc = role:
        let roleWanted = roleWantedPaths role;
        in mkFilteredSrc "nix-source-${role}" roleWanted (relPath: fileMatchesWanted relPath roleWanted);

      hostToolSrc = mkFilteredSrc "host-tool-source" [
        "framework/nix/lib/bpg-proxmox-provider.nix"
      ] (relPath: relPath == "framework/nix/lib/bpg-proxmox-provider.nix");

      hilBootConfigured =
        builtins.pathExists "${mkRoleSrc "hil-boot"}/tests/hil/bfnet/config.yaml" &&
        builtins.pathExists "${mkRoleSrc "hil-boot"}/site/nix/hosts/hil-boot.nix";

      sourceForRole = role: mkRoleSrc role;

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

      roleSrcs =
        nixpkgs.lib.genAttrs
          (nixpkgs.lib.unique (builtins.attrValues imageRoles))
          mkRoleSrc;

      hilBootArtifacts = if hilBootConfigured then import "${mkRoleSrc "hil-boot"}/site/nix/lib/hil-boot-artifacts.nix" {
        pkgs = pkgsHostTools;
        lib = nixpkgs.lib;
        nixSrc = mkRoleSrc "hil-boot";
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

      # hil-boot embeds one remastered Proxmox installer ISO per enabled
      # regreening node. The default 512M make-disk-image slack is too tight
      # once six ~1.8G ISOs are copied into /nix/store.
      imageAdditionalSpaceFor = role:
        if role == "hil-boot" then "8G" else "512M";

      mkImage = role: import "${sourceForRole role}/framework/nix/lib/make-image.nix" {
        inherit nixpkgs;
        extraSpecialArgs = extraSpecialArgsFor role;
        system = imageSystem;
        modules = mkVmModules role;
        additionalSpace = imageAdditionalSpaceFor role;
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
        source-filter = import "${sharedSrc}/framework/nix/checks/source-filter-check.nix" {
          inherit sharedSrc;
          pkgs = nixpkgs.legacyPackages.${imageSystem};
        };
        per-role-isolation = import "${sharedSrc}/framework/nix/checks/per-role-isolation-check.nix" {
          inherit roleSrcs sharedSrc;
          pkgs = nixpkgs.legacyPackages.${imageSystem};
        };
        systemd-bpf-fd-leak-package = fixedSystemdPackage;
        # Guard the libburniaOverlay: if a future refactor silently
        # regresses the overlay (drops the bump, mis-scopes it, drops
        # one of the three libraries), the paia determinism test
        # eventually catches it — but only probabilistically, and the
        # signal takes weeks to appear. This static check fails at
        # flake evaluation time. See #461.
        libburnia-overlay-applied = pkgsHostTools.runCommand
          "libburnia-overlay-applied" { } ''
            fail=0
            for pkgver in \
              "libburn:${pkgsHostTools.libburn.version}" \
              "libisofs:${pkgsHostTools.libisofs.version}" \
              "libisoburn:${pkgsHostTools.libisoburn.version}"; do
              name="''${pkgver%%:*}"
              ver="''${pkgver#*:}"
              if [ "$ver" != "1.5.8" ]; then
                echo "libburnia overlay defeated: $name.version = $ver (expected 1.5.8)" >&2
                fail=1
              fi
            done
            [ "$fail" -eq 0 ] || exit 1
            mkdir -p $out
            echo "libburn ${pkgsHostTools.libburn.version}"       >  $out/versions
            echo "libisofs ${pkgsHostTools.libisofs.version}"     >> $out/versions
            echo "libisoburn ${pkgsHostTools.libisoburn.version}" >> $out/versions
          '';
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
