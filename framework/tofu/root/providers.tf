# bpg/proxmox provider configuration.
# Credentials are provided via environment variables set by tofu-wrapper.sh:
#   PROXMOX_VE_ENDPOINT  — https://<node>:8006/
#   PROXMOX_VE_USERNAME  — root@pam (or API token user)
#   PROXMOX_VE_PASSWORD  — from SOPS
#   PROXMOX_VE_INSECURE  — true (self-signed cert)
#
# The provider reads these env vars natively — no credential fields needed here.

provider "proxmox" {
  ssh {
    agent    = true
    username = "root"
  }
}
