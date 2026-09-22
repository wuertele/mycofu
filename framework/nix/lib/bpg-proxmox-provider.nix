# Vendored bpg/proxmox OpenTofu provider, pinned to a specific upstream
# release. The provider binary is fetched from github.com at Nix build
# time only — once, by Nix, before the image is built. At `tofu init`
# time on the cicd runner or the workstation, the provider is already
# in the nix store. The wrapper `terraformrc` directs OpenTofu to a
# filesystem mirror pointing at this nix-store derivation; tofu never
# reaches registry.opentofu.org or github.com.
#
# We deliberately do NOT use `opentofu.withPlugins`: that mechanism
# wraps the provider binary in a ~280-byte bash shim, and OpenTofu
# would then verify the shim's hash against `.terraform.lock.hcl` —
# which would never match the upstream package recorded in the lock.
# A `filesystem_mirror` exposes the real binary at the layout tofu
# expects (`<source-address>/<version>/<os>_<arch>/`), and the binary
# is byte-identical to upstream so the lock-file `h1:` matches.
#
# Output layout:
#   $out/libexec/terraform-providers/registry.opentofu.org/bpg/proxmox/<version>/<os>_<arch>/terraform-provider-proxmox_v<version>
#   $out/etc/terraformrc   — points tofu at $out/libexec/... as a mirror
#
# Consumers:
#   - flake.nix devShell shellHook exports TF_CLI_CONFIG_FILE to
#     ${this-derivation}/etc/terraformrc
#   - framework/nix/modules/gitlab-runner.nix sets the same env var
#     in the gitlab-runner systemd unit so pipeline jobs inherit it
#
# To bump the provider version:
#   1. Update `version` below.
#   2. Update the per-platform hashes (use `nix-prefetch-url --unpack`
#      against each release URL and convert with
#      `nix hash convert --hash-algo sha256 --to sri`).
#   3. Run `tofu providers lock -platform=linux_amd64
#      -platform=darwin_amd64 -platform=darwin_arm64` from inside the
#      repo to refresh `framework/tofu/root/.terraform.lock.hcl` with
#      the new version's hashes.
#   4. Rebuild the cicd image and run
#      `tests/test_sovereign_tofu_init.sh` to verify `tofu init` still
#      works with HTTPS_PROXY pointed at a dead address.
{ stdenv, lib, fetchzip }:

let
  pname = "terraform-provider-proxmox-bpg";
  version = "0.101.1";
  providerSourceAddress = "registry.opentofu.org/bpg/proxmox";

  # Per-platform binary releases from upstream.
  platforms = {
    "x86_64-linux" = {
      goPlatform = "linux_amd64";
      hash = "sha256-FY1q0Su15Knd/00cSp+mQrcvFCVOFI/4MguNfF10opo=";
    };
    "x86_64-darwin" = {
      goPlatform = "darwin_amd64";
      hash = "sha256-8jroMkWo5lK4qTRwMypO4O3A7K+CdTpJM3vLkZLs9CY=";
    };
    "aarch64-darwin" = {
      goPlatform = "darwin_arm64";
      hash = "sha256-8HwtCEwEjJRCaUdlIYhxY9dpm/Pt2rPevfdYPPhHnNs=";
    };
  };

  current = platforms.${stdenv.hostPlatform.system}
    or (throw "${pname}: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  inherit pname version;

  src = fetchzip {
    url = "https://github.com/bpg/terraform-provider-proxmox/releases/download/v${version}/terraform-provider-proxmox_${version}_${current.goPlatform}.zip";
    inherit (current) hash;
    stripRoot = false;
  };

  dontConfigure = true;
  dontBuild = true;

  # Keep the upstream binary byte-identical: macOS stdenv's fixupPhase
  # would otherwise strip the Mach-O code signature (8 bytes), and Linux
  # stdenv's stripPhase would strip Go debug info. Either would change
  # the binary's hash and make it diverge from the upstream package that
  # `.terraform.lock.hcl` records — which would make `tofu init` reject
  # the local copy as a checksum mismatch.
  dontStrip = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    # Copy ALL files from the upstream zip (CHANGELOG.md, LICENSE,
    # README.md, and the binary). OpenTofu's `h1:` hash is
    # `dirhash.Hash1` over the unpacked directory contents — if we
    # only install the binary, the hash won't match the lock file's
    # h1 (which was computed against the full upstream zip).
    install_dir="$out/libexec/terraform-providers/${providerSourceAddress}/${version}/${current.goPlatform}"
    mkdir -p "$install_dir"
    cp -r . "$install_dir/"
    chmod 0755 "$install_dir/terraform-provider-proxmox_v${version}"

    # Terraformrc fragment: filesystem_mirror is the ONLY provider
    # source. No `direct {}` block — that means OpenTofu has no fallback
    # to registry.opentofu.org for ANY provider, not just bpg/proxmox.
    # If a new provider is added to versions.tf without also being
    # vendored under framework/nix/lib/, `tofu init` will fail loudly
    # rather than silently reach the Internet. This is the sovereign
    # default (operator stated: "no dependency on anything not
    # explicitly allowed"); see issue #333.
    mkdir -p "$out/etc"
    cat > "$out/etc/terraformrc" <<EOF
provider_installation {
  filesystem_mirror {
    path = "$out/libexec/terraform-providers"
  }
}
EOF

    runHook postInstall
  '';

  passthru = {
    provider-source-address = providerSourceAddress;
    # `version` is exposed for the drift-guard test (see
    # tests/test_bpg_proxmox_version_drift.sh) — it compares this
    # against the version pinned in framework/tofu/root/versions.tf
    # and the locked version in .terraform.lock.hcl, so a future
    # bump that touches only one of the three sources fails CI.
    inherit version;
  };

  meta = {
    description = "OpenTofu provider for Proxmox VE (bpg fork), pinned for sovereign deploys";
    homepage = "https://github.com/bpg/terraform-provider-proxmox";
    license = lib.licenses.mpl20;
    platforms = lib.attrNames platforms;
  };
}
