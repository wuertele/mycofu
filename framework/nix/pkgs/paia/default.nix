{ lib, stdenvNoCC, makeWrapper, bash, coreutils, gnused, xorriso }:

stdenvNoCC.mkDerivation rec {
  # Deliberately local shim: Sprint 037 only needs deterministic prepare-iso.
  pname = "mycofu-paia-compatible-shim";
  version = "9.1.3";

  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/share/doc/paia"

    cat > "$out/bin/proxmox-auto-install-assistant" <<'EOF'
    #!@bash@/bin/bash
    set -euo pipefail

    usage() {
      cat <<'USAGE'
    Mycofu paia-compatible prepare-iso shim
    Upstream compatibility target: proxmox-auto-install-assistant @version@

    Usage:
      proxmox-auto-install-assistant --help
      proxmox-auto-install-assistant prepare-iso --help
      proxmox-auto-install-assistant prepare-iso SOURCE.iso --fetch-from iso --answer-file answer.toml --output OUTPUT.iso
    USAGE
    }

    prepare_iso_usage() {
      cat <<'USAGE'
    Usage:
      proxmox-auto-install-assistant prepare-iso SOURCE.iso --fetch-from iso --answer-file answer.toml --output OUTPUT.iso

    This is a Mycofu-local paia-compatible shim, not the upstream Proxmox
    binary. It implements the deterministic prepare-iso subset used by
    hil-boot: embed /answer.toml and canonical /auto-installer-mode.toml
    into a Proxmox VE installer ISO with xorriso.
    USAGE
    }

    if [[ $# -eq 0 || "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
      usage
      exit 0
    fi

    if [[ "''${1:-}" != "prepare-iso" ]]; then
      echo "ERROR: unsupported subcommand: ''${1:-}" >&2
      usage >&2
      exit 2
    fi
    shift

    if [[ $# -eq 0 || "''${1:-}" == "--help" || "''${1:-}" == "-h" ]]; then
      prepare_iso_usage
      exit 0
    fi

    input=""
    answer=""
    output=""
    fetch_from=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --fetch-from)
          fetch_from="''${2:-}"
          shift 2
          ;;
        --answer-file)
          answer="''${2:-}"
          shift 2
          ;;
        --output)
          output="''${2:-}"
          shift 2
          ;;
        -*)
          echo "ERROR: unknown prepare-iso option: $1" >&2
          prepare_iso_usage >&2
          exit 2
          ;;
        *)
          if [[ -n "$input" ]]; then
            echo "ERROR: extra positional argument: $1" >&2
            exit 2
          fi
          input="$1"
          shift
          ;;
      esac
    done

    [[ -n "$input" ]] || { echo "ERROR: SOURCE.iso is required" >&2; exit 2; }
    [[ -n "$answer" ]] || { echo "ERROR: --answer-file is required" >&2; exit 2; }
    [[ -n "$output" ]] || { echo "ERROR: --output is required" >&2; exit 2; }
    [[ "$fetch_from" == "iso" ]] || { echo "ERROR: only --fetch-from iso is supported" >&2; exit 2; }
    [[ -s "$input" ]] || { echo "ERROR: input ISO missing or empty: $input" >&2; exit 2; }
    [[ -s "$answer" ]] || { echo "ERROR: answer file missing or empty: $answer" >&2; exit 2; }

    work="$(mktemp -d "''${TMPDIR:-/tmp}/paia-prepare-iso.XXXXXX")"
    cleanup() {
      rm -rf "$work"
    }
    trap cleanup EXIT

    extract="$work/iso"
    mkdir -p "$extract"
    xorriso -osirrox on -indev "$input" -extract / "$extract" >/dev/null 2>&1

    chmod -R u+w "$extract" 2>/dev/null || true
    cp "$answer" "$extract/answer.toml"
    # Match upstream proxmox-auto-install-assistant: AutoInstSettings is
    # serialized with deny_unknown_fields, so the previous shim form
    # mode = "iso"\n[iso]\n crashed parse with "unknown field iso, expected
    # one of mode, partition_label, http". The correct form is the full
    # serde-Serialize output of AutoInstSettings { Iso, "proxmox-ais", HttpOptions::default() }.
    printf 'mode = "iso"\npartition_label = "proxmox-ais"\n\n[http]\n' > "$extract/auto-installer-mode.toml"
    chmod 0600 "$extract/answer.toml" "$extract/auto-installer-mode.toml"
    touch -d @0 "$extract/answer.toml" "$extract/auto-installer-mode.toml"

    [[ -f "$extract/efi.img" ]] || { echo "ERROR: stock ISO lacks /efi.img" >&2; exit 1; }

    mkdir -p "$(dirname "$output")"
    # Reproducibility, mkisofs-emulation edition: SOURCE_DATE_EPOCH is
    # honored by xorriso 1.5+ as the default volume creation + modification
    # date. --modification-date pins the modification field redundantly.
    # -A/-publisher/-preparer would otherwise default to xorriso's build
    # info or the runner's user/host, which varies across machines. The
    # native -volume_date command is not accepted inside -as mkisofs mode.
    SOURCE_DATE_EPOCH=0 LC_ALL=C TZ=UTC xorriso -as mkisofs \
      -o "$output" \
      -r -J -V "PVE" \
      -A "PROXMOX-VE" \
      -publisher "MYCOFU" \
      -preparer "MYCOFU-PAIA-SHIM" \
      --modification-date=1970010100000000 \
      -b boot/grub/i386-pc/eltorito.img \
      -c boot/boot.cat \
      -no-emul-boot -boot-load-size 4 \
      -boot-info-table --grub2-boot-info \
      -eltorito-alt-boot \
      -e efi.img \
      -no-emul-boot \
      -isohybrid-gpt-basdat \
      "$extract" >/dev/null

    [[ -s "$output" ]] || { echo "ERROR: xorriso did not produce $output" >&2; exit 1; }
    EOF

    substituteInPlace "$out/bin/proxmox-auto-install-assistant" \
      --replace-fail "@bash@" "${bash}" \
      --replace-fail "@version@" "${version}"
    chmod 0755 "$out/bin/proxmox-auto-install-assistant"
    wrapProgram "$out/bin/proxmox-auto-install-assistant" \
      --prefix PATH : ${lib.makeBinPath [ coreutils gnused xorriso ]}

    ln -s "$out/bin/proxmox-auto-install-assistant" "$out/bin/paia"

    cat > "$out/share/doc/paia/pin.json" <<EOF
    {
      "package": "proxmox-auto-install-assistant",
      "version": "${version}",
      "upstream_url": "https://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/proxmox-auto-install-assistant_${version}_amd64.deb",
      "upstream_size": 1017636,
      "packaging_note": "Mycofu does not package the upstream deb in Sprint 037. This is a local paia-compatible prepare-iso shim, versioned against the upstream CLI target and tested for deterministic output."
    }
    EOF

    runHook postInstall
  '';

  passthru = {
    paiaVersion = version;
    upstreamUrl = "https://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/proxmox-auto-install-assistant_${version}_amd64.deb";
    upstreamSize = 1017636;
    isMycofuShim = true;
  };

  meta = with lib; {
    description = "Mycofu paia-compatible prepare-iso shim for hil-boot ISO remastering";
    homepage = "https://pve.proxmox.com/wiki/Automated_Installation";
    license = licenses.agpl3Plus;
    platforms = platforms.linux;
    mainProgram = "proxmox-auto-install-assistant";
  };
}
