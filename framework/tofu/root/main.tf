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
  # Application VMs are in site/applications.yaml (separate from config.yaml)
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

  vm_id               = local.config.vms.acme_dev.vmid
  target_node         = local.config.vms.acme_dev.node
  all_node_names      = local.node_names
  vlan_id             = local.config.environments.dev.vlan_id
  mac_address         = local.config.vms.acme_dev.mac
  image               = "local:iso/${var.image_versions["acme-dev"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = ["pool-${local.config.vms.acme_dev.pool}"]
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  domain              = local.domain
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

  dns1_vm_id          = local.config.vms.dns1_prod.vmid
  dns2_vm_id          = local.config.vms.dns2_prod.vmid
  environment         = "prod"
  vlan_id             = local.config.environments.prod.vlan_id
  dns1_ip             = local.config.vms.dns1_prod.ip
  dns1_mac            = local.config.vms.dns1_prod.mac
  dns2_ip             = local.config.vms.dns2_prod.ip
  dns2_mac            = local.config.vms.dns2_prod.mac
  node_names          = local.node_names
  image               = "local:iso/${var.image_versions["dns"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  pdns_api_key        = var.pdns_api_key
  storage_pool        = local.config.proxmox.storage_pool
  dns1_tags           = ["pool-${local.config.vms.dns1_prod.pool}"]
  dns2_tags           = ["pool-${local.config.vms.dns2_prod.pool}"]
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  acme_server_url     = local.prod_acme_url
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

  vm_id               = local.config.vms.vault_prod.vmid
  environment         = "prod"
  target_node         = local.node_names[2]
  all_node_names      = local.node_names
  vlan_id             = local.config.environments.prod.vlan_id
  mac_address         = local.config.vms.vault_prod.mac
  image               = "local:iso/${var.image_versions["vault"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = ["pool-${local.config.vms.vault_prod.pool}"]
  vdb_size_gb         = 10
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  pdns_api_key        = var.pdns_api_key
  acme_server_url     = local.prod_acme_url
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

  vm_id               = local.config.vms.vault_dev.vmid
  environment         = "dev"
  target_node         = local.node_names[2]
  all_node_names      = local.node_names
  vlan_id             = local.config.environments.dev.vlan_id
  mac_address         = local.config.vms.vault_dev.mac
  image               = "local:iso/${var.image_versions["vault"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = ["pool-${local.config.vms.vault_dev.pool}"]
  vdb_size_gb         = 10
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  pdns_api_key        = var.pdns_api_key
  acme_server_url     = local.dev_acme_url
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
  mac_address  = local.config.vms.pbs.mac
  iso_file     = "" # Detached after PBS installation
  storage_pool = local.config.proxmox.storage_pool
  tags         = ["pool-${local.config.vms.pbs.pool}"]
}

# --- GitLab (management network) ---

module "gitlab" {
  source = "../modules/gitlab"

  vm_id               = local.config.vms.gitlab.vmid
  target_node         = local.node_names[2]
  all_node_names      = local.node_names
  mac_address         = local.config.vms.gitlab.mac
  image               = "local:iso/${var.image_versions["gitlab"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = ["pool-${local.config.vms.gitlab.pool}"]
  vdb_size_gb         = 50
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  external_url        = local.gitlab_url
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

  vm_id               = local.config.vms.cicd.vmid
  target_node         = local.node_names[0] # pve01 — needs headroom for builds
  all_node_names      = local.node_names
  mac_address         = local.config.vms.cicd.mac
  image               = "local:iso/${var.image_versions["cicd"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = ["pool-${local.config.vms.cicd.pool}"]
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  cores               = local.config.cicd.runner_cores
  ram_mb              = local.config.cicd.runner_ram_mb
  gitlab_url          = local.gitlab_url
  github_remote_url   = local.github_remote_url
  sops_age_key        = var.sops_age_key
  ssh_privkey         = var.ssh_privkey
  domain              = local.domain
  ip_address          = local.config.vms.cicd.ip
  gateway             = local.config.management.gateway
  dns_servers         = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain       = "prod.${local.domain}"

  vault_approle_role_id   = var.vault_approle_cicd_role_id
  vault_approle_secret_id = var.vault_approle_cicd_secret_id

  ssh_host_key_private = try(local.ssh_host_keys.cicd.private, "")
  ssh_host_key_public  = try(local.ssh_host_keys.cicd.public, "")
}

# --- Gatus (prod VLAN) ---

module "gatus" {
  source = "../modules/gatus"

  vm_id               = local.config.vms.gatus.vmid
  target_node         = local.node_names[1] # pve02 — underutilized
  all_node_names      = local.node_names
  vlan_id             = local.config.environments.prod.vlan_id
  mac_address         = local.config.vms.gatus.mac
  image               = "local:iso/${var.image_versions["gatus"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = ["pool-${local.config.vms.gatus.pool}"]
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  gatus_config        = fileexists("${path.module}/../../../site/gatus/config.yaml") ? file("${path.module}/../../../site/gatus/config.yaml") : ""
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
  ram_mb                = try(local.app_influxdb.ram, null)
  vdb_size_gb           = try(local.app_influxdb.data_disk_size, null)
  start_vms             = var.start_vms
  register_ha           = var.register_ha
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
  ram_mb                = try(local.app_influxdb.ram, null)
  vdb_size_gb           = try(local.app_influxdb.data_disk_size, null)
  start_vms             = var.start_vms
  register_ha           = var.register_ha
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
  ram_mb                  = try(local.app_grafana.ram, null)
  vdb_size_gb             = try(local.app_grafana.data_disk_size, null)
  start_vms               = var.start_vms
  register_ha             = var.register_ha
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
  ram_mb                  = try(local.app_grafana.ram, null)
  vdb_size_gb             = try(local.app_grafana.data_disk_size, null)
  start_vms               = var.start_vms
  register_ha             = var.register_ha
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

  vm_id               = try(local.app_roon.environments.dev.vmid, null)
  environment         = "dev"
  target_node         = try(local.app_roon.environments.dev.node, null)
  all_node_names      = local.node_names
  vlan_id             = local.config.environments.dev.vlan_id
  mac_address         = try(local.app_roon.environments.dev.mac, null)
  image               = "local:iso/${var.image_versions["roon"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = try(local.app_roon.enabled, false) ? ["pool-${local.app_roon.environments.dev.pool}"] : []
  ram_mb              = try(local.app_roon.ram, null)
  vdb_size_gb         = try(local.app_roon.data_disk_size, null)
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  domain              = local.domain
  extra_ca_cert       = local.dev_extra_ca_cert
  ip_address          = try(local.app_roon.environments.dev.ip, null)
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

  vm_id               = try(local.app_roon.environments.prod.vmid, null)
  environment         = "prod"
  target_node         = try(local.app_roon.environments.prod.node, null)
  all_node_names      = local.node_names
  vlan_id             = local.config.environments.prod.vlan_id
  mac_address         = try(local.app_roon.environments.prod.mac, null)
  image               = "local:iso/${var.image_versions["roon"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = try(local.app_roon.enabled, false) ? ["pool-${local.app_roon.environments.prod.pool}"] : []
  ram_mb              = try(local.app_roon.ram, null)
  vdb_size_gb         = try(local.app_roon.data_disk_size, null)
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  domain              = local.domain
  extra_ca_cert       = ""
  ip_address          = try(local.app_roon.environments.prod.ip, null)
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

  vm_id               = try(local.app_workstation.environments.dev.vmid, null)
  environment         = "dev"
  target_node         = try(local.app_workstation.environments.dev.node, try(local.app_workstation.node, null))
  all_node_names      = local.node_names
  vlan_id             = local.config.environments.dev.vlan_id
  mac_address         = try(local.app_workstation.environments.dev.mac, null)
  image               = "local:iso/${var.image_versions["workstation"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = try(local.app_workstation.enabled, false) ? ["pool-${local.app_workstation.environments.dev.pool}"] : []
  ram_mb              = try(local.app_workstation.ram_dev, try(local.app_workstation.ram, null))
  cores               = try(local.app_workstation.cpus_dev, try(local.app_workstation.cores, null))
  # vda_size_gb: 16 GB fallback (not null). OpenTofu does not coerce explicit
  # null to a variable's default — null propagates through nested module
  # variables to the proxmox provider, which rejects it ("shrinking disks
  # is not supported"). coalesce() also defends against an explicit
  # disk_size: null in applications.yaml. See issue #276 / Pipeline 710.
  vda_size_gb         = coalesce(try(local.app_workstation.disk_size, null), 16)
  vdb_size_gb         = try(local.app_workstation.data_disk_size_dev, try(local.app_workstation.data_disk_size, null))
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

  vm_id               = try(local.app_workstation.environments.prod.vmid, null)
  environment         = "prod"
  target_node         = try(local.app_workstation.environments.prod.node, try(local.app_workstation.node, null))
  all_node_names      = local.node_names
  vlan_id             = local.config.environments.prod.vlan_id
  mac_address         = try(local.app_workstation.environments.prod.mac, null)
  image               = "local:iso/${var.image_versions["workstation"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  storage_pool        = local.config.proxmox.storage_pool
  tags                = try(local.app_workstation.enabled, false) ? ["pool-${local.app_workstation.environments.prod.pool}"] : []
  ram_mb              = try(local.app_workstation.ram_prod, try(local.app_workstation.ram, null))
  cores               = try(local.app_workstation.cpus_prod, try(local.app_workstation.cores, null))
  # See issue #276 — null fallback would propagate to the provider; coalesce
  # also defends against explicit disk_size: null in applications.yaml.
  vda_size_gb         = coalesce(try(local.app_workstation.disk_size, null), 16)
  vdb_size_gb         = try(local.app_workstation.data_disk_size_prod, try(local.app_workstation.data_disk_size, null))
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

module "dns_dev" {
  source = "../modules/dns-pair"

  dns1_vm_id          = local.config.vms.dns1_dev.vmid
  dns2_vm_id          = local.config.vms.dns2_dev.vmid
  environment         = "dev"
  vlan_id             = local.config.environments.dev.vlan_id
  dns1_ip             = local.config.vms.dns1_dev.ip
  dns1_mac            = local.config.vms.dns1_dev.mac
  dns2_ip             = local.config.vms.dns2_dev.ip
  dns2_mac            = local.config.vms.dns2_dev.mac
  node_names          = local.node_names
  image               = "local:iso/${var.image_versions["dns"]}"
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = local.operator_ssh_pubkey
  pdns_api_key        = var.pdns_api_key
  storage_pool        = local.config.proxmox.storage_pool
  dns1_tags           = ["pool-${local.config.vms.dns1_dev.pool}"]
  dns2_tags           = ["pool-${local.config.vms.dns2_dev.pool}"]
  start_vms           = var.start_vms
  register_ha         = var.register_ha
  acme_server_url     = local.dev_acme_url
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
