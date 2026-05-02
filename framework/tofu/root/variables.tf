# Image versions are populated automatically by framework/scripts/build-image.sh.
# Reference images in main.tf as: "local:iso/${var.image_versions["rolename"]}"
#
# Do NOT add per-role variables here — the map grows automatically when
# build-image.sh is run for a new role. No variables.tf edits needed.
variable "image_versions" {
  type        = map(string)
  description = "Map of role name to image filename. Populated by build-image.sh."
  default     = {}
}

variable "sops_age_key" {
  description = "SOPS age private key for runner secret decryption (read from operator.age.key)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_privkey" {
  description = "SSH private key for runner node access (from SOPS)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "start_vms" {
  description = "Whether OpenTofu should start managed NixOS VMs."
  type        = bool
  default     = true
}

variable "register_ha" {
  description = "Whether OpenTofu should register VM HA resources."
  type        = bool
  default     = true
}

# acme_server_url_prod removed — now derived from config.yaml acme field
# in locals block of main.tf
