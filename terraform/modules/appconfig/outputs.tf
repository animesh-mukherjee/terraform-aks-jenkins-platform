# Terraform concept: App Configuration exposes two pairs of keys — read and
# write — each with a primary and secondary (for rotation without downtime).
# The sample app only needs the read key; Jenkins pipelines that push config
# updates during a deploy stage need the write key.
# Both are marked sensitive = true because they grant programmatic access to
# the store's data plane (create/update/delete keys).

output "store_id" {
  description = "Full Azure resource ID of the App Configuration store. Used by downstream modules that reference the store as a dependency."
  value       = azurerm_app_configuration.this.id
}

output "store_name" {
  description = "Short name of the App Configuration store (e.g. \"appcfg-<prefix>-<suffix>\"). Used in Azure Portal navigation and `az appconfig` CLI commands."
  value       = azurerm_app_configuration.this.name
}

# Terraform concept: `endpoint` is the HTTPS base URL of the store's data
# plane (e.g. https://appcfg-xxx.azconfig.io). The App Configuration SDK
# constructor accepts either the endpoint + a credential, or a full
# connection string. The endpoint form is preferred in production because it
# works with Managed Identity auth (no secret needed); the connection string
# form is simpler for local development and the KK playground.
output "endpoint" {
  description = "HTTPS endpoint of the App Configuration store (e.g. \"https://appcfg-<prefix>-<suffix>.azconfig.io\"). Used by the App Configuration SDK when authenticating with a Managed Identity (preferred in production). Also displayed in the Azure Portal overview pane."
  value       = azurerm_app_configuration.this.endpoint
}

output "primary_read_connection_string" {
  description = "Connection string for the store's primary read key. Grants read-only access to all key-values and feature flags. Inject this into the sample app's K8s Secret so it can pull config at startup. Sensitive — treat like a password."
  value       = azurerm_app_configuration.this.primary_read_key[0].connection_string
  sensitive   = true
}

output "primary_write_connection_string" {
  description = "Connection string for the store's primary write key. Grants read + write access to all keys. Used by Jenkins deploy stages that push environment-specific config changes. Sensitive — treat like a password."
  value       = azurerm_app_configuration.this.primary_write_key[0].connection_string
  sensitive   = true
}
