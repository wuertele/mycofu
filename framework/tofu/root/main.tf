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
  _raw_apps    = try(local.config.applications, null)
  applications = local._raw_apps != null ? local._raw_apps : tomap({})

  # ACME URL for prod VMs — derived from config.yaml acme mode
  acme_mode = try(local.config.acme, "production")
  prod_acme_url = local.acme_mode == "staging" ? (
    "https://acme-staging-v02.api.letsencrypt.org/directory"
  ) : (
    "https://acme-v02.api.letsencrypt.org/directory"
  )

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
  app_influxdb = try(local.applications.influxdb, {})
  app_grafana  = try(local.applications.grafana, {})
  app_roon     = try(local.applications.roon, {})
}

# PowerDNS API key from SOPS secrets (exported as TF_VAR_pdns_api_key by tofu-wrapper.sh)
variable "pdns_api_key" {
  description = "PowerDNS API key (from SOPS via TF_VAR_pdns_api_key)"
  type        = string
  sensitive   = true
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

# --- Pebble ACME test server (dev only) ---

module "pebble" {
  source = "../modules/pebble"

  vm_id          = local.config.vms.pebble.vmid
  target_node    = local.node_names[2]
  all_node_names = local.node_names
  vlan_id      = local.config.environments.dev.vlan_id
  mac_address  = local.config.vms.pebble.mac
  image        = "local:iso/${var.image_versions["pebble"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool = local.config.proxmox.storage_pool
  dns_server   = local.config.vms.dns1_dev.ip
  domain       = local.domain
  ip_address     = local.config.vms.pebble.ip
  gateway        = local.config.environments.dev.gateway
  dns_servers    = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain  = "dev.${local.domain}"
}

# --- DNS VM pairs ---

module "dns_prod" {
  source = "../modules/dns-pair"

  dns1_vm_id      = local.config.vms.dns1_prod.vmid
  dns2_vm_id      = local.config.vms.dns2_prod.vmid
  environment     = "prod"
  vlan_id         = local.config.environments.prod.vlan_id
  dns1_ip         = local.config.vms.dns1_prod.ip
  dns1_mac        = local.config.vms.dns1_prod.mac
  dns2_ip         = local.config.vms.dns2_prod.ip
  dns2_mac        = local.config.vms.dns2_prod.mac
  node_names      = local.node_names
  image           = "local:iso/${var.image_versions["dns"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  pdns_api_key    = var.pdns_api_key
  storage_pool    = local.config.proxmox.storage_pool
  acme_server_url = local.prod_acme_url
  acme_ca_cert    = ""
  gateway_ip      = local.config.environments.prod.gateway
  dns_domain      = local.prod_domain
  zone_data       = local.prod_zone_data
  domain          = local.domain
  dns_servers     = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain   = "prod.${local.domain}"
}

# --- Vault ---

module "vault_prod" {
  source = "../modules/vault"

  vm_id           = local.config.vms.vault_prod.vmid
  environment     = "prod"
  target_node     = local.node_names[2]
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.prod.vlan_id
  mac_address     = local.config.vms.vault_prod.mac
  image           = "local:iso/${var.image_versions["vault"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  vdb_size_gb     = 10
  pdns_api_key    = var.pdns_api_key
  acme_server_url = local.prod_acme_url
  acme_ca_cert    = ""
  pdns_api_servers = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain           = local.domain
  ip_address       = local.config.vms.vault_prod.ip
  gateway          = local.config.environments.prod.gateway
  dns_servers      = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain    = "prod.${local.domain}"
}

module "vault_dev" {
  source = "../modules/vault"

  vm_id           = local.config.vms.vault_dev.vmid
  environment     = "dev"
  target_node     = local.node_names[2]
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.dev.vlan_id
  mac_address     = local.config.vms.vault_dev.mac
  image           = "local:iso/${var.image_versions["vault"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  vdb_size_gb     = 10
  pdns_api_key    = var.pdns_api_key
  acme_server_url = "https://${local.config.vms.pebble.ip}:14000/dir"
  acme_ca_cert    = file("${path.module}/../../pebble/pebble-ca.pem")
  pdns_api_servers = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  domain           = local.domain
  ip_address       = local.config.vms.vault_dev.ip
  gateway          = local.config.environments.dev.gateway
  dns_servers      = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain    = "dev.${local.domain}"
}

# --- PBS (Proxmox Backup Server) ---

module "pbs" {
  source = "../modules/pbs"

  vm_id        = local.config.vms.pbs.vmid
  target_node  = local.node_names[2]
  # No vlan_id — PBS is on the management network (native/untagged VLAN).
  # Shared operational services (PBS, GitLab, CI/CD, Gatus) live on the management
  # network because their clients are Proxmox nodes, not VMs.
  mac_address  = local.config.vms.pbs.mac
  iso_file     = ""  # Detached after PBS installation
  storage_pool = local.config.proxmox.storage_pool
}

# --- GitLab (management network) ---

module "gitlab" {
  source = "../modules/gitlab"

  vm_id           = local.config.vms.gitlab.vmid
  target_node     = local.node_names[2]
  all_node_names  = local.node_names
  mac_address     = local.config.vms.gitlab.mac
  image           = "local:iso/${var.image_versions["gitlab"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  vdb_size_gb     = 50
  external_url    = local.gitlab_url
  certbot_fqdn    = "gitlab.${local.prod_domain}"
  pdns_api_key    = var.pdns_api_key
  acme_server_url = local.prod_acme_url
  pdns_api_servers = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain           = local.domain
  ip_address       = local.config.vms.gitlab.ip
  gateway          = local.config.management.gateway
  dns_servers      = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain    = "prod.${local.domain}"
}

# --- GitLab Runner (management network) ---

module "cicd" {
  source = "../modules/cicd"

  vm_id              = local.config.vms.cicd.vmid
  target_node        = local.node_names[0]  # pve01 — needs headroom for builds
  all_node_names     = local.node_names
  mac_address        = local.config.vms.cicd.mac
  image              = "local:iso/${var.image_versions["cicd"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool       = local.config.proxmox.storage_pool
  cores              = local.config.cicd.runner_cores
  ram_mb             = local.config.cicd.runner_ram_mb
  gitlab_url         = local.gitlab_url
  sops_age_key       = var.sops_age_key
  ssh_privkey        = var.ssh_privkey
  domain             = local.domain
  ip_address         = local.config.vms.cicd.ip
  gateway            = local.config.management.gateway
  dns_servers        = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain      = "prod.${local.domain}"
}

# --- Gatus (prod VLAN) ---

module "gatus" {
  source = "../modules/gatus"

  vm_id           = local.config.vms.gatus.vmid
  target_node     = local.node_names[1]  # pve02 — underutilized
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.prod.vlan_id
  mac_address     = local.config.vms.gatus.mac
  image           = "local:iso/${var.image_versions["gatus"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  gatus_config    = fileexists("${path.module}/../../../site/gatus/config.yaml") ? file("${path.module}/../../../site/gatus/config.yaml") : ""
  pdns_api_key    = var.pdns_api_key
  acme_server_url = local.prod_acme_url
  pdns_api_servers = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain           = local.domain
  ip_address       = local.config.vms.gatus.ip
  gateway          = local.config.environments.prod.gateway
  dns_servers      = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain    = "prod.${local.domain}"
}

# --- Testapp (both environments) ---

module "testapp_dev" {
  source = "../modules/testapp"

  vm_id           = local.config.vms.testapp_dev.vmid
  environment     = "dev"
  target_node     = local.node_names[1]
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.dev.vlan_id
  mac_address     = local.config.vms.testapp_dev.mac
  image           = "local:iso/${var.image_versions["testapp"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  pdns_api_key    = var.pdns_api_key
  acme_server_url = "https://${local.config.vms.pebble.ip}:14000/dir"
  acme_ca_cert    = file("${path.module}/../../pebble/pebble-ca.pem")
  pdns_api_servers = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  domain           = local.domain
  ip_address       = local.config.vms.testapp_dev.ip
  gateway          = local.config.environments.dev.gateway
  dns_servers      = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain    = "dev.${local.domain}"
}

module "testapp_prod" {
  source = "../modules/testapp"

  vm_id           = local.config.vms.testapp_prod.vmid
  environment     = "prod"
  target_node     = local.node_names[1]
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.prod.vlan_id
  mac_address     = local.config.vms.testapp_prod.mac
  image           = "local:iso/${var.image_versions["testapp"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  pdns_api_key    = var.pdns_api_key
  acme_server_url = local.prod_acme_url
  acme_ca_cert    = ""
  pdns_api_servers = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  domain           = local.domain
  ip_address       = local.config.vms.testapp_prod.ip
  gateway          = local.config.environments.prod.gateway
  dns_servers      = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain    = "prod.${local.domain}"
}

# --- InfluxDB (both environments) ---

module "influxdb_dev" {
  source = "../../catalog/influxdb"

  count  = try(local.app_influxdb.enabled, false) ? 1 : 0

  vm_id           = try(local.app_influxdb.environments.dev.vmid, null)
  environment     = "dev"
  target_node     = try(local.app_influxdb.node, null)
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.dev.vlan_id
  mac_address     = try(local.app_influxdb.environments.dev.mac, null)
  image           = "local:iso/${var.image_versions["influxdb"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  ram_mb          = try(local.app_influxdb.ram, null)
  vdb_size_gb     = try(local.app_influxdb.data_disk_size, null)
  pdns_api_key    = var.pdns_api_key
  acme_server_url = "https://${local.config.vms.pebble.ip}:14000/dir"
  acme_ca_cert    = file("${path.module}/../../pebble/pebble-ca.pem")
  pdns_api_servers = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  influxdb_admin_token = var.influxdb_admin_token
  domain               = local.domain
  ip_address           = try(local.app_influxdb.environments.dev.ip, null)
  gateway              = local.config.environments.dev.gateway
  dns_servers          = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain        = "dev.${local.domain}"
}

module "influxdb_prod" {
  source = "../../catalog/influxdb"

  count  = try(local.app_influxdb.enabled, false) ? 1 : 0

  vm_id           = try(local.app_influxdb.environments.prod.vmid, null)
  environment     = "prod"
  target_node     = try(local.app_influxdb.node, null)
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.prod.vlan_id
  mac_address     = try(local.app_influxdb.environments.prod.mac, null)
  image           = "local:iso/${var.image_versions["influxdb"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  ram_mb          = try(local.app_influxdb.ram, null)
  vdb_size_gb     = try(local.app_influxdb.data_disk_size, null)
  pdns_api_key    = var.pdns_api_key
  acme_server_url = local.prod_acme_url
  acme_ca_cert    = ""
  pdns_api_servers = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  influxdb_admin_token = var.influxdb_admin_token
  domain               = local.domain
  ip_address           = try(local.app_influxdb.environments.prod.ip, null)
  gateway              = local.config.environments.prod.gateway
  dns_servers          = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain        = "prod.${local.domain}"
}

# --- Grafana (both environments) ---

module "grafana_dev" {
  source = "../../catalog/grafana"

  count  = try(local.app_grafana.enabled, false) ? 1 : 0

  vm_id           = try(local.app_grafana.environments.dev.vmid, null)
  environment     = "dev"
  target_node     = try(local.app_grafana.node, null)
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.dev.vlan_id
  mac_address     = try(local.app_grafana.environments.dev.mac, null)
  image           = "local:iso/${var.image_versions["grafana"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  ram_mb          = try(local.app_grafana.ram, null)
  vdb_size_gb     = try(local.app_grafana.data_disk_size, null)
  pdns_api_key    = var.pdns_api_key
  acme_server_url = "https://${local.config.vms.pebble.ip}:14000/dir"
  acme_ca_cert    = file("${path.module}/../../pebble/pebble-ca.pem")
  pdns_api_servers = "${local.config.vms.dns1_dev.ip}\n${local.config.vms.dns2_dev.ip}\n"
  grafana_admin_password = var.grafana_admin_password
  grafana_influxdb_token = var.grafana_influxdb_token
  domain                 = local.domain
  ip_address             = try(local.app_grafana.environments.dev.ip, null)
  gateway                = local.config.environments.dev.gateway
  dns_servers            = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain          = "dev.${local.domain}"
}

module "grafana_prod" {
  source = "../../catalog/grafana"

  count  = try(local.app_grafana.enabled, false) ? 1 : 0

  vm_id           = try(local.app_grafana.environments.prod.vmid, null)
  environment     = "prod"
  target_node     = try(local.app_grafana.node, null)
  all_node_names  = local.node_names
  vlan_id         = local.config.environments.prod.vlan_id
  mac_address     = try(local.app_grafana.environments.prod.mac, null)
  image           = "local:iso/${var.image_versions["grafana"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool    = local.config.proxmox.storage_pool
  ram_mb          = try(local.app_grafana.ram, null)
  vdb_size_gb     = try(local.app_grafana.data_disk_size, null)
  pdns_api_key    = var.pdns_api_key
  acme_server_url = local.prod_acme_url
  acme_ca_cert    = ""
  pdns_api_servers = "${local.config.vms.dns1_prod.ip}\n${local.config.vms.dns2_prod.ip}\n"
  grafana_admin_password = var.grafana_admin_password
  grafana_influxdb_token = var.grafana_influxdb_token
  domain                 = local.domain
  ip_address             = try(local.app_grafana.environments.prod.ip, null)
  gateway                = local.config.environments.prod.gateway
  dns_servers            = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain          = "prod.${local.domain}"
}

# --- Roon Server (both environments) ---

module "roon_dev" {
  source = "../../catalog/roon"

  count  = try(local.app_roon.enabled, false) ? 1 : 0

  vm_id          = try(local.app_roon.environments.dev.vmid, null)
  environment    = "dev"
  target_node    = try(local.app_roon.environments.dev.node, null)
  all_node_names = local.node_names
  vlan_id        = local.config.environments.dev.vlan_id
  mac_address    = try(local.app_roon.environments.dev.mac, null)
  image          = "local:iso/${var.image_versions["roon"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool   = local.config.proxmox.storage_pool
  ram_mb         = try(local.app_roon.ram, null)
  vdb_size_gb    = try(local.app_roon.data_disk_size, null)
  domain         = local.domain
  ip_address     = try(local.app_roon.environments.dev.ip, null)
  gateway        = local.config.environments.dev.gateway
  dns_servers    = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain  = "dev.${local.domain}"
  mgmt_nic = try(local.app_roon.environments.dev.mgmt_nic != null ? {
    ip          = try(local.app_roon.environments.dev.mgmt_nic.ip, null)
    mac_address = try(local.app_roon.environments.dev.mgmt_nic.mac, null)
  } : null, null)

  mounts = try(local.app_roon.mounts, [])
}

module "roon_prod" {
  source = "../../catalog/roon"

  count  = try(local.app_roon.enabled, false) ? 1 : 0

  vm_id          = try(local.app_roon.environments.prod.vmid, null)
  environment    = "prod"
  target_node    = try(local.app_roon.environments.prod.node, null)
  all_node_names = local.node_names
  vlan_id        = local.config.environments.prod.vlan_id
  mac_address    = try(local.app_roon.environments.prod.mac, null)
  image          = "local:iso/${var.image_versions["roon"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  storage_pool   = local.config.proxmox.storage_pool
  ram_mb         = try(local.app_roon.ram, null)
  vdb_size_gb    = try(local.app_roon.data_disk_size, null)
  domain         = local.domain
  ip_address     = try(local.app_roon.environments.prod.ip, null)
  gateway        = local.config.environments.prod.gateway
  dns_servers    = [local.config.vms.dns1_prod.ip, local.config.vms.dns2_prod.ip]
  search_domain  = "prod.${local.domain}"
  mgmt_nic = try(local.app_roon.environments.prod.mgmt_nic != null ? {
    ip          = try(local.app_roon.environments.prod.mgmt_nic.ip, null)
    mac_address = try(local.app_roon.environments.prod.mgmt_nic.mac, null)
  } : null, null)

  mounts = try(local.app_roon.mounts, [])
}

module "dns_dev" {
  source = "../modules/dns-pair"

  dns1_vm_id      = local.config.vms.dns1_dev.vmid
  dns2_vm_id      = local.config.vms.dns2_dev.vmid
  environment     = "dev"
  vlan_id         = local.config.environments.dev.vlan_id
  dns1_ip         = local.config.vms.dns1_dev.ip
  dns1_mac        = local.config.vms.dns1_dev.mac
  dns2_ip         = local.config.vms.dns2_dev.ip
  dns2_mac        = local.config.vms.dns2_dev.mac
  node_names      = local.node_names
  image           = "local:iso/${var.image_versions["dns"]}"
  ssh_pubkey           = var.ssh_pubkey
  operator_ssh_pubkey  = local.operator_ssh_pubkey
  pdns_api_key    = var.pdns_api_key
  storage_pool    = local.config.proxmox.storage_pool
  acme_server_url = "https://${local.config.vms.pebble.ip}:14000/dir"
  acme_ca_cert    = file("${path.module}/../../pebble/pebble-ca.pem")
  gateway_ip      = local.config.environments.dev.gateway
  dns_domain      = local.dev_domain
  zone_data       = local.dev_zone_data
  domain          = local.domain
  dns_servers     = [local.config.vms.dns1_dev.ip, local.config.vms.dns2_dev.ip]
  search_domain   = "dev.${local.domain}"
}
