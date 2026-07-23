# framework/tofu/root/main.tf — Root module for VM deployments.
#
# All site-specific values come from config.yaml via yamldecode.
# Secrets come from SOPS via TF_VAR_* env vars (set by tofu-wrapper.sh).
# The framework modules receive values through input variables only.

locals {
  config      = yamldecode(file("${path.module}/../../../site/config.yaml"))
  node_names  = [for n in local.config.nodes : n.name]
  domain      = local.config.domain
  prod_domain = "prod.${local.domain}"
  dev_domain  = "dev.${local.domain}"
  gitlab_url  = "https://gitlab.prod.${local.domain}"
  github_remote_url = trimspace(
    var.github_remote_url != "" ? var.github_remote_url : try(local.config.github.remote_url, "")
  )
  # Application VMs are in site/applications.yaml (separate from config.yaml).
  #
  # The _apps_file / _raw_apps / applications ladder handles three shapes that
  # a valid site can produce, without any of them halting plan evaluation:
  #   1. site/applications.yaml is missing entirely — the outer try(...) on
  #      _apps_file yields {} (file(...) errors would otherwise be fatal).
  #   2. The file exists but has no `applications:` key (e.g., a bootstrap
  #      site with only the header) — the try(...) on _raw_apps yields null.
  #   3. The file exists and `applications:` is set — _raw_apps is the map.
  # applications = _raw_apps != null ? _raw_apps : tomap({}) then converts
  # the null case into an empty map so all downstream `try(local.app_*, ...)`
  # accessors see a uniformly-typed map, never null. The null-check step is
  # doing real work — `try(local._apps_file.applications, tomap({}))` would
  # NOT be equivalent, because `try()` only invokes its fallback on error,
  # not on a successful null result. For `applications: null` explicit in
  # site/applications.yaml, `try(...)` returns null, so downstream `try(
  # local.applications.<app>, {})` would then crash on the null-attribute
  # access. The explicit `_raw_apps != null ? _raw_apps : tomap({})` catches
  # both "missing key" (which try() does fallback for) and "null value"
  # (which try() does not) and normalizes them. The two-stage split also
  # makes each shape case individually greppable during debugging
  # (missing-file vs. missing-key vs. null-value). See #63.
  _apps_file     = try(yamldecode(file("${path.module}/../../../site/applications.yaml")), {})
  _raw_apps      = try(local._apps_file.applications, null)
  applications   = local._raw_apps != null ? local._raw_apps : tomap({})
  influxdb_setup = jsondecode(file("${path.module}/../../../site/apps/influxdb/setup.json"))

  # ACME URL for prod VMs — derived from config.yaml acme mode
  acme_mode = try(local.config.acme, "production")
  prod_acme_url = local.acme_mode == "staging" ? (
    "https://acme-staging-v02.api.letsencrypt.org/directory"
    ) : (
    "https://acme-v02.api.letsencrypt.org/directory"
  )
  dev_acme_url      = "https://acme:14000/acme/acme/directory"
  dev_extra_ca_cert = file("${path.module}/../../step-ca/root-ca.crt")

  # --- Zone data generation ---
  # Infrastructure VMs with environment suffix
  prod_env_records = [
    for vm_name, vm in local.config.vms :
    { name = replace(vm_name, "_prod", ""), type = "A", content = vm.ip }
    if endswith(vm_name, "_prod")
  ]
  dev_env_records = [
    for vm_name, vm in local.config.vms :
    { name = replace(vm_name, "_dev", ""), type = "A", content = vm.ip }
    if endswith(vm_name, "_dev")
  ]

  # Shared VMs (no env suffix) — included in all zones for operator convenience
  shared_vm_records = [
    for vm_name, vm in local.config.vms :
    { name = vm_name, type = "A", content = vm.ip }
    if !endswith(vm_name, "_prod") && !endswith(vm_name, "_dev")
  ]

  # Application VMs
  prod_app_records = [
    for app_name, app in local.applications :
    { name = app_name, type = "A", content = app.environments.prod.ip }
    if try(app.enabled, false) && lookup(try(app.environments, {}), "prod", null) != null
  ]
  dev_app_records = [
    for app_name, app in local.applications :
    { name = app_name, type = "A", content = app.environments.dev.ip }
    if try(app.enabled, false) && lookup(try(app.environments, {}), "dev", null) != null
  ]

  # Management NIC A records (for VMs with mgmt_nic in config.yaml)
  prod_mgmt_records = [
    for app_name, app in local.applications :
    { name = app.environments.prod.mgmt_nic.name, type = "A", content = app.environments.prod.mgmt_nic.ip }
    if try(app.enabled, false) && try(app.environments.prod.mgmt_nic, null) != null
  ]
  dev_mgmt_records = [
    for app_name, app in local.applications :
    { name = app.environments.dev.mgmt_nic.name, type = "A", content = app.environments.dev.mgmt_nic.ip }
    if try(app.enabled, false) && try(app.environments.dev.mgmt_nic, null) != null
  ]

  # Extra records from optional per-environment files (MX, TXT, CNAME, etc.)
  prod_extra_file    = "${path.module}/../../../site/dns/zones/prod.yaml"
  dev_extra_file     = "${path.module}/../../../site/dns/zones/dev.yaml"
  prod_extra_records = fileexists(local.prod_extra_file) ? try(yamldecode(file(local.prod_extra_file)).extra_records, []) : []
  dev_extra_records  = fileexists(local.dev_extra_file) ? try(yamldecode(file(local.dev_extra_file)).extra_records, []) : []

  # Complete zone data JSON for each environment
  prod_zone_data = jsonencode({
    zone = local.prod_domain
    records = concat(
      [
        { name = "@", type = "SOA", content = "dns1.${local.domain}. hostmaster.${local.domain}. 1 10800 3600 604800 300" },
        { name = "@", type = "NS", content = "dns1.${local.domain}." },
        { name = "@", type = "NS", content = "dns2.${local.domain}." },
      ],
      local.prod_env_records,
      local.shared_vm_records,
      local.prod_app_records,
      local.prod_mgmt_records,
      local.prod_extra_records,
    )
  })

  dev_zone_data = jsonencode({
    zone = local.dev_domain
    records = concat(
      [
        { name = "@", type = "SOA", content = "dns1.${local.domain}. hostmaster.${local.domain}. 1 10800 3600 604800 300" },
        { name = "@", type = "NS", content = "dns1.${local.domain}." },
        { name = "@", type = "NS", content = "dns2.${local.domain}." },
      ],
      local.dev_env_records,
      local.shared_vm_records,
      local.dev_app_records,
      local.dev_mgmt_records,
      local.dev_extra_records,
    )
  })
}

# --- Sprint 047 #691 replication-policy wiring ---
#
# Consumed by every module invocation below as `replication_policy_on`. The
# interior proxmox-vm modules use it to set haresource.max_restart /
# max_relocate to 0 ONLY for VMs with LITERAL `replicate: false` (the
# override contract — A6). Under Sprint 048 MR-4 doctrine (universal
# replication), the shipped-site override set is EMPTY, so every VM gets
# PVE defaults (max_restart=1, max_relocate=1) — the 047 damage limiter
# fires only when an operator explicitly opts out of replication.
#
# V5.1 single-authority note: the sanctioned authority for the replication
# policy is framework/scripts/list-replicated-vmids.sh. This local re-derives
# the SAME override-only rule in HCL so tofu plan does not need to shell out
# at plan time (which would require vendoring hashicorp/external in the
# sovereign provider mirror — see #691 review P1-1). To keep the two
# derivations honest, tests/test_replication_policy_hcl_wiring.sh is an
# equivalence ratchet: it runs the shell helper on the current site config
# and asserts the same override VMID set that this HCL produces. Adding
# this file to the V5.1.a allowlist is deliberate — the ratchet is the
# equivalence proof the V5.1 doctrine requires.
#
# The rule (Sprint 048 MR-5, must match list-replicated-vmids.sh --off
# output — the literal-`replicate: false` set only):
#   policy_on = (explicit `replicate: false`) ? false : true
#
# Applied to enabled VMs from local.config.vms and enabled apps'
# per-environment entries in local.applications. Disabled VMs / apps are
# skipped (matches helper).
locals {
  # Framework VMs: one entry per vms.<name> that is not disabled.
  # policy_on is FALSE iff `replicate` is set AND equals the literal
  # boolean false; otherwise policy_on is TRUE (PVE defaults preserved).
  _fw_vm_policy = {
    for name, vm in local.config.vms :
    tostring(vm.vmid) => !(
      contains(keys(vm), "replicate") && vm.replicate == false
    )
    if try(vm.enabled, true) != false
  }

  # Application VMs: one entry per enabled app × environment.
  # merge([...]...) folds the per-app maps into a single map keyed by
  # the environment's VMID as a string.
  _app_vm_policy = merge([
    for name, app in local.applications : {
      for env_name, env_cfg in try(app.environments, {}) :
      tostring(env_cfg.vmid) => !(
        contains(keys(app), "replicate") && app.replicate == false
      )
    }
    if try(app.enabled, false) == true
  ]...)

  # Combined per-VMID policy map. Framework VMs and app VMs use disjoint
  # VMID ranges (see .claude/rules/config-yaml.md VM Identity Fields);
  # merge() preserves last-write semantics but no collision is expected.
  replication_policy_on_by_vmid = merge(local._fw_vm_policy, local._app_vm_policy)
}

# SSH public key from SOPS secrets (exported as TF_VAR_ssh_pubkey by tofu-wrapper.sh)
# This is the framework's key — used by the CI runner for automated SSH.
variable "ssh_pubkey" {
  description = "Framework SSH public key (from SOPS via TF_VAR_ssh_pubkey)"
  type        = string
}

# Operator's workstation SSH key — from config.yaml, for interactive SSH.
locals {
  operator_ssh_pubkey = local.config.operator_ssh_pubkey

  # Safe application config accessors — return empty defaults when the
  # application is not in config.yaml. OpenTofu evaluates module arguments
  # even when count = 0, so these must not error on missing keys.
  app_influxdb    = try(local.applications.influxdb, {})
  app_grafana     = try(local.applications.grafana, {})
  app_roon        = try(local.applications.roon, {})
  app_workstation = try(local.applications.workstation, {})

  dashboard_pools = ["control-plane", "prod", "dev"]

  influxdb_dev_dashboard_config = jsonencode({
    environment             = "dev"
    pools                   = local.dashboard_pools
    nodes                   = local.node_names
    proxmoxApiTargets       = [for node in local.config.nodes : node.mgmt_ip]
    grafanaBaseUrl          = "https://grafana.dev.${local.domain}"
    grafanaNodeDashboardUid = "cluster-node-detail"
    grafanaVmDashboardUid   = "cluster-vm-detail"
    metricsBucket           = local.influxdb_setup.bucket
    metricsOrg              = local.influxdb_setup.org
    pollSeconds             = 15
    chartWindowMinutes      = 15
    soakMr                  = 221
  })

  influxdb_prod_dashboard_config = jsonencode({
    environment             = "prod"
    pools                   = local.dashboard_pools
    nodes                   = local.node_names
    proxmoxApiTargets       = [for node in local.config.nodes : node.mgmt_ip]
    grafanaBaseUrl          = "https://grafana.prod.${local.domain}"
    grafanaNodeDashboardUid = "cluster-node-detail"
    grafanaVmDashboardUid   = "cluster-vm-detail"
    metricsBucket           = local.influxdb_setup.bucket
    metricsOrg              = local.influxdb_setup.org
    pollSeconds             = 15
    chartWindowMinutes      = 15
  })
}

# SSH host keys from SOPS (exported as TF_VAR_ssh_host_keys_json by tofu-wrapper.sh).
# JSON map: { "vm_key": { "private": "...", "public": "..." }, ... }
# Empty string means keys have not been provisioned yet.
variable "ssh_host_keys_json" {
  description = "Per-VM SSH host keys from SOPS (JSON map, empty = not provisioned)"
  type        = string
  default     = "{}"
  sensitive   = true
}

locals {
  ssh_host_keys = try(jsondecode(var.ssh_host_keys_json), {})
}

# PowerDNS API key from SOPS secrets (exported as TF_VAR_pdns_api_key by tofu-wrapper.sh)
variable "pdns_api_key" {
  description = "PowerDNS API key (from SOPS via TF_VAR_pdns_api_key)"
  type        = string
  sensitive   = true
}

variable "github_remote_url" {
  description = "GitHub remote URL for publishing (from config.yaml via TF_VAR_github_remote_url)"
  type        = string
  default     = ""
}

variable "influxdb_admin_token" {
  description = "InfluxDB admin API token (from SOPS via TF_VAR_influxdb_admin_token)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_admin_password" {
  description = "Grafana admin password (from SOPS via TF_VAR_grafana_admin_password)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_influxdb_token" {
  description = "InfluxDB API token for Grafana data source (from SOPS via TF_VAR_grafana_influxdb_token)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tailscale_auth_key" {
  description = "Tailscale reusable pre-auth key (from SOPS via TF_VAR_tailscale_auth_key)"
  type        = string
  sensitive   = true
  default     = ""
}

# Vault AppRole credentials for vault-agent (generated by configure-vault.sh)
variable "vault_approle_dns1_prod_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_dns1_prod_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_dns2_prod_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_dns2_prod_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_dns1_dev_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_dns1_dev_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_dns2_dev_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_dns2_dev_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_gatus_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_gatus_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_gitlab_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_gitlab_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_cicd_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_cicd_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_influxdb_dev_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_influxdb_dev_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_influxdb_prod_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_influxdb_prod_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_testapp_dev_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_testapp_dev_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_testapp_prod_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_testapp_prod_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_grafana_dev_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_grafana_dev_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_grafana_prod_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_grafana_prod_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_workstation_dev_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_workstation_dev_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_workstation_prod_role_id" {
  type      = string
  sensitive = true
  default   = ""
}
variable "vault_approle_workstation_prod_secret_id" {
  type      = string
  sensitive = true
  default   = ""
}

# --- Dev ACME server (dev only) ---

module "acme_dev" {
  source = "../modules/acme-dev"

  vm_id                 = local.config.vms.acme_dev.vmid
  target_node           = local.config.vms.acme_dev.node
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.dev.vlan_id
  mac_address           = local.config.vms.acme_dev.mac
  image                 = "local:iso/${var.image_versions["acme-dev"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = ["pool-${local.config.vms.acme_dev.pool}"]
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.acme_dev.vmid)], null)
  domain                = local.domain
  extra_ca_cert       = local.dev_extra_ca_cert
  ip_address          = local.config.vms.acme_dev.ip
  gateway             = local.config.environments.dev.gateway
  dns_servers         = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain       = "dev.${local.domain}"

  ssh_host_key_private = try(local.ssh_host_keys.acme_dev.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.acme_dev.public, "")
}

# --- DNS VM pairs ---

module "dns_prod" {
  source = "../modules/dns-pair"

  dns1_vm_id            = local.config.vms.dns1_prod.vmid
  dns2_vm_id            = local.config.vms.dns2_prod.vmid
  environment           = "prod"
  vlan_id               = local.config.environments.prod.vlan_id
  dns1_ip               = local.config.vms.dns1_prod.ip
  dns1_mac              = local.config.vms.dns1_prod.mac
  dns2_ip               = local.config.vms.dns2_prod.ip
  dns2_mac              = local.config.vms.dns2_prod.mac
  node_names            = local.node_names
  image                 = "local:iso/${var.image_versions["dns"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  pdns_api_key          = var.pdns_api_key
  storage_pool          = local.config.proxmox.storage_pool
  dns1_tags             = ["pool-${local.config.vms.dns1_prod.pool}"]
  dns2_tags             = ["pool-${local.config.vms.dns2_prod.pool}"]
  start_vms                  = var.start_vms
  register_ha                = var.register_ha
  dns1_replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.dns1_prod.vmid)], null)
  dns2_replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.dns2_prod.vmid)], null)
  acme_server_url            = local.prod_acme_url
  extra_ca_cert       = ""
  gateway_ip          = local.config.environments.prod.gateway
  dns_domain          = local.prod_domain
  zone_data           = local.prod_zone_data
  domain              = local.domain
  dns_servers         = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain       = "prod.${local.domain}"

  dns1_vault_approle_role_id   = var.vault_approle_dns1_prod_role_id
  dns1_vault_approle_secret_id = var.vault_approle_dns1_prod_secret_id
  dns2_vault_approle_role_id   = var.vault_approle_dns2_prod_role_id
  dns2_vault_approle_secret_id = var.vault_approle_dns2_prod_secret_id

  dns1_ssh_host_key_private = try(local.ssh_host_keys.dns1_prod.private, "")
  dns1_ssh_host_key_public  = try(local.ssh_host_keys.dns1_prod.public, "")
  dns2_ssh_host_key_private = try(local.ssh_host_keys.dns2_prod.private, "")
  dns2_ssh_host_key_public  = try(local.ssh_host_keys.dns2_prod.public, "")
}

# --- Vault ---

module "vault_prod" {
  source = "../modules/vault"

  vm_id                 = local.config.vms.vault_prod.vmid
  environment           = "prod"
  target_node           = local.node_names[2]
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.prod.vlan_id
  mac_address           = local.config.vms.vault_prod.mac
  image                 = "local:iso/${var.image_versions["vault"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = ["pool-${local.config.vms.vault_prod.pool}"]
  vdb_size_gb           = 10
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.vault_prod.vmid)], null)
  pdns_api_key          = var.pdns_api_key
  acme_server_url       = local.prod_acme_url
  extra_ca_cert       = ""
  pdns_api_servers    = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain              = local.domain
  ip_address          = local.config.vms.vault_prod.ip
  gateway             = local.config.environments.prod.gateway
  dns_servers         = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain       = "prod.${local.domain}"

  ssh_host_key_private = try(local.ssh_host_keys.vault_prod.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.vault_prod.public, "")
}

module "vault_dev" {
  source = "../modules/vault"

  vm_id                 = local.config.vms.vault_dev.vmid
  environment           = "dev"
  target_node           = local.node_names[2]
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.dev.vlan_id
  mac_address           = local.config.vms.vault_dev.mac
  image                 = "local:iso/${var.image_versions["vault"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = ["pool-${local.config.vms.vault_dev.pool}"]
  vdb_size_gb           = 10
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.vault_dev.vmid)], null)
  pdns_api_key          = var.pdns_api_key
  acme_server_url       = local.dev_acme_url
  extra_ca_cert       = local.dev_extra_ca_cert
  pdns_api_servers    = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  domain              = local.domain
  ip_address          = local.config.vms.vault_dev.ip
  gateway             = local.config.environments.dev.gateway
  dns_servers         = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain       = "dev.${local.domain}"

  ssh_host_key_private = try(local.ssh_host_keys.vault_dev.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.vault_dev.public, "")
}

# --- PBS (Proxmox Backup Server) ---

module "pbs" {
  source = "../modules/pbs"

  vm_id       = local.config.vms.pbs.vmid
  target_node = local.node_names[2]
  # No vlan_id — PBS is on the management network (native/untagged VLAN).
  # Shared operational services (PBS, GitLab, CI/CD, Gatus) live on the management
  # network because their clients are Proxmox nodes, not VMs.
  mac_address           = local.config.vms.pbs.mac
  iso_file              = "" # Detached after PBS installation
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = ["pool-${local.config.vms.pbs.pool}"]
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.pbs.vmid)], null)
}

# --- GitLab (management network) ---

module "gitlab" {
  source = "../modules/gitlab"

  vm_id                 = local.config.vms.gitlab.vmid
  target_node           = local.node_names[2]
  all_node_names        = local.node_names
  mac_address           = local.config.vms.gitlab.mac
  image                 = "local:iso/${var.image_versions["gitlab"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = ["pool-${local.config.vms.gitlab.pool}"]
  vdb_size_gb           = 50
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.gitlab.vmid)], null)
  external_url          = local.gitlab_url
  certbot_fqdn        = "gitlab.${local.prod_domain}"
  pdns_api_key        = var.pdns_api_key
  acme_server_url     = local.prod_acme_url
  pdns_api_servers    = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain              = local.domain
  ip_address          = local.config.vms.gitlab.ip
  gateway             = local.config.management.gateway
  dns_servers         = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain       = "prod.${local.domain}"

  tailscale_auth_key = try(local.config.vms.gitlab.tailscale, false) ? var.tailscale_auth_key : ""

  vault_approle_role_id   = var.vault_approle_gitlab_role_id
  vault_approle_secret_id = var.vault_approle_gitlab_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.gitlab.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.gitlab.public, "")
}

# --- GitLab Runner (management network) ---

module "cicd" {
  source = "../modules/cicd"

  vm_id                 = local.config.vms.cicd.vmid
  target_node           = local.config.vms.cicd.node
  all_node_names        = local.node_names
  mac_address           = local.config.vms.cicd.mac
  image                 = "local:iso/${var.image_versions["cicd"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = ["pool-${local.config.vms.cicd.pool}"]
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.cicd.vmid)], null)
  cores                 = local.config.cicd.runner_cores
  ram_mb                = local.config.cicd.runner_ram_mb
  # Balloon floor. try(..., null) so a site config that predates ballooning keeps
  # today's behavior (null -> no floating -> balloon:0 -> device disabled) instead
  # of failing tofu eval on a missing key. Same idiom as runner_disk_gb below.
  ram_floating_mb   = try(local.config.cicd.runner_ram_floor_mb, null)
  root_disk_gb      = coalesce(try(local.config.cicd.runner_disk_gb, null), 256)
  gitlab_url        = local.gitlab_url
  github_remote_url = local.github_remote_url
  sops_age_key      = var.sops_age_key
  ssh_privkey       = var.ssh_privkey
  domain            = local.domain
  ip_address        = local.config.vms.cicd.ip
  gateway           = local.config.management.gateway
  dns_servers       = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain     = "prod.${local.domain}"

  vault_approle_role_id   = var.vault_approle_cicd_role_id
  vault_approle_secret_id = var.vault_approle_cicd_secret_id

  tailscale_auth_key = try(local.config.vms.cicd.tailscale, false) ? var.tailscale_auth_key : ""

  ssh_host_key_private = try(local.ssh_host_keys.cicd.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.cicd.public, "")
}

# --- HIL PXE boot service (management network) ---

module "hil_boot" {
  source = "../modules/proxmox-vm"

  vm_id                 = local.config.vms.hil_boot.vmid
  vm_name               = "hil-boot"
  hostname              = "hil-boot"
  instance_id           = "hil-boot"
  target_node           = local.config.vms.hil_boot.node
  all_node_names        = local.node_names
  image_file_id         = "local:iso/${var.image_versions["hil-boot"]}"
  vlan_id               = null
  mac_address           = local.config.vms.hil_boot.mac
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = ["pool-${local.config.vms.hil_boot.pool}"]
  domain                = local.domain
  ip_address            = local.config.vms.hil_boot.ip
  gateway               = local.config.management.gateway
  dns_servers           = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain         = "prod.${local.domain}"
  vda_size_gb           = 32
  vdb_size_gb           = 0
  ha_enabled            = true
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.hil_boot.vmid)], null)

  ssh_host_key_private = try(local.ssh_host_keys.hil_boot.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.hil_boot.public, "")
}

# --- Gatus (prod VLAN) ---

module "gatus" {
  source = "../modules/gatus"

  vm_id                 = local.config.vms.gatus.vmid
  target_node           = local.node_names[1] # pve02 — underutilized
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.prod.vlan_id
  mac_address           = local.config.vms.gatus.mac
  image                 = "local:iso/${var.image_versions["gatus"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = ["pool-${local.config.vms.gatus.pool}"]
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.gatus.vmid)], null)
  gatus_config          = fileexists("${path.module}/../../../site/gatus/config.yaml") ? file("${path.module}/../../../site/gatus/config.yaml") : ""
  pdns_api_key        = var.pdns_api_key
  acme_server_url     = local.prod_acme_url
  extra_ca_cert       = ""
  pdns_api_servers    = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain              = local.domain
  ip_address          = local.config.vms.gatus.ip
  gateway             = local.config.environments.prod.gateway
  dns_servers         = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain       = "prod.${local.domain}"

  vault_approle_role_id   = var.vault_approle_gatus_role_id
  vault_approle_secret_id = var.vault_approle_gatus_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.gatus.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.gatus.public, "")
}

# --- Testapp (both environments) ---

module "testapp_dev" {
  source = "../modules/testapp"

  vm_id                   = local.config.vms.testapp_dev.vmid
  environment             = "dev"
  target_node             = local.node_names[1]
  all_node_names          = local.node_names
  vlan_id                 = local.config.environments.dev.vlan_id
  mac_address             = local.config.vms.testapp_dev.mac
  image                   = "local:iso/${var.image_versions["testapp"]}"
  ssh_pubkey              = var.ssh_pubkey
  operator_ssh_pubkey     = local.operator_ssh_pubkey
  storage_pool            = local.config.proxmox.storage_pool
  tags                    = ["pool-${local.config.vms.testapp_dev.pool}"]
  pdns_api_key            = var.pdns_api_key
  start_vms               = var.start_vms
  register_ha             = var.register_ha
  replication_policy_on   = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.testapp_dev.vmid)], null)
  acme_server_url         = local.dev_acme_url
  extra_ca_cert           = local.dev_extra_ca_cert
  pdns_api_servers        = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  domain                  = local.domain
  ip_address              = local.config.vms.testapp_dev.ip
  gateway                 = local.config.environments.dev.gateway
  dns_servers             = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain           = "dev.${local.domain}"
  vault_approle_role_id   = var.vault_approle_testapp_dev_role_id
  vault_approle_secret_id = var.vault_approle_testapp_dev_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.testapp_dev.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.testapp_dev.public, "")
}

module "testapp_prod" {
  source = "../modules/testapp"

  vm_id                   = local.config.vms.testapp_prod.vmid
  environment             = "prod"
  target_node             = local.node_names[1]
  all_node_names          = local.node_names
  vlan_id                 = local.config.environments.prod.vlan_id
  mac_address             = local.config.vms.testapp_prod.mac
  image                   = "local:iso/${var.image_versions["testapp"]}"
  ssh_pubkey              = var.ssh_pubkey
  operator_ssh_pubkey     = local.operator_ssh_pubkey
  storage_pool            = local.config.proxmox.storage_pool
  tags                    = ["pool-${local.config.vms.testapp_prod.pool}"]
  pdns_api_key            = var.pdns_api_key
  start_vms               = var.start_vms
  register_ha             = var.register_ha
  replication_policy_on   = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.testapp_prod.vmid)], null)
  acme_server_url         = local.prod_acme_url
  extra_ca_cert           = ""
  pdns_api_servers        = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain                  = local.domain
  ip_address              = local.config.vms.testapp_prod.ip
  gateway                 = local.config.environments.prod.gateway
  dns_servers             = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain           = "prod.${local.domain}"
  vault_approle_role_id   = var.vault_approle_testapp_prod_role_id
  vault_approle_secret_id = var.vault_approle_testapp_prod_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.testapp_prod.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.testapp_prod.public, "")
}

# --- InfluxDB (both environments) ---

# NOTE on sizing-field coalesce fallbacks (`ram_mb`, `vdb_size_gb`, `cores`)
# used across influxdb_{dev,prod}, grafana_{dev,prod}, roon_{dev,prod}, and
# workstation_{dev,prod} below:
#
# The pattern `coalesce(try(local.app_<app>.<field>, null), <catalog-default>)`
# defends against the null-cascade footgun documented in #276 and #280:
# OpenTofu does NOT coerce explicit null to a receiving variable's default,
# so a bare `try(<field>, null)` passes null through to the proxmox provider
# (rejected with a confusing message) or to the field-updatable module's
# dynamic vdb block (`for_each = var.vdb_size_gb > 0 ? [1] : []` errors on
# null). The trailing numeric literal must match the receiving catalog
# module's `variable "<field>" { default = N }` in
# `framework/catalog/<app>/variables.tf`; a drift check for that invariant
# is tracked as a follow-up issue. See #42 (structural cascade collapsed
# into the sizing subset here) and #280 (proactive of #276).
#
# NOTE on the `count = try(local.app_<app>.enabled, false) ? 1 : 0` pattern used
# on every optional application module below (influxdb_{dev,prod},
# grafana_{dev,prod}, roon_{dev,prod}, workstation_{dev,prod}):
#
# `count` must evaluate to a known number at plan time. The `local.app_<app>`
# locals defined earlier in this file (see `app_influxdb`, `app_grafana`,
# `app_roon`, `app_workstation`) already collapse a missing entry in
# site/applications.yaml to `{}`, so `local.app_<app>` itself is always
# a value. But `local.app_<app>.enabled` will still crash the plan with an
# "Attempt to get attribute from an object without that attribute" error
# when applications.yaml does not include `<app>` at all (in which case
# `local.app_<app>` is `{}` and has no `enabled` key). The
# `try(local.app_<app>.enabled, false)` swallows that class of error and
# returns `false`, and the `? 1 : 0` converts the boolean into the required
# numeric count so the module is instantiated only when the operator has
# explicitly opted in.
#
# Do NOT rewrite this as `count = local.app_<app>.enabled ? 1 : 0` — that
# breaks any config that does not enumerate every optional application, which
# is the common bootstrap case. See #63.
module "influxdb_dev" {
  source = "../../catalog/influxdb"

  count = try(local.app_influxdb.enabled, false) ? 1 : 0

  vm_id                 = try(local.app_influxdb.environments.dev.vmid, null)
  environment           = "dev"
  target_node           = try(local.app_influxdb.node, null)
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.dev.vlan_id
  mac_address           = try(local.app_influxdb.environments.dev.mac, null)
  image                 = "local:iso/${var.image_versions["influxdb"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = try(local.app_influxdb.enabled, false) ? ["pool-${local.app_influxdb.environments.dev.pool}"] : []
  ram_mb                = coalesce(try(local.app_influxdb.ram, null), 2048)
  vda_size_gb           = coalesce(try(local.app_influxdb.disk_size, null), 4)
  vdb_size_gb           = coalesce(try(local.app_influxdb.data_disk_size, null), 20)
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.app_influxdb.environments.dev.vmid)], null)
  pdns_api_key          = var.pdns_api_key
  acme_server_url       = local.dev_acme_url
  extra_ca_cert         = local.dev_extra_ca_cert
  pdns_api_servers      = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  influxdb_admin_token  = var.influxdb_admin_token
  dashboard_config_json = local.influxdb_dev_dashboard_config
  domain                = local.domain
  ip_address            = try(local.app_influxdb.environments.dev.ip, null)
  gateway               = local.config.environments.dev.gateway
  dns_servers           = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain         = "dev.${local.domain}"
  mgmt_nic = try(local.app_influxdb.environments.dev.mgmt_nic != null ? {
    ip          = try(local.app_influxdb.environments.dev.mgmt_nic.ip, null)
    mac_address = try(local.app_influxdb.environments.dev.mgmt_nic.mac, null)
  } : null, null)
  vault_approle_role_id   = var.vault_approle_influxdb_dev_role_id
  vault_approle_secret_id = var.vault_approle_influxdb_dev_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.influxdb_dev.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.influxdb_dev.public, "")
}

module "influxdb_prod" {
  source = "../../catalog/influxdb"

  count = try(local.app_influxdb.enabled, false) ? 1 : 0

  vm_id                 = try(local.app_influxdb.environments.prod.vmid, null)
  environment           = "prod"
  target_node           = try(local.app_influxdb.node, null)
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.prod.vlan_id
  mac_address           = try(local.app_influxdb.environments.prod.mac, null)
  image                 = "local:iso/${var.image_versions["influxdb"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = try(local.app_influxdb.enabled, false) ? ["pool-${local.app_influxdb.environments.prod.pool}"] : []
  ram_mb                = coalesce(try(local.app_influxdb.ram, null), 2048)
  vda_size_gb           = coalesce(try(local.app_influxdb.disk_size, null), 4)
  vdb_size_gb           = coalesce(try(local.app_influxdb.data_disk_size, null), 20)
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.app_influxdb.environments.prod.vmid)], null)
  pdns_api_key          = var.pdns_api_key
  acme_server_url       = local.prod_acme_url
  extra_ca_cert         = ""
  pdns_api_servers      = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  influxdb_admin_token  = var.influxdb_admin_token
  dashboard_config_json = local.influxdb_prod_dashboard_config
  domain                = local.domain
  ip_address            = try(local.app_influxdb.environments.prod.ip, null)
  gateway               = local.config.environments.prod.gateway
  dns_servers           = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain         = "prod.${local.domain}"
  mgmt_nic = try(local.app_influxdb.environments.prod.mgmt_nic != null ? {
    ip          = try(local.app_influxdb.environments.prod.mgmt_nic.ip, null)
    mac_address = try(local.app_influxdb.environments.prod.mgmt_nic.mac, null)
  } : null, null)
  vault_approle_role_id   = var.vault_approle_influxdb_prod_role_id
  vault_approle_secret_id = var.vault_approle_influxdb_prod_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.influxdb_prod.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.influxdb_prod.public, "")
}

# --- Grafana (both environments) ---

module "grafana_dev" {
  source = "../../catalog/grafana"

  count = try(local.app_grafana.enabled, false) ? 1 : 0

  vm_id                   = try(local.app_grafana.environments.dev.vmid, null)
  environment             = "dev"
  target_node             = try(local.app_grafana.node, null)
  all_node_names          = local.node_names
  vlan_id                 = local.config.environments.dev.vlan_id
  mac_address             = try(local.app_grafana.environments.dev.mac, null)
  image                   = "local:iso/${var.image_versions["grafana"]}"
  ssh_pubkey              = var.ssh_pubkey
  operator_ssh_pubkey     = local.operator_ssh_pubkey
  storage_pool            = local.config.proxmox.storage_pool
  tags                    = try(local.app_grafana.enabled, false) ? ["pool-${local.app_grafana.environments.dev.pool}"] : []
  ram_mb                  = coalesce(try(local.app_grafana.ram, null), 1024)
  vda_size_gb             = coalesce(try(local.app_grafana.disk_size, null), 8)
  vdb_size_gb             = coalesce(try(local.app_grafana.data_disk_size, null), 4)
  start_vms               = var.start_vms
  register_ha             = var.register_ha
  replication_policy_on   = try(local.replication_policy_on_by_vmid[tostring(local.app_grafana.environments.dev.vmid)], null)
  pdns_api_key            = var.pdns_api_key
  acme_server_url         = local.dev_acme_url
  extra_ca_cert           = local.dev_extra_ca_cert
  pdns_api_servers        = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  grafana_admin_password  = var.grafana_admin_password
  grafana_influxdb_token  = var.grafana_influxdb_token
  domain                  = local.domain
  ip_address              = try(local.app_grafana.environments.dev.ip, null)
  gateway                 = local.config.environments.dev.gateway
  dns_servers             = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain           = "dev.${local.domain}"
  vault_approle_role_id   = var.vault_approle_grafana_dev_role_id
  vault_approle_secret_id = var.vault_approle_grafana_dev_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.grafana_dev.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.grafana_dev.public, "")
}

module "grafana_prod" {
  source = "../../catalog/grafana"

  count = try(local.app_grafana.enabled, false) ? 1 : 0

  vm_id                   = try(local.app_grafana.environments.prod.vmid, null)
  environment             = "prod"
  target_node             = try(local.app_grafana.node, null)
  all_node_names          = local.node_names
  vlan_id                 = local.config.environments.prod.vlan_id
  mac_address             = try(local.app_grafana.environments.prod.mac, null)
  image                   = "local:iso/${var.image_versions["grafana"]}"
  ssh_pubkey              = var.ssh_pubkey
  operator_ssh_pubkey     = local.operator_ssh_pubkey
  storage_pool            = local.config.proxmox.storage_pool
  tags                    = try(local.app_grafana.enabled, false) ? ["pool-${local.app_grafana.environments.prod.pool}"] : []
  ram_mb                  = coalesce(try(local.app_grafana.ram, null), 1024)
  vda_size_gb             = coalesce(try(local.app_grafana.disk_size, null), 8)
  vdb_size_gb             = coalesce(try(local.app_grafana.data_disk_size, null), 4)
  start_vms               = var.start_vms
  register_ha             = var.register_ha
  replication_policy_on   = try(local.replication_policy_on_by_vmid[tostring(local.app_grafana.environments.prod.vmid)], null)
  pdns_api_key            = var.pdns_api_key
  acme_server_url         = local.prod_acme_url
  extra_ca_cert           = ""
  pdns_api_servers        = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  grafana_admin_password  = var.grafana_admin_password
  grafana_influxdb_token  = var.grafana_influxdb_token
  domain                  = local.domain
  ip_address              = try(local.app_grafana.environments.prod.ip, null)
  gateway                 = local.config.environments.prod.gateway
  dns_servers             = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain           = "prod.${local.domain}"
  vault_approle_role_id   = var.vault_approle_grafana_prod_role_id
  vault_approle_secret_id = var.vault_approle_grafana_prod_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.grafana_prod.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.grafana_prod.public, "")
}

# --- Roon Server (both environments) ---

module "roon_dev" {
  source = "../../catalog/roon"

  count = try(local.app_roon.enabled, false) ? 1 : 0

  vm_id                 = try(local.app_roon.environments.dev.vmid, null)
  environment           = "dev"
  target_node           = try(local.app_roon.environments.dev.node, null)
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.dev.vlan_id
  mac_address           = try(local.app_roon.environments.dev.mac, null)
  image                 = "local:iso/${var.image_versions["roon"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = try(local.app_roon.enabled, false) ? ["pool-${local.app_roon.environments.dev.pool}"] : []
  ram_mb                = coalesce(try(local.app_roon.ram, null), 4096)
  vda_size_gb           = coalesce(try(local.app_roon.disk_size, null), 4)
  vdb_size_gb           = coalesce(try(local.app_roon.data_disk_size, null), 50)
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.app_roon.environments.dev.vmid)], null)
  domain                = local.domain
  extra_ca_cert         = local.dev_extra_ca_cert
  ip_address            = try(local.app_roon.environments.dev.ip, null)
  gateway             = local.config.environments.dev.gateway
  dns_servers         = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain       = "dev.${local.domain}"
  mgmt_nic = try(local.app_roon.environments.dev.mgmt_nic != null ? {
    ip          = try(local.app_roon.environments.dev.mgmt_nic.ip, null)
    mac_address = try(local.app_roon.environments.dev.mgmt_nic.mac, null)
  } : null, null)

  mounts = try(local.app_roon.mounts, [])

  ssh_host_key_private = try(local.ssh_host_keys.roon_dev.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.roon_dev.public, "")
}

module "roon_prod" {
  source = "../../catalog/roon"

  count = try(local.app_roon.enabled, false) ? 1 : 0

  vm_id                 = try(local.app_roon.environments.prod.vmid, null)
  environment           = "prod"
  target_node           = try(local.app_roon.environments.prod.node, null)
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.prod.vlan_id
  mac_address           = try(local.app_roon.environments.prod.mac, null)
  image                 = "local:iso/${var.image_versions["roon"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = try(local.app_roon.enabled, false) ? ["pool-${local.app_roon.environments.prod.pool}"] : []
  ram_mb                = coalesce(try(local.app_roon.ram, null), 4096)
  vda_size_gb           = coalesce(try(local.app_roon.disk_size, null), 4)
  vdb_size_gb           = coalesce(try(local.app_roon.data_disk_size, null), 50)
  start_vms             = var.start_vms
  register_ha           = var.register_ha
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.app_roon.environments.prod.vmid)], null)
  domain                = local.domain
  extra_ca_cert         = ""
  ip_address            = try(local.app_roon.environments.prod.ip, null)
  gateway             = local.config.environments.prod.gateway
  dns_servers         = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain       = "prod.${local.domain}"
  mgmt_nic = try(local.app_roon.environments.prod.mgmt_nic != null ? {
    ip          = try(local.app_roon.environments.prod.mgmt_nic.ip, null)
    mac_address = try(local.app_roon.environments.prod.mgmt_nic.mac, null)
  } : null, null)

  mounts = try(local.app_roon.mounts, [])

  ssh_host_key_private = try(local.ssh_host_keys.roon_prod.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.roon_prod.public, "")
}

# --- Workstation (both environments) ---

module "workstation_dev" {
  source = "../../catalog/workstation"

  count = try(local.app_workstation.enabled, false) ? 1 : 0

  vm_id                 = try(local.app_workstation.environments.dev.vmid, null)
  environment           = "dev"
  target_node           = try(local.app_workstation.environments.dev.node, try(local.app_workstation.node, null))
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.dev.vlan_id
  mac_address           = try(local.app_workstation.environments.dev.mac, null)
  image                 = "local:iso/${var.image_versions["workstation"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = try(local.app_workstation.enabled, false) ? ["pool-${local.app_workstation.environments.dev.pool}"] : []
  ram_mb                = coalesce(try(local.app_workstation.ram_dev, null), try(local.app_workstation.ram, null), 4096)
  cores                 = coalesce(try(local.app_workstation.cpus_dev, null), try(local.app_workstation.cores, null), 2)
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.app_workstation.environments.dev.vmid)], null)
  # vda_size_gb: 16 GB fallback (not null). OpenTofu does not coerce explicit
  # null to a variable's default — null propagates through nested module
  # variables to the proxmox provider, which rejects it ("shrinking disks
  # is not supported"). coalesce() also defends against an explicit
  # disk_size: null in applications.yaml. See issue #276 / Pipeline 710.
  vda_size_gb         = coalesce(try(local.app_workstation.disk_size, null), 16)
  vdb_size_gb         = coalesce(try(local.app_workstation.data_disk_size_dev, null), try(local.app_workstation.data_disk_size, null), 80)
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  username            = try(local.app_workstation.username, null)
  shell               = try(local.app_workstation.shell, null)
  user_ssh_public_key = try(local.app_workstation.ssh_public_key, null)
  pdns_api_key        = var.pdns_api_key
  acme_server_url     = local.dev_acme_url
  extra_ca_cert       = local.dev_extra_ca_cert
  pdns_api_servers    = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  domain              = local.domain
  ip_address          = try(local.app_workstation.environments.dev.ip, null)
  gateway             = local.config.environments.dev.gateway
  dns_servers         = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain       = "dev.${local.domain}"
  mgmt_nic = try(local.app_workstation.environments.dev.mgmt_nic != null ? {
    ip          = try(local.app_workstation.environments.dev.mgmt_nic.ip, null)
    mac_address = try(local.app_workstation.environments.dev.mgmt_nic.mac, null)
  } : null, null)
  tailscale_auth_key = var.tailscale_auth_key

  vault_approle_role_id   = var.vault_approle_workstation_dev_role_id
  vault_approle_secret_id = var.vault_approle_workstation_dev_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.workstation_dev.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.workstation_dev.public, "")
}

module "workstation_prod" {
  source = "../../catalog/workstation"

  count = try(local.app_workstation.enabled, false) ? 1 : 0

  vm_id                 = try(local.app_workstation.environments.prod.vmid, null)
  environment           = "prod"
  target_node           = try(local.app_workstation.environments.prod.node, try(local.app_workstation.node, null))
  all_node_names        = local.node_names
  vlan_id               = local.config.environments.prod.vlan_id
  mac_address           = try(local.app_workstation.environments.prod.mac, null)
  image                 = "local:iso/${var.image_versions["workstation"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  storage_pool          = local.config.proxmox.storage_pool
  tags                  = try(local.app_workstation.enabled, false) ? ["pool-${local.app_workstation.environments.prod.pool}"] : []
  ram_mb                = coalesce(try(local.app_workstation.ram_prod, null), try(local.app_workstation.ram, null), 4096)
  cores                 = coalesce(try(local.app_workstation.cpus_prod, null), try(local.app_workstation.cores, null), 2)
  replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.app_workstation.environments.prod.vmid)], null)
  # See issue #276 — null fallback would propagate to the provider; coalesce
  # also defends against explicit disk_size: null in applications.yaml.
  vda_size_gb         = coalesce(try(local.app_workstation.disk_size, null), 16)
  vdb_size_gb         = coalesce(try(local.app_workstation.data_disk_size_prod, null), try(local.app_workstation.data_disk_size, null), 80)
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  username            = try(local.app_workstation.username, null)
  shell               = try(local.app_workstation.shell, null)
  user_ssh_public_key = try(local.app_workstation.ssh_public_key, null)
  pdns_api_key        = var.pdns_api_key
  acme_server_url     = local.prod_acme_url
  extra_ca_cert       = ""
  pdns_api_servers    = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain              = local.domain
  ip_address          = try(local.app_workstation.environments.prod.ip, null)
  gateway             = local.config.environments.prod.gateway
  dns_servers         = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain       = "prod.${local.domain}"
  mgmt_nic = try(local.app_workstation.environments.prod.mgmt_nic != null ? {
    ip          = try(local.app_workstation.environments.prod.mgmt_nic.ip, null)
    mac_address = try(local.app_workstation.environments.prod.mgmt_nic.mac, null)
  } : null, null)
  tailscale_auth_key = var.tailscale_auth_key

  vault_approle_role_id   = var.vault_approle_workstation_prod_role_id
  vault_approle_secret_id = var.vault_approle_workstation_prod_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.workstation_prod.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.workstation_prod.public, "")
}

# --- Precious-state sizing preconditions (#557) ---
#
# G11 (#42 + #280) replaced `try(<field>, null)` with `coalesce(try(<field>,
# null), <catalog-default>)` at every sizing site above. That closed the
# null-cascade footgun (which crashed the plan for ALL VMs when a single
# YAML field was missing), but it converted a loud crash into a silent
# default-substitution: an operator who removes a sizing field from
# site/applications.yaml on an enabled application VM with `backup: true`
# now gets the catalog default silently instead of the loud crash.
#
# For a fresh deploy or a newly-enabled precious VM, that silent-default
# behavior is a regression — the operator's intended sizing is gone from
# the config but the deploy still proceeds, allocating a smaller disk (or
# smaller RAM) than intended. For an already-provisioned VM, the proxmox
# provider's downstream "shrinking disks is not supported" error catches
# the accidental shrink, but that safety net does not exist on first
# deploy.
#
# These `terraform_data` resources guard against that regression with a
# plan-time precondition on each precious-state sizing field. `count = 0`
# when the application is disabled OR when `backup: false`, so the check
# is a no-op unless the operator has explicitly opted into
# precious-state semantics. The preconditions fail loudly (G4: checks
# have teeth) with a named error message that tells the operator which
# field to set and which file to edit.
#
# `workstation` uses env-suffixed sizing (`ram_dev` / `ram_prod` /
# `data_disk_size_dev` / `data_disk_size_prod`) with a fallback to the
# base field (`ram` / `data_disk_size`); the guards accept EITHER form
# per environment, matching the coalesce chain in the workstation
# module blocks above. On the workstation guard, `disk_size` (which
# maps to `vda_size_gb`) is intentionally NOT checked: workstation's
# applications.yaml convention omits `disk_size` entirely, and vda is
# ephemeral (rebuilt from image on every deploy) so a silent default
# would not risk data loss. `influxdb` and `roon` DO guard
# `disk_size` because issue #557 explicitly asks for that field and a
# typo (`disc_size:` vs `disk_size:`) would silently miss the operator's
# intent even though vda is ephemeral.
#
# For an operator who deliberately wants the catalog default: remove
# `backup: true` from the app entry in applications.yaml. The guard
# reads the desire to persist the app's data as the desire to size it
# deliberately.
#
# `terraform_data` is a built-in OpenTofu resource that holds no
# external state and takes no action on apply; its precondition is the
# only observable behavior. It appears once in the plan as a
# to-be-created resource on the first apply after the guard is
# introduced, then remains stable across future plans.
resource "terraform_data" "precious_sizing_influxdb" {
  count = (try(local.app_influxdb.enabled, false) && try(local.app_influxdb.backup, false)) ? 1 : 0

  lifecycle {
    precondition {
      condition     = try(local.app_influxdb.ram, null) != null
      error_message = "Precious-state app 'influxdb' is enabled with backup: true but 'ram' is not set in site/applications.yaml. Remove backup: true or set applications.influxdb.ram explicitly. A silent catalog default would change the deployed RAM size on a fresh deploy."
    }
    precondition {
      condition     = try(local.app_influxdb.disk_size, null) != null
      error_message = "Precious-state app 'influxdb' is enabled with backup: true but 'disk_size' is not set in site/applications.yaml. Set applications.influxdb.disk_size explicitly."
    }
    precondition {
      condition     = try(local.app_influxdb.data_disk_size, null) != null
      error_message = "Precious-state app 'influxdb' is enabled with backup: true but 'data_disk_size' is not set in site/applications.yaml. Set applications.influxdb.data_disk_size explicitly — a silent catalog default would allocate a smaller vdb than intended on a fresh deploy."
    }
  }
}

resource "terraform_data" "precious_sizing_roon" {
  count = (try(local.app_roon.enabled, false) && try(local.app_roon.backup, false)) ? 1 : 0

  lifecycle {
    precondition {
      condition     = try(local.app_roon.ram, null) != null
      error_message = "Precious-state app 'roon' is enabled with backup: true but 'ram' is not set in site/applications.yaml. Remove backup: true or set applications.roon.ram explicitly. A silent catalog default would halve the deployed RAM (current YAML: 8192; catalog default: 4096)."
    }
    precondition {
      condition     = try(local.app_roon.disk_size, null) != null
      error_message = "Precious-state app 'roon' is enabled with backup: true but 'disk_size' is not set in site/applications.yaml. Set applications.roon.disk_size explicitly."
    }
    precondition {
      condition     = try(local.app_roon.data_disk_size, null) != null
      error_message = "Precious-state app 'roon' is enabled with backup: true but 'data_disk_size' is not set in site/applications.yaml. Set applications.roon.data_disk_size explicitly — a silent catalog default would allocate a smaller vdb than intended on a fresh deploy."
    }
  }
}

resource "terraform_data" "precious_sizing_workstation" {
  count = (try(local.app_workstation.enabled, false) && try(local.app_workstation.backup, false)) ? 1 : 0

  lifecycle {
    # workstation uses env-suffixed sizing with a base-field fallback (see the
    # coalesce chains in module.workstation_dev / workstation_prod above).
    # The precondition mirrors that chain: at least one non-null value must
    # be reachable per environment.
    precondition {
      condition     = try(local.app_workstation.ram_dev, null) != null || try(local.app_workstation.ram, null) != null
      error_message = "Precious-state app 'workstation' is enabled with backup: true but neither 'ram_dev' nor 'ram' is set in site/applications.yaml. Set applications.workstation.ram_dev (env-specific) or applications.workstation.ram (base fallback) explicitly."
    }
    precondition {
      condition     = try(local.app_workstation.ram_prod, null) != null || try(local.app_workstation.ram, null) != null
      error_message = "Precious-state app 'workstation' is enabled with backup: true but neither 'ram_prod' nor 'ram' is set in site/applications.yaml. Set applications.workstation.ram_prod (env-specific) or applications.workstation.ram (base fallback) explicitly."
    }
    precondition {
      condition     = try(local.app_workstation.data_disk_size_dev, null) != null || try(local.app_workstation.data_disk_size, null) != null
      error_message = "Precious-state app 'workstation' is enabled with backup: true but neither 'data_disk_size_dev' nor 'data_disk_size' is set in site/applications.yaml. Set applications.workstation.data_disk_size_dev (env-specific) or applications.workstation.data_disk_size (base fallback) explicitly."
    }
    precondition {
      condition     = try(local.app_workstation.data_disk_size_prod, null) != null || try(local.app_workstation.data_disk_size, null) != null
      error_message = "Precious-state app 'workstation' is enabled with backup: true but neither 'data_disk_size_prod' nor 'data_disk_size' is set in site/applications.yaml. Set applications.workstation.data_disk_size_prod (env-specific) or applications.workstation.data_disk_size (base fallback) explicitly. A silent catalog default (80 GB) would allocate a smaller vdb than a workstation using data_disk_size_prod: 500 typically wants."
    }
  }
}

module "dns_dev" {
  source = "../modules/dns-pair"

  dns1_vm_id            = local.config.vms.dns1_dev.vmid
  dns2_vm_id            = local.config.vms.dns2_dev.vmid
  environment           = "dev"
  vlan_id               = local.config.environments.dev.vlan_id
  dns1_ip               = local.config.vms.dns1_dev.ip
  dns1_mac              = local.config.vms.dns1_dev.mac
  dns2_ip               = local.config.vms.dns2_dev.ip
  dns2_mac              = local.config.vms.dns2_dev.mac
  node_names            = local.node_names
  image                 = "local:iso/${var.image_versions["dns"]}"
  ssh_pubkey            = var.ssh_pubkey
  operator_ssh_pubkey   = local.operator_ssh_pubkey
  pdns_api_key          = var.pdns_api_key
  storage_pool          = local.config.proxmox.storage_pool
  dns1_tags             = ["pool-${local.config.vms.dns1_dev.pool}"]
  dns2_tags             = ["pool-${local.config.vms.dns2_dev.pool}"]
  start_vms                  = var.start_vms
  register_ha                = var.register_ha
  dns1_replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.dns1_dev.vmid)], null)
  dns2_replication_policy_on = try(local.replication_policy_on_by_vmid[tostring(local.config.vms.dns2_dev.vmid)], null)
  acme_server_url            = local.dev_acme_url
  extra_ca_cert       = local.dev_extra_ca_cert
  gateway_ip          = local.config.environments.dev.gateway
  dns_domain          = local.dev_domain
  zone_data           = local.dev_zone_data
  domain              = local.domain
  dns_servers         = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain       = "dev.${local.domain}"

  dns1_vault_approle_role_id   = var.vault_approle_dns1_dev_role_id
  dns1_vault_approle_secret_id = var.vault_approle_dns1_dev_secret_id
  dns2_vault_approle_role_id   = var.vault_approle_dns2_dev_role_id
  dns2_vault_approle_secret_id = var.vault_approle_dns2_dev_secret_id

  dns1_ssh_host_key_private = try(local.ssh_host_keys.dns1_dev.private, "")
  dns1_ssh_host_key_public  = try(local.ssh_host_keys.dns1_dev.public, "")
  dns2_ssh_host_key_private = try(local.ssh_host_keys.dns2_dev.private, "")
  dns2_ssh_host_key_public  = try(local.ssh_host_keys.dns2_dev.public, "")
}
