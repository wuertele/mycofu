# PostgreSQL state backend on NAS.
# conn_str is provided via PG_CONN_STR environment variable,
# set by framework/scripts/tofu-wrapper.sh from SOPS secrets.
# Do NOT use -backend-config for conn_str — it causes hash mismatches.

terraform {
  backend "pg" {
    schema_name = "prod"
  }
}
