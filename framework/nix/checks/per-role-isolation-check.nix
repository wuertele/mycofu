{ roleSrcs, sharedSrc, pkgs }:

pkgs.runCommand "per-role-isolation-check" {} ''
  set -eu

  fail() {
    echo "FAIL: $*" >&2
    exit 1
  }

  pass() {
    echo "PASS: $*"
  }

  assert_exists() {
    path="$1"
    label="$2"
    if [ ! -e "$path" ]; then
      fail "$label missing: $path"
    fi
    pass "$label present"
  }

  assert_absent() {
    path="$1"
    label="$2"
    if [ -e "$path" ]; then
      fail "$label leaked: $path"
    fi
    pass "$label absent"
  }

  assert_host_file() {
    role="$1"
    src="$2"
    assert_exists "$src/site/nix/hosts/$role.nix" "$role host file"
  }

  assert_base_module() {
    role="$1"
    src="$2"
    assert_exists "$src/framework/nix/modules/base.nix" "$role shared base module"
  }

  assert_meshcmd_absent() {
    role="$1"
    src="$2"
    assert_absent "$src/framework/nix/pkgs/meshcmd/default.nix" "$role host-tool MeshCmd package"
  }

  echo "=== Per-role source isolation structural check ==="

  # Host files are role-owned for every image role except the modules-only base image.
  assert_host_file "acme-dev" "${roleSrcs."acme-dev"}"
  assert_host_file "cicd" "${roleSrcs.cicd}"
  assert_host_file "dns" "${roleSrcs.dns}"
  assert_host_file "gatus" "${roleSrcs.gatus}"
  assert_host_file "gitlab" "${roleSrcs.gitlab}"
  assert_host_file "grafana" "${roleSrcs.grafana}"
  assert_host_file "hil-boot" "${roleSrcs."hil-boot"}"
  assert_host_file "influxdb" "${roleSrcs.influxdb}"
  assert_host_file "roon" "${roleSrcs.roon}"
  assert_host_file "testapp" "${roleSrcs.testapp}"
  assert_host_file "vault" "${roleSrcs.vault}"
  assert_host_file "workstation" "${roleSrcs.workstation}"

  for role_src in \
    "acme-dev:${roleSrcs."acme-dev"}" \
    "base:${roleSrcs.base}" \
    "cicd:${roleSrcs.cicd}" \
    "dns:${roleSrcs.dns}" \
    "gatus:${roleSrcs.gatus}" \
    "gitlab:${roleSrcs.gitlab}" \
    "grafana:${roleSrcs.grafana}" \
    "hil-boot:${roleSrcs."hil-boot"}" \
    "influxdb:${roleSrcs.influxdb}" \
    "roon:${roleSrcs.roon}" \
    "testapp:${roleSrcs.testapp}" \
    "vault:${roleSrcs.vault}" \
    "workstation:${roleSrcs.workstation}"
  do
    role="''${role_src%%:*}"
    src="''${role_src#*:}"
    assert_base_module "$role" "$src"
    assert_meshcmd_absent "$role" "$src"
  done

  assert_absent "${sharedSrc}/framework/nix/pkgs/meshcmd/default.nix" "sharedSrc host-tool MeshCmd package"
  assert_absent "${sharedSrc}/framework/nix/lib/bpg-proxmox-provider.nix" "sharedSrc bpg/proxmox provider"

  # Role-specific presence: grafana.
  assert_exists "${roleSrcs.grafana}/site/apps/grafana/grafana.ini" "grafana grafana.ini"
  assert_exists "${roleSrcs.grafana}/site/apps/grafana/datasources.yaml" "grafana datasources.yaml"
  grafana_dashboards=$(find "${roleSrcs.grafana}/site/apps/grafana/dashboards" -type f -name '*.json' | wc -l | tr -d ' ')
  if [ "$grafana_dashboards" -lt 1 ]; then
    fail "grafana dashboard JSON missing under ${roleSrcs.grafana}/site/apps/grafana/dashboards"
  fi
  pass "grafana dashboard JSON present ($grafana_dashboards file(s))"
  assert_exists "${roleSrcs.grafana}/framework/catalog/grafana/module.nix" "grafana catalog module"
  assert_exists "${roleSrcs.grafana}/benchmarks/grafana/dashboard.json" "grafana benchmark dashboard"

  # Role-specific presence: influxdb.
  assert_exists "${roleSrcs.influxdb}/site/apps/influxdb/setup.json" "influxdb setup.json"
  assert_exists "${roleSrcs.influxdb}/site/apps/influxdb/buckets.json" "influxdb buckets.json"
  assert_exists "${roleSrcs.influxdb}/site/apps/influxdb/env.conf" "influxdb env.conf"
  assert_exists "${roleSrcs.influxdb}/framework/catalog/influxdb/module.nix" "influxdb catalog module"
  assert_exists "${roleSrcs.influxdb}/framework/catalog/cluster-dashboard/module.nix" "influxdb cluster-dashboard catalog module"

  # Role-specific presence: hil-boot. Assert directory presence only;
  # naming a site subdirectory (e.g. `tests/hil/<site>/config.yaml`)
  # would inject a site literal into framework/ and trip
  # `tests/test_regreener_no_site_hardcoding.sh`. The per-role isolation
  # property we care about is that the role tree contains the HIL
  # fixtures and the artifacts builder at all.
  assert_exists "${roleSrcs."hil-boot"}/tests/hil" "hil-boot HIL fixtures directory"
  assert_exists "${roleSrcs."hil-boot"}/site/config.yaml" "hil-boot site config"
  assert_exists "${roleSrcs."hil-boot"}/site/nix/lib/hil-boot-artifacts.nix" "hil-boot artifacts lib"

  # Shared-base reachability in role trees.
  assert_exists "${roleSrcs."acme-dev"}/framework/step-ca" "acme-dev step-ca data"
  assert_exists "${roleSrcs.dns}/framework/nix/modules/dns.nix" "dns role module"
  assert_exists "${roleSrcs.cicd}/framework/nix/lib/bpg-proxmox-provider.nix" "cicd bpg/proxmox provider"

  # Cross-role absence and directory-leak checks.
  assert_absent "${roleSrcs.dns}/site/apps" "dns site/apps directory"
  assert_absent "${roleSrcs.dns}/framework/catalog" "dns framework/catalog directory"
  assert_absent "${roleSrcs.dns}/framework/catalog/grafana" "dns grafana catalog"
  assert_absent "${roleSrcs.dns}/framework/catalog/roon" "dns roon catalog"
  assert_absent "${roleSrcs.dns}/tests/hil" "dns HIL fixtures"
  assert_absent "${roleSrcs.dns}/site/config.yaml" "dns site config"
  assert_absent "${roleSrcs.dns}/benchmarks" "dns benchmarks directory"
  assert_absent "${roleSrcs.dns}/framework/nix/lib/bpg-proxmox-provider.nix" "dns bpg/proxmox provider"

  assert_absent "${roleSrcs.grafana}/site/apps/influxdb" "grafana influxdb app config"
  assert_absent "${roleSrcs.grafana}/framework/catalog/cluster-dashboard" "grafana cluster-dashboard catalog"
  assert_absent "${roleSrcs.grafana}/site/nix/hosts/influxdb.nix" "grafana influxdb host file"
  assert_absent "${roleSrcs.grafana}/framework/nix/lib/bpg-proxmox-provider.nix" "grafana bpg/proxmox provider"

  assert_absent "${roleSrcs.roon}/framework/catalog/grafana" "roon grafana catalog"
  assert_absent "${roleSrcs.roon}/site/apps" "roon site/apps directory"
  assert_absent "${roleSrcs.roon}/benchmarks" "roon benchmarks directory"
  assert_absent "${roleSrcs.roon}/framework/nix/lib/bpg-proxmox-provider.nix" "roon bpg/proxmox provider"

  assert_absent "${roleSrcs."hil-boot"}/site/nix/hosts/dns.nix" "hil-boot dns host file"
  assert_absent "${roleSrcs."hil-boot"}/site/apps" "hil-boot site/apps directory"
  assert_absent "${roleSrcs."hil-boot"}/framework/catalog/grafana" "hil-boot grafana catalog"
  assert_absent "${roleSrcs."hil-boot"}/framework/nix/lib/bpg-proxmox-provider.nix" "hil-boot bpg/proxmox provider"

  mkdir -p "$out"
  echo "passed" > "$out/result"
''
